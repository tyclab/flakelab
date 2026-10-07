{
  description = "Private flakelab overlay - real personal values, kept off the shareable template";

  inputs.flakelab.url = "github:tyclab/flakelab"; # flakelab-url: substitution anchor

  outputs =
    { flakelab, ... }:
    {
      nixosConfigurations.default = flakelab.lib.mkSystem {
        # Platform to build for; set on a Proxmox guest, never on a WSL distro.
        # target = "proxmox-vm";

        username = "CHANGEME"; # Linux user (no dashes)
        gitName = "CHANGEME";
        gitEmail = "changeme@example.com";
        locale = "en_US.UTF-8";
        windowsUsername = "WindowsUser"; # your C:\Users\<name> folder - WSL only; null elsewhere
        repoPath = "/mnt/c/Users/WindowsUser/git/flakelab-config"; # this flake

        gitEditor = null; # null -> leave the git default
        backupAutostart = false;

        # Which flakelab/profiles/ entries apply; an entry may also be an imported
        # profile attrset, which this overlay must `git add` before switching.
        profiles = [
          "example"
        ];

        gitlabGroups = [ ];

        cloneGithub = false;
        githubOwners = [ ];

        cloneExclude = [
          "flakelab"
          "flakelab-config"
        ];

        extraReposDirs = [ "/mnt/c/Users/WindowsUser/git" ];

      };
    };
}
