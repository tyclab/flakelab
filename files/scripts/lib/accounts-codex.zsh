# accounts-codex.zsh — the Codex adapter for files/scripts/accounts.
#
# Sourced, never run. The adapter contract every tool answers (accounts.md,
# "The adapter contract"), as zsh functions named acct_codex_*.
#
# Where Codex keeps the live login (external contract):
#   $CODEX_HOME/auth.json          {"OPENAI_API_KEY": null | "sk-...",
#                                   "tokens": {id_token, access_token,
#                                   refresh_token, account_id}, "last_refresh"}
#                                  with cli_auth_credentials_store = file, the
#                                  default without a keyring (WSL); 0600
#   CODEX_HOME                     ~/.codex unless set; moves the whole home
# The identity is in the id_token's claims: email at the top level,
# chatgpt_account_id and chatgpt_plan_type under "https://api.openai.com/auth"
# (tokens.account_id carries the account id too). An OPENAI_API_KEY with no
# tokens is an API-key login, a different auth axis.
#
# No lock is known and a running codex does not pick up a swapped auth.json
# (verify 6), so a switch is refused while one runs unless --force, and the
# running ones then keep their old token: the command prints the
# `codex resume <id>` line for each. The CLI refreshes the token itself at
# first use and rewrites the file; a fresh `codex login` on an account that
# already has a live seat invalidates that seat, so a login is done once and
# a switch is a file copy that never contacts the server. Usage comes from
# the tool itself: `codex app-server`, method account/rateLimits/read, run in
# a scratch home seeded with the entry's auth.json (never ~/.codex itself,
# verify 7); a token the tool refreshed on the way is copied back.

ACCT_CODEX_HOME="${CODEX_HOME:-${HOME}/.codex}"
ACCT_CODEX_AUTH="${ACCT_CODEX_HOME}/auth.json"
ACCT_CODEX_PROC_ROOT="${FLAKELAB_PROC_ROOT:-/proc}"
# The usage fallback when no codex is on PATH: what codexctl calls, with the
# bearer and the account id header. A variable so the suite can redirect it.
ACCT_CODEX_USAGE_URL="${FLAKELAB_ACCOUNTS_CODEX_USAGE_URL:-https://chatgpt.com/backend-api/wham/usage}"
ACCT_CODEX_UA="flakelab-accounts/1.0"

# The files an entry of this tool holds under <store>/<id>/.
acct_codex_files() { print -rl -- auth.json }
# A live login (or an API key) is present, identifiable or not.
acct_codex_live_present() { [[ -r "${ACCT_CODEX_AUTH}" ]] }

# What the tool runs as, for the running-session count.
acct_codex_process() { print -r -- codex }

# The claims of a JWT's payload as JSON, or nothing.
acct_codex_jwt_claims() {
  local seg="${1#*.}" pad
  seg="${seg%%.*}"
  [[ -n "$seg" ]] || return 1
  seg="${seg//-/+}"; seg="${seg//_//}"
  pad=$(( (4 - ${#seg} % 4) % 4 ))
  (( pad )) && seg+="${(l:pad::=:):-}"
  print -rn -- "$seg" | base64 -d 2>/dev/null | jq -c . 2>/dev/null
}

# The identity an auth.json carries as {id, label, org}, or:
#   exit 1  no login (no file, no tokens)
#   exit 3  an API-key login (OPENAI_API_KEY and no tokens)
acct_codex_identity_of() {
  local file="$1" tokens idt claims id
  [[ -r "$file" ]] || return 1
  tokens="$(jq -c '.tokens // null' "$file" 2>/dev/null)" || return 1
  if [[ "$tokens" == null || "$(print -r -- "$tokens" | jq -r '.access_token // empty')" == "" ]]; then
    [[ "$(jq -r '.OPENAI_API_KEY // empty' "$file" 2>/dev/null)" == "" ]] && return 1 || return 3
  fi
  idt="$(print -r -- "$tokens" | jq -r '.id_token // empty')"
  claims="$(acct_codex_jwt_claims "$idt")" || claims='{}'
  [[ -n "$claims" ]] || claims='{}'
  id="$(jq -cn --argjson t "$tokens" --argjson c "$claims" '
    ($c["https://api.openai.com/auth"] // {}) as $a
    | {id: ($t.account_id // $a.chatgpt_account_id // $c.chatgpt_account_id // ""),
       label: ($c.email // $a.email // ""),
       org: ($a.chatgpt_plan_type // $c.chatgpt_plan_type // "chatgpt")}')"
  [[ -n "$(print -r -- "$id" | jq -r '.id')" ]] || return 1
  [[ -n "$(print -r -- "$id" | jq -r '.label')" ]] || id="$(print -r -- "$id" | jq -c '.label = .id')"
  print -r -- "$id"
}

acct_codex_identity() { acct_codex_identity_of "${ACCT_CODEX_AUTH}" }

# Copy the live login into DIR, verbatim.
acct_codex_read_live() {
  local dir="$1"
  [[ -r "${ACCT_CODEX_AUTH}" ]] || return 1
  (umask 077; cp -- "${ACCT_CODEX_AUTH}" "${dir}/auth.json.tmp") || return 1
  mv -f -- "${dir}/auth.json.tmp" "${dir}/auth.json"
}

acct_codex_snapshot_live() {
  ACCT_LIVE_CREDS=""; ACCT_LIVE_CREDS_EXISTED=false
  if [[ -f "${ACCT_CODEX_AUTH}" ]]; then
    ACCT_LIVE_CREDS="$(<"${ACCT_CODEX_AUTH}")" || return 1
    ACCT_LIVE_CREDS_EXISTED=true
  fi
  return 0
}

# Make DIR's stored login the live one: the file replaced whole (temp beside
# it, 0600, rename). FLAKELAB_ACCOUNTS_FAIL_AT=credentials is the suite's
# seam for the rollback path.
acct_codex_write_live() {
  local dir="$1" tmp
  [[ -r "${dir}/auth.json" ]] || { print -ru2 -- "Error: entry has no stored login (${dir})"; return 1 }
  (umask 077; mkdir -p -- "${ACCT_CODEX_HOME}") || return 1
  tmp="${ACCT_CODEX_AUTH}.flakelab-tmp.$$"
  (umask 077; cp -- "${dir}/auth.json" "$tmp") || { rm -f "$tmp"; return 1 }
  [[ "${FLAKELAB_ACCOUNTS_FAIL_AT:-}" == credentials ]] && { rm -f "$tmp"; return 1 }
  mv -f -- "$tmp" "${ACCT_CODEX_AUTH}" || { rm -f "$tmp"; return 1 }
  return 0
}

acct_codex_restore_live() {
  local tmp
  if ${ACCT_LIVE_CREDS_EXISTED}; then
    tmp="${ACCT_CODEX_AUTH}.flakelab-tmp.$$"
    (umask 077; print -rn -- "${ACCT_LIVE_CREDS}" > "$tmp") && mv -f -- "$tmp" "${ACCT_CODEX_AUTH}"
  else
    rm -f -- "${ACCT_CODEX_AUTH}"
  fi
}

# The running codex processes, one pid per line.
acct_codex_running() { pgrep -x codex 2>/dev/null | grep . ; return 0 }

# The rollout a running codex holds open names its session id.
acct_codex_session_of() {
  local pid="$1" f
  for f in "${ACCT_CODEX_PROC_ROOT}/${pid}"/fd/*(N@); do
    f="$(readlink -- "$f" 2>/dev/null)" || continue
    [[ "$f" == */rollout-*.jsonl ]] || continue
    print -r -- "${f:t}" | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | tail -1
    return 0
  done
  return 1
}

# No lock of the tool's own: the swap is refused while a codex runs, since
# the running ones would keep the old token without knowing it, unless
# ACCT_FORCE says they may. The reason goes to ACCT_LOCK_REASON.
acct_codex_lock() {
  local -a pids
  pids=("${(f)$(acct_codex_running)}")
  pids=("${pids[@]:#}")
  if (( ${#pids[@]} > 0 )) && [[ "${ACCT_FORCE:-false}" != true ]]; then
    ACCT_LOCK_REASON="${#pids[@]} codex session(s) are running and a running codex keeps the token it started with; finish them (flakelab sessions), or switch --force and resume them on the new account. Nothing changed."
    return 1
  fi
  return 0
}
acct_codex_unlock() { return 0 }

# After a --force switch the running sessions carry on as the previous
# account: one resume line each, for when they should be on the new one.
acct_codex_after_switch() {
  local n="$1" pid sid
  (( n > 0 )) || return 0
  print -r -- "${n} running codex session(s) keep the previous account's token until restarted; to continue them on the new account:"
  for pid in $(acct_codex_running); do
    sid="$(acct_codex_session_of "$pid")" && print -r -- "  codex resume ${sid}" || print -r -- "  (pid ${pid}: no session id found; restart it with codex resume --last)"
  done
}

# --- usage -------------------------------------------------------------------

# A lineage fingerprint: the refresh token's hash survives access-token
# rotation; a credential without one hashes whole.
acct_codex_fingerprint() {
  local file="$1" rt
  [[ -r "$file" ]] || return 1
  rt="$(jq -r '.tokens.refresh_token // empty' "$file" 2>/dev/null)"
  if [[ -n "$rt" ]]; then print -r -- "sha256:$(print -rn -- "$rt" | sha256sum | cut -d' ' -f1)"
  else print -r -- "sha256-full:$(sha256sum < "$file" | cut -d' ' -f1)"; fi
}

# The access token's expiry (epoch s) from its claims, or nothing.
acct_codex_expiry_of() {
  local file="$1" claims
  claims="$(acct_codex_jwt_claims "$(jq -r '.tokens.access_token // empty' "$file" 2>/dev/null)")" || return 1
  print -r -- "$claims" | jq -r '.exp // empty | numbers'
}

# The credential file an entry's usage is read with.
acct_codex_creds_path() {
  local dir="$1" active="$2"
  case "$active" in
    true) print -r -- "${ACCT_CODEX_AUTH}" ;;
    *) print -r -- "${dir}/auth.json" ;;
  esac
}

# Normalise the tool's RateLimitSnapshot (camel or snake, one or many
# limits) into windows: primary -> session, secondary -> week, a named
# limit -> model.
ACCT_CODEX_NORMALISE_JQ='
  def num: if type == "number" then . elif type == "string" then (tonumber? // null) else null end;
  def reset: (.resetsAt // .resets_at // .resetAt // .reset_at // null) as $r
    | if ($r | type) == "number" then ($r | floor)
      elif ($r | type) == "string" then ($r | sub("\\.[0-9]+"; "") | try fromdateiso8601 catch (tonumber? // null))
      else null end;
  def win($label; $class): select(. != null)
    | {label: $label, class: $class, pct: ((.usedPercent // .used_percent // 0) | num // 0), resetsAtEpoch: reset};
  def snapshot: (.rateLimits // .rate_limits // .);
  def one($name):
    [ (.primary | win((if $name == "" then "5h" else "\($name) 5h" end); (if $name == "" then "session" else "model" end))),
      (.secondary | win((if $name == "" then "7d" else "\($name) 7d" end); (if $name == "" then "week" else "model" end))) ];
  snapshot as $s
  | ( ($s | one("")) )
    + ( [ ($s.rateLimitsByLimitId // $s.rate_limits_by_limit_id // {}) | to_entries[]
          | .key as $k | .value | one((.limitName // .limit_name // $k)) | .[] ] )
  | map(select(.pct != null))
'

# The JSON-RPC exchange with codex app-server: initialize, initialized, one
# rateLimits read; the tool exits on EOF. Prints the raw response line.
acct_codex_app_server() {
  local home="$1" out
  out="$(cd / && CODEX_HOME="$home" timeout 30 codex app-server 2>/dev/null <<'RPC'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"flakelab-accounts","title":"flakelab accounts","version":"1.0"}}}
{"jsonrpc":"2.0","method":"initialized"}
{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read","params":{}}
RPC
)"
  print -r -- "$out" | jq -c 'select((.id // null) == 2)' 2>/dev/null | head -n 1
}

# Read an entry's usage through the tool in a scratch home seeded with its
# auth.json, then copy a refreshed token back where it came from. Prints
# {ok: true, windows} or {ok: false, error}.
acct_codex_usage() {
  local dir="$1" active="$2" file scratch resp err body code tok acct exp
  file="$(acct_codex_creds_path "$dir" "$active")"
  [[ -r "$file" ]] || { jq -cn '{ok: false, error: "no-credentials"}'; return 0 }
  if command -v codex >/dev/null 2>&1; then
    scratch="$(mktemp -d)" || { jq -cn '{ok: false, error: "no-scratch"}'; return 0 }
    chmod 700 "$scratch"
    (umask 077; cp -- "$file" "${scratch}/auth.json") || { rm -rf -- "${scratch:?}"; jq -cn '{ok: false, error: "no-scratch"}'; return 0 }
    resp="$(acct_codex_app_server "$scratch")"
    # The tool refreshed on the way: that generation is the one to keep.
    if [[ -s "${scratch}/auth.json" ]] && ! cmp -s -- "${scratch}/auth.json" "$file" &&
       [[ -n "$(jq -r '.tokens.access_token // empty' "${scratch}/auth.json" 2>/dev/null)" ]]; then
      (umask 077; cp -- "${scratch}/auth.json" "${file}.flakelab-tmp.$$") && mv -f -- "${file}.flakelab-tmp.$$" "$file"
    fi
    rm -rf -- "${scratch:?}"
    [[ -n "$resp" ]] || { jq -cn '{ok: false, error: "app-server-silent"}'; return 0 }
    err="$(print -r -- "$resp" | jq -r '.error.message // empty')"
    if [[ -n "$err" ]]; then
      if print -r -- "$err" | grep -qiE 'unauthori|401|not logged in|invalid.*token|token.*(invalid|expired|revoked)|refresh'; then
        jq -cn '{ok: false, error: "seat-revoked"}'
      else
        jq -cn --arg e "$err" '{ok: false, error: ("app-server: " + $e)}'
      fi
      return 0
    fi
    print -r -- "$resp" | jq -c --arg mw "" '.result | '"${ACCT_CODEX_NORMALISE_JQ}"' | {ok: true, windows: .}' 2>/dev/null ||
      jq -cn '{ok: false, error: "unparseable"}'
    return 0
  fi
  # No codex on PATH: the endpoint codexctl uses, with the stored token as is.
  # Nothing refreshes it on this path, so a token past its expiry is reported
  # as such rather than sent to be refused; a 401 on one that should work is
  # `unauthorized`, an error with backoff, since only the tool's own refresh
  # (the app-server path) can tell a revoked seat from a stale token.
  tok="$(jq -r '.tokens.access_token // empty' "$file" 2>/dev/null)"
  acct="$(jq -r '.tokens.account_id // empty' "$file" 2>/dev/null)"
  [[ -n "$tok" ]] || { jq -cn '{ok: false, error: "no-access-token"}'; return 0 }
  exp="$(acct_codex_expiry_of "$file")"
  if [[ "$exp" == <-> ]] && (( exp <= ${FLAKELAB_NOW:-$(date +%s)} )); then jq -cn '{ok: false, error: "expired"}'; return 0; fi
  body="$(mktemp)"
  code="$(curl -sS -m 10 -o "$body" -w '%{http_code}' -H "Authorization: Bearer ${tok}" -H "chatgpt-account-id: ${acct}" -H "User-Agent: ${ACCT_CODEX_UA}" "${ACCT_CODEX_USAGE_URL}" 2>/dev/null)" || code=000
  case "$code" in
    200) jq -c "${ACCT_CODEX_NORMALISE_JQ}"' | {ok: true, windows: .}' "$body" 2>/dev/null || jq -cn '{ok: false, error: "unparseable"}' ;;
    401|403) jq -cn '{ok: false, error: "unauthorized"}' ;;
    429) jq -cn '{ok: false, error: "http-429"}' ;;
    *) jq -cn --arg c "$code" '{ok: false, error: ("http-" + $c)}' ;;
  esac
  rm -f "$body"
  return 0
}

# We never refresh a Codex token (the tool does, at first use); a stored
# token past its expiry is not a candidate. Prints ok or expired.
acct_codex_freshen() {
  local dir="$1" exp
  [[ -r "${dir}/auth.json" ]] || { print -r -- transient; return 0 }
  exp="$(acct_codex_expiry_of "${dir}/auth.json")"
  if [[ "$exp" == <-> ]] && (( exp <= ${FLAKELAB_NOW:-$(date +%s)} )); then print -r -- expired; else print -r -- ok; fi
  return 0
}

# Whether the live token is expired on disk.
acct_codex_active_expired() {
  local exp
  [[ -r "${ACCT_CODEX_AUTH}" ]] || return 1
  exp="$(acct_codex_expiry_of "${ACCT_CODEX_AUTH}")"
  [[ "$exp" == <-> ]] || return 1
  (( exp <= ${FLAKELAB_NOW:-$(date +%s)} ))
}

# --- profiles ----------------------------------------------------------------
#
# CODEX_HOME moves the whole home. Shared into a profile by symlink: the
# config and its profiles, the instructions, hooks, rules, memories, the MCP
# OAuth store, and with the history the sessions and the prompt history.
# Never shared: auth.json (the login), log/, packages/, the SQLite state.

acct_codex_profile_vars() { print -r -- CODEX_HOME }
acct_codex_profile_env()  { print -r -- "CODEX_HOME=$1" }
acct_codex_profile_home() { print -r -- "${ACCT_CODEX_HOME}" }

acct_codex_profile_shared() {
  local f
  print -rl -- config.toml AGENTS.md AGENTS.override.md hooks.json hooks/ rules/ memories/ .credentials.json
  for f in "${ACCT_CODEX_HOME}"/*.config.toml(N); do print -r -- "${f:t}"; done
  [[ "${1:-true}" == true ]] && print -rl -- sessions/ history.jsonl
  return 0
}

acct_codex_scrub_vars() { print -rl -- OPENAI_API_KEY }

acct_codex_profile_identity() { acct_codex_identity_of "$1/auth.json" 2>/dev/null | jq -r '.id // empty' }

acct_codex_profile_seed() {
  local dir="$1" src="$2"
  [[ -r "${src}/auth.json" ]] || return 1
  (umask 077; cp -- "${src}/auth.json" "${dir}/auth.json.tmp") || return 1
  mv -f -- "${dir}/auth.json.tmp" "${dir}/auth.json"
}

# `codex login status` exits 0 with a credential present (ten seconds), when
# a codex is on PATH; else the file's presence.
acct_codex_profile_valid() {
  local dir="$1"
  [[ -r "${dir}/auth.json" ]] || return 1
  [[ -n "$(acct_codex_profile_identity "$dir")" ]] || return 1
  command -v codex >/dev/null 2>&1 || return 0
  env -u OPENAI_API_KEY CODEX_HOME="$dir" timeout 10 codex login status >/dev/null 2>&1
}

acct_codex_profile_harvest() {
  local dir="$1" src="$2"
  [[ -f "${dir}/auth.json" && -f "${src}/auth.json" ]] || return 0
  [[ "${dir}/auth.json" -nt "${src}/auth.json" ]] || return 0
  cmp -s -- "${dir}/auth.json" "${src}/auth.json" && return 0
  [[ -n "$(jq -r '.tokens.access_token // empty' "${dir}/auth.json" 2>/dev/null)" ]] || return 0
  (umask 077; cp -- "${dir}/auth.json" "${src}/auth.json.tmp") || return 1
  mv -f -- "${src}/auth.json.tmp" "${src}/auth.json" && print -r -- harvested
}

acct_codex_profile_stale() {
  local dir="$1" src="$2"
  [[ -f "${src}/auth.json" ]] || return 1
  [[ -f "${dir}/auth.json" ]] || return 0
  [[ "${src}/auth.json" -nt "${dir}/auth.json" ]] || return 1
  ! cmp -s -- "${src}/auth.json" "${dir}/auth.json"
}

# No registry of its own: a running codex whose environment carries the
# profile as CODEX_HOME.
acct_codex_profile_live() {
  local dir="$1" pid
  for pid in $(acct_codex_running); do
    [[ -r "${ACCT_CODEX_PROC_ROOT}/${pid}/environ" ]] || continue
    tr '\0' '\n' < "${ACCT_CODEX_PROC_ROOT}/${pid}/environ" 2>/dev/null | grep -qx "CODEX_HOME=${dir}" && return 0
  done
  return 1
}
