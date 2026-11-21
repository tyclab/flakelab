# Loaded only in interactive WSL zsh. Nested shells inherit the outer marker.
[[ -o interactive && -t 0 && -t 1 && -n ${WSL_DISTRO_NAME:-} && -n ${WT_SESSION:-} &&
   -z ${TMUX:-} && -z ${SSH_CONNECTION:-} && -z ${CLAUDECODE:-} && -z ${CODEX_THREAD_ID:-} &&
   ${FLAKELAB_TYCSNAP_ACTIVE:-} != "$WT_SESSION" ]] || return 0

autoload -Uz add-zsh-hook
export FLAKELAB_TYCSNAP_ACTIVE="$WT_SESSION" FLAKELAB_TYCSNAP_OWNER=$$
typeset -g _tycsnap_name="" _tycsnap_dirty="" _tycsnap_ready=""

_tycsnap_update() {
  [[ -n "$_tycsnap_ready" ]] || return 0
  _tycsnap_name="$(command flakelab sessions --tab-state update "$PWD")"
}

# A custom shell title survives a fresh Windows Terminal window as well as a
# native layout restore. Clearing it gives title control back to oh-my-zsh.
tycsnap-name() {
  [[ $# == 1 ]] || { print -ru2 -- 'Usage: tycsnap-name "tab title"'; return 2 }
  command flakelab tycsnap --name "$1"
}

# A single foreground executable lets zsh preserve stop/fg and the native
# exit status. The launcher passes pipes, redirects and background jobs through.
if (( ! ${+aliases[codex]} && ! ${+functions[codex]} )); then
  alias codex='command flakelab sessions --tab-state codex'
fi

_tycsnap_preexec() {
  _tycsnap_dirty=1
}

_tycsnap_prompt() {
  local entry action dir name
  if [[ -z "$_tycsnap_ready" ]]; then
    entry="$(command flakelab sessions --tab-state enter)" || return 0
    unset FLAKELAB_TYCSNAP_SOURCE
    action="$(jq -r '.action // empty' <<<"$entry")"
    [[ "$action" != superseded ]] || exit 0
    if [[ "$action" == restore ]]; then
      dir="$(jq -r .cwd <<<"$entry")"
      name="$(jq -r .name <<<"$entry")"
      [[ "$name" == *[[:cntrl:]]* ]] || _tycsnap_name="$name"
      [[ -d "$dir" ]] && builtin cd -- "$dir"
    fi
    _tycsnap_ready=1
    if [[ -n "$action" ]]; then
      [[ -z "$_tycsnap_name" ]] || printf '\033]2;%s\007' "$_tycsnap_name"
      FLAKELAB_TYCSNAP_START=1 command flakelab tycsnap
      _tycsnap_update
    fi
  elif [[ -n "$_tycsnap_dirty" ]]; then
    _tycsnap_update
  fi
  _tycsnap_dirty=""
  [[ -z "$_tycsnap_name" ]] || printf '\033]2;%s\007' "$_tycsnap_name"
}

_tycsnap_exit() {
  # On a terminal hangup its PTY can no longer answer tcgetattr. A typed
  # exit or Ctrl-D reaches zshexit with a working tty.
  [[ -n "$_tycsnap_ready" && -t 0 ]] && command flakelab sessions --tab-state exit
  return 0
}

add-zsh-hook precmd _tycsnap_prompt
add-zsh-hook preexec _tycsnap_preexec
add-zsh-hook chpwd _tycsnap_update
add-zsh-hook zshexit _tycsnap_exit
