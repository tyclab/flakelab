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

  # Servers whose definition is taken from the Claude marketplace clone instead of
  # from mcp.nix. Add one only after checking its plugin `.mcp.json` env block is
  # pure pass-through, since kiroMcpMerge drops that block -- see the comment there.
  marketplaceSingleSourced = [ "synology" ];
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
  #
  # A third layer sits on top: the Claude marketplace clone, whose plugins carry the
  # same `mcpServers` schema. Where a plugin defines a server this set already has,
  # the plugin's definition wins, so a pin lives in one place instead of being copied
  # into this file and drifting -- which is how the synology pin sat four months
  # stale. Restricting the merge to servers already present keeps the gating in Nix:
  # the marketplace can redefine what flakelab enabled, never add to it. Its `env`
  # blocks are dropped, because they hold `${VAR}` placeholders that Claude Code
  # expands and Kiro does not; every server here inherits those from the shell
  # instead. That is lossless only where the block is pure pass-through -- an entry
  # like `HA_URL = "''${HASS_URL}"` renames a variable, and dropping it would quietly
  # change what the server runs with -- so single-sourcing is opt-in per server
  # rather than applied to whatever the clone happens to contain. A missing clone
  # changes nothing: the definitions below stay as the fallback.
  home.activation.kiroMcpMerge =
    lib.hm.dag.entryAfter
      [
        "writeBoundary"
        "flakelabWarnReset"
        "kiroInstallGlobal"
        # The marketplace layer below reads a clone that installClaudePlugins
        # refreshes, so a switch would otherwise merge last switch's definitions.
        "installClaudePlugins"
      ]
      ''
        export PATH="${
          lib.makeBinPath [
            pkgs.jq
            pkgs.coreutils
            pkgs.findutils
          ]
        }:$PATH"
        _mcp="$HOME/.kiro/settings/mcp.json"
        _override=${lib.escapeShellArg (builtins.toJSON { inherit mcpServers; })}
        _tmp="$(mktemp)"
        mkdir -p "$HOME/.kiro/settings"

        # Server definitions from the Claude marketplace clone, keyed by server name.
        # The clone is runtime data read under the activation script's `set -eu -o
        # pipefail`, and it is absent on every first switch: installClaudePlugins
        # defers until provisioning has seeded a key. Unguarded, find's non-zero exit
        # on that absent root aborts the whole switch before the fallback applies.
        # An empty root leaves xargs nothing to run (-r), hence the '{}' default. A
        # manifest jq cannot read warns and keeps the definitions below instead of
        # aborting mid-entry; flakelabHealthCheck then names it.
        _marketRoot="$HOME/.claude/plugins/marketplaces"
        _market='{}'
        if [ -d "$_marketRoot" ]; then
          if ! _market="$(
            find "$_marketRoot" -mindepth 3 -maxdepth 4 \
                 -name .mcp.json -type f -print0 2>/dev/null \
              | xargs -0 -r jq -s 'reduce .[] as $f ({}; . * ($f.mcpServers // {}))
                                   | with_entries(.value |= del(.env))' 2>/dev/null
          )"; then
            ${flakelabWarn} "could not read the Claude marketplace MCP definitions under $_marketRoot; Kiro keeps flakelab's own definitions for those servers."
            _market='{}'
          fi
          [ -n "$_market" ] || _market='{}'
        fi

        # A first run has no file to merge onto; an empty object is that same merge
        # with nothing on the left, so the marketplace layer applies either way.
        _base="$_mcp"
        if [ ! -s "$_mcp" ]; then
          _base="$(mktemp)"
          printf '{}\n' > "$_base"
        fi

        if jq --argjson ov "$_override" --argjson mk "$_market" \
               --argjson single ${lib.escapeShellArg (builtins.toJSON marketplaceSingleSourced)} \
               '(. * $ov) as $base
                | $base
                | .mcpServers = ((.mcpServers // {})
                    * ($mk | with_entries(select(.key as $k
                        | ($k | in($base.mcpServers // {})) and ($single | index($k))))))' \
               "$_base" > "$_tmp" 2>/dev/null; then
          # jq's `*` takes the right-hand side for arrays and scalars, so our pinned
          # args override same-named entries from the plugin repo's baseline.
          :
        else
          ${flakelabWarn} "could not merge MCP overrides into $_mcp; leaving the kiro-plugin base intact."
          rm -f "$_tmp"
          _tmp=""
        fi
        [ "$_base" = "$_mcp" ] || rm -f "$_base"
        if [ -n "$_tmp" ]; then
          $DRY_RUN_CMD install -m644 "$_tmp" "$_mcp"
          rm -f "$_tmp"
        fi
      '';
}
