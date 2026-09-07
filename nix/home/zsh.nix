# zsh + Oh My Zsh: history, aliases, env, and the interactive init block.
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
  inherit (flakelab) isWsl sshKeys;

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

  # Built once so the reporter and the deleter cannot disagree about the scan scope.
  inherit (cfg) extraReposDirs;
  gitRootArgs = lib.concatStringsSep " " (
    [ ''--repos-dir "$HOME/git"'' ] ++ map (d: ''--repos-dir "${d}"'') extraReposDirs
  );
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
    # Written after oh-my-zsh, so `k` here shadows the kubectl plugin's `k=kubectl`.
    # Emitted as `alias -- <name>=...`, so anything grepping .zshrc must allow the `--`.
    shellAliases = {
      ll = "ls -alF";

      # `gitcheck` reports, `gitclean` deletes; both take their scripts' own flags
      # appended, so no flag needs an alias of its own.
      gitcheck = "gitchecker ${gitRootArgs}";
      gitclean = "gitcleaner ${gitRootArgs}";

      k = "kiro-cli chat";
      kwsl = ''(cd "${cfg.repoPath}" && kiro-cli chat)'';

      c = "claude";
    }
    # Trust-all outranks the agent's deniedCommands, so the destructive floor does
    # not apply under `kk`; hence the opt-in.
    // lib.optionalAttrs cfg.kiroTrustAll {
      kk = "kiro-cli chat --trust-all-tools";
    }
    # The Claude-side twin, gated for the same reason.
    // lib.optionalAttrs cfg.claudeTrustAll {
      cc = "claude --dangerously-skip-permissions";
    }
    # Last, so an overlay's customAliases can override any of the above.
    // cfg.customAliases;
    oh-my-zsh = {
      enable = true;
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

      # nixpkgs' pre-patched browsers, so nix-ld is not needed. Playwright matches
      # browsers by revision, so a harness pinning PW_VERSION must track playwright-driver.
      export PLAYWRIGHT_BROWSERS_PATH="${pkgs.playwright-driver.browsers}"
      export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
    '';
    initContent = ''
      export GPG_TTY="$(tty)"

      ${homeJump}# Runtime secrets from exactly one source, chosen at build time by
      # whether the overlay set `sopsSecretsFile`. No runtime fallback: an enrolled
      # box with no render must start with no secrets rather than source a stale file.
      # The `tr -d` strips CRs, which land inside the quoted value and corrupt tokens.
      ${
        if cfg.sopsSecretsFile != null then
          ''
            if [[ -r /run/secrets/tyc-env ]]; then
              set -a; source =(tr -d '\r' < /run/secrets/tyc-env); set +a
            fi
          ''
        else
          ''
            if [[ -r "$HOME/.config/tyc/secrets.env" ]]; then
              set -a; source =(tr -d '\r' < "$HOME/.config/tyc/secrets.env"); set +a
            fi
          ''
      }

      # `bwu` unlocks on the TTY and parks the per-unlock token in a mode-600 file
      # every shell exports from, so it never rides a command line or a transcript.
      if [[ -r "$HOME/.config/tyc/bw-session" ]]; then
        export BW_SESSION="$(tr -d '\r\n' < "$HOME/.config/tyc/bw-session")"
      fi
      bwu() {
        local _f="$HOME/.config/tyc/bw-session" _t
        _t="$(bw unlock --raw)" || return 1
        mkdir -p "$HOME/.config/tyc" && chmod 700 "$HOME/.config/tyc"
        (umask 077; printf '%s\n' "$_t" > "$_f") || return 1
        export BW_SESSION="$_t"
        echo "bw: unlocked — token in $_f, exported to new shells (bwl to lock)"
      }
      bwl() {
        bw lock
        rm -f "$HOME/.config/tyc/bw-session"
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

      # The Claude mcp-homeassistant plugin expands HA_URL/HA_TOKEN, not HASS_*.
      [[ -n "''${HASS_URL:-}" ]] && export HA_URL="$HASS_URL"
      [[ -n "''${HASS_TOKEN:-}" ]] && export HA_TOKEN="$HASS_TOKEN"

      # Merge every ~/.kube/*.yaml into KUBECONFIG.
      export KUBECONFIG="$HOME/.kube/config:"
      for file in $HOME/.kube/*.yaml(N); do
        export KUBECONFIG="$KUBECONFIG$file:"
      done

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

      # Keybindings.
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
}
