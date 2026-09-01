# Git identity, ssh client config, and the systemd user ssh-agent.
#
# This module declares no activation entry. Should it ever grow one, append it
# to health.nix's flakelabHealthCheck entryAfter list (or give it
# `lib.hm.dag.entryBefore [ "flakelabHealthCheck" ]`), or the health check stops
# being the last entry and reports on work that has not run yet.
{
  lib,
  osConfig,
  flakelab,
  ...
}:
let
  cfg = osConfig.flakelab;
  inherit (flakelab) sshKeys;
in
{
  # ── Git identity (replaces git_config in tasks/ssh_git.yaml) ───────────────
  # home-manager's git module now exposes `programs.git.settings` as a single
  # git-config attrset; the flat `userName`/`userEmail`/`extraConfig` options
  # are deprecated aliases. See ARCHITECTURE.md "Packaging notes".
  programs.git = {
    enable = true;
    settings = {
      user = {
        name = cfg.gitName;
        email = cfg.gitEmail;
      };
      core = {
        autocrlf = "input";
      }
      // lib.optionalAttrs (cfg.gitEditor != null) {
        editor = cfg.gitEditor;
      };
      safe.directory = cfg.repoPath;
    };
  };

  # systemd user ssh-agent instead of the OMZ ssh-agent plugin — avoids the
  # documented non-tty passphrase hang. It starts EMPTY and loads nothing by
  # itself, and `AddKeysToAgent = "yes"` below does not change that: ssh_config(5)
  # adds a key to the agent only when ssh loads it from a file during a
  # connection, which for a passphrase-protected key needs a TTY prompt first. The
  # TTY-gated hook in programs.zsh.initContent (zsh.nix) is what fills the agent,
  # on the first interactive login. Its socket is /run/user/<uid>/ssh-agent, which
  # is also why the activation steps in kiro.nix and claude.nix can find it.
  # Private key material is provisioned at bootstrap (seeded from the Windows
  # mount). The first sshKeys entry is the git/clone key, which those activations
  # pass explicitly via `ssh -i` and therefore never need the agent for.
  services.ssh-agent.enable = true;
  # The agent's whole value is the keys loaded into the RUNNING process; its
  # unit file changes on every package bump, and sd-switch's default restart
  # would empty it on every such switch — mid-session, silently, until the next
  # interactive login re-prompts. Same flag pair as backup.nix's oneshots
  # (sd-switch reads [Unit], switch-to-configuration reads [Service]): the
  # running agent keeps its keys, the new definition applies when the user
  # manager next starts.
  systemd.user.services.ssh-agent = {
    Unit."X-RestartIfChanged" = false;
    Service."X-RestartIfChanged" = false;
  };
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    # Upstream OpenSSH directive names: home-manager deprecated matchBlocks and
    # its camelCase aliases in favour of settings, which is freeform and takes
    # the ssh_config(5) spelling verbatim.
    settings."*" = {
      AddKeysToAgent = "yes";
      IdentityFile = map (k: "~/.ssh/${k}") sshKeys;
      SendEnv = "-LC_*"; # don't forward LC_* to remotes (locale-fix)
    };
  };

  # ── Secrets ────────────────────────────────────────────────────────────────
  # Not managed declaratively: tokens are loaded at shell start from
  # ~/.config/tyc/secrets.env (git-ignored, from OpenBao) if present — see the
  # zsh initContent (zsh.nix). Nothing secret enters the repo or the Nix store.
}
