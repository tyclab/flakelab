# The one copy of this repo's network-facing plumbing: SSH options and one retry
# helper. Sourced, not executed, by clone-repos and lib/gitscan.zsh.

typeset -g GITNET_SSH_BASE="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3"

# Callers may set this to a timeout wrapper (e.g. `timeout -k 5 30`); an array,
# because zsh does not word-split a plain expansion.
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
