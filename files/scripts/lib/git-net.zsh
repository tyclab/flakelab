# git-net.zsh — the one copy of this repo's network-facing plumbing.
#
# Sourced (not executed) by clone-repos and, via lib/gitscan.zsh, by gitchecker
# and gitcleaner. Two things live here, and only these two — everything
# else about those callers differs on purpose (mux scope, timeouts, abort
# semantics, key handling) and stays with the caller:
#
#   GITNET_SSH_BASE — bound the connect, keep the session alive. Without the
#     ConnectTimeout a dead network hangs at the TCP default; without the
#     keepalives gitlab.com drops long-lived multiplexed sessions mid-sweep.
#
#   gitnet_retry — run a network call with the reason kept. A silenced call
#     reports "failed" with no cause and cannot be diagnosed afterwards
#     (737cb49). One retry after 2s: a fetch transient with EMPTY output hit
#     gitchecker on 2026-08-07 and a forge transient on 2026-08-10; both
#     passed by hand seconds later. rc 124/137 is a timeout wrapper killing
#     the command — name it, since a killed process prints nothing and the
#     failure would otherwise read as blind.

typeset -g GITNET_SSH_BASE="-o ConnectTimeout=10 -o ServerAliveInterval=15 -o ServerAliveCountMax=3"

# Callers may bound each attempt by setting this array to a timeout wrapper
# (e.g. `timeout -k 5 30`). Declared here so the empty default survives
# `set -u`; kept as an array because zsh does not word-split a plain
# expansion, so a string prefix would be passed as one argv entry.
typeset -ga GITNET_TIMEOUT_CMD=()

# gitnet_retry <command> [arg...]
#
# rc 0    — succeeded (possibly on the retry); GITNET_OUT holds any output.
# rc != 0 — both attempts failed: GITNET_OUT holds the last combined output,
#           GITNET_WHY holds "rc N" or "timed out". The caller owns the
#           messaging — gitchecker aborts the sweep, clone-repos records a
#           per-repo result, gitcleaner skips the repo.
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
