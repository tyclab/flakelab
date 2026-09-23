# Identity, package set, session environment, and static dotfiles.
{
  config,
  lib,
  pkgs,
  osConfig,
  flakelab,
  flakelabMcp,
  ...
}:
let
  cfg = osConfig.flakelab;
  inherit (flakelab) isWsl;

  # The checked-in baseline stays the place to edit every key but the trust-all
  # confirmation suppressor, which is gated on flakelab.kiroTrustAll.
  kiroCliBase = builtins.fromJSON (builtins.readFile ../../files/config/kiro/cli.json);
  kiroCliJson = (pkgs.formats.json { }).generate "kiro-cli.json" (
    kiroCliBase
    // lib.optionalAttrs cfg.kiroTrustAll {
      "chat.disableTrustAllConfirmation" = true;
    }
  );
  inherit (flakelabMcp) whatsappMcpDir;

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
      # claude, kiro-cli and codex come from their own installers (kiro.nix,
      # claude.nix, codex.nix): the nixpkgs builds lag upstream.
    ]
    ++ [
      # The one entrypoint for the distro commands; the old per-command names
      # survive only as cli.shims.
      cli.flakelab

      # Standalone on purpose: other repos and skills invoke them by name.
      scripts.gitchecker
      scripts.gitcleaner
      scripts.gitpublisher
    ]
    ++ cli.shims
    ++ profilePkgs;

  # ~/.local/bin for the Kiro CLI, Claude Code, Codex, and `uv tool` installs.
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
    # The flake's xdg-open hands the URL to the Windows default browser; a headless
    # target has none. Same command a CLI that ignores BROWSER execs by name.
    BROWSER = "xdg-open";
  }
  // lib.optionalAttrs (whatsappMcpDir != null) {
    # Expanded as ${WHATSAPP_MCP_DIR} by the mcp-whatsapp plugin's .mcp.json.
    WHATSAPP_MCP_DIR = whatsappMcpDir;
  }
  // lib.optionalAttrs (builtins.elem "ansible" profileCliTools) {
    # The bundled collections (community.general, community.docker, ansible.posix)
    # ship in the ansible DISTRIBUTION, not in pkgs.ansible — that attribute is
    # ansible-core, and its ansible_collections tree does not exist. ansible-lint
    # cannot see them either way: pre-commit runs it from an isolated venv carrying
    # its own ansible-core, so naming the tree here is what resolves them there.
    # The writable entry stays FIRST: ansible-galaxy installs into the head of this
    # list, and the store is read-only.
    ANSIBLE_COLLECTIONS_PATH = "${config.home.homeDirectory}/.ansible/collections:${pkgs.python3Packages.ansible}/${pkgs.python3.sitePackages}/ansible_collections";
  }
  // cfg.sessionVariables;

  # Do not add ~/.kiro/settings/mcp.json here: a plugin repo's `make install-global`
  # copies over that path, which fails on a read-only store symlink and silently
  # drops every server it ships. kiro.nix merges onto it instead.
  home.file = {
    # force: kiro-cli saves this file by rename, replacing the link; see the
    # kiro-cli-json check in flake.nix.
    ".kiro/settings/cli.json" = {
      source = kiroCliJson;
      force = true;
    };
    ".kiro/settings/kiro_cli_theme.json".source = ../../files/config/kiro/kiro_cli_theme.json;
    # NPM_CONFIG_PREFIX only covers processes inheriting the session env; ~/.npmrc
    # covers every npm invocation, and must name the same directory.
    ".npmrc".text = "prefix=${config.home.homeDirectory}/.npm-global\n";
    # git reads ~/.gitconfig after ~/.config/git/config, so a real file here would
    # silently shadow every key programs.git sets; owning it with an include stops that.
    # Consequence: `git config --global` fails, since this path is in the store.
    ".gitconfig".text = "[include]\n  path = ~/.config/git/config\n";
  };
}
