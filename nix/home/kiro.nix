# Kiro CLI: official installer, the kiro-plugin checkout, and the MCP merge
# onto ~/.kiro/settings/mcp.json.
#
# All three activation entries here are already named in health.nix's
# flakelabHealthCheck entryAfter list. Any entry added to this module must be
# appended there too (or use `lib.hm.dag.entryBefore [ "flakelabHealthCheck" ]`),
# or the health check stops being the last entry and reports on work that has
# not run yet.
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
    firstSshKey
    sshAgentPreamble
    sshDefer
    flakelabWarn
    flakelabDefer
    ;
  inherit (flakelabMcp) mcpServers;
in
{
  # kiro-cli has no nixpkgs path and is not on Homebrew (kiro.dev/docs/cli).
  # Install the official binary into ~/.local/bin (runs via programs.nix-ld),
  # then keep it current through its own updater. Opt-out via installKiro=false.
  home.activation.installKiroCli = lib.hm.dag.entryAfter [ "writeBoundary" "flakelabWarnReset" ] (
    lib.optionalString installKiro ''
      export PATH="${
        lib.makeBinPath [
          pkgs.curl
          pkgs.bash
          pkgs.coreutils
          # The installer hard-requires unzip on Linux — it aborts with
          # "Missing required dependencies: unzip" before downloading — and the
          # activation unit's PATH does not include the system profile.
          pkgs.unzip
        ]
      }:$PATH"
      export SSL_CERT_FILE="${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
      # $DRY_RUN_CMD, here and on every other command in these activations that
      # reaches the network or writes outside the store: Home Manager sets it to
      # `echo` under `nixos-rebuild dry-activate`, and empty otherwise. Ungated,
      # a dry run installed software, cloned repos and pinned a global npm — so
      # the one cheap rehearsal this repo has (a real provisioning test costs an
      # interop wipe) was the opposite of a rehearsal.
      #
      # Gated so far: both curl|bash installers, the kiro-cli self-update, the
      # kiro-plugin clone and its `make install-global`, the npm pin and the
      # Bitwarden endpoint. The settings.json rewrites are NOT yet gated; they
      # already write via tmpfile-then-move, so gating only the final move is the
      # remaining work, and lines like the `install -m644` below are the pattern.
      if [ ! -x "$HOME/.local/bin/kiro-cli" ]; then
        $DRY_RUN_CMD ${pkgs.bash}/bin/bash -c 'curl -fsSL https://cli.kiro.dev/install | bash' || \
          ${flakelabDefer} "kiro-cli not installed: its installer could not be fetched or run (offline?). Retry: flakelab update, or curl -fsSL https://cli.kiro.dev/install | bash"
      else
        # The guard above keeps the installer from re-running, so the CLI moves
        # only through its own updater. No pinnable release feed exists (the
        # installer takes the `stable` channel head), so Renovate cannot track
        # it. A stale CLI must not fail activation.
        $DRY_RUN_CMD "$HOME/.local/bin/kiro-cli" update --non-interactive || \
          ${flakelabWarn} "kiro-cli not updated (offline?); it stays on its installed version."
      fi
    ''
  );

  # Clone kiro-plugin (if absent) and install its agents/steering/hooks/skills
  # into ~/.kiro via `make install-global` (idempotent on re-run). Opt-in: only
  # runs when flakelab.kiroPluginRepo is set (default null -> skipped entirely).
  # Cloned full: the operator commits from this checkout, so history-dependent
  # tooling (gitleaks history scans, the repo statistics) works without a
  # follow-up `fetch --unshallow`.
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
          if [ ! -d "${kiroPlugin}/.git" ]; then
            if [ -f "$HOME/.ssh/${firstSshKey}" ]; then
              GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new -i $HOME/.ssh/${firstSshKey}" \
                $DRY_RUN_CMD git clone ${kiroPluginRepo} "${kiroPlugin}" || \
                ${sshDefer "kiro-plugin not cloned, so its agents/skills/steering are not installed. Either activation had no passphrase-unlocked ssh-agent key, or the host was unreachable. Log in interactively (the zsh hook loads the key), then run: flakelab update"}
            else
              # No key yet is the NORMAL state of the first rebuild on a fresh
              # system: setup-wsl-nix.ps1 (WSL) or cloud-init/Ansible (a VM
              # target) can only seed ~/.ssh after this rebuild has created the
              # user. Record the deferral the health check looks for - skipping
              # silently made it report the missing checkout as a defect and
              # failed the very rebuild that creates the user.
              ${flakelabDefer} "kiro-plugin not cloned: no ~/.ssh/${firstSshKey} yet, so the clone was not attempted. Provisioning seeds the key after this rebuild; flakelab update then completes it."
            fi
          fi
          if [ -f "${kiroPlugin}/Makefile" ]; then
            $DRY_RUN_CMD make -C "${kiroPlugin}" install-global || \
              ${flakelabWarn} "'make install-global' failed; Kiro agents may be incomplete."
          fi
        ''
      );

  # Merge this flake's MCP overrides onto whatever the kiro-plugin repo installed,
  # so that baseline survives and our pins/gated servers win where they overlap.
  # Must run after kiroInstallGlobal, which writes the base file.
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
          # No plugin-repo base (kiroPluginRepo unset, or its clone was deferred):
          # our set alone, which is what the removed home.file entry used to write.
          printf '%s\n' "$_override" > "$_tmp"
        elif jq --argjson ov "$_override" '. * $ov' "$_mcp" > "$_tmp" 2>/dev/null; then
          # jq's `*` recurses into objects and takes the right-hand side for arrays
          # and scalars, so our pinned playwright args and the credential-gated
          # servers override same-named entries from the plugin repo's baseline.
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
