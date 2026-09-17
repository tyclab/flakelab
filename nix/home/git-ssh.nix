# Git identity, ssh client config, and the systemd user ssh-agent.
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
      # gh and glab are in the package set, and `gh auth login` / `glab auth login`
      # end by writing this helper with `git config --global` - which fails here:
      # both ~/.gitconfig and ~/.config/git/config are store symlinks ("could not
      # lock config file: read-only file system"), so https pushes kept asking for
      # a password the CLI already holds. Declared once instead; answer the login's
      # "Authenticate Git with your ... credentials?" either way. A self-hosted
      # GitLab is the same one line in the overlay, under its own https://<host>.
      credential = {
        "https://github.com" = forgeCredential pkgs.gh;
        "https://gist.github.com" = forgeCredential pkgs.gh;
        "https://gitlab.com" = forgeCredential pkgs.glab;
      };
    };
  };

  # Not the OMZ ssh-agent plugin: that hangs on a passphrase without a tty. This
  # agent starts empty and the TTY-gated hook in zsh.nix is what fills it.
  services.ssh-agent.enable = true;
  # A restart would silently empty the running agent's keys mid-session, and its
  # unit file changes on every package bump. Both sections, as in backup.nix.
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
