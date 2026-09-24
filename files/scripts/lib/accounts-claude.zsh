# accounts-claude.zsh — the Claude Code adapter for files/scripts/accounts.
#
# Sourced, never run. The adapter contract every tool answers (accounts.md,
# "The adapter contract"), as zsh functions named acct_claude_*; the main
# script never branches on the tool name, it calls acct_${tool}_<question>.
#
# Where Claude Code keeps the live login (external contract):
#   ~/.claude/.credentials.json   {"claudeAiOauth": {accessToken, refreshToken,
#                                 expiresAt (epoch ms), scopes, ...}}; 0600
#   ~/.claude.json                oauthAccount {emailAddress, accountUuid,
#                                 organizationUuid, organizationName, ...}
#                                 beside every other key that file carries
#                                 (projects, mcpServers, theme, ...); an
#                                 API-key login is `primaryApiKey` here
# Its lock: a DIRECTORY, ~/.claude.lock for the credentials and
# ~/.claude.json.lock for the config, mkdir as the mutex; stale when its mtime
# is older than ten seconds; the holder touches it every few seconds. Claude
# Code's own token refresh reads, refreshes and saves under that lock and
# re-reads before saving, so a credential swapped in under it makes the
# refresh stand down instead of overwriting the new login with the old
# account's rotated token.
#
# The live login is always the default one under $HOME, never a profile: a
# shell pinned with CLAUDE_CONFIG_DIR gets a note and the default login.

ACCT_CLAUDE_HOME="${HOME}/.claude"
ACCT_CLAUDE_CREDS="${ACCT_CLAUDE_HOME}/.credentials.json"
ACCT_CLAUDE_CONFIG="${HOME}/.claude.json"
ACCT_CLAUDE_LOCK_CREDS="${ACCT_CLAUDE_HOME}.lock"
ACCT_CLAUDE_LOCK_CONFIG="${ACCT_CLAUDE_CONFIG}.lock"
# Claude Code's constants: a lock older than this is a dead holder's.
ACCT_CLAUDE_LOCK_STALE_S="${FLAKELAB_ACCOUNTS_LOCK_STALE:-10}"
# Comfortably outlasts a refresh's few-second hold without stalling a CLI.
ACCT_CLAUDE_LOCK_TIMEOUT_S="${FLAKELAB_ACCOUNTS_LOCK_TIMEOUT:-9}"

# The files an entry of this tool holds under <store>/<id>/.
acct_claude_files() { print -rl -- credentials.json identity.json }

# What the tool runs as, for the running-session count.
acct_claude_process() { print -r -- claude }

# The live login's identity as one JSON object {id, label, org}, or:
#   exit 1  no login (no oauthAccount, or no credential file)
#   exit 3  an API-key login (primaryApiKey, or a credential that is not the
#           OAuth blob): a different auth axis, never an entry
acct_claude_identity() {
  local cfg
  [[ -r "${ACCT_CLAUDE_CONFIG}" ]] || return 1
  cfg="$(jq -c '{
      id: (.oauthAccount.accountUuid // ""),
      label: (.oauthAccount.emailAddress // ""),
      org: (.oauthAccount.organizationName // "personal"),
      apiKey: ((.primaryApiKey // "") != "")
    }' "${ACCT_CLAUDE_CONFIG}" 2>/dev/null)" || return 1
  [[ "$(print -r -- "$cfg" | jq -r '.apiKey')" == true ]] && return 3
  [[ -n "$(print -r -- "$cfg" | jq -r '.id')" ]] || return 1
  [[ -r "${ACCT_CLAUDE_CREDS}" ]] || return 1
  jq -e '.claudeAiOauth.accessToken? // empty | length > 0' "${ACCT_CLAUDE_CREDS}" >/dev/null 2>&1 || return 3
  print -r -- "$cfg" | jq -c 'del(.apiKey)'
}

# Copy the live login into DIR: the credential verbatim, the identity block
# plus the theme (a profile seeded from it must not start on onboarding).
acct_claude_read_live() {
  local dir="$1"
  [[ -r "${ACCT_CLAUDE_CREDS}" && -r "${ACCT_CLAUDE_CONFIG}" ]] || return 1
  (umask 077; cp -- "${ACCT_CLAUDE_CREDS}" "${dir}/credentials.json.tmp") || return 1
  (umask 077; jq '{oauthAccount: .oauthAccount, theme: (.theme // null)}' "${ACCT_CLAUDE_CONFIG}" > "${dir}/identity.json.tmp") || { rm -f "${dir}/credentials.json.tmp"; return 1 }
  mv -f -- "${dir}/credentials.json.tmp" "${dir}/credentials.json" || return 1
  mv -f -- "${dir}/identity.json.tmp" "${dir}/identity.json" || return 1
}

# The live credential's bytes and the live config's bytes, for a rollback;
# empty when the file is absent.
acct_claude_snapshot_live() {
  ACCT_LIVE_CREDS=""; ACCT_LIVE_CONFIG=""; ACCT_LIVE_CREDS_EXISTED=false
  if [[ -f "${ACCT_CLAUDE_CREDS}" ]]; then
    ACCT_LIVE_CREDS="$(<"${ACCT_CLAUDE_CREDS}")" || return 1
    ACCT_LIVE_CREDS_EXISTED=true
  fi
  [[ -f "${ACCT_CLAUDE_CONFIG}" ]] && { ACCT_LIVE_CONFIG="$(<"${ACCT_CLAUDE_CONFIG}")" || return 1 }
  return 0
}

# Make DIR's stored login the live one: the credential file replaced whole
# (temp beside it, 0600, rename), the identity spliced into ~/.claude.json
# with every other key left as it was. FLAKELAB_ACCOUNTS_FAIL_AT is the
# suite's seam for the rollback path.
acct_claude_write_live() {
  local dir="$1" tmp
  [[ -r "${dir}/credentials.json" && -r "${dir}/identity.json" ]] || { print -ru2 -- "Error: entry has no stored login (${dir})"; return 1 }
  mkdir -p -- "${ACCT_CLAUDE_HOME}" || return 1
  tmp="${ACCT_CLAUDE_CREDS}.flakelab-tmp.$$"
  (umask 077; cp -- "${dir}/credentials.json" "$tmp") || { rm -f "$tmp"; return 1 }
  [[ "${FLAKELAB_ACCOUNTS_FAIL_AT:-}" == credentials ]] && { rm -f "$tmp"; return 1 }
  mv -f -- "$tmp" "${ACCT_CLAUDE_CREDS}" || { rm -f "$tmp"; return 1 }
  tmp="${ACCT_CLAUDE_CONFIG}.flakelab-tmp.$$"
  [[ -s "${ACCT_CLAUDE_CONFIG}" ]] || print -r -- '{}' > "${ACCT_CLAUDE_CONFIG}"
  if ! (umask 077; jq --slurpfile ident "${dir}/identity.json" '
        .oauthAccount = $ident[0].oauthAccount
        | .hasCompletedOnboarding = true
        | if (.theme // "") == "" and ($ident[0].theme // "") != "" then .theme = $ident[0].theme else . end
      ' "${ACCT_CLAUDE_CONFIG}" > "$tmp") || [[ "${FLAKELAB_ACCOUNTS_FAIL_AT:-}" == config ]]; then
    rm -f "$tmp"
    return 1
  fi
  mv -f -- "$tmp" "${ACCT_CLAUDE_CONFIG}" || { rm -f "$tmp"; return 1 }
  chmod 600 "${ACCT_CLAUDE_CONFIG}" 2>/dev/null
  return 0
}

# Put the snapshot back, credentials last so a half-restored state never
# pairs a new credential with the old identity.
acct_claude_restore_live() {
  local tmp
  if [[ -n "${ACCT_LIVE_CONFIG}" ]]; then
    tmp="${ACCT_CLAUDE_CONFIG}.flakelab-tmp.$$"
    (umask 077; print -rn -- "${ACCT_LIVE_CONFIG}" > "$tmp") && mv -f -- "$tmp" "${ACCT_CLAUDE_CONFIG}"
  fi
  if ${ACCT_LIVE_CREDS_EXISTED}; then
    tmp="${ACCT_CLAUDE_CREDS}.flakelab-tmp.$$"
    (umask 077; print -rn -- "${ACCT_LIVE_CREDS}" > "$tmp") && mv -f -- "$tmp" "${ACCT_CLAUDE_CREDS}"
  else
    rm -f -- "${ACCT_CLAUDE_CREDS}"
  fi
}

# --- Claude Code's own locks -------------------------------------------------

# Acquire one lock directory with Claude Code's protocol: mkdir is the mutex;
# a directory whose mtime is older than the staleness is a dead holder's and
# is removed and retaken; otherwise wait a jittered quarter to half second
# and try again, for at most the timeout. Then keep it fresh from a toucher
# in the background. Returns 1 on timeout with nothing taken.
typeset -a ACCT_CLAUDE_HELD=()
acct_claude_lock_one() {
  local dir="$1" start now age
  mkdir -p -- "${dir:h}" 2>/dev/null
  start=$EPOCHREALTIME
  while true; do
    if mkdir -- "$dir" 2>/dev/null; then
      ( while sleep 3; do touch -- "$dir" 2>/dev/null || exit 0; done ) &
      ACCT_CLAUDE_HELD+=("${dir}${US}$!")
      return 0
    fi
    now=$EPOCHREALTIME
    (( now - start > ACCT_CLAUDE_LOCK_TIMEOUT_S )) && return 1
    age=$(( $(date +%s) - $(stat -c %Y -- "$dir" 2>/dev/null || print 0) ))
    if [[ -d "$dir" ]] && (( age > ACCT_CLAUDE_LOCK_STALE_S )); then
      rmdir -- "$dir" 2>/dev/null || sleep 0.05
      continue
    fi
    sleep "0.$(( 25 + RANDOM % 25 ))"
  done
}

# Both locks, credentials first as Claude Code takes them; on a timeout
# whatever was taken is released and the caller refuses.
acct_claude_lock() {
  zmodload zsh/datetime 2>/dev/null
  acct_claude_lock_one "${ACCT_CLAUDE_LOCK_CREDS}" || return 1
  acct_claude_lock_one "${ACCT_CLAUDE_LOCK_CONFIG}" || { acct_claude_unlock; return 1 }
  return 0
}

acct_claude_unlock() {
  local held dir pid
  for held in "${ACCT_CLAUDE_HELD[@]}"; do
    IFS="$US" read -r dir pid <<<"$held"
    kill "$pid" 2>/dev/null
    rmdir -- "$dir" 2>/dev/null
  done
  ACCT_CLAUDE_HELD=()
}

# A switch of the live login reaches running sessions on their next message
# on Linux (verify 1 in accounts.md); nothing to refuse, one line to say.
acct_claude_after_switch() {
  local n="$1"
  if (( n > 0 )); then
    print -r -- "${n} running claude session(s) continue on the new account with their next message; no restart needed."
  fi
}
