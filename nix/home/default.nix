# Home Manager entrypoint: imports the section modules and computes only what more
# than one of them shares, handed over via _module.args.flakelab.
# Everything derives from `osConfig`, never this module's own `config`, so the args
# passing cannot recurse - which ties these modules to home-manager-as-NixOS-module.
{
  lib,
  pkgs,
  osConfig,
  ...
}:
let
  cfg = osConfig.flakelab;

  # Installers are warn-not-fail, so they record too and the health check can act.
  # warnLog is a logic failure and fails the rebuild; deferredLog is work activation
  # structurally cannot do (network, locked agent) and is never fatal.
  stateDir = "$HOME/.local/state/flakelab";
  warnLog = "${stateDir}/activation-failures";
  deferredLog = "${stateDir}/activation-deferred";
  # The explicit `exit 0` is load-bearing: call sites are `cmd || flakelab-warn …`
  # under `set -e`, so failing here would abort activation with no message at all.
  mkReporter =
    name: log: prefix:
    pkgs.writeShellScript name ''
      set -uo pipefail
      export PATH="${lib.makeBinPath [ pkgs.coreutils ]}:$PATH"
      mkdir -p "$(dirname "${log}")" || true
      printf '%s%s\n' '${prefix}' "$*" >&2
      printf '%s\n' "$*" >> "${log}" || true
      exit 0
    '';
  flakelabWarn = mkReporter "flakelab-warn" warnLog "WARNING: ";
  flakelabDefer = mkReporter "flakelab-defer" deferredLog "DEFERRED: ";

  # The activation unit has no SSH_AUTH_SOCK: point it at the well-known user agent
  # socket and record whether it holds a key, since no unattended run can unlock a
  # passphrase-encrypted key.
  sshAgentPreamble = ''
    if [ -z "''${SSH_AUTH_SOCK:-}" ] && [ -S "/run/user/$(id -u)/ssh-agent" ]; then
      export SSH_AUTH_SOCK="/run/user/$(id -u)/ssh-agent"
    fi
    # 0 = no usable agent, so an SSH failure below is expected, not a defect.
    _sshReady=0
    if [ -n "''${SSH_AUTH_SOCK:-}" ] && ssh-add -l >/dev/null 2>&1; then
      _sshReady=1
    fi
  '';
  sshDefer = what: "${flakelabDefer} ${lib.escapeShellArg what}";

  inherit (cfg) sshKeys;
  firstSshKey = builtins.head sshKeys; # the git/clone key

  # The clone identity is the first sshKeys entry that exists on disk, resolved at
  # activation: gating on the first name would park clones on a box carrying a later one.
  cloneKeyResolve = ''
    _cloneKey=""
    for _k in ${lib.concatMapStringsSep " " lib.escapeShellArg sshKeys}; do
      if [ -f "$HOME/.ssh/$_k" ]; then _cloneKey="$HOME/.ssh/$_k"; break; fi
    done
  '';

  # The one target fact the home modules need: whether there is a Windows side.
  isWsl = cfg.target == "wsl";

  inherit (cfg) installKiro installClaude;

  inherit (cfg) kiroPluginRepo;
  kiroPlugin = (import ../kiro-plugin.nix { inherit lib cfg; }).dirOrNull;
in
{
  imports = [
    ./mcp.nix
    ./packages.nix
    ./zsh.nix
    ./backup.nix
    ./git-ssh.nix
    ./kiro.nix
    ./claude.nix
    ./tooling.nix
    ./health.nix
  ];

  _module.args.flakelab = {
    inherit
      stateDir
      warnLog
      deferredLog
      flakelabWarn
      flakelabDefer
      sshAgentPreamble
      sshDefer
      isWsl
      sshKeys
      firstSshKey
      cloneKeyResolve
      installKiro
      installClaude
      kiroPluginRepo
      kiroPlugin
      ;
  };

  programs.home-manager.enable = true;
}
