# Home Manager: per-user environment.
#   toolchain · zsh/OMZ · git/ssh · kiro · claude · secrets (env/OpenBao).
#
# Split by concern: the section modules below own their own values, and this
# module computes only what is shared, handing it over via _module.args.flakelab.
# Shared means either two or more section modules use it, or one of them does
# and so does this file — stateDir/warnLog/deferredLog have health.nix as their
# only section consumer, but mkReporter here derives flakelabWarn/flakelabDefer
# from them, so moving them would make this module depend on one it exports to.
# A value with a single consumer and no use here belongs in that consumer's own
# `let`, not this file. Everything here derives from pkgs and the flakelab options
# only. Those come from `osConfig` — the NIXOS configuration, whose `flakelab.*`
# values mkSystem defines from the userData attrset — and never from this
# module's own `config`, so the args passing cannot recurse.
#
# Reading `osConfig` ties these modules to home-manager-as-a-NixOS-module: a
# standalone `homeManagerConfiguration` has no osConfig and would not evaluate.
# That coupling is DELIBERATE. Every target this repo has, including the remote
# one, is a NixOS system — the Proxmox VM form factor reuses exactly this path —
# and standalone home-manager is not on the roadmap. If it ever becomes one, the
# exit is small and known: import nix/options.nix into the home-manager
# evaluation too, and have the NixOS module feed
# `home-manager.users.<user>.flakelab` from `osConfig.flakelab` via mkDefault, so
# these modules read their own `config.flakelab` and stop caring which side
# supplied it.
#
# This module declares no activation entry of its own. Should it ever grow
# one, append it to health.nix's flakelabHealthCheck entryAfter list (or give it
# `lib.hm.dag.entryBefore [ "flakelabHealthCheck" ]`), or the health check stops
# being the last entry and reports on work that has not run yet.
{
  lib,
  pkgs,
  osConfig,
  ...
}:
let
  cfg = osConfig.flakelab;

  # Every installer in the section modules is warn-not-fail so one offline step
  # cannot block activation. That guard also destroys the only signal: a rebuild
  # reports success on a distro with no kiro-cli, no plugins and no repos. These two
  # reporters print the same message AND record it, so the post-activation health
  # check can act on it.
  #
  # Two severities, because they have genuinely different remedies:
  #   warnLog     a LOGIC failure with no external dependency — bad JSON, a failed
  #               local merge, a broken binary. The health check FAILS the rebuild
  #               on it, because nothing about the environment excuses it.
  #   deferredLog work activation structurally cannot do: it needs the network, an
  #               unlocked ssh-agent or a token only the interactive shell loads.
  #               Reported loudly, never fatal — making it fatal would trade a
  #               silent failure for a distro that cannot be rebuilt offline.
  stateDir = "$HOME/.local/state/flakelab";
  warnLog = "${stateDir}/activation-failures";
  deferredLog = "${stateDir}/activation-deferred";
  # writeShellScript is bash, so plain `dirname` — not zsh's `:h`. The explicit
  # `exit 0` matters: every call site is `cmd || flakelab-warn …` under `set -e`, so
  # a non-zero exit here (a full disk, say) would abort activation with no message
  # at all.
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

  # Activation runs from the home-manager-<user>.service unit, which has no
  # SSH_AUTH_SOCK. Point it at the well-known user agent socket, which IS
  # reachable from the unit (same UID, /run/user/<uid> is 0700 and owned by the
  # user), and record whether it actually holds a key. With the TTY-gated ssh-add
  # hook in initContent (zsh.nix), every rebuild after the first interactive login
  # finds a loaded agent and the SSH-dependent steps simply succeed; when it does
  # not, their failure is DEFERRED rather than fatal, because the provisioned key
  # is passphrase-encrypted and no unattended run can unlock it.
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
  # An SSH-dependent step fails for one of two reasons, neither of them a defect
  # activation can be blamed for: no passphrase-unlocked agent, or the host is
  # unreachable. Both are deferred, and the message names both so the operator is
  # not sent hunting the wrong one.
  sshDefer = what: "${flakelabDefer} ${lib.escapeShellArg what}";

  # The systemd ssh-agent starts EMPTY. The TTY-gated hook in
  # programs.zsh.initContent (zsh.nix) loads every key listed here on the first
  # interactive login; the first entry is the git/clone identity the activations in
  # kiro.nix and claude.nix name with `ssh -i`. That `-i` only selects the key — it
  # cannot decrypt it without a TTY, so those clones still depend on the agent
  # sshAgentPreamble points at.
  inherit (cfg) sshKeys;
  firstSshKey = builtins.head sshKeys; # the git/clone key

  inherit (cfg) installKiro installClaude;

  inherit (cfg) kiroPluginRepo;
  # Derived from the remote so the clone lands under the GitLab group structure,
  # where `flakelab clone` and the ansible provisioning already put it. A second
  # hardcoded path lets two provisioners clone the same repo twice and then install
  # ~/.kiro from whichever ran last — which is why nix/scripts.nix reads the same
  # derivation instead of repeating it.
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
      sshKeys
      firstSshKey
      installKiro
      installClaude
      kiroPluginRepo
      kiroPlugin
      ;
  };

  programs.home-manager.enable = true;
}
