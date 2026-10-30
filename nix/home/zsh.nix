# initContent is only for work that must happen in the interactive shell; a real
# command belongs in files/scripts with a wrapper in nix/scripts.nix.
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
  inherit (flakelab) isWsl sshKeys flakelabWarn;

  homeJump = lib.optionalString (isWsl && cfg.windowsUsername != null) ''
    # Jump to the Linux home only from the two Windows default entry paths, so a
    # shell deliberately opened elsewhere on /mnt keeps its directory. Both sides
    # lowercased: Windows preserves the profile directory's case but does not enforce it.
    if [[ -z "''${_flakelab_home_jump:-}" ]]; then
      _flakelab_home_jump=1
      _flakelab_win_home="/mnt/c/Users/${cfg.windowsUsername}"
      [[ "''${PWD:l}" == "''${_flakelab_win_home:l}" || "''${PWD:l}" == /mnt/c/windows/system32 ]] && cd ~
      unset _flakelab_win_home
    fi

  '';

  # sopsKeyFiles variables live in their own files; the shell never carries them.
  keyFilesFilter =
    lib.optionalString (cfg.sopsKeyFiles != { })
      " | ${pkgs.gnugrep}/bin/grep -vE ${lib.escapeShellArg "^(${lib.concatStringsSep "|" (builtins.attrNames cfg.sopsKeyFiles)})="}";

  # The deleter stays on ~/git: extraReposDirs names trees whose clones exist nowhere else.
  inherit (cfg) extraReposDirs;
  gitCheckRootArgs = lib.concatStringsSep " " (
    [ ''--repos-dir "$HOME/git"'' ] ++ map (d: ''--repos-dir "${d}"'') extraReposDirs
  );
  gitCleanRootArgs = ''--repos-dir "$HOME/git"'';
in
{
  programs.zsh = {
    enable = true;
    history = {
      size = 1000000;
      save = 1000000;
      path = "${config.home.homeDirectory}/.zsh_history";
      extended = true;
      ignoreDups = true;
    };
    # Written after oh-my-zsh, so an alias here shadows a plugin's of the same name.
    # Emitted as `alias -- <name>=...`, so anything grepping .zshrc must allow the `--`.
    shellAliases = {
      ll = "ls -alF";

      # `gitcheck` reports, `gitclean` deletes; both take their scripts' own flags appended.
      gitcheck = "gitchecker ${gitCheckRootArgs}";
      gitclean = "gitcleaner ${gitCleanRootArgs}";

      c = "claude";
    }
    # Opt-in: trust-all skips every permission prompt, the one guard before an unreviewed command.
    // lib.optionalAttrs cfg.claudeTrustAll {
      cc = "claude --dangerously-skip-permissions";
    }
    # Last, so an overlay's customAliases can override any of the above.
    // cfg.customAliases;
    oh-my-zsh = {
      enable = true;
      # For the git segment's colours: git_prompt_info is plain without a theme. The PROMPT below replaces the theme's.
      theme = lib.mkDefault "robbyrussell";
      plugins = [
        "git"
        "kubectl"
        "helm"
        "docker"
      ];
    };
    # .zshenv, so it applies to every zsh context, not just interactive shells.
    envExtra = ''
      # Prepend: the pinned npm must beat the nix profile's, and sessionPath only appends.
      export PATH="$HOME/.npm-global/bin:$PATH"

      # nixpkgs' pre-patched browsers, so nix-ld is not needed. Playwright matches browsers by
      # revision: a harness that npm-installs playwright takes PLAYWRIGHT_VERSION, never its own pin.
      export PLAYWRIGHT_BROWSERS_PATH="${pkgs.playwright-driver.browsers}"
      export PLAYWRIGHT_VERSION="${pkgs.playwright-driver.version}"
      export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

      # Secrets from exactly one source, chosen at build time by `sopsSecretsFile`; no runtime
      # fallback, so an enrolled box with no render starts with none, not a stale file.
      # `tr -d` strips CRs, which land inside quoted values and corrupt tokens. Here in
      # .zshenv, not .zshrc: an agent's non-interactive `zsh -c` never reads .zshrc.
      ${
        if cfg.sopsSecretsFile != null then
          ''
            if [[ -r /run/secrets/flakelab-env ]]; then
              set -a; source =(tr -d '\r' < /run/secrets/flakelab-env${keyFilesFilter}); set +a
            fi
          ''
        else
          ''
            if [[ -r "$HOME/.config/flakelab/secrets.env" ]]; then
              set -a; source =(tr -d '\r' < "$HOME/.config/flakelab/secrets.env"); set +a
            fi
          ''
      }

      # The Claude mcp-homeassistant plugin expands HA_URL/HA_TOKEN, not HASS_*; after the
      # secrets and in .zshenv, so non-interactive starts (agent `zsh -c`, dashboard) get them.
      [[ -n "''${HASS_URL:-}" ]] && export HA_URL="$HASS_URL"
      [[ -n "''${HASS_TOKEN:-}" ]] && export HA_TOKEN="$HASS_TOKEN"
    '';
    initContent = ''
      export GPG_TTY="$(tty)"

      # A systemd unit has no WSL_DISTRO_NAME and no interop socket for wsl.exe,
      # so the shell leaves the name where `flakelab distro-name` and the
      # backup units read it.
      if [[ -n "''${WSL_DISTRO_NAME:-}" ]]; then
        _f="''${XDG_STATE_HOME:-$HOME/.local/state}/flakelab/distro-name"
        if [[ ! -r "$_f" || "$(<"$_f")" != "$WSL_DISTRO_NAME" ]]; then
          { mkdir -p "''${_f:h}" && print -r -- "$WSL_DISTRO_NAME" > "$_f"; } 2>/dev/null
        fi
        unset _f
      fi

      ${homeJump}

      # `bwu` unlocks on the TTY and parks the per-unlock token in a mode-600 file
      # every shell exports from, so it never rides a command line or a transcript.
      if [[ -r "$HOME/.config/flakelab/bw-session" ]]; then
        export BW_SESSION="$(tr -d '\r\n' < "$HOME/.config/flakelab/bw-session")"
      fi
      bwu() {
        local _f="$HOME/.config/flakelab/bw-session" _t
        _t="$(bw unlock --raw)" || return 1
        mkdir -p "$HOME/.config/flakelab" && chmod 700 "$HOME/.config/flakelab"
        (umask 077; printf '%s\n' "$_t" > "$_f") || return 1
        export BW_SESSION="$_t"
        echo "bw: unlocked — token in $_f, exported to new shells (bwl to lock)"
      }
      bwl() {
        bw lock
        rm -f "$HOME/.config/flakelab/bw-session"
        unset BW_SESSION
      }

      # The agent starts empty and nothing else seeds it, so without this hook every
      # git@ clone fails with "Permission denied (publickey)". TTY-gated: a
      # non-interactive path must never reach ssh-add and hang on the passphrase prompt.
      if [[ -o interactive && -t 0 && -t 1 && -n "''${SSH_AUTH_SOCK:-}" ]]; then
        _loaded="$(ssh-add -l 2>/dev/null)"
        for _key in ${lib.concatStringsSep " " (map lib.escapeShellArg sshKeys)}; do
          [[ -r "$HOME/.ssh/$_key" ]] || continue
          _fp="''${''${$(ssh-keygen -lf "$HOME/.ssh/$_key" 2>/dev/null)}[(w)2]}"
          [[ -n "$_fp" && "$_loaded" == *"$_fp"* ]] && continue
          ssh-add "$HOME/.ssh/$_key" && _loaded="$(ssh-add -l 2>/dev/null)"
        done
        unset _key _fp _loaded
      fi

      # Every ~/.kube/*.yaml after an existing KUBECONFIG (sessionVariables keep theirs),
      # else after ~/.kube/config; each path once, so a nested shell adds nothing.
      () {
        local kc="''${KUBECONFIG:-$HOME/.kube/config}" f
        for f in $HOME/.kube/*.yaml(N); do
          [[ ":$kc:" == *":$f:"* ]] || kc="$kc:$f"
        done
        export KUBECONFIG="$kc"
      }

      # Prompt: [exit-code] time user git cwd / %#
      setopt PROMPT_SUBST
      function lastCommandCode() {
        if [[ $1 == 0 ]]; then
          echo "[%F{green}✓%f]"
        else
          echo "[%F{red}''${1}%f]"
        fi
      }
      PROMPT=""
      PROMPT+='$(lastCommandCode $?)'
      PROMPT+=' %*'
      PROMPT+=' %F{yellow}%n%f'
      PROMPT+=' $(git_prompt_info)'
      PROMPT+=' %~'
      PROMPT+=$'\n'
      PROMPT+='%# '

      bindkey '^[[H' beginning-of-line
      bindkey '^[[F' end-of-line
      bindkey '^[[3~' delete-char
      bindkey '^[[1;5D' backward-word
      bindkey '^[[1;5C' forward-word
      bindkey '^[[A' up-line-or-search
      bindkey '^[[B' down-line-or-search
      zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'
    '';
  };

  # The secrets share ~/.config/flakelab with home-manager's own files, which would
  # leave it 755; owner-only, like bwu makes it.
  home.activation.flakelabSecretsDir =
    lib.hm.dag.entryAfter [ "writeBoundary" "flakelabWarnReset" ]
      ''
        $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -d -m700 "$HOME/.config/flakelab" || \
          ${flakelabWarn} "could not make ~/.config/flakelab owner-only; the secrets in it keep their own 600."
      '';
}
