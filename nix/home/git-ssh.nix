{
  lib,
  pkgs,
  osConfig,
  flakelab,
  ...
}:
let
  cfg = osConfig.flakelab;
  inherit (flakelab) sshKeys;
  # The two values `gh auth setup-git` writes per host, and glab's login the same.
  # The empty one first resets the helper list, so a general credential.helper an
  # overlay adds (store, cache) is neither asked for these hosts nor handed the
  # forge token to keep.
  forgeCredential = tool: {
    helper = [
      ""
      "!${lib.getExe tool} auth git-credential"
    ];
  };
in
{
  # `settings` is canonical; the flat userName/userEmail/extraConfig are deprecated.
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
      # Declared here: `gh/glab auth login` cannot write this helper, as ~/.gitconfig is a read-only store symlink.
      # A self-hosted GitLab is the same one line in the overlay, under its own https://<host>.
      credential = {
        "https://github.com" = forgeCredential pkgs.gh;
        "https://gist.github.com" = forgeCredential pkgs.gh;
        "https://gitlab.com" = forgeCredential pkgs.glab;
      };
    };
  };

  # Not the OMZ ssh-agent plugin, which hangs on a passphrase without a tty; zsh.nix's TTY-gated hook fills it.
  services.ssh-agent.enable = true;
  # No restart on switch: it would silently empty the agent's keys mid-session (as in backup.nix).
  systemd.user.services.ssh-agent = {
    Unit."X-RestartIfChanged" = false;
    Service."X-RestartIfChanged" = false;
  };
  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    # Freeform, taking the ssh_config(5) spelling verbatim; matchBlocks is deprecated.
    settings."*" = {
      AddKeysToAgent = "yes";
      IdentityFile = map (k: "~/.ssh/${k}") sshKeys;
      SendEnv = "-LC_*"; # do not forward LC_* to remotes
    };
  };
}
