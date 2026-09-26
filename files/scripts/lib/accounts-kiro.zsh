# accounts-kiro.zsh — the Kiro CLI adapter for files/scripts/accounts.
#
# Sourced, never run. The adapter contract every tool answers (accounts.md,
# "The adapter contract"), as zsh functions named acct_kiro_*.
#
# Where Kiro CLI keeps the live login (external contract, inherited from the
# Amazon Q Developer CLI):
#   ~/.local/share/kiro-cli/data.sqlite3     (XDG_DATA_HOME/kiro-cli/ when set)
#     table auth_kv (key, value):  kirocli:odic:token          a Builder ID or
#                                  IAM Identity Center login, JSON {access_token,
#                                  expires_at, refresh_token, region, start_url,
#                                  oauth_flow, scopes}
#                                  kirocli:social:token         a Google/GitHub login
#                                  kirocli:external-idp:token   an external IdP login
#                                  kirocli:odic:device-registration  the SSO-OIDC
#                                  client registration a refresh needs
#     table state (key, value):    api.codewhisperer.profile   the profile ARN
#                                  auth.idc.start-url, auth.idc.region
#   ~/.kiro                                  agents, skills, steering, settings,
#                                            sessions; KIRO_HOME moves it
# Values are copied as the bytes they are, whatever the CLI's encoding; the
# adapter only reads inside them for the identity and the usage call.
#
# No lock is known and no live pickup (verify 9), so a switch is refused
# while a kiro-cli runs unless --force; the running ones keep their token and
# the command prints `kiro-cli chat --resume-id <id>` for each locked session.
# Nothing is refreshed here: the CLI refreshes through SSO-OIDC itself, and a
# stored token past its expiry is not a candidate. Usage is the same
# GetUsageLimits call the CLI's /usage makes, answering one monthly window
# of credits that never steers a switch (accounts.md, "Usage").

ACCT_KIRO_HOME="${KIRO_HOME:-${HOME}/.kiro}"
ACCT_KIRO_DATA="${XDG_DATA_HOME:-${HOME}/.local/share}/kiro-cli"
ACCT_KIRO_DB="${ACCT_KIRO_DATA}/data.sqlite3"
ACCT_KIRO_PROC_ROOT="${FLAKELAB_PROC_ROOT:-/proc}"
# The usage endpoint, REGION substituted; a variable so the suite can point
# it at a curl stand-in and a box can route an EU profile (verify 10).
ACCT_KIRO_USAGE_URL="${FLAKELAB_ACCOUNTS_KIRO_USAGE_URL:-https://codewhisperer.REGION.amazonaws.com/}"
ACCT_KIRO_UA="flakelab-accounts/1.0"
typeset -a ACCT_KIRO_TOKEN_KEYS=(kirocli:odic:token kirocli:social:token kirocli:external-idp:token)
typeset -a ACCT_KIRO_AUTH_KEYS=("${ACCT_KIRO_TOKEN_KEYS[@]}" kirocli:odic:device-registration)
typeset -a ACCT_KIRO_STATE_KEYS=(api.codewhisperer.profile auth.idc.start-url auth.idc.region)

acct_kiro_files() { print -rl -- token.json }
# A token row is present, identifiable or not.
acct_kiro_live_present() { [[ -r "${ACCT_KIRO_DB}" ]] && [[ -n "$(acct_kiro_token_of "$(acct_kiro_export "${ACCT_KIRO_DB}")")" ]] }
acct_kiro_process() { print -r -- kiro-cli }

# A SQLite string literal.
acct_kiro_q() { print -r -- "'${1//\'/\'\'}'" }

# Export the login rows of DB $1 as one JSON document
# {auth_kv: {key: value}, state: {key: value}}; tables that do not exist
# read as empty. Values are the stored text verbatim.
acct_kiro_export() {
  local db="$1" table keys out='{"auth_kv": {}, "state": {}}' row k v
  [[ -r "$db" ]] || { print -r -- "$out"; return 0 }
  for table in auth_kv state; do
    if [[ "$table" == auth_kv ]]; then keys=("${ACCT_KIRO_AUTH_KEYS[@]}"); else keys=("${ACCT_KIRO_STATE_KEYS[@]}"); fi
    sqlite3 "$db" "SELECT name FROM sqlite_master WHERE type = 'table' AND name = '${table}'" 2>/dev/null | grep -qx "$table" || continue
    for k in "${keys[@]}"; do
      v="$(sqlite3 -json "$db" "SELECT CAST(value AS TEXT) AS v FROM ${table} WHERE key = $(acct_kiro_q "$k")" 2>/dev/null | jq -r '.[0].v // empty')"
      [[ -n "$v" ]] || continue
      out="$(print -r -- "$out" | jq --arg t "$table" --arg k "$k" --arg v "$v" '.[$t][$k] = $v')"
    done
  done
  print -r -- "$out"
}

# The token row of an export, whichever sign-in method it is, as {key, json}.
acct_kiro_token_of() {
  print -r -- "$1" | jq -c --argjson keys "$(print -rl -- "${ACCT_KIRO_TOKEN_KEYS[@]}" | jq -R . | jq -s .)" '
    .auth_kv as $a | [ $keys[] | select($a[.] != null) | {key: ., json: ($a[.] | fromjson? // {})} ] | .[0] // empty'
}

# A state value as the plain string inside it (the CLI JSON-encodes them).
acct_kiro_plain() { print -r -- "$1" | jq -r 'fromjson? // . | if type == "object" then (.arn // .profileArn // .value // "") elif type == "string" then . else tostring end' 2>/dev/null }

# The identity of an export as {id, label, org}: the start URL and region
# from the token row, the email from `kiro-cli whoami` when it answers.
# exit 1 no login; exit 3 an API-key login (KIRO_API_KEY set, no token).
acct_kiro_identity_of() {
  local doc="$1" ask="${2:-false}" tok start region email="" type="" who
  tok="$(acct_kiro_token_of "$doc")"
  if [[ -z "$tok" ]]; then [[ -n "${KIRO_API_KEY:-}" ]] && return 3 || return 1; fi
  start="$(print -r -- "$tok" | jq -r '.json.start_url // empty')"
  region="$(print -r -- "$tok" | jq -r '.json.region // empty')"
  [[ -n "$start" ]] || start="$(acct_kiro_plain "$(print -r -- "$doc" | jq -r '.state["auth.idc.start-url"] // ""')")"
  [[ -n "$region" ]] || region="$(acct_kiro_plain "$(print -r -- "$doc" | jq -r '.state["auth.idc.region"] // ""')")"
  # A social or external-IdP login has no start URL: the row's key stands in.
  [[ -n "$start" ]] || start="$(print -r -- "$tok" | jq -r '.key')"
  if [[ "$ask" == true ]] && command -v kiro-cli >/dev/null 2>&1; then
    # The JSON comes first, a plain-text profile trailer after it; a non-zero
    # exit (not logged in, no network) leaves the identity to the rows.
    who="$(env -u KIRO_API_KEY timeout 10 kiro-cli whoami --format json 2>/dev/null)" || who=""
    who="$(print -r -- "$who" | jq -c . 2>/dev/null | head -n 1)"
    email="$(print -r -- "${who:-{\}}" | jq -r '.email // .emailAddress // .userEmail // empty' 2>/dev/null)"
    type="$(print -r -- "${who:-{\}}" | jq -r '.accountType // .account_type // .type // .licenseType // empty' 2>/dev/null)"
  fi
  [[ -n "$type" ]] || case "$start" in
    *view.awsapps.com/start*) type="builder-id" ;;
    kirocli:social:token*) type="social" ;;
    kirocli:external-idp:token*) type="external-idp" ;;
    *) type="identity-center" ;;
  esac
  # The id is what the rows hold, the start URL and the region: the same
  # login must map to the same id offline (a profile check, a tick without
  # network), so the email, which only whoami knows, is the label.
  jq -cn --arg start "$start" --arg region "$region" --arg email "$email" --arg type "$type" '
    {id: ([$start, $region] | map(select(. != "")) | join("|")),
     label: (if $email != "" then $email else ($start | sub("^https?://"; "")) end),
     org: $type}'
}

acct_kiro_identity() { acct_kiro_identity_of "$(acct_kiro_export "${ACCT_KIRO_DB}")" true }

# Copy the live login into DIR as token.json, 0600.
acct_kiro_read_live() {
  local dir="$1" doc
  [[ -r "${ACCT_KIRO_DB}" ]] || return 1
  doc="$(acct_kiro_export "${ACCT_KIRO_DB}")"
  [[ -n "$(acct_kiro_token_of "$doc")" ]] || return 1
  (umask 077; print -r -- "$doc" > "${dir}/token.json.tmp") || return 1
  mv -f -- "${dir}/token.json.tmp" "${dir}/token.json"
}

acct_kiro_snapshot_live() {
  ACCT_LIVE_CREDS="$(acct_kiro_export "${ACCT_KIRO_DB}")" || return 1
  ACCT_LIVE_CREDS_EXISTED=true
  return 0
}

# Write the rows of document $1 into DB $2 in one transaction: the tables
# created when missing, our keys replaced, the token rows of the other
# sign-in methods removed so exactly one login is present.
acct_kiro_import() {
  local doc="$1" db="$2" sql k v
  (umask 077; mkdir -p -- "${db:h}") || return 1
  sql="BEGIN;
CREATE TABLE IF NOT EXISTS auth_kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, value TEXT NOT NULL);"
  for k in "${ACCT_KIRO_AUTH_KEYS[@]}"; do sql+=$'\n'"DELETE FROM auth_kv WHERE key = $(acct_kiro_q "$k");"; done
  for k in "${ACCT_KIRO_STATE_KEYS[@]}"; do sql+=$'\n'"DELETE FROM state WHERE key = $(acct_kiro_q "$k");"; done
  for k in "${(f)$(print -r -- "$doc" | jq -r '.auth_kv | keys[]')}"; do
    [[ -n "$k" ]] || continue
    v="$(print -r -- "$doc" | jq -r --arg k "$k" '.auth_kv[$k]')"
    sql+=$'\n'"INSERT INTO auth_kv (key, value) VALUES ($(acct_kiro_q "$k"), $(acct_kiro_q "$v"));"
  done
  for k in "${(f)$(print -r -- "$doc" | jq -r '.state | keys[]')}"; do
    [[ -n "$k" ]] || continue
    v="$(print -r -- "$doc" | jq -r --arg k "$k" '.state[$k]')"
    sql+=$'\n'"INSERT INTO state (key, value) VALUES ($(acct_kiro_q "$k"), $(acct_kiro_q "$v"));"
  done
  [[ "${FLAKELAB_ACCOUNTS_FAIL_AT:-}" == credentials ]] && sql+=$'\n'"INSERT INTO nowhere VALUES (1);"
  sql+=$'\n'"COMMIT;"
  print -r -- "$sql" | sqlite3 -bail "$db" >/dev/null 2>&1 || { print -r -- "ROLLBACK;" | sqlite3 "$db" >/dev/null 2>&1; return 1 }
  chmod 600 "$db" 2>/dev/null
  return 0
}

acct_kiro_write_live() {
  local dir="$1"
  [[ -r "${dir}/token.json" ]] || { print -ru2 -- "Error: entry has no stored login (${dir})"; return 1 }
  acct_kiro_import "$(<"${dir}/token.json")" "${ACCT_KIRO_DB}"
}

acct_kiro_restore_live() {
  [[ -n "${ACCT_LIVE_CREDS}" ]] || return 0
  FLAKELAB_ACCOUNTS_FAIL_AT="" acct_kiro_import "${ACCT_LIVE_CREDS}" "${ACCT_KIRO_DB}"
}

acct_kiro_running() { pgrep -x kiro-cli 2>/dev/null | grep . ; return 0 }

acct_kiro_lock() {
  local -a pids
  pids=("${(f)$(acct_kiro_running)}")
  pids=("${pids[@]:#}")
  if (( ${#pids[@]} > 0 )) && [[ "${ACCT_FORCE:-false}" != true ]]; then
    ACCT_LOCK_REASON="${#pids[@]} kiro-cli session(s) are running and a running kiro-cli keeps the token it started with; finish them (flakelab sessions), or switch --force and resume them on the new account. Nothing changed."
    return 1
  fi
  return 0
}
acct_kiro_unlock() { return 0 }

# After a --force switch: the locked sessions in Kiro's registry are the
# running ones; one resume line each.
acct_kiro_after_switch() {
  local n="$1" f
  (( n > 0 )) || return 0
  print -r -- "${n} running kiro-cli session(s) keep the previous account's token until restarted; to continue them on the new account:"
  for f in "${ACCT_KIRO_HOME}"/sessions/cli/*.lock(N); do
    print -r -- "  kiro-cli chat --resume-id ${${f:t}%.lock}"
  done
}

# --- usage -------------------------------------------------------------------

acct_kiro_fingerprint() {
  local file="$1" rt
  [[ -r "$file" ]] || return 1
  rt="$(acct_kiro_token_of "$(<"$file")" | jq -r '.json.refresh_token // empty')"
  if [[ -n "$rt" ]]; then print -r -- "sha256:$(print -rn -- "$rt" | sha256sum | cut -d' ' -f1)"
  else print -r -- "sha256-full:$(sha256sum < "$file" | cut -d' ' -f1)"; fi
}

# The token's expiry as an epoch (expires_at: ISO 8601, or an epoch), or nothing.
acct_kiro_expiry_of() {
  acct_kiro_token_of "$1" | jq -r '.json.expires_at // empty
    | if type == "number" then floor elif type == "string" then (sub("\\.[0-9]+"; "") | try fromdateiso8601 catch (tonumber? // empty)) else empty end' 2>/dev/null
}

acct_kiro_creds_doc() {
  local dir="$1" active="$2"
  case "$active" in
    true) acct_kiro_export "${ACCT_KIRO_DB}" ;;
    profile) acct_kiro_export "${dir}/share/kiro-cli/data.sqlite3" ;;
    *) [[ -r "${dir}/token.json" ]] && cat -- "${dir}/token.json" ;;
  esac
}

# GetUsageLimits, one window of class month; the response's fields are taken
# with and without the WithPrecision suffix.
ACCT_KIRO_NORMALISE_JQ='
  def num: if type == "number" then . elif type == "string" then (tonumber? // null) else null end;
  def reset: (.nextDateReset // .next_date_reset // null) as $r
    | if ($r | type) == "number" then (if $r > 100000000000 then ($r / 1000 | floor) else ($r | floor) end)
      elif ($r | type) == "string" then ($r | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch (tonumber? // null))
      else null end;
  [ (.usageBreakdownList // .usage_breakdown_list // [.])[]
    | (.currentUsageWithPrecision // .currentUsage // .current_usage // null | num) as $u
    | (.usageLimitWithPrecision // .usageLimit // .usage_limit // null | num) as $l
    | select($u != null and $l != null and $l > 0)
    | {label: ((.resourceType // .resource_type // "credits") | ascii_downcase), class: "month",
       pct: ($u / $l * 100), resetsAtEpoch: reset} ]
'

acct_kiro_usage() {
  local dir="$1" active="$2" doc tok region arn body code url exp
  doc="$(acct_kiro_creds_doc "$dir" "$active")"
  [[ -n "$doc" ]] || { jq -cn '{ok: false, error: "no-credentials"}'; return 0 }
  tok="$(acct_kiro_token_of "$doc" | jq -r '.json.access_token // empty')"
  [[ -n "$tok" ]] || { jq -cn '{ok: false, error: "no-access-token"}'; return 0 }
  region="$(acct_kiro_token_of "$doc" | jq -r '.json.region // empty')"
  [[ -n "$region" ]] || region="$(acct_kiro_plain "$(print -r -- "$doc" | jq -r '.state["auth.idc.region"] // ""')")"
  arn="$(acct_kiro_plain "$(print -r -- "$doc" | jq -r '.state["api.codewhisperer.profile"] // ""')")"
  [[ -n "$region" && -n "$arn" ]] || { jq -cn '{ok: false, error: "no-profile"}'; return 0 }
  # No refresh here: an access token past its expiry is reported as such,
  # not sent to be refused (a 401 on a token that should work is
  # `unauthorized`, an error with backoff; nothing here proves a seat gone).
  exp="$(acct_kiro_expiry_of "$doc")"
  if [[ "$exp" == <-> ]] && (( exp <= ${FLAKELAB_NOW:-$(date +%s)} )); then jq -cn '{ok: false, error: "expired"}'; return 0; fi
  url="${ACCT_KIRO_USAGE_URL//REGION/${region}}"
  body="$(mktemp)"
  code="$(curl -sS -m 10 -o "$body" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer ${tok}" -H "X-Amz-Target: AmazonCodeWhispererService.GetUsageLimits" \
    -H "Content-Type: application/x-amz-json-1.0" -H "User-Agent: ${ACCT_KIRO_UA}" \
    -d "$(jq -cn --arg arn "$arn" '{profileArn: $arn}')" "$url" 2>/dev/null)" || code=000
  case "$code" in
    200) jq -c "${ACCT_KIRO_NORMALISE_JQ}"' | {ok: true, windows: .}' "$body" 2>/dev/null || jq -cn '{ok: false, error: "unparseable"}' ;;
    401|403) jq -cn '{ok: false, error: "unauthorized"}' ;;
    429) jq -cn '{ok: false, error: "http-429"}' ;;
    *) jq -cn --arg c "$code" '{ok: false, error: ("http-" + $c)}' ;;
  esac
  rm -f "$body"
  return 0
}

acct_kiro_freshen() {
  local dir="$1" exp
  [[ -r "${dir}/token.json" ]] || { print -r -- transient; return 0 }
  exp="$(acct_kiro_expiry_of "$(<"${dir}/token.json")")"
  if [[ "$exp" == <-> ]] && (( exp <= ${FLAKELAB_NOW:-$(date +%s)} )); then print -r -- expired; else print -r -- ok; fi
  return 0
}

acct_kiro_active_expired() {
  local exp
  [[ -r "${ACCT_KIRO_DB}" ]] || return 1
  exp="$(acct_kiro_expiry_of "$(acct_kiro_export "${ACCT_KIRO_DB}")")"
  [[ "$exp" == <-> ]] || return 1
  (( exp <= ${FLAKELAB_NOW:-$(date +%s)} ))
}

# --- profiles ----------------------------------------------------------------
#
# Two moves: KIRO_HOME, the profile directory itself, for ~/.kiro (agents,
# skills, steering, settings and, with the history, the sessions linked from
# the real home) and XDG_DATA_HOME, its share/, for the secret store, a copy
# of the live one with the entry's rows in it (verify 8: whether
# XDG_DATA_HOME moves it is inherited from the Amazon Q code and unverified
# on the box). XDG_DATA_HOME moves every other XDG data dir of that shell
# too, which is the price of a profile for this tool.

acct_kiro_profile_vars() { print -rl -- KIRO_HOME XDG_DATA_HOME }
acct_kiro_profile_env()  { print -rl -- "KIRO_HOME=$1" "XDG_DATA_HOME=$1/share" }
acct_kiro_profile_home() { print -r -- "${ACCT_KIRO_HOME}" }

acct_kiro_profile_shared() {
  print -rl -- agents/ skills/ steering/
  if [[ -d "${ACCT_KIRO_HOME}/settings" ]]; then print -r -- "settings/"
  elif [[ -f "${ACCT_KIRO_HOME}/settings.json" ]]; then print -r -- "settings.json"; fi
  [[ "${1:-true}" == true ]] && print -r -- "sessions/"
  return 0
}

acct_kiro_scrub_vars() { print -rl -- KIRO_API_KEY }

acct_kiro_profile_identity() {
  local db="$1/share/kiro-cli/data.sqlite3"
  [[ -r "$db" ]] || return 1
  acct_kiro_identity_of "$(acct_kiro_export "$db")" false 2>/dev/null | jq -r '.id // empty'
}

# Seed: the live store copied (its other state comes along), the entry's
# rows written in; the kiro/ home created.
acct_kiro_profile_seed() {
  local dir="$1" src="$2" db="${dir}/share/kiro-cli/data.sqlite3"
  [[ -r "${src}/token.json" ]] || return 1
  (umask 077; mkdir -p -- "${db:h}") || return 1
  if [[ -r "${ACCT_KIRO_DB}" && ! -f "$db" ]]; then
    (umask 077; cp -- "${ACCT_KIRO_DB}" "${db}.tmp") && mv -f -- "${db}.tmp" "$db" || return 1
  fi
  acct_kiro_import "$(<"${src}/token.json")" "$db"
}

acct_kiro_profile_valid() {
  local dir="$1" db="$1/share/kiro-cli/data.sqlite3"
  [[ -r "$db" ]] || return 1
  [[ -n "$(acct_kiro_profile_identity "$dir")" ]] || return 1
  command -v kiro-cli >/dev/null 2>&1 || return 0
  env -u KIRO_API_KEY KIRO_HOME="${dir}" XDG_DATA_HOME="${dir}/share" timeout 10 kiro-cli whoami --format json >/dev/null 2>&1
}

# The profile's rows differ from the store's and its store is newer: the
# CLI refreshed there (when it writes a refresh back at all, verify 9).
acct_kiro_profile_harvest() {
  local dir="$1" src="$2" db="${dir}/share/kiro-cli/data.sqlite3" doc
  [[ -f "$db" && -f "${src}/token.json" ]] || return 0
  [[ "$db" -nt "${src}/token.json" ]] || return 0
  doc="$(acct_kiro_export "$db")"
  [[ -n "$(acct_kiro_token_of "$doc")" ]] || return 0
  [[ "$(print -r -- "$doc" | jq -S -c .)" != "$(jq -S -c . "${src}/token.json" 2>/dev/null)" ]] || return 0
  (umask 077; print -r -- "$doc" > "${src}/token.json.tmp") || return 1
  mv -f -- "${src}/token.json.tmp" "${src}/token.json" && print -r -- harvested
}

acct_kiro_profile_stale() {
  local dir="$1" src="$2" db="${dir}/share/kiro-cli/data.sqlite3"
  [[ -f "${src}/token.json" ]] || return 1
  [[ -f "$db" ]] || return 0
  [[ "${src}/token.json" -nt "$db" ]] || return 1
  [[ "$(acct_kiro_export "$db" | jq -S -c .)" != "$(jq -S -c . "${src}/token.json" 2>/dev/null)" ]]
}

acct_kiro_profile_live() {
  local dir="$1" pid
  for pid in $(acct_kiro_running); do
    [[ -r "${ACCT_KIRO_PROC_ROOT}/${pid}/environ" ]] || continue
    tr '\0' '\n' < "${ACCT_KIRO_PROC_ROOT}/${pid}/environ" 2>/dev/null | grep -qx "KIRO_HOME=${dir}" && return 0
  done
  return 1
}
