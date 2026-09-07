# Kiro CLI: official installer, the kiro-plugin checkout, and the MCP merge onto
# ~/.kiro/settings/mcp.json.
# An activation entry added here must also be named in health.nix's
# flakelabHealthCheck entryAfter list, or that check stops running last.
{
  lib,
  pkgs,
  flakelab,
  flakelabMcp,
  ...
}:
let
  inherit (flakelab)
    installKiro
    kiroPluginRepo
    kiroPlugin
    sshAgentPreamble
    sshDefer
    flakelabWarn
    flakelabDefer
    cloneKeyResolve
    sshKeys
    ;
  inherit (flakelabMcp) mcpServers;
in
{
  # No nixpkgs path, so the official binary goes into ~/.local/bin and its own
  # updater keeps it current.
  home.activation.installKiroCli = lib.hm.dag.entryAfter [ "writeBoundary" "flakelabWarnReset" ] (
    lib.optionalString installKiro ''
      export PATH="${
        lib.makeBinPath [
          pkgs.curl
          pkgs.bash
          pkgs.coreutils
          # The installer aborts without unzip, which the activation PATH lacks.
          pkgs.unzip
        ]
      }:$PATH"
      export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      # $DRY_RUN_CMD on every command that reaches the network or writes outside the
      # store, or `dry-activate` installs software instead of rehearsing.
      # TODO: the settings.json rewrites are still ungated; gate the final move.
      if [ ! -x "$HOME/.local/bin/kiro-cli" ]; then
        $DRY_RUN_CMD ${pkgs.bash}/bin/bash -c 'curl -fsSL https://cli.kiro.dev/install | bash' || \
          ${flakelabDefer} "kiro-cli not installed: its installer could not be fetched or run (offline?). Retry: flakelab update, or curl -fsSL https://cli.kiro.dev/install | bash"
      else
        # The CLI moves only through its own updater: there is no pinnable release
        # feed for Renovate to track, and a stale CLI must not fail activation.
        $DRY_RUN_CMD "$HOME/.local/bin/kiro-cli" update --non-interactive || \
          ${flakelabWarn} "kiro-cli not updated (offline?); it stays on its installed version."
      fi
    ''
  );

  # Clone kiro-plugin and install it into ~/.kiro via `make install-global`.
  # Cloned full: the operator commits from this checkout, so history-dependent tools
  # work without a follow-up `fetch --unshallow`.
  home.activation.kiroInstallGlobal =
    lib.hm.dag.entryAfter [ "writeBoundary" "flakelabWarnReset" "installKiroCli" ]
      (
        lib.optionalString (installKiro && kiroPluginRepo != null) ''
          export PATH="${
            lib.makeBinPath [
              pkgs.git
              pkgs.openssh
              pkgs.gnumake
              pkgs.coreutils
            ]
          }:$HOME/.local/bin:$PATH"
          ${sshAgentPreamble}
          ${cloneKeyResolve}
          if [ ! -d "${kiroPlugin}/.git" ]; then
            if [ -n "$_cloneKey" ]; then
              GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -i $_cloneKey" \
                $DRY_RUN_CMD git clone ${kiroPluginRepo} "${kiroPlugin}" || \
                ${sshDefer "kiro-plugin not cloned, so its agents/skills/steering are not installed. Either activation had no passphrase-unlocked ssh-agent key, or the host was unreachable. Log in interactively (the zsh hook loads the key), then run: flakelab update"}
            else
              # No key yet is the normal first-rebuild state: provisioning can only
              # seed ~/.ssh after this rebuild created the user, so defer rather than
              # let the health check fail that very rebuild.
              ${flakelabDefer} "kiro-plugin not cloned: none of ~/.ssh/{${lib.concatStringsSep "," sshKeys}} exists yet, so the clone was not attempted. Provisioning seeds a key after this rebuild; flakelab update then completes it."
            fi
          fi
          if [ -f "${kiroPlugin}/Makefile" ]; then
            $DRY_RUN_CMD make -C "${kiroPlugin}" install-global || \
              ${flakelabWarn} "'make install-global' failed; Kiro agents may be incomplete."
          fi
        ''
      );

  # Merge onto whatever the kiro-plugin repo installed, so that baseline survives and
  # our pins win where they overlap. Must run after kiroInstallGlobal.
  home.activation.kiroMcpMerge =
    lib.hm.dag.entryAfter
      [
        "writeBoundary"
        "flakelabWarnReset"
        "kiroInstallGlobal"
      ]
      ''
        export PATH="${
          lib.makeBinPath [
            pkgs.jq
            pkgs.coreutils
          ]
        }:$PATH"
        _mcp="$HOME/.kiro/settings/mcp.json"
        _override=${lib.escapeShellArg (builtins.toJSON { inherit mcpServers; })}
        _tmp="$(mktemp)"
        mkdir -p "$HOME/.kiro/settings"
        if [ ! -s "$_mcp" ]; then
          printf '%s\n' "$_override" > "$_tmp"
        elif jq --argjson ov "$_override" '. * $ov' "$_mcp" > "$_tmp" 2>/dev/null; then
          # jq's `*` takes the right-hand side for arrays and scalars, so our pinned
          # args override same-named entries from the plugin repo's baseline.
          :
        else
          ${flakelabWarn} "could not merge MCP overrides into $_mcp; leaving the kiro-plugin base intact."
          rm -f "$_tmp"
          _tmp=""
        fi
        if [ -n "$_tmp" ]; then
          $DRY_RUN_CMD install -m644 "$_tmp" "$_mcp"
          rm -f "$_tmp"
        fi
      '';
}
