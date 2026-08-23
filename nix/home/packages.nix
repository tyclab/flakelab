# Identity, package set, session environment, and static dotfiles.
#
# This module declares no activation entry. Should it ever grow one, append it
# to health.nix's flakelabHealthCheck entryAfter list (or give it
# `lib.hm.dag.entryBefore [ "flakelabHealthCheck" ]`), or the health check stops
# being the last entry and reports on work that has not run yet.
{
  config,
  lib,
  pkgs,
  osConfig,
  flakelabMcp,
  ...
}:
let
  cfg = osConfig.flakelab;
  inherit (flakelabMcp) whatsappMcpDir;

  scripts = import ../scripts.nix { inherit pkgs cfg; };
  cli = import ../cli.nix { inherit pkgs cfg; };

  # Unmapped entries are skipped so a profile may name a tool this repo has not
  # wired yet without failing eval - but they WARN, because a typo here otherwise
  # costs the tool with no output at all.
  inherit (cfg) profileCliTools;
  profileCliMap = {
    # Tokens whose nixpkgs attr name differs need an explicit `token = pkgs.attr;`.
    inherit (pkgs) ansible k6;
  };
  unmappedCliTools = builtins.filter (t: !(profileCliMap ? ${t})) profileCliTools;
  profilePkgs =
    lib.warnIf (unmappedCliTools != [ ])
      "profileCliTools: no package mapped for ${lib.concatStringsSep ", " unmappedCliTools} (mapped: ${lib.concatStringsSep ", " (builtins.attrNames profileCliMap)}); nothing is installed for them. Add them to profileCliMap in nix/home/packages.nix."
      (map (t: profileCliMap.${t}) (builtins.filter (t: profileCliMap ? ${t}) profileCliTools));
in
{
  home.username = cfg.username;
  home.homeDirectory = "/home/${cfg.username}";
  # Pinned to the release home-manager's stateful defaults were built against;
  # independent of the channel refs in flake.nix.
  home.stateVersion = "25.11";

  # Replaces install_executable_from_url/_archive, Homebrew, nvm, bun/uv
  # curl-installers, npm globals, and `go install gopls`.
  home.packages =
    with pkgs;
    [
      # Kubernetes
      kubectl
      kubernetes-helm
      k9s
      kubectx # provides kubectx + kubens
      kubelogin-oidc # int128 kubectl oidc-login; swap to `kubelogin` if you use Azure AD
      # IaC / security
      opentofu
      tofu-ls
      tflint
      trivy
      gitleaks
      # Languages / runtimes
      go
      gopls
      nodejs_24
      typescript-language-server
      # 26.05 removed the nodePackages set; tsc lives at the top level now.
      typescript
      pyright
      nodeenv # npm globals baseline
      bun
      uv
      # An interpreter for `#!/usr/bin/env python3`: without it every such script
      # dies with "no such file or directory", and the Claude marketplace's
      # PreToolUse guard hooks are exactly that. No `pip`: `uv` above is this
      # repo's installer for Python tooling.
      python3
      # Cloud / git
      glab
      gh
      awscli2
      gitless
      # Secrets
      bitwarden-cli # `bw` (unstable overlay); unlock interactively via `bw unlock`
      openbao # `bao` CLI for runtime secrets
      # Lint / dev utilities
      pre-commit
      yamllint
      shellcheck
      # Nix's own formatter/linters — CI runs the same three (.nix:lint).
      nixfmt
      statix
      deadnix
      # AI CLIs (claude, kiro-cli) are installed via home.activation (kiro.nix,
      # claude.nix), not nixpkgs: their official installers self-update in
      # ~/.local, while the nixpkgs builds lag behind the versions these tools
      # require.
      # Data
      yq-go # mikefarah yq (matches the old yq_linux_amd64 binary)
    ]
    ++ [
      # ONE entrypoint for the distro commands: `flakelab <subcommand>`, listed
      # by `flakelab --help`. It routes to the same per-command wrappers
      # nix/scripts.nix has always built, so each subcommand keeps its own
      # pinned PATH and exported environment — see nix/cli.nix.
      #
      # None of the fourteen names it replaced is on PATH as itself any more;
      # seven of them answer only as the deprecation shims below. Those fourteen
      # were badly named: nix-update, nix-doctor, nix-backup, nix-provision,
      # nix-clone-repos, nix-overlay-generate and nix-update-all squatted on the
      # Nix ecosystem namespace, next to nix-build/nix-shell/nix-env, and the
      # rest were outliers (build-dev-wsl-nix, get_current_wsl_distro_name).
      cli.flakelab

      # Generic git tools, deliberately left standalone: no namespace collision,
      # and other repos and skills invoke them by name.
      scripts.gitchecker
      scripts.gitcleaner
      scripts.gitpublisher
    ]
    # Seven deprecation shims: one line to stderr, then exec the new path. Six
    # are for muscle memory and for an already-provisioned box whose notes still
    # say the old names; the seventh, nix-clone-repos, is a silent-failure guard
    # for an older setup-wsl-nix.ps1 (see nix/cli.nix). DELETE next release.
    ++ cli.shims
    # Profile-gated CLIs (profiles/ -> profileCliMap in the let above).
    ++ profilePkgs;

  # ~/.local/bin for the Kiro CLI, Claude Code, and `uv tool` installs.
  home.sessionPath = [ "$HOME/.local/bin" ];

  home.sessionVariables = {
    EDITOR = "nano";
    BROWSER = "wsl-open"; # open URLs in the Windows default browser
    KUBE_EDITOR = "code --wait";
    GOPATH = "${config.home.homeDirectory}/git/go";
    GOBIN = "${config.home.homeDirectory}/git/go/bin";
    # `npm install -g` targets ~/.npm-global (writable, unlike the nix store);
    # home.activation.pinNpm installs the pinned npm there.
    NPM_CONFIG_PREFIX = "${config.home.homeDirectory}/.npm-global";
  }
  // lib.optionalAttrs (whatsappMcpDir != null) {
    # Expanded as ${WHATSAPP_MCP_DIR} by the mcp-whatsapp plugin's .mcp.json.
    WHATSAPP_MCP_DIR = whatsappMcpDir;
  }
  // cfg.sessionVariables;

  # ── Kiro CLI integration (replaces tasks/kiro.yaml) ────────────────────────
  # cli.json is the enforced baseline.
  #
  # mcp.json is deliberately NOT a home.file entry. A kiro-plugin repo's
  # `make install-global` installs its own MCP baseline by copying over
  # ~/.kiro/settings/mcp.json; a store symlink there is read-only, so that copy
  # fails with EROFS and the `|| warn` in kiro.nix swallows it, silently dropping every
  # server the plugin repo ships. With no backupFileExtension set, a plain
  # mcp.json already in place aborts activation instead. So this flake's servers
  # are merged *onto* whatever the plugin repo installed, in the kiroMcpMerge
  # activation (kiro.nix).
  home.file = {
    ".kiro/settings/cli.json".source = ../../files/config/kiro/cli.json;
    ".kiro/settings/kiro_cli_theme.json".source = ../../files/config/kiro/kiro_cli_theme.json;
    # npm's default prefix is the read-only nodejs store path, so `npm i -g` dies
    # with ENOENT. NPM_CONFIG_PREFIX (sessionVariables) only covers processes that
    # inherit the session env; ~/.npmrc covers every npm invocation, including the
    # bare `bash -c` ones. Same directory as NPM_CONFIG_PREFIX, so there is one
    # writable prefix and the pinned npm on PATH is the one that answers.
    ".npmrc".text = "prefix=${config.home.homeDirectory}/.npm-global\n";
    # git reads ~/.gitconfig AFTER ~/.config/git/config, so a real file at the
    # legacy path overrides every key programs.git sets — silently, and
    # backupFileExtension cannot catch it, because home-manager writes the XDG
    # path while a migration or a restore writes this one: two different files,
    # no collision to detect. Owning the legacy path with nothing but an include
    # of the XDG file makes the flake's values the last word again; home-manager
    # moves any existing file to ~/.gitconfig.hm-bak on the next switch, and
    # `flakelab backup`'s restore skips store symlinks, so --restore cannot reintroduce
    # the shadow.
    #
    # Consequence, accepted: `git config --global` now writes to a read-only
    # store path and fails. Git config is declarative here — change
    # programs.git.settings (or flakelab.gitName/gitEmail) and run `flakelab update`.
    ".gitconfig".text = "[include]\n  path = ~/.config/git/config\n";
  };
}
