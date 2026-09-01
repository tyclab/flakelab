{
  description = "Private flakelab overlay - real personal values, kept off the shareable template";

  # Which flakelab this overlay builds against. The default names the public
  # repo, which is what a bare `nix flake new -t <flakelab>#overlay` scaffold
  # locks against. Point it at a flakelab you have instead when you are working
  # on both side by side - both generators do exactly that for you, and
  # `--override-input flakelab path:/path/to/flakelab` does it for a one-off.
  #
  # SUBSTITUTION ANCHOR: `setup-wsl-nix.ps1 init` and
  # `flakelab/files/scripts/nix-overlay-generate` both rewrite the WHOLE line
  # below, keyed on the marker comment it ends with, and both abort if that
  # marker is not there exactly once. Keep it, and keep the line on ONE line -
  # matching the URL itself instead would silently no-op the day the default
  # changes, and the overlay would then build against the public repo without
  # saying so.
  #
  # Override it by hand for the cases the public repo does not cover:
  #
  #   inputs.flakelab.url = "git+ssh://git@<your-forge>/<you>/flakelab.git";
  #   inputs.flakelab.url = "path:/mnt/c/Users/<WindowsUser>/git/flakelab";
  #
  # A local `path:` input is the usual choice while you edit flakelab and this
  # overlay side by side: nix re-resolves it on every build, untracked edits
  # included. That is what both generators write.
  #
  # Either way, git-ignore this overlay's flake.lock: a committed lock pins the
  # NAR hash of a local checkout, and the next change over there aborts the build
  # with "NAR hash mismatch". flakelab's own lock already pins nixpkgs,
  # home-manager and nixos-wsl.
  inputs.flakelab.url = "github:tyclab/flakelab"; # flakelab-url: substitution anchor

  outputs =
    { flakelab, ... }:
    {
      # Apply with `sudo nixos-rebuild switch --flake .#default`, or `flakelab update`
      # once repoPath below points here.
      #
      # Every field below is a DECLARED OPTION - flakelab/nix/options.nix lists them
      # all with their types and what each one does, and that file is the schema
      # this attrset is checked against: a misspelt key (`instalKiro`) and a value
      # of the wrong type both abort evaluation instead of being ignored.
      #
      # mkSystem does NOT layer flakelab/nix/users/default.nix underneath: every
      # option nix/options.nix declares WITHOUT a default (username and repoPath
      # among them - that file is the list, do not keep a copy of it here) must be
      # set HERE or evaluation aborts. Everything else falls back to that option's
      # default. Attrsets and lists REPLACE rather than merge - only gitlabGroups,
      # profileCliTools, customAliases and sessionVariables get unioned, and only
      # with the profile-derived values from flakelab/profiles/.
      #
      # Secrets are NOT in this flake in plaintext - the Nix store is
      # world-readable. Either commit them ENCRYPTED via sops-nix (set
      # `sopsSecretsFile = ./secrets/secrets.env;` to an age-encrypted sops
      # dotenv file after enrolling the host key - flakelab README "Secrets"),
      # or keep tokens in ~/.config/tyc/secrets.env (git-ignored, LF-only);
      # `flakelab doctor` inside the distro verifies either.
      #
      # Need something no userData field covers? mkSystem's second call form
      # takes arbitrary NixOS and home-manager modules, so an overlay never has
      # to fork flakelab:
      #   flakelab.lib.mkSystem {
      #     userData = { <the fields below, unchanged> };
      #     modules = [ { services.tailscale.enable = true; } ];
      #     homeModules = [ { home.packages = [ ... ]; home.shellAliases = ...; } ];
      #   };
      # A `modules` entry may also set any flakelab.* option, and it OUTRANKS the
      # userData below. How that lands depends on the option:
      #   scalars (installKiro, bitwardenServer, ...)  the module value wins.
      #   lists   (gitlabGroups, claudePlugins, ...)   the module value REPLACES
      #                                                the userData list.
      #   sessionVariables / customAliases /           merged per key: the module
      #   claudeMcpServers                             ADDS to what is set below
      #                                                and overrides colliding
      #                                                keys. Replacing one of
      #                                                these wholesale needs
      #                                                lib.mkForce.
      nixosConfigurations.default = flakelab.lib.mkSystem {
        # Optional: the platform this box is built for (default "wsl"). Picks
        # the module set in flakelab/nix/targets/ - set it on a Proxmox guest,
        # never on a WSL distro.
        # target = "proxmox-vm";

        username = "CHANGEME"; # Linux user (no dashes)
        gitName = "CHANGEME";
        gitEmail = "changeme@example.com";
        locale = "en_US.UTF-8";
        windowsUsername = "WindowsUser"; # your C:\Users\<name> folder - WSL only; null elsewhere
        repoPath = "/mnt/c/Users/WindowsUser/git/flakelab-config"; # this flake

        gitEditor = null; # null -> leave the git default
        backupAutostart = false;

        # Optional: this distro's hostname (default "flakelab"). Set it when the
        # distro is registered under another name, or when a second box builds
        # from this overlay.
        # hostName = "flakelab";

        # Optional: a second root for the SHAREABLE backup state (merged shell
        # history, Claude auto-memory) so another machine can pick it up. Point it
        # at a plain directory that your folder-sync client replicates - which
        # client, or none, is your business. NEVER a git checkout, never inside
        # repoPath. Credentials stay in the payload under repoPath regardless.
        # stateRoot = "/mnt/d/sync/flakelab-state";
        # Session transcripts too (large, and the verbatim text of every session):
        # stateTranscripts = true;

        # Which flakelab/profiles/ entries apply. Selecting a profile is the only
        # thing that installs its gitlabGroups and profileCliTools, so an empty
        # list means none of it is installed. Known: example. An entry may also be
        # a profile attrset itself - `(import ./profiles/mine.nix)` - to keep real
        # groups in this private overlay instead of the shared repo. This overlay
        # is a git repo and a flake only sees TRACKED files, so
        # `git add profiles/mine.nix` before switching or the import fails with
        # "path does not exist".
        profiles = [
          "example"
        ];

        # Personal full-clone GitLab groups. Profile groups are unioned in, so do
        # not repeat them here.
        gitlabGroups = [ ];

        # Keep both this flake and flakelab out of ~/git.
        cloneExclude = [
          "flakelab"
          "flakelab-config"
        ];

        # Extra roots for the gitcheck/gitclean aliases beyond ~/git - the
        # Windows-mount tree holds clones (flakelab, flakelab-config, GitHub repos)
        # that exist nowhere else.
        extraReposDirs = [ "/mnt/c/Users/WindowsUser/git" ];

        # Private keys under files/config/shared/ssh/keys/ that setup-wsl-nix.ps1
        # seeds and the zsh login hook loads. The FIRST entry is the git/clone
        # identity. Omit to keep the template's [ "id_ed25519" ].
        # sshKeys = [ "id_ed25519" ];

        # NON-SECRET config only - these land in the Nix store. Each entry is
        # also what GATES its MCP server in flakelab/nix/home/mcp.nix, so a missing
        # endpoint means a missing server. The token halves belong in
        # ~/.config/tyc/secrets.env.
        # sessionVariables = {
        #   HASS_URL = "http://homeassistant.example.lan:8123";
        #   PROXMOX_API_URL = "https://pve.example.lan:8006"; # no /api2/json
        #   PROXMOX_VERIFY_SSL = "false";
        #   SYNOLOGY_HOST = "nas.example.com"; # bare host, NO port
        #   SYNOLOGY_PORT = "443";
        #   SYNOLOGY_HTTPS = "true";
        #   SYNOLOGY_USERNAME = "mcp-service";
        #   GRAFANA_URL = "https://grafana.example.lan";
        #   WHATSAPP_BRIDGE_HOST = "localhost:8180";
        # };

        # customAliases = { proxmox-ssh = "ssh root@pve.example.lan"; };

        # Private integrations, off by default in the template.
        # kiroPluginRepo = "git@gitlab.com:you/kiro-plugin.git";
        # claudePluginMarketplaces = [
        #   {
        #     # Must match the `name` in the marketplace's own
        #     # .claude-plugin/marketplace.json - a wrong name fails every
        #     # install silently and leaves zero plugins installed.
        #     name = "your-tools";
        #     url = "git@gitlab.com:you/claude-plugins.git";
        #   }
        # ];
        # claudePlugins = [ "agents" "skills" "hooks" "statusbar" ];

        # The agent-box bundle: settings.permissions.defaultMode = "auto" with
        # its consent flag, Remote Control at startup, and removal of the four
        # env vars (DISABLE_TELEMETRY, DO_NOT_TRACK,
        # CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC, DISABLE_GROWTHBOOK) that
        # would otherwise defeat it. Default false; turn it on only for a box you
        # intend to run agents on unattended. Everything else the flake asserts
        # in ~/.claude/settings.json (attribution, the classifier rules, the
        # force-push deny floor) is written either way.
        # claudeAgentDefaults = true;

        # Your own rules, appended INSIDE the managed block of
        # ~/.claude/CLAUDE.md after the neutral text the flake ships. Default "".
        # claudeMdExtra = ''
        #   ## Workflow Preferences
        #
        #   - `glab` for the GitLab repos under `~/git`; `gh` only for GitHub remotes.
        # '';

        # Per-developer Claude user-scope MCP servers, merged into
        # ~/.claude.json; the flake's own servers are declared in nix/home/mcp.nix.
        # claudeMcpServers = {
        #   scratch = {
        #     type = "stdio";
        #     command = "node";
        #     args = [ "/home/CHANGEME/git/.../dist/index.js" ];
        #   };
        # };

        # Absolute path to the whatsapp-mcp-server checkout; follows your
        # gitlabGroups, since clones land under the GitLab namespace.
        # whatsappMcpDir = "/home/CHANGEME/git/.../whatsapp-mcp-server";

        # Endpoint `bw config server` is pointed at on every rebuild. Default
        # null leaves the Bitwarden CLI wherever it already points; the CLI's own
        # default is US, so name your region if `bw login` fails against it.
        # bitwardenServer = "https://vault.bitwarden.eu";
      };
    };
}
