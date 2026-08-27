# zsh + Oh My Zsh: history, aliases, env, and the interactive init block
# (secrets sourcing, ssh-add hook, prompt, keybindings).
#
# initContent is for work that must happen IN the interactive shell. Anything
# that is really a command belongs in files/scripts with a wrapper in
# nix/scripts.nix and routed through `flakelab` (nix/cli.nix) — that is where
# nix-update went, as `flakelab update`.
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
  flakelab,
  ...
}:
let
  cfg = osConfig.flakelab;
  inherit (flakelab) isWsl sshKeys;

  # The jump is WSL-only and needs a Windows user to jump away from: nothing
  # else has a Windows profile directory a shell can start in.
  homeJump = lib.optionalString (isWsl && cfg.windowsUsername != null) ''
    # Jump to Linux home only when the shell starts at a Windows default entry
    # path. There are two: the Windows profile root, and C:\Windows\System32 —
    # the WSL profiles Windows Terminal generates carry no startingDirectory,
    # so the distro inherits Terminal's own cwd, which is System32 whenever
    # Terminal itself was launched from the Start menu or a pinned icon.
    # Shells deliberately opened elsewhere on /mnt — e.g. a file manager's
    # "open shell here" — keep their directory. Guarded so a .zshrc re-source
    # never re-triggers the jump mid-session.
    #
    # Both sides are lowercased with zsh's :l modifier: windowsUsername is free
    # text typed into the overlay, while $PWD carries the profile directory
    # name as Windows actually stores it — Windows preserves case but does not
    # enforce it, so a mismatched-case configured name would silently stop the
    # jump on a literal compare.
    if [[ -z "''${_flakelab_home_jump:-}" ]]; then
      _flakelab_home_jump=1
      _flakelab_win_home="/mnt/c/Users/${cfg.windowsUsername}"
      [[ "''${PWD:l}" == "''${_flakelab_win_home:l}" || "''${PWD:l}" == /mnt/c/windows/system32 ]] && cd ~
      unset _flakelab_win_home
    fi

  '';

  # gitcheck/gitclean scan roots, built once so the reporter and the deleter
  # cannot disagree about what is in scope. extraReposDirs adds roots beyond
  # ~/git — e.g. the Windows-mount tree that predates the group layout and
  # still holds clones that exist nowhere else.
  inherit (cfg) extraReposDirs;
  gitRootArgs = lib.concatStringsSep " " (
    [ ''--repos-dir "$HOME/git"'' ] ++ map (d: ''--repos-dir "${d}"'') extraReposDirs
  );
in
{
  # ── zsh + Oh My Zsh (replaces tasks/zsh.yaml + tasks/shell_config.yaml) ────
  programs.zsh = {
    enable = true;
    history = {
      size = 1000000;
      save = 1000000;
      path = "${config.home.homeDirectory}/.zsh_history";
      extended = true;
      ignoreDups = true;
    };
    # Home Manager writes these AFTER initContent in .zshrc (and both come after
    # `source $ZSH/oh-my-zsh.sh`), so `k` still shadows the kubectl plugin's
    # `k=kubectl` exactly as it did while these lived in initContent. It emits
    # them as `alias -- <name>=<shell-quoted value>`, so the `--` is part of
    # every generated line — anything grepping .zshrc for a bare `alias k=`
    # has to allow for it (files/scripts/test-provision-nix does).
    shellAliases = {
      ll = "ls -alF";

      # git — one alias per half. `gitcheck` reports (uncommitted, ahead/behind,
      # diverged, gone, stashes, open MRs); `gitclean` retires the branches and
      # worktree entries whose work has landed, asking about each one. Both get
      # the same roots (gitRootArgs, built once in nix/home/zsh.nix) so the reporter and
      # the deleter cannot disagree about what is in scope. zsh expands an alias
      # as a command prefix, so every flag the scripts take still works appended
      # — `gitcheck --dirty-only`, `gitclean --dry-run`, `gitclean --repo .
      # --json`. A flag therefore needs no alias of its own, and `--help` stays
      # the one list of them.
      gitcheck = "gitchecker ${gitRootArgs}";
      gitclean = "gitcleaner ${gitRootArgs}";

      # kiro
      # `k`  — everyday entrypoint. The default agent auto-runs file writes + the safe
      #        git write-flow; push/apply and anything unlisted prompt. The worst-only
      #        destructive set (force-push, reset --hard, clean -f, branch -D, rm -rf)
      #        is denied via the agent's deniedCommands and cannot be bypassed by
      #        instruction.
      # `kk` — FULL TRUST (--trust-all-tools), only with flakelab.kiroTrustAll.
      #        Auto-approves every tool. Trust-all
      #        outranks deniedCommands, so the destructive floor does NOT apply under
      #        `kk` (only write.deniedPaths secret gates remain). Use `k` for risky
      #        work; reach for `kk` only when you knowingly accept full send.
      k = "kiro-cli chat";
      kwsl = ''(cd "${cfg.repoPath}" && kiro-cli chat)'';

      # claude (mirrors k/kk/kwsl)
      # `c`  — everyday Claude Code.
      # `cc` — FULL TRUST (--dangerously-skip-permissions), only with
      #        flakelab.claudeTrustAll. Auto-approves every
      #        tool with no permission prompts. Use `c` for risky work; reach for
      #        `cc` only when you knowingly accept full send. (Shadows the C
      #        compiler name, but only in interactive shells — scripts are
      #        unaffected since aliases don't expand there.)
      # `cwsl` — Claude Code in the flake repo dir.
      c = "claude";
      cwsl = ''(cd "${cfg.repoPath}" && claude)'';
    }
    # `kk` ships ONLY when the operator opts in (flakelab.kiroTrustAll). Trust-all
    # outranks the agent's deniedCommands, so the destructive floor does not apply
    # under it — an adopter who never read that should not inherit the alias.
    // lib.optionalAttrs cfg.kiroTrustAll {
      kk = "kiro-cli chat --trust-all-tools";
    }
    # `cc` is the Claude-side twin and gates the same way (flakelab.claudeTrustAll):
    # --dangerously-skip-permissions removes the prompt that is the only thing
    # between an agent and an unreviewed command.
    // lib.optionalAttrs cfg.claudeTrustAll {
      cc = "claude --dangerously-skip-permissions";
    }
    # LAST, so an overlay's customAliases can override any of the above.
    // cfg.customAliases;
    oh-my-zsh = {
      enable = true;
      plugins = [
        "git"
        "kubectl"
        "helm"
        "docker"
      ]; # kubectl plugin provides k* aliases
    };
    # .zshenv, so it applies to ALL zsh contexts (pre-commit hooks, MCP servers),
    # not just interactive shells.
    envExtra = ''
      # The pinned npm (home.activation.pinNpm) must beat the bundled npm 11
      # from the nix profile — prepend, sessionPath only appends.
      export PATH="$HOME/.npm-global/bin:$PATH"

      # Host browser for harnesses that launch chromium on the host. nixpkgs'
      # pre-patched browsers avoid nix-ld, whose search path would need ~52 libs.
      # In .zshenv because driver.sh runs non-interactive. Playwright matches
      # browsers by revision, so a harness pinning PW_VERSION must track
      # playwright-driver (currently 1.61.1, browser revision 1228).
      export PLAYWRIGHT_BROWSERS_PATH="${pkgs.playwright-driver.browsers}"
      export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
    '';
    initContent = ''
      export GPG_TTY="$(tty)"

      ${homeJump}# Load runtime secrets from a git-ignored env file if present. Populate it
      # from OpenBao (e.g. `bao kv get`) or export the vars yourself — nothing is
      # baked into the repo or the Nix store.
      #
      # Sourced through `tr -d '\r'`: a file written from PowerShell keeps CRLF
      # line endings, and because the values are single-quoted (export K='v') the
      # CR lands INSIDE the value — a 62-character GITLAB_TOKEN arrives as 63 and
      # every GitLab API call dies with `invalid header field value for
      # "Private-Token"`. Stripping it here keeps such a file working.
      if [[ -r "$HOME/.config/tyc/secrets.env" ]]; then
        set -a; source =(tr -d '\r' < "$HOME/.config/tyc/secrets.env"); set +a
      fi

      # services.ssh-agent starts an agent but loads no key, and ssh_config(5)
      # adds one via `AddKeysToAgent yes` only when ssh itself loads a key from a
      # file mid-connection — which for a passphrase-protected key means prompting
      # on a TTY first. Neither seeds an empty agent, so without this hook every
      # git@ clone fails with "Permission denied (publickey)". Gated on a real
      # TTY: the non-interactive paths that would hang on a passphrase prompt
      # (known-issues.md) must never reach ssh-add.
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

      # Map HASS_* → HA_* for the Claude mcp-homeassistant plugin, whose
      # .mcp.json expands HA_URL/HA_TOKEN (the Kiro server wrapper does its own
      # mapping in nix/home/mcp.nix).
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
