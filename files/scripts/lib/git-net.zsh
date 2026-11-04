# Network plumbing shared by clone-repos and lib/gitscan.zsh: SSH options and one retry helper.
typeset -g GITNET_SSH_BASE="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3"

# Optional timeout wrapper (`timeout -k 5 30`); an array, as zsh does not word-split a plain expansion.
typeset -ga GITNET_TIMEOUT_CMD=()

# gitnet_retry <command> [arg...] — GITNET_OUT holds the combined output, and on
# failure GITNET_WHY holds "rc N" or "timed out"; the caller owns the messaging.
gitnet_retry() {
  local -i _rc=0
  typeset -g GITNET_OUT="" GITNET_WHY=""
  GITNET_OUT="$("${GITNET_TIMEOUT_CMD[@]}" "$@" 2>&1)" || _rc=$?
  if (( _rc != 0 )); then
    sleep 2
    _rc=0
    GITNET_OUT="$("${GITNET_TIMEOUT_CMD[@]}" "$@" 2>&1)" || _rc=$?
  fi
  (( _rc == 0 )) && return 0
  GITNET_WHY="rc ${_rc}"
  (( _rc == 124 || _rc == 137 )) && GITNET_WHY="timed out"
  return ${_rc}
}

# gitnet_push_once <git push command> — hooks may run for minutes or queue on a
# shared validation lock. A whole-command network timeout would kill that work;
# bound idle transports instead, and never repeat a hook or an ambiguous write.
gitnet_push_once() {
  local -i _rc=0
  local -a transport_env=(GIT_TERMINAL_PROMPT=0
    "GIT_HTTP_LOW_SPEED_LIMIT=${GIT_HTTP_LOW_SPEED_LIMIT:-1}"
    "GIT_HTTP_LOW_SPEED_TIME=${GIT_HTTP_LOW_SPEED_TIME:-30}")
  # GIT_SSH_COMMAND outranks GIT_SSH, so do not mask either explicit override.
  if [[ -z "${GIT_SSH_COMMAND-}" && -z "${GIT_SSH-}" ]]; then
    transport_env+=("GIT_SSH_COMMAND=ssh ${GITNET_SSH_BASE}")
  fi
  typeset -g GITNET_OUT="" GITNET_WHY=""
  GITNET_OUT="$(env "${transport_env[@]}" "$@" 2>&1)" || _rc=$?
  (( _rc == 0 )) && return 0
  GITNET_WHY="rc ${_rc}"
  (( _rc == 124 || _rc == 137 )) && GITNET_WHY="timed out"
  return ${_rc}
}
