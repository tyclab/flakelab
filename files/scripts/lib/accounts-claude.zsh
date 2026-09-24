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

# --- usage ---------------------------------------------------------------------
#
# The endpoints Claude Code itself uses (accounts.md, "Prior art"): the token
# refresh on platform.claude.com with the CLI's public client id, and the
# usage report on api.anthropic.com. Both are variables so the suite can point
# them at canned answers through a curl stand-in; nothing else about them is
# configurable. The usage endpoint's rate limit on non-first-party clients is
# about 28 to 30 requests per token per rolling hour, which the poll plan in
# the main script keeps under with a margin; this adapter only fetches when
# asked.

ACCT_CLAUDE_TOKEN_URL="${FLAKELAB_ACCOUNTS_CLAUDE_TOKEN_URL:-https://platform.claude.com/v1/oauth/token}"
ACCT_CLAUDE_USAGE_URL="${FLAKELAB_ACCOUNTS_CLAUDE_USAGE_URL:-https://api.anthropic.com/api/oauth/usage}"
ACCT_CLAUDE_CLIENT_ID="9d1c250a-e61b-44d9-88ed-5944d1962f5e"
ACCT_CLAUDE_BETA="oauth-2025-04-20"
ACCT_CLAUDE_UA="flakelab-accounts/1.0"
# Refresh an inactive token this close to its expiry (ms): twice Claude Code's
# own five-minute buffer, so a token handed to a session outlives its check.
ACCT_CLAUDE_REFRESH_BUFFER_MS=600000

# The credential file an entry's usage is read with: the live file for the
# active entry (its token belongs to Claude Code and is never refreshed here),
# the stored one otherwise.
acct_claude_creds_path() {
  local dir="$1" active="$2"
  case "$active" in
    true) print -r -- "${ACCT_CLAUDE_CREDS}" ;;        # the live login, Claude Code's to refresh
    profile) print -r -- "${dir}/.credentials.json" ;;  # a running profile's, its session's to refresh
    *) print -r -- "${dir}/credentials.json" ;;         # the store's, ours
  esac
}

# A lineage fingerprint: the refresh token's hash survives access-token
# rotation; a credential without one hashes whole.
acct_claude_fingerprint() {
  local file="$1" rt
  [[ -r "$file" ]] || return 1
  rt="$(jq -r '.claudeAiOauth.refreshToken // empty' "$file" 2>/dev/null)"
  if [[ -n "$rt" ]]; then
    print -r -- "sha256:$(print -rn -- "$rt" | sha256sum | cut -d' ' -f1)"
  else
    print -r -- "sha256-full:$(sha256sum < "$file" | cut -d' ' -f1)"
  fi
}

# Refresh the token in FILE in place (temp beside it, rename). Prints ok,
# invalid_grant (the lineage is dead: quarantine it) or transient.
acct_claude_refresh() {
  local file="$1" rt body code tmp now_ms
  rt="$(jq -r '.claudeAiOauth.refreshToken // empty' "$file" 2>/dev/null)"
  [[ -n "$rt" ]] || { print -r -- invalid_grant; return 2 }
  body="$(mktemp)"
  code="$(curl -sS -m 10 -o "$body" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' -H "User-Agent: ${ACCT_CLAUDE_UA}" \
    -d "$(jq -cn --arg rt "$rt" --arg cid "${ACCT_CLAUDE_CLIENT_ID}" '{grant_type: "refresh_token", refresh_token: $rt, client_id: $cid}')" \
    "${ACCT_CLAUDE_TOKEN_URL}" 2>/dev/null)" || code=000
  if [[ "$code" == 200 ]] && jq -e '.access_token? // empty | length > 0' "$body" >/dev/null 2>&1; then
    now_ms=$(( ${FLAKELAB_NOW:-$(date +%s)} * 1000 ))
    tmp="${file}.flakelab-tmp.$$"
    if (umask 077; jq --slurpfile r "$body" --argjson now "$now_ms" '
          .claudeAiOauth.accessToken = $r[0].access_token
          | .claudeAiOauth.expiresAt = ($now + (($r[0].expires_in // 3600) * 1000))
          | (if ($r[0].refresh_token // "") != "" then .claudeAiOauth.refreshToken = $r[0].refresh_token else . end)
          | (if ($r[0].scope // "") != "" then .claudeAiOauth.scopes = ($r[0].scope | split(" ")) else . end)
        ' "$file" > "$tmp") && mv -f -- "$tmp" "$file"; then
      rm -f "$body"; print -r -- ok; return 0
    fi
    rm -f "$tmp" "$body"; print -r -- transient; return 1
  fi
  if [[ "$code" == 400 || "$code" == 401 || "$code" == 403 ]] && grep -qE 'invalid_grant|invalid_client' "$body" 2>/dev/null; then
    rm -f "$body"; print -r -- invalid_grant; return 2
  fi
  rm -f "$body"; print -r -- transient; return 1
}

# Normalise the usage report into the cache's window list: the two
# account-wide windows and every model-scoped entry of limits[]. resets_at
# fractions are dropped so jq can parse the stamp.
acct_claude_normalise() {
  jq -c '
    def stamp: if . == null or . == "" then null else (. | sub("\\.[0-9]+"; "")) end;
    def epoch: if . == null then null else (try (. | fromdateiso8601) catch null) end;
    [ (if (.five_hour.utilization? | numbers) != null then
        {label: "5h", class: "session", pct: .five_hour.utilization, resetsAt: (.five_hour.resets_at | stamp)} else empty end),
      (if (.seven_day.utilization? | numbers) != null then
        {label: "7d", class: "week", pct: .seven_day.utilization, resetsAt: (.seven_day.resets_at | stamp)} else empty end),
      ((.limits // []) | .[] | select(type == "object") | select((.scope.model.display_name? // "") != "" and (.percent? | numbers) != null)
        | {label: .scope.model.display_name, class: "model", pct: .percent, resetsAt: (.resets_at | stamp)})
    ] | map(. + {resetsAtEpoch: (.resetsAt | epoch)})'
}

# Usage for one entry: {ok: true, windows: [...]} or {ok: false, error, retryAfter}.
# An inactive entry's expired token is refreshed first and persisted before
# use; a 401 on an inactive entry with a refresh token is retried once after a
# refresh; the active entry's token is read as Claude Code left it.
acct_claude_usage() {
  local dir="$1" active="$2" file tok now_ms expires body hdr code retry outcome
  file="$(acct_claude_creds_path "$dir" "$active")"
  [[ -r "$file" ]] || { jq -cn '{ok: false, error: "no-credentials"}'; return 0 }
  now_ms=$(( ${FLAKELAB_NOW:-$(date +%s)} * 1000 ))
  expires="$(jq -r '.claudeAiOauth.expiresAt // empty' "$file" 2>/dev/null)"
  if [[ "$active" == false && "$expires" == <-> ]] && (( now_ms + ACCT_CLAUDE_REFRESH_BUFFER_MS >= expires )); then
    outcome="$(acct_claude_refresh "$file")"
    [[ "$outcome" == invalid_grant ]] && { jq -cn '{ok: false, error: "invalid_grant"}'; return 0 }
  fi
  tok="$(jq -r '.claudeAiOauth.accessToken // empty' "$file" 2>/dev/null)"
  [[ -n "$tok" ]] || { jq -cn '{ok: false, error: "no-access-token"}'; return 0 }
  body="$(mktemp)"; hdr="$(mktemp)"
  code="$(curl -sS -m 10 -o "$body" -D "$hdr" -w '%{http_code}' \
    -H "Authorization: Bearer ${tok}" -H "anthropic-beta: ${ACCT_CLAUDE_BETA}" -H "User-Agent: ${ACCT_CLAUDE_UA}" \
    "${ACCT_CLAUDE_USAGE_URL}" 2>/dev/null)" || code=000
  if [[ "$code" == 401 && "$active" == false ]]; then
    outcome="$(acct_claude_refresh "$file")"
    case "$outcome" in
      ok)
        tok="$(jq -r '.claudeAiOauth.accessToken // empty' "$file" 2>/dev/null)"
        code="$(curl -sS -m 10 -o "$body" -D "$hdr" -w '%{http_code}' \
          -H "Authorization: Bearer ${tok}" -H "anthropic-beta: ${ACCT_CLAUDE_BETA}" -H "User-Agent: ${ACCT_CLAUDE_UA}" \
          "${ACCT_CLAUDE_USAGE_URL}" 2>/dev/null)" || code=000 ;;
      invalid_grant) rm -f "$body" "$hdr"; jq -cn '{ok: false, error: "invalid_grant"}'; return 0 ;;
      *) rm -f "$body" "$hdr"; jq -cn '{ok: false, error: "refresh-failed"}'; return 0 ;;
    esac
  fi
  case "$code" in
    200)
      if acct_claude_normalise < "$body" | jq -c '{ok: true, windows: .}' 2>/dev/null; then :; else jq -cn '{ok: false, error: "bad-response"}'; fi ;;
    000) jq -cn '{ok: false, error: "network"}' ;;
    429)
      retry="$(grep -i '^retry-after:' "$hdr" 2>/dev/null | tail -1 | tr -d '\r' | awk '{print $2}')"
      [[ "$retry" == <-> ]] || retry=-1
      jq -cn --argjson r "$retry" '{ok: false, error: "http-429", retryAfter: (if $r < 0 then null else $r end)}' ;;
    *) jq -cn --arg c "$code" '{ok: false, error: ("http-" + $c)}' ;;
  esac
  rm -f "$body" "$hdr"
  return 0
}

# --- the engine's questions ----------------------------------------------------

# Freshen a stored login before it becomes live: a token expiring within the
# buffer is refreshed now and persisted first. Prints ok, dead (the lineage
# was refused), transient (retry later) or expired (no refresh token and the
# token is gone).
acct_claude_freshen() {
  local dir="$1" file="$1/credentials.json" expires now_ms outcome
  [[ -r "$file" ]] || { print -r -- transient; return 0 }
  now_ms=$(( ${FLAKELAB_NOW:-$(date +%s)} * 1000 ))
  expires="$(jq -r '.claudeAiOauth.expiresAt // empty' "$file" 2>/dev/null)"
  if [[ "$expires" == <-> ]] && (( now_ms + ACCT_CLAUDE_REFRESH_BUFFER_MS < expires )); then print -r -- ok; return 0; fi
  outcome="$(acct_claude_refresh "$file")"
  case "$outcome" in
    ok) print -r -- ok ;;
    invalid_grant) [[ -n "$(jq -r '.claudeAiOauth.refreshToken // empty' "$file" 2>/dev/null)" ]] && print -r -- dead || print -r -- expired ;;
    *) print -r -- transient ;;
  esac
  return 0
}

# Whether the live token is expired on disk: with no session running that is
# Claude Code idle, and the engine holds rather than counts a failure.
acct_claude_active_expired() {
  local expires now_ms
  [[ -r "${ACCT_CLAUDE_CREDS}" ]] || return 1
  expires="$(jq -r '.claudeAiOauth.expiresAt // empty' "${ACCT_CLAUDE_CREDS}" 2>/dev/null)"
  [[ "$expires" == <-> ]] || return 1
  now_ms=$(( ${FLAKELAB_NOW:-$(date +%s)} * 1000 ))
  (( expires <= now_ms ))
}

# --- profiles (accounts.md, "A second account in a second terminal") ---------
#
# CLAUDE_CONFIG_DIR moves the whole home: .claude.json, .credentials.json,
# settings, projects/, sessions/, history.jsonl, keybindings.json, plugins/.
# A profile is such a directory seeded from a stored login, with the items
# that are not the login linked back into ~/.claude so the two homes share
# settings, skills, and (by default) the transcripts.

acct_claude_profile_var()  { print -r -- CLAUDE_CONFIG_DIR }
acct_claude_profile_home() { print -r -- "${ACCT_CLAUDE_HOME}" }

# The items shared into a profile by symlink, one per line, a directory with
# a trailing slash; the history items only when $1 is true. Never shared:
# .claude.json and .credentials.json (the login), sessions/ and ide/ (per
# process), plugins/ (instance-scoped, per the design; verify 11).
acct_claude_profile_shared() {
  print -rl -- settings.json keybindings.json CLAUDE.md skills/ commands/ agents/
  [[ "${1:-true}" == true ]] && print -rl -- projects/ history.jsonl
  return 0
}

# The variables that would override the profile's login (authentication.md).
acct_claude_scrub_vars() { print -rl -- ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN ANTHROPIC_PROFILE }

# The account a profile's config carries.
acct_claude_profile_identity() { jq -r '.oauthAccount.accountUuid // empty' "$1/.claude.json" 2>/dev/null }

# Seed profile DIR from the stored login in SRC: the credential verbatim, the
# identity spliced into the profile's .claude.json (created when absent with
# onboarding done, the theme and the user-scoped mcpServers mirrored from the
# live config, so the profile starts as the live login would).
acct_claude_profile_seed() {
  local dir="$1" src="$2" live='{}' base='{}'
  [[ -r "${src}/credentials.json" && -r "${src}/identity.json" ]] || return 1
  (umask 077; cp -- "${src}/credentials.json" "${dir}/.credentials.json.tmp") || return 1
  mv -f -- "${dir}/.credentials.json.tmp" "${dir}/.credentials.json" || return 1
  [[ -r "${ACCT_CLAUDE_CONFIG}" ]] && live="$(jq -c '{theme: (.theme // null), mcpServers: (.mcpServers // {})}' "${ACCT_CLAUDE_CONFIG}" 2>/dev/null)" || live='{}'
  [[ -s "${dir}/.claude.json" ]] && base="$(jq -c . "${dir}/.claude.json" 2>/dev/null)" || base='{}'
  (umask 077; jq --argjson live "$live" --argjson base "$base" '
      . as $ident
      | $base
      | .oauthAccount = $ident.oauthAccount
      | .hasCompletedOnboarding = true
      | if (.theme // "") == "" and (($ident.theme // $live.theme // "") != "") then .theme = ($ident.theme // $live.theme) else . end
      | if (.mcpServers // {}) == {} and (($live.mcpServers // {}) != {}) then .mcpServers = $live.mcpServers else . end
    ' "${src}/identity.json" > "${dir}/.claude.json.tmp") || { rm -f "${dir}/.claude.json.tmp"; return 1 }
  mv -f -- "${dir}/.claude.json.tmp" "${dir}/.claude.json"
}

# Whether the profile still logs in: the files, then the tool's own answer
# (`claude auth status --json`, exit 0 logged in, 1 not; ten seconds) when a
# claude is on PATH, with the override variables scrubbed so an API key in
# the shell cannot vouch for it.
acct_claude_profile_valid() {
  local dir="$1"
  local -a unsets
  [[ -r "${dir}/.credentials.json" && -r "${dir}/.claude.json" ]] || return 1
  jq -e '.claudeAiOauth.accessToken? // empty | length > 0' "${dir}/.credentials.json" >/dev/null 2>&1 || return 1
  [[ -n "$(acct_claude_profile_identity "$dir")" ]] || return 1
  command -v claude >/dev/null 2>&1 || return 0
  for v in $(acct_claude_scrub_vars); do unsets+=(-u "$v"); done
  env "${unsets[@]}" CLAUDE_CONFIG_DIR="$dir" timeout 10 claude auth status --json >/dev/null 2>&1
}

# The profile's credential back into the store when the profile refreshed it:
# a rotated refresh token lives in one place only, and the store must hold the
# lineage's newest generation before anything reads it. Prints harvested when
# it copied.
acct_claude_profile_harvest() {
  local dir="$1" src="$2"
  [[ -f "${dir}/.credentials.json" && -f "${src}/credentials.json" ]] || return 0
  [[ "${dir}/.credentials.json" -nt "${src}/credentials.json" ]] || return 0
  cmp -s -- "${dir}/.credentials.json" "${src}/credentials.json" && return 0
  jq -e '.claudeAiOauth.accessToken? // empty | length > 0' "${dir}/.credentials.json" >/dev/null 2>&1 || return 0
  (umask 077; cp -- "${dir}/.credentials.json" "${src}/credentials.json.tmp") || return 1
  mv -f -- "${src}/credentials.json.tmp" "${src}/credentials.json" && print -r -- harvested
}

# Whether the store's credential is newer than the profile's and differs: the
# entry was refreshed or written back since the profile was seeded, so the
# profile holds a superseded generation and must be reseeded before use.
acct_claude_profile_stale() {
  local dir="$1" src="$2"
  [[ -f "${src}/credentials.json" ]] || return 1
  [[ -f "${dir}/.credentials.json" ]] || return 0
  [[ "${src}/credentials.json" -nt "${dir}/.credentials.json" ]] || return 1
  ! cmp -s -- "${src}/credentials.json" "${dir}/.credentials.json"
}

# Whether a session runs on the profile: its own registry, sessions/<pid>.json,
# names a live pid.
acct_claude_profile_live() {
  local dir="$1" f p
  for f in "${dir}"/sessions/*.json(N); do
    p="${${f:t}%.json}"
    [[ "$p" == <-> ]] && kill -0 "$p" 2>/dev/null && return 0
  done
  return 1
}
