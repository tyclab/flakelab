# Identity, package set, session environment, and static dotfiles.
{
  config,
  lib,
  pkgs,
  osConfig,
  flakelab,
  ...
}:
let
  cfg = osConfig.flakelab;
  inherit (flakelab) isWsl;
  inherit (cfg) whatsappMcpDir;

  scripts = import ../scripts.nix { inherit pkgs cfg; };
  cli = import ../cli.nix { inherit pkgs cfg; };

  # Unmapped entries only warn, so a profile may name a tool this repo has not wired.
  inherit (cfg) profileCliTools;
  profileCliMap = {
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
  # Pinned to the release whose stateful defaults this was built against.
  home.stateVersion = "25.11";

  home.packages =
    with pkgs;
    [
      kubectl
      kubernetes-helm
      k9s
      kubectx # provides kubectx + kubens
      kubelogin-oidc # int128 kubectl oidc-login, not the Azure AD one
      opentofu
      tofu-ls
      tflint
      trivy
      gitleaks
      go
      gopls
      nodejs_24
      typescript-language-server
      typescript
      pyright
      nodeenv
      bun
      uv
      # Interpreter for `#!/usr/bin/env python3` hooks; `uv` above installs Python tooling.
      python3
      glab
      gh
      awscli2
      gitless
      bitwarden-cli
      openbao
      pre-commit
      yamllint
      shellcheck
      # CI runs the same three.
      nixfmt
      statix
      deadnix
      yq-go
      # claude and codex come from their own installers (claude.nix, codex.nix):
      # the nixpkgs builds lag upstream.
    ]
    ++ [
      # The one entrypoint for the distro commands.
      cli.flakelab

      # Standalone on purpose: other repos and skills invoke them by name.
      scripts.gitchecker
      scripts.gitcleaner
      scripts.gitpublisher
    ]
    # Codex's Linux sandbox runs the first bwrap on PATH; without one it warns at
    # every start and falls back to a bundled helper.
    ++ lib.optional cfg.installCodex pkgs.bubblewrap
    # The account switcher for Claude Code and Codex, pinned in flake.nix.
    ++ lib.optional cfg.installTycswap pkgs.tycswap
    ++ profilePkgs;

  # ~/.local/bin for Claude Code, Codex, and `uv tool` installs.
  home.sessionPath = [ "$HOME/.local/bin" ];

  home.sessionVariables = {
    EDITOR = "nano";
    KUBE_EDITOR = "code --wait";
    GOPATH = "${config.home.homeDirectory}/git/go";
    GOBIN = "${config.home.homeDirectory}/git/go/bin";
    # ~/.npm-global is writable, unlike the nix store npm defaults to.
    NPM_CONFIG_PREFIX = "${config.home.homeDirectory}/.npm-global";
    # Without this, a missing flag hangs an agent's terminal-less Bash on a prompt
    # instead of erroring out and naming the flag.
    GLAB_NO_PROMPT = "1";
  }
  // lib.optionalAttrs isWsl {
    # xdg-open reaches the Windows browser; a headless target has none.
    BROWSER = "xdg-open";
  }
  // lib.optionalAttrs (whatsappMcpDir != null) {
    # Expanded as ${WHATSAPP_MCP_DIR} by the mcp-whatsapp plugin's .mcp.json.
    WHATSAPP_MCP_DIR = whatsappMcpDir;
  }
  // lib.optionalAttrs (builtins.elem "ansible" profileCliTools) {
    # Collections ship in the ansible distribution, not pkgs.ansible (ansible-core); naming them lets pre-commit's ansible-lint
    # venv see them. The writable entry stays FIRST: ansible-galaxy installs into the head, and the store is read-only.
    ANSIBLE_COLLECTIONS_PATH = "${config.home.homeDirectory}/.ansible/collections:${pkgs.python3Packages.ansible}/${pkgs.python3.sitePackages}/ansible_collections";
  }
  // cfg.sessionVariables;

  programs.tmux = {
    enable = true;
    extraConfig = builtins.readFile ../../files/config/tmux/tmux.conf;
  };

  home.file = {
    # NPM_CONFIG_PREFIX only covers processes inheriting the session env; ~/.npmrc
    # covers every npm invocation, and must name the same directory.
    ".npmrc".text = "prefix=${config.home.homeDirectory}/.npm-global\n";
    # git reads ~/.gitconfig after ~/.config/git/config, so a real file would shadow programs.git; hence `git config --global` fails.
    ".gitconfig".text = "[include]\n  path = ~/.config/git/config\n";
  };
}
