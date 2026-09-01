# state-gate.zsh — the secret gate in front of every write to the state root,
# and the review of what it held back. Sourced by nix-backup, which defines
# every global and helper it reads.
#
# The gate sits in FRONT of the first write because sync clients keep version
# history: a token that reaches the synced copy once stays recoverable there.
# gitleaks detects, jq reads. History is held back a whole record at a time,
# transcripts are redacted per line. Nothing here stores a secret: a finding is
# its FINGERPRINT, rule:sha256(secret), which is what makes the held list and
# the decisions file safe to keep and to sync — though a low-entropy secret is
# guessable from a plain sha256, so the decisions file stays sensitive like the
# rest of the state root. Held is not a failure; a scanner that cannot RUN is.

# Local, per-machine: review scratch that names local paths, so neither payload
# nor state root. Created on demand.
GATE_LOCAL_DIR="${HOME_DIR}/.local/state/flakelab/state-gate"
GATE_HELD_FILE="${GATE_LOCAL_DIR}/held.jsonl"
GATE_DECISIONS_LOCAL="${GATE_LOCAL_DIR}/decisions.local.jsonl"
GATE_PRE_SCRUB_DIR="${GATE_LOCAL_DIR}/pre-scrub"

GATE_HELD_COUNT=0
GATE_FILTER_HELD=0
# ... of which the review will actually offer: a record settled by `keep` is
# held for good and on no list, so counting it points at a review with nothing to show.
GATE_FILTER_COUNTABLE=0
GATE_REDACT_HELD=0
GATE_REDACT_COUNTABLE=0
GATE_STATUS=""
GATE_UNAVAILABLE_REPORTED=false
GATE_DECISIONS_LOADED=false
typeset -gA GATE_DECISIONS=()
# The winning decision's epoch, so a later ruling can be written to beat it
# even when the other box's clock runs ahead.
typeset -gA GATE_DECISION_EPOCH=()
# Fingerprints THIS box has a decision record of its own for — see gate_decided_here.
typeset -gA GATE_HOST_DECIDED=()
GATE_THIS_HOST=""
# Set by gate_scrub_transcript: the finding is provably gone from the local file /
# the file itself is gone (nothing to scrub, which is not a failed scrub).
GATE_SCRUB_OK=false
GATE_SCRUB_MISSING=false
# Held entry ids this review applied or settled with `k` — see gate_prune_held.
typeset -gA GATE_SETTLED_IDS=()

gate_now() { date +%s }

gate_host() { print -r -- "${HOST:-$(hostname)}" }

gate_decisions_shared() { print -r -- "${STATE_ROOT}/.flakelab-state-gate/decisions.jsonl" }

# Store path from the wrapper, the repo file in a checkout, else gitleaks' defaults.
gate_config() {
  if [[ -n "${FLAKELAB_STATE_GATE_CONFIG:-}" ]]; then
    print -r -- "${FLAKELAB_STATE_GATE_CONFIG}"
    return 0
  fi
  local checkout="${0:A:h:h:h}/files/config/gitleaks-state.toml"
  [[ -f "${checkout}" ]] && print -r -- "${checkout}"
  return 0
}

gate_available() {
  if [[ -z "${GATE_STATUS}" ]]; then
    if command -v gitleaks > /dev/null 2>&1 && command -v jq > /dev/null 2>&1; then
      GATE_STATUS=ok
    else
      GATE_STATUS=unavailable
    fi
  fi
  [[ "${GATE_STATUS}" == ok ]]
}

# `gate_guard || return 0`: no scanner means no write; recorded once per run.
gate_guard() {
  if gate_available; then
    return 0
  fi
  if ! ${GATE_UNAVAILABLE_REPORTED}; then
    GATE_UNAVAILABLE_REPORTED=true
    record_failure "Secret gate unavailable (gitleaks/jq not on PATH); history and transcripts NOT written to the state root this run"
  fi
  return 1
}

# One scan over a staging directory. Findings are not an error (--exit-code 0);
# non-zero means the SCANNER failed and the caller must write nothing.
gate_scan() {
  local dir="$1" out="$2"
  local -a args=(
    dir "${dir}"
    --report-format json --report-path "${out}"
    --no-banner --log-level error --exit-code 0
  )
  local cfg
  cfg="$(gate_config)"
  [[ -n "${cfg}" && -f "${cfg}" ]] && args+=(--config "${cfg}")
  if ! gitleaks "${args[@]}" > /dev/null 2>&1; then
    return 1
  fi
  [[ -s "${out}" ]] || print -n -- "[]" > "${out}" || return 1
  jq -e 'type == "array"' "${out}" > /dev/null 2>&1 || return 1

  # gate_findings_for_file matches `.File` exactly. A report with findings but
  # none under the staged directory would read as a clean scan and publish
  # everything unfiltered, so it fails closed like any other scanner failure.
  local total matched
  total="$(jq -r 'length' "${out}" 2> /dev/null)" || return 1
  [[ "${total}" == <-> ]] || return 1
  if (( total > 0 )); then
    matched="$(jq -r --arg d "${dir}/" '[.[] | select(((.File // "") | type) == "string" and ((.File // "") | startswith($d)))] | length' "${out}" 2> /dev/null)" || return 1
    [[ "${matched}" == <-> ]] || return 1
    if (( matched == 0 )); then
      log_warn "Secret gate: the scanner reported ${total} finding(s), none of them under ${dir} — its report cannot be mapped onto the staged files"
      return 1
    fi
  fi
  return 0
}

gate_fingerprint() {
  local rule="$1" secret="$2" sum
  sum="$(print -rn -- "${secret}" | sha256sum)" || return 1
  print -r -- "${rule}:${sum%% *}"
}

# A stable id for one held finding, so a record held on every run is listed once.
gate_id() {
  local sum
  sum="$(print -r -- "$*" | sha256sum)" || return 1
  print -r -- "${sum%% *}"
}

# <text> with EVERY listed secret replaced by ***. All of them, not just the
# finding's own: one record can carry two, and masking one would print the
# other. Repeated per secret because a replacement can leave an overlapping
# occurrence behind; bounded, and skipped outright for a secret the mask itself
# contains, which no replacement could ever remove.
gate_mask() {
  local text="$1" s
  local -i guard
  shift
  for s in "$@"; do
    [[ -n "${s}" ]] || continue
    [[ "***" == *"${s}"* ]] && continue
    guard=0
    while [[ "${text}" == *"${s}"* ]] && (( guard < 16 )); do
      text="${text//"${s}"/***}"
      guard=$(( guard + 1 ))
    done
  done
  print -r -- "${text}"
  return 0
}

# One display line for a held record: every secret masked, newlines shown as ⏎,
# control characters dropped, 160 characters. EMPTY when any secret survives —
# flattened the way gate_findings_for_file flattens the scanner's own findings
# (so a match reported across a line break is caught, CRLF included), or
# reassembled by the control strip. The reader then falls back to the redacted
# match rather than print a literal.
gate_preview() {
  local text="$1" masked flat pv s
  shift
  masked="$(gate_mask "${text}" "$@")"
  flat="${masked//[$'\n\r']/ }"
  pv="${masked//$'\n'/ ⏎ }"
  pv="${pv//[[:cntrl:]]/}"
  for s in "$@"; do
    [[ -n "${s}" ]] || continue
    if [[ "${flat}" == *"${s}"* ]] || [[ "${pv}" == *"${s}"* ]]; then
      return 0
    fi
  done
  (( ${#pv} > 160 )) && pv="${pv[1,160]}…"
  print -r -- "${pv}"
  return 0
}

# When a held record was written: the zsh history key's epoch, or the
# transcript's mtime — the only timestamps that outlive the scan.
# `live`, not `path`: zsh ties a local `path` to PATH and would empty it here.
gate_entry_date() {
  local kind="$1" key="$2" live="$3" epoch out
  if [[ "${kind}" == history ]]; then
    epoch="${key%%:*}"
    if [[ "${epoch}" == <-> ]] && out="$(date -d "@${epoch}" '+%Y-%m-%d %H:%M' 2> /dev/null)"; then
      print -r -- "${out}"
      return 0
    fi
  elif [[ -f "${live}" ]] && out="$(date -r "${live}" '+%Y-%m-%d %H:%M' 2> /dev/null)"; then
    print -r -- "${out}"
    return 0
  fi
  print -r -- "unknown"
  return 0
}

# One \x01-joined line per finding for <path>: start, end, rule, description,
# match, secret. \x01, not a tab: zsh collapses consecutive tabs and an empty
# description would shift the fields. Newlines are flattened to spaces, so a
# multi-line secret cannot be found literally by the redactor and fails closed.
gate_findings_for_file() {
  local json="$1" file_path="$2"
  jq -r --arg f "${file_path}" '
    def flat: tostring | gsub("[\n\r]"; " ");
    .[] | select(.File == $f)
    | [ (.StartLine | tostring), (.EndLine | tostring),
        (.RuleID // "unknown"), (.Description // ""),
        (.Match // "" | flat), (.Secret // "" | flat) ]
    | join("\u0001")' "${json}"
}

# Union of the shared file, its conflict copies and the local log, all
# append-only: last decision per fingerprint wins by epoch.
gate_decisions_load() {
  ${GATE_DECISIONS_LOADED} && return 0
  GATE_DECISIONS_LOADED=true
  [[ -n "${GATE_THIS_HOST}" ]] || GATE_THIS_HOST="$(gate_host)"
  gate_available || return 0

  local -a files=()
  local shared
  if state_enabled; then
    shared="$(gate_decisions_shared)"
    files+=("${shared}")
    sync_conflict_copies "${shared}"
    files+=("${reply[@]}")
  fi
  files+=("${GATE_DECISIONS_LOCAL}")

  local f fp dec ep host parsed
  local unknown=false
  for f in "${files[@]}"; do
    [[ -f "${f}" ]] || continue
    # Fail CLOSED on a file jq cannot read (a half-written append a sync client
    # captured): with one input unreadable nothing can say which ruling is the
    # latest, so the WHOLE set is unknown and everything is held — after every
    # file was tried, so the failure names each unreadable one.
    if ! parsed="$(jq -r 'select(type == "object")
      | [(.fingerprint // ""), (.decision // ""), ((.epoch // 0) | tostring),
         (.host // "")]
      | join("\u0001")' "${f}" 2> /dev/null)"; then
      record_failure "Could not read the decisions in ${f}; every finding is held back this run"
      unknown=true
      continue
    fi
    while IFS=$'\x01' read -r fp dec ep host; do
      [[ -n "${fp}" && -n "${dec}" ]] || continue
      [[ "${ep}" == <-> ]] || ep=0
      [[ "${host}" == "${GATE_THIS_HOST}" ]] && GATE_HOST_DECIDED[${fp}]=1
      if [[ -z "${GATE_DECISION_EPOCH[${fp}]:-}" ]] || (( ep >= GATE_DECISION_EPOCH[${fp}] )); then
        GATE_DECISION_EPOCH[${fp}]="${ep}"
        GATE_DECISIONS[${fp}]="${dec}"
      fi
    done <<< "${parsed}"
  done
  if ${unknown}; then
    GATE_DECISIONS=()
    GATE_DECISION_EPOCH=()
    GATE_HOST_DECIDED=()
  fi
  return 0
}

# allow | keep | delete | "" (undecided). Does NOT load: callers read it in a
# `$(…)` subshell, where a load would be thrown away — they load once, before their loop.
gate_decision() {
  print -r -- "${GATE_DECISIONS[$1]:-}"
}

# THIS box has answered for <fingerprint> in its own files (applied, or `k`):
# the winning decision says what every box syncs; this keeps a delete from
# being held again here while a box that never answered is still offered it.
gate_decided_here() {
  [[ -n "${GATE_HOST_DECIDED[$1]:-}" ]]
}

# Readable end to end. Empty is fine; a truncated last line must never be unioned.
gate_decisions_parseable() {
  jq -n 'inputs' "$1" > /dev/null 2>&1
}

gate_local_dir_ready() {
  [[ -d "${GATE_LOCAL_DIR}" ]] && return 0
  mkdir -p "${GATE_LOCAL_DIR}" || return 1
  chmod 700 "${GATE_LOCAL_DIR}" 2> /dev/null || true
  return 0
}

# Append one held finding, deduped by id. An empty <held-file> counts without
# writing — what --dry-run passes.
gate_hold() {
  local held_file="$1" entry="$2" id="$3"
  [[ -n "${held_file}" ]] || return 0
  if ! gate_local_dir_ready; then
    log_warn "Could not create ${GATE_LOCAL_DIR}; held finding not recorded for review"
    return 0
  fi
  if [[ -f "${held_file}" ]] && LC_ALL=C grep -F -q -- "\"id\":\"${id}\"" "${held_file}"; then
    # A legacy entry written before the gate stored previews stays blind at
    # review time; a re-hold that carries one upgrades it in place.
    local stored new_pv
    stored="$(LC_ALL=C grep -F -- "\"id\":\"${id}\"" "${held_file}" | head -n 1)" || stored=""
    new_pv="$(print -r -- "${entry}" | jq -r '.preview // ""' 2> /dev/null)" || new_pv=""
    if [[ -n "${new_pv}" && -n "${stored}" ]] && \
      [[ -z "$(print -r -- "${stored}" | jq -r '.preview // ""' 2> /dev/null)" ]]; then
      local tmp
      if tmp="$(mktemp "${held_file:h}/.${held_file:t}.flakelab-tmp.XXXXXX")"; then
        if ENTRY="${entry}" awk -v id="${id}" 'index($0, "\"id\":\"" id "\"") { print ENVIRON["ENTRY"]; next } { print }' "${held_file}" > "${tmp}" \
          && mv "${tmp}" "${held_file}"; then
          chmod 600 "${held_file}" 2> /dev/null || true
        else
          rm -f "${tmp}" 2> /dev/null || true
        fi
      fi
    fi
    return 0
  fi
  print -r -- "${entry}" >> "${held_file}" || log_warn "Could not record held finding in ${held_file}"
  chmod 600 "${held_file}" 2> /dev/null || true
  return 0
}

# Unpack one held entry into the caller's kind fp rule desc redacted key
# record_sha file live_path entry_id preview — zsh scopes locals dynamically.
# `preview` is last and empty for an entry written before the gate stored one.
gate_read_held() {
  IFS=$'\x01' read -r kind fp rule desc redacted key record_sha file live_path entry_id preview <<< \
    "$(print -r -- "$1" | jq -r '[(.kind // ""), (.fingerprint // ""), (.rule // ""),
      (.desc // ""), (.redacted // ""), (.key // ""), (.record_sha // ""),
      (.file // ""), (.path // ""), (.id // ""), (.preview // "")] | join("\u0001")' 2> /dev/null)" || true
  return 0
}

# `start end key` per record of a history file; same header regex as merge_history_records.
gate_history_index() {
  LC_ALL=C awk '
    /^: [0-9]+:[0-9]+;/ {
      if (start > 0) print start, NR - 1, key
      start = NR
      key = $0
      sub(/^: /, "", key)
      sub(/;.*/, "", key)
      next
    }
    END { if (start > 0) print start, NR, key }
  ' "$1"
}

# <src> minus every WHOLE record overlapping a "start end" line range in
# <ranges>. Everything before the first header passes through: a local
# ~/.zsh_history written before EXTENDED_HISTORY has headerless lines there.
gate_history_drop() {
  local src="$1" ranges="$2" out="$3"
  LC_ALL=C awk -v ranges="${ranges}" '
    BEGIN {
      n = 0
      while ((getline line < ranges) > 0) {
        split(line, a, " ")
        lo[n] = a[1] + 0; hi[n] = a[2] + 0; n++
      }
      close(ranges)
      buf = ""; started = 0; drop = 0
    }
    function flagged(ln,   i) {
      for (i = 0; i < n; i++) if (ln >= lo[i] && ln <= hi[i]) return 1
      return 0
    }
    function flush() {
      if (!started || !drop) printf "%s", buf
      buf = ""; drop = 0
    }
    /^: [0-9]+:[0-9]+;/ { flush(); started = 1 }
    { buf = buf $0 "\n"; if (flagged(NR)) drop = 1 }
    END { flush() }
  ' "${src}" > "${out}"
}

# <candidate> to <out> without the records a finding lands in, each recorded in
# <held-file> for review. `allow` keeps a record; `keep`, `delete` and undecided
# drop it — undecided means nobody has looked yet. Sets GATE_FILTER_HELD.
gate_filter_history() {
  local candidate="$1" findings="$2" out="$3" held_file="$4"
  GATE_FILTER_HELD=0

  local index ranges
  if ! index="$(mktemp)" || ! ranges="$(mktemp)"; then
    rm -f "${index}" "${ranges}"
    record_failure "Secret gate: could not create work files for the history filter"
    return 1
  fi
  if ! gate_history_index "${candidate}" > "${index}"; then
    rm -f "${index}" "${ranges}"
    record_failure "Secret gate: could not index the merged history"
    return 1
  fi

  local start end rule desc match secret fp decision
  local rs re key text sha red pv id entry now
  local -a secrets=()
  local -i held=0 countable=0
  now="$(gate_now)"
  gate_decisions_load
  # Every secret the scanner found in this file, before anything is written
  # down: a record carrying two of them must show neither.
  while IFS=$'\x01' read -r start end rule desc match secret; do
    [[ -n "${start}" ]] || continue
    [[ -n "${secret}" ]] || secret="${match}"
    [[ -n "${secret}" ]] || continue
    (( ${secrets[(Ie)${secret}]} )) || secrets+=("${secret}")
  done < <(gate_findings_for_file "${findings}" "${candidate}")
  while IFS=$'\x01' read -r start end rule desc match secret; do
    [[ -n "${start}" ]] || continue
    [[ -n "${secret}" ]] || secret="${match}"
    [[ -n "${secret}" ]] || continue
    fp="$(gate_fingerprint "${rule}" "${secret}")" || continue
    decision="$(gate_decision "${fp}")"
    [[ "${decision}" == allow ]] && continue
    # Every record the finding's lines fall in; a multi-line match can straddle two.
    while read -r rs re key; do
      (( start > re || end < rs )) && continue
      # The range is written FIRST: a failure below costs the review entry, never the hold.
      print -r -- "${rs} ${re}" >> "${ranges}"
      held=$(( held + 1 ))
      if ! text="$(sed -n "${rs},${re}p" "${candidate}")" \
        || ! sha="$(print -r -- "${text}" | sha256sum)"; then
        record_failure "Secret gate: could not identify a held history record; it is held back but not listed for review"
        continue
      fi
      sha="${sha%% *}"
      red="$(gate_mask "${match}" "${secrets[@]}")"
      (( ${#red} > 200 )) && red="${red[1,200]}…"
      id="$(gate_id history "${fp}" "${key}" "${sha}")"
      # `keep` is settled outright — unless the operator asked to revisit those
      # rulings, which re-holds the record (still excluded from the sync) so the
      # next --review-secrets can re-decide it; `delete` per BOX — ruled
      # elsewhere and never answered here, the record is still in this box's
      # files and must be offered.
      if [[ "${decision}" == keep ]]; then
        ${REVISIT_KEEPS} || continue
      fi
      [[ "${decision}" == delete ]] && gate_decided_here "${fp}" && continue
      countable=$(( countable + 1 ))
      if [[ -z "${decision}" || "${decision}" == delete ]] \
        || { [[ "${decision}" == keep ]] && ${REVISIT_KEEPS} }; then
        # HOLD time is the only moment the secret literal is known, so the
        # preview is masked here and never rebuilt. Only when the WHOLE finding
        # sits inside this record: one that straddles two records leaves half
        # the secret in each, and neither half can be masked out of its own.
        pv=""
        (( start >= rs && end <= re )) \
          && pv="$(gate_preview "${text#": ${key};"}" "${secrets[@]}")"
        entry="$(jq -c -n --arg id "${id}" --arg fingerprint "${fp}" \
          --arg rule "${rule}" --arg desc "${desc}" --arg redacted "${red}" \
          --arg preview "${pv}" \
          --arg key "${key}" --arg record_sha "${sha}" --argjson first_seen "${now}" \
          '{id:$id,kind:"history",fingerprint:$fingerprint,rule:$rule,desc:$desc,
            redacted:$redacted,preview:$preview,key:$key,record_sha:$record_sha,
            first_seen:$first_seen}')" \
          && gate_hold "${held_file}" "${entry}" "${id}"
      fi
    done < "${index}"
  done < <(gate_findings_for_file "${findings}" "${candidate}")

  GATE_FILTER_HELD=${held}
  GATE_FILTER_COUNTABLE=${countable}
  if (( held == 0 )); then
    rm -f "${index}" "${ranges}"
    if ! cp "${candidate}" "${out}"; then
      record_failure "Secret gate: could not stage the merged history"
      return 1
    fi
    return 0
  fi
  if ! gate_history_drop "${candidate}" "${ranges}" "${out}"; then
    rm -f "${index}" "${ranges}"
    record_failure "Secret gate: could not filter the merged history"
    return 1
  fi
  rm -f "${index}" "${ranges}"
  return 0
}

# <src> to <out> with every flagged secret replaced by [REDACTED:<rule>]. Sets
# GATE_REDACT_HELD. Non-zero means the result cannot be trusted (a secret not
# found literally, a redacted line no longer valid JSON) and the caller holds
# the whole file. <held-file> empty records nothing (dry run). <only-fp> redacts
# that one finding and ignores decisions — the review's `delete`, which
# re-scans rather than keeping the secret around. <live-path> is what the held
# entry names: <src> is a staging copy that is gone by the review.
gate_redact_transcript() {
  local src="$1" findings="$2" out="$3" held_file="${4:-}" only_fp="${5:-}"
  local live_src="${6:-${src}}"
  GATE_REDACT_HELD=0

  local spec
  if ! spec="$(mktemp)"; then
    record_failure "Secret gate: could not create work file for the transcript redactor"
    return 1
  fi

  local start end rule desc match secret fp decision red pv ptext id entry now
  local -i held=0 countable=0 ln
  local -a checked=() secrets=()
  now="$(gate_now)"
  gate_decisions_load
  if [[ -n "${held_file}" ]]; then
    while IFS=$'\x01' read -r start end rule desc match secret; do
      [[ -n "${start}" ]] || continue
      [[ -n "${secret}" ]] || secret="${match}"
      [[ -n "${secret}" ]] || continue
      (( ${secrets[(Ie)${secret}]} )) || secrets+=("${secret}")
    done < <(gate_findings_for_file "${findings}" "${src}")
  fi
  while IFS=$'\x01' read -r start end rule desc match secret; do
    [[ -n "${start}" ]] || continue
    [[ -n "${secret}" ]] || secret="${match}"
    [[ -n "${secret}" ]] || continue
    fp="$(gate_fingerprint "${rule}" "${secret}")" || continue
    if [[ -n "${only_fp}" ]]; then
      [[ "${fp}" == "${only_fp}" ]] || continue
    else
      decision="$(gate_decision "${fp}")"
      [[ "${decision}" == allow ]] && continue
    fi
    print -r -- "${start}"$'\x01'"${end}"$'\x01'"${rule}"$'\x01'"${secret}" >> "${spec}"
    for (( ln = start; ln <= end; ln++ )); do
      checked+=("${ln}")
    done
    held=$(( held + 1 ))
    decision="$(gate_decision "${fp}")"
    # Redacted either way; `keep` (unless the operator asked to revisit those
    # rulings), or a `delete` this box answered for, has nothing to review.
    if [[ "${decision}" == keep ]]; then
      ${REVISIT_KEEPS} || continue
    elif [[ "${decision}" == delete ]] && gate_decided_here "${fp}"; then
      continue
    fi
    countable=$(( countable + 1 ))
    if [[ -n "${held_file}" ]]; then
      if [[ -z "${decision}" || "${decision}" == delete ]] \
        || { [[ "${decision}" == keep ]] && ${REVISIT_KEEPS} }; then
        red="$(gate_mask "${match}" "${secrets[@]}")"
        (( ${#red} > 200 )) && red="${red[1,200]}…"
        id="$(gate_id transcript "${fp}" "${live_src:t}")"
        ptext="$(sed -n "${start},${end}p" "${src}")" || ptext=""
        pv="$(gate_preview "${ptext}" "${secrets[@]}")"
        entry="$(jq -c -n --arg id "${id}" --arg fingerprint "${fp}" \
          --arg rule "${rule}" --arg desc "${desc}" --arg redacted "${red}" \
          --arg preview "${pv}" \
          --arg file "${live_src:t}" --arg path "${live_src}" --argjson first_seen "${now}" \
          '{id:$id,kind:"transcript",fingerprint:$fingerprint,rule:$rule,desc:$desc,
            redacted:$redacted,preview:$preview,file:$file,path:$path,
            first_seen:$first_seen}')" \
          && gate_hold "${held_file}" "${entry}" "${id}"
      fi
    fi
  done < <(gate_findings_for_file "${findings}" "${src}")

  GATE_REDACT_HELD=${held}
  GATE_REDACT_COUNTABLE=${countable}
  if (( held == 0 )); then
    rm -f "${spec}"
    if ! cp "${src}" "${out}"; then
      record_failure "Secret gate: could not stage transcript ${src:t}"
      return 1
    fi
    return 0
  fi

  # index()/substr(), not a regex: the secret is a literal. The scanner
  # reports overlapping VARIANTS of one token (the same JWT at three lengths,
  # each its own finding) and exact duplicates of one finding — a naive
  # sequential pass replaces the first and then cannot find the rest, failing
  # a line that is in fact fully redacted (issue #36). So: duplicates are
  # dropped, needles apply longest-first, and a needle that is missing counts
  # as redacted ONLY when it sits inside a longer needle already replaced on
  # that line — every other miss still exits 3 and must not pass for redacted.
  if ! LC_ALL=C awk -v spec="${spec}" '
    BEGIN {
      n = 0
      while ((getline line < spec) > 0) {
        split(line, a, "\001")
        key = a[1] "\001" a[2] "\001" a[4]
        if (key in seen) continue
        seen[key] = 1
        lo[n] = a[1] + 0; hi[n] = a[2] + 0; rule[n] = a[3]; sec[n] = a[4]; n++
      }
      close(spec)
      # Longest needle first: a long variant consumes the short ones nested
      # inside it, which the covered check below then accounts for.
      for (i = 1; i < n; i++) {
        tl = lo[i]; th = hi[i]; tr = rule[i]; ts = sec[i]
        for (j = i - 1; j >= 0 && length(sec[j]) < length(ts); j--) {
          lo[j+1] = lo[j]; hi[j+1] = hi[j]; rule[j+1] = rule[j]; sec[j+1] = sec[j]
        }
        lo[j+1] = tl; hi[j+1] = th; rule[j+1] = tr; sec[j+1] = ts
      }
      bad = 0
    }
    function redact(s, needle, repl,   p, acc) {
      acc = ""
      while ((p = index(s, needle)) > 0) {
        acc = acc substr(s, 1, p - 1) repl
        s = substr(s, p + length(needle))
      }
      return acc s
    }
    {
      line = $0
      for (i = 0; i < n; i++) applied[i] = 0
      for (i = 0; i < n; i++) {
        if (NR < lo[i] || NR > hi[i]) continue
        if (index(line, sec[i]) > 0) {
          line = redact(line, sec[i], "[REDACTED:" rule[i] "]")
          applied[i] = 1
          continue
        }
        covered = 0
        for (j = 0; j < n; j++) {
          if (j == i || !applied[j]) continue
          if (NR < lo[j] || NR > hi[j]) continue
          if (index(sec[j], sec[i]) > 0) { covered = 1; break }
        }
        if (!covered) bad = 1
      }
      print line
    }
    END { exit (bad ? 3 : 0) }
  ' "${src}" > "${out}"; then
    rm -f "${spec}"
    return 1
  fi
  rm -f "${spec}"

  # Only the changed lines are validated: one jq per finding, not per line.
  for ln in "${checked[@]}"; do
    if ! sed -n "${ln}p" "${out}" | jq -e . > /dev/null 2>&1; then
      return 1
    fi
  done
  return 0
}

# Stage the raw merged history, scan it, filter it. Sets GATE_CANDIDATE (the
# caller removes it) and GATE_FILTER_HELD; non-zero means NOTHING may be written.
# A staging directory of our own keeps the scan off both roots and gives the
# findings a File to match on.
GATE_CANDIDATE=""
gate_history_candidate() {
  local raw="$1"
  GATE_CANDIDATE=""
  GATE_FILTER_HELD=0

  local stage findings out
  if ! stage="$(mktemp -d)"; then
    record_failure "Secret gate: could not create a staging directory for the history scan"
    return 1
  fi
  if ! findings="$(mktemp)" || ! out="$(mktemp)"; then
    rm -rf "${stage}" "${findings}" "${out}"
    record_failure "Secret gate: could not create work files for the history scan"
    return 1
  fi
  GATE_CANDIDATE="${out}"

  local staged="${stage}/.zsh_history_merged"
  if ! cp "${raw}" "${staged}"; then
    rm -rf "${stage}" "${findings}"
    record_failure "Secret gate: could not stage the merged history for scanning"
    return 1
  fi
  if ! gate_scan "${stage}" "${findings}"; then
    rm -rf "${stage}" "${findings}"
    record_failure "Secret gate scan failed (gitleaks); merged history NOT written to ${STATE_ROOT} this run"
    return 1
  fi

  local held_file="${GATE_HELD_FILE}"
  ${DRY_RUN} && held_file=""
  if ! gate_filter_history "${staged}" "${findings}" "${out}" "${held_file}"; then
    rm -rf "${stage}" "${findings}"
    return 1
  fi
  rm -rf "${stage}" "${findings}"
  return 0
}

# --dry-run: scan and say what WOULD be held. A preview that cannot set itself
# up warns rather than failing; a SCANNER that cannot run fails the dry run,
# as backup_transcripts does on the same run — one rule for both paths.
gate_preview_history() {
  if ! gate_available; then
    log_dry "Secret gate: gitleaks/jq not on PATH — the merged history would NOT be written to ${STATE_ROOT}"
    return 0
  fi
  local raw
  if ! raw="$(mktemp)"; then
    log_warn "Secret gate: could not preview the scan (no work file)"
    return 0
  fi
  if ! cat "$@" | merge_history_records > "${raw}"; then
    rm -f "${raw}"
    log_warn "Secret gate: could not preview the scan (merge failed)"
    return 0
  fi
  local failures_before=${FAILURES}
  if gate_history_candidate "${raw}"; then
    log_dry "Secret gate: would hold back ${GATE_FILTER_HELD} history record(s)"
    FAILURES=${failures_before}
  else
    log_dry "Secret gate: the scan could not run, so the history would NOT be written"
  fi
  rm -f "${raw}" "${GATE_CANDIDATE}"
  return 0
}

# ---------------------------------------------------------------------------
# Reviewing what the gate held back
# ---------------------------------------------------------------------------

# Persist one decision: the local log first (it exists when the sync folder is
# not mounted), then the shared file. <epoch> is explicit only where the entry
# must beat one already there whatever the other box's clock says.
gate_decision_record() {
  local fp="$1" decision="$2" epoch="${3:-}" entry
  [[ -n "${fp}" ]] || return 0
  if [[ -z "${epoch}" ]]; then
    if ! epoch="$(gate_now)"; then
      record_failure "Could not timestamp the decision for ${fp}"
      return 0
    fi
  fi
  # `host` tells the OTHER machine this ruling is not its own: a `delete` only
  # ever rewrites the files of the box that answered for it.
  if ! entry="$(jq -c -n --arg f "${fp}" --arg d "${decision}" --argjson e "${epoch}" \
    --arg h "$(gate_host)" \
    '{fingerprint:$f,decision:$d,epoch:$e,host:$h}')"; then
    record_failure "Could not build the decision entry for ${fp}"
    return 0
  fi

  if gate_local_dir_ready; then
    print -r -- "${entry}" >> "${GATE_DECISIONS_LOCAL}" \
      || record_failure "Could not record the decision locally (${GATE_DECISIONS_LOCAL})"
    chmod 600 "${GATE_DECISIONS_LOCAL}" 2> /dev/null || true
  else
    record_failure "Could not create ${GATE_LOCAL_DIR}; the decision was not recorded locally"
  fi

  if state_enabled; then
    gate_decisions_sync "${entry}"
  else
    log_warn "No state root available; the decision is local only and will not reach the other machine."
  fi

  GATE_DECISIONS[${fp}]="${decision}"
  GATE_DECISION_EPOCH[${fp}]="${epoch}"
  GATE_HOST_DECIDED[${fp}]=1
  return 0
}

# Rebuild the shared decisions file as the deduped union of its own lines, the
# conflict copies beside it, the local log and, when given, one new <entry>.
# Not `>>`: an in-place append is what a sync client catches half-written.
# Every input is checked BEFORE any is unioned, so a truncated copy is never
# carried into the primary and then removed as folded — the corruption would
# move and the evidence go. One unreadable input: nothing rewritten, nothing removed.
gate_decisions_sync() {
  local entry="${1:-}" shared
  shared="$(gate_decisions_shared)"
  if ! mkdir -p "${shared:h}"; then
    record_failure "Could not create ${shared:h}; the decision was not shared"
    return 0
  fi
  sync_conflict_copies "${shared}"
  local -a copies=("${reply[@]}") inputs=()
  [[ -f "${shared}" ]] && inputs+=("${shared}")
  inputs+=("${copies[@]}")
  [[ -f "${GATE_DECISIONS_LOCAL}" ]] && inputs+=("${GATE_DECISIONS_LOCAL}")
  local f unreadable=false
  for f in "${inputs[@]}"; do
    gate_decisions_parseable "${f}" && continue
    record_failure "Decisions in ${f} cannot be parsed; ${shared:t} was NOT rewritten and nothing was folded or removed — repair or move that file by hand"
    unreadable=true
  done
  if ${unreadable}; then
    return 0
  fi

  local build
  if ! build="$(mktemp)"; then
    record_failure "Could not create a work file for ${shared}"
    return 0
  fi
  if ! {
      (( ${#inputs} > 0 )) && cat "${inputs[@]}"
      [[ -n "${entry}" ]] && print -r -- "${entry}"
      true
    } | LC_ALL=C awk '!seen[$0]++' > "${build}"; then
    rm -f "${build}"
    record_failure "Could not build the decisions file ${shared}"
    return 0
  fi
  if ! place_atomically "${build}" "${shared}"; then
    rm -f "${build}"
    record_failure "Could not write the decisions file ${shared}"
    return 0
  fi
  rm -f "${build}"
  fold_conflict_copies decisions "${copies[@]}"
  return 0
}

# Decisions taken while the sync folder was unmounted sit in the local log
# only; fold them into the shared file on the next backup with the root back,
# rather than on the next decision, which may never come. Only when there is
# something to fold — the shared file is rewritten wholesale.
gate_decisions_replay() {
  state_enabled || return 0
  ${DRY_RUN} && return 0
  [[ -s "${GATE_DECISIONS_LOCAL}" ]] || return 0
  gate_available || return 0
  local shared
  shared="$(gate_decisions_shared)"
  if [[ -f "${shared}" ]]; then
    LC_ALL=C awk 'FILENAME == ARGV[1] { seen[$0] = 1; next }
      !($0 in seen) { found = 1; exit }
      END { exit !found }' "${shared}" "${GATE_DECISIONS_LOCAL}" || return 0
  fi
  log_info "Folding decisions taken while the state root was unavailable into ${shared:t}"
  gate_decisions_sync ""
  return 0
}

# Keep a copy of a file about to be rewritten, named after its role: two of the
# three history files are both called .zsh_history.
gate_pre_scrub() {
  local file="$1" label="$2"
  if ! gate_local_dir_ready || ! mkdir -p "${GATE_PRE_SCRUB_DIR}"; then
    record_failure "Could not create ${GATE_PRE_SCRUB_DIR}; refusing to rewrite ${file}"
    return 1
  fi
  chmod 700 "${GATE_PRE_SCRUB_DIR}" 2> /dev/null || true
  local copy="${GATE_PRE_SCRUB_DIR}/${label}.$(gate_now)"
  if ! cp "${file}" "${copy}"; then
    record_failure "Could not keep a pre-scrub copy of ${file}; refusing to rewrite it"
    return 1
  fi
  chmod 600 "${copy}" 2> /dev/null || true
  log_info "Pre-scrub copy: ${copy}"
  return 0
}

# Drop one record from every LOCAL source that holds it (the state root never
# received it). Matched on the header key AND the record's sha256: a merge can
# carry two records with the same timestamp.
gate_delete_history_record() {
  local key="$1" want_sha="$2"
  local -a targets=("${HOME_DIR}/.zsh_history" "${BACKUP_SHELL}/.zsh_history" "${LEGACY_MERGED}")
  local -a labels=(home-zsh_history payload-instance-zsh_history payload-zsh_history_merged)
  local -i i removed=0
  local f index ranges tmp rs re k text sha

  for (( i = 1; i <= ${#targets}; i++ )); do
    f="${targets[i]}"
    [[ -f "${f}" ]] || continue
    if ! index="$(mktemp)" || ! ranges="$(mktemp)"; then
      rm -f "${index}" "${ranges}"
      record_failure "Could not create work files to rewrite ${f}"
      continue
    fi
    if ! gate_history_index "${f}" > "${index}"; then
      rm -f "${index}" "${ranges}"
      record_failure "Could not index ${f}"
      continue
    fi
    while read -r rs re k; do
      [[ "${k}" == "${key}" ]] || continue
      if ! text="$(sed -n "${rs},${re}p" "${f}")" \
        || ! sha="$(print -r -- "${text}" | sha256sum)"; then
        record_failure "Could not read the candidate record in ${f}; it was not deleted"
        continue
      fi
      sha="${sha%% *}"
      [[ "${sha}" == "${want_sha}" ]] || continue
      print -r -- "${rs} ${re}" >> "${ranges}"
    done < "${index}"
    if [[ ! -s "${ranges}" ]]; then
      rm -f "${index}" "${ranges}"
      continue
    fi
    if ! gate_pre_scrub "${f}" "${labels[i]}"; then
      rm -f "${index}" "${ranges}"
      continue
    fi
    if ! tmp="$(mktemp)"; then
      rm -f "${index}" "${ranges}"
      record_failure "Could not create a work file to rewrite ${f}"
      continue
    fi
    if ! gate_history_drop "${f}" "${ranges}" "${tmp}" || ! place_atomically "${tmp}" "${f}"; then
      rm -f "${index}" "${ranges}" "${tmp}"
      record_failure "Could not rewrite ${f}"
      continue
    fi
    chmod 600 "${f}" 2> /dev/null || true
    rm -f "${index}" "${ranges}" "${tmp}"
    removed=$(( removed + 1 ))
    log_ok "Removed the record from ${f}"
  done

  if (( removed == 0 )); then
    log_warn "The record was not found in any local history file — nothing to delete."
  fi
  return 0
}

# Redact one finding in a local transcript by re-scanning it (the secret was
# never written down). GATE_SCRUB_OK only when the finding is provably gone —
# redacted, or no longer found; a file that is GONE is not proof and stays held.
gate_scrub_transcript() {
  local live_path="$1" fp="$2"
  GATE_SCRUB_OK=false
  GATE_SCRUB_MISSING=false
  if [[ ! -f "${live_path}" ]]; then
    GATE_SCRUB_MISSING=true
    log_warn "Transcript is gone, nothing to scrub: ${live_path}"
    return 0
  fi
  gate_guard || return 0

  local stage findings out
  if ! stage="$(mktemp -d)" || ! findings="$(mktemp)" || ! out="$(mktemp)"; then
    rm -rf "${stage}" "${findings}" "${out}"
    record_failure "Could not create work files to scrub ${live_path:t}"
    return 0
  fi
  if ! cp "${live_path}" "${stage}/${live_path:t}" || ! gate_scan "${stage}" "${findings}"; then
    rm -rf "${stage}" "${findings}" "${out}"
    record_failure "Could not re-scan ${live_path:t}; it was not changed"
    return 0
  fi
  if ! gate_redact_transcript "${stage}/${live_path:t}" "${findings}" "${out}" "" "${fp}"; then
    rm -rf "${stage}" "${findings}" "${out}"
    record_failure "Redaction of ${live_path:t} could not be verified; the file was NOT changed"
    return 0
  fi
  if (( GATE_REDACT_HELD == 0 )); then
    rm -rf "${stage}" "${findings}" "${out}"
    GATE_SCRUB_OK=true
    log_warn "No matching finding left in ${live_path:t}; nothing to scrub."
    return 0
  fi
  # Belt and braces for the one path that rewrites a live transcript: the
  # redactor proved every reported occurrence destroyed, and this proves the
  # scanner agrees — the candidate re-scans clean for the ruled fingerprint.
  local vstage vfindings vstart vend vrule vdesc vmatch vsecret vfp
  if ! vstage="$(mktemp -d)" || ! vfindings="$(mktemp)" \
    || ! cp "${out}" "${vstage}/${live_path:t}" || ! gate_scan "${vstage}" "${vfindings}"; then
    rm -rf "${stage}" "${findings}" "${out}" "${vstage}" "${vfindings}"
    record_failure "Could not verify the redaction of ${live_path:t}; the file was NOT changed"
    return 0
  fi
  while IFS=$'\x01' read -r vstart vend vrule vdesc vmatch vsecret; do
    [[ -n "${vstart}" ]] || continue
    [[ -n "${vsecret}" ]] || vsecret="${vmatch}"
    [[ -n "${vsecret}" ]] || continue
    vfp="$(gate_fingerprint "${vrule}" "${vsecret}")" || continue
    if [[ "${vfp}" == "${fp}" ]]; then
      rm -rf "${stage}" "${findings}" "${out}" "${vstage}" "${vfindings}"
      record_failure "Redaction of ${live_path:t} did not survive a re-scan; the file was NOT changed"
      return 0
    fi
  done < <(gate_findings_for_file "${vfindings}" "${vstage}/${live_path:t}")
  rm -rf "${vstage}" "${vfindings}"
  if ! gate_pre_scrub "${live_path}" "transcript-${live_path:t}"; then
    rm -rf "${stage}" "${findings}" "${out}"
    return 0
  fi
  if ! place_atomically "${out}" "${live_path}"; then
    rm -rf "${stage}" "${findings}" "${out}"
    record_failure "Could not rewrite ${live_path}"
    return 0
  fi
  chmod 600 "${live_path}" 2> /dev/null || true
  rm -rf "${stage}" "${findings}" "${out}"
  GATE_SCRUB_OK=true
  log_ok "Redacted the finding in ${live_path}"
  return 0
}

# Record a `delete` under THIS host with an epoch that beats the ruling it
# answers — the other box's clock may be ahead, and a lower epoch would lose
# the union and leave an applied delete looking foreign forever.
gate_settle_delete_here() {
  local fp="$1" now ep
  now="$(gate_now)" || now=0
  ep="${GATE_DECISION_EPOCH[${fp}]:-0}"
  (( now > ep )) || now=$(( ep + 1 ))
  gate_decision_record "${fp}" delete "${now}"
}

# Deletions already ruled, applied to THIS machine's files. A decision is shared,
# the files it names are not, and a scheduled backup must never rewrite a live
# history because another machine said so: it happens here, in the review the
# operator started, behind one confirmation for the batch. Uses the caller's
# `interactive` / `answers` / `asked` (zsh scopes locals dynamically).
gate_apply_pending_deletes() {
  # What is still held under a `delete` is still in this box's own files.
  local -a pending=()
  local line kind fp rule desc redacted key record_sha file live_path entry_id preview
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    gate_read_held "${line}"
    [[ -n "${fp}" ]] || continue
    [[ "$(gate_decision "${fp}")" == delete ]] || continue
    pending+=("${line}")
  done < "${GATE_HELD_FILE}"

  (( ${#pending} > 0 )) || return 0

  local ans=""
  local prompt="Apply ${#pending} deletion(s) already decided to this machine's local files? [y = apply / N = ask again next time / k = keep this box's copies of ALL of them, records still here included, and stop offering them here] "
  if ${interactive}; then
    print -n -- "${prompt}"
    read -r ans || ans=n
  else
    asked=$(( asked + 1 ))
    ans="${answers[asked]:-n}"
    print -r -- "${prompt}${ans}"
  fi

  # `k` settles every pending fingerprint for THIS box and touches no file; the
  # shared ruling, and so the other machines, are unaffected.
  if [[ "${ans}" == (k|K) ]]; then
    local -A kseen=()
    for line in "${pending[@]}"; do
      gate_read_held "${line}"
      [[ -n "${fp}" ]] || continue
      [[ -n "${entry_id}" ]] && GATE_SETTLED_IDS[${entry_id}]=1
      [[ -z "${kseen[${fp}]:-}" ]] || continue
      kseen[${fp}]=1
      gate_settle_delete_here "${fp}"
    done
    log_ok "Left as is on this box by operator choice; no local file was touched and these are not offered here again."
    return 0
  fi

  # Declining is NOT final: the entries stay held and the offer comes back.
  if [[ "${ans}" != (y|Y) ]]; then
    log_info "Left this machine's local files alone. The records stay held and the next --review-secrets offers them again."
    return 0
  fi

  # A fingerprint settles only when EVERY record carrying it was accounted for:
  # settling on a partial apply would prune the entries that did not go through.
  local -A failed=() seen=() ids=()
  local -a order=()
  local applied_now
  local -i gone=0 failures_before=0
  for line in "${pending[@]}"; do
    gate_read_held "${line}"
    [[ -n "${seen[${fp}]:-}" ]] || { seen[${fp}]=1; order+=("${fp}") }
    ids[${fp}]="${ids[${fp}]:-} ${entry_id}"
    if [[ "${kind}" == transcript ]]; then
      gate_scrub_transcript "${live_path}" "${fp}"
      if ${GATE_SCRUB_OK}; then
        applied_now=true
      elif ${GATE_SCRUB_MISSING}; then
        # Nothing to scrub: this box has carried out everything the ruling asked of it.
        applied_now=true
        gone=$(( gone + 1 ))
      else
        applied_now=false
      fi
    else
      # A record in none of this box's files settles (it may have come from a
      # conflict copy); a rewrite that FAILED left it in place and is offered again.
      failures_before=${FAILURES}
      gate_delete_history_record "${key}" "${record_sha}"
      if (( FAILURES > failures_before )); then
        applied_now=false
      else
        applied_now=true
      fi
    fi
    ${applied_now} || failed[${fp}]=1
  done

  (( gone == 0 )) || log_warn "${gone} record(s) named a file that is no longer on this box; there was nothing to scrub and they are settled."

  local settled_id
  for fp in "${order[@]}"; do
    if [[ -n "${failed[${fp}]:-}" ]]; then
      record_failure "A deletion already decided could not be applied to this box's local files; it stays held and will be offered again (answer k at the confirmation to keep this box's copies instead)"
      continue
    fi
    for settled_id in ${=ids[${fp}]}; do
      [[ -n "${settled_id}" ]] && GATE_SETTLED_IDS[${settled_id}]=1
    done
    gate_settle_delete_here "${fp}"
  done
  return 0
}

# Walk the held findings and act on the operator's answer — the one place that
# DELETES history. FLAKELAB_GATE_ANSWERS is a test seam (undocumented in
# --help): one character per PROMPT, y/n for the cross-box confirmation,
# d/k/a/s per finding.
do_review_secrets() {
  if ! gate_available; then
    record_failure "Secret gate unavailable (gitleaks/jq not on PATH); cannot review held findings"
    return 0
  fi
  # A run that cannot ask has failed even when there is nothing to ask about:
  # reporting 0 would tell a scheduled caller the findings were reviewed.
  local interactive=false
  local -a answers=()
  local -i asked=0
  if [[ -t 0 ]]; then
    interactive=true
  elif [[ -n "${FLAKELAB_GATE_ANSWERS:-}" ]]; then
    answers=(${(s::)FLAKELAB_GATE_ANSWERS//[^dkasyn]/})
  fi
  if ! ${interactive} && (( ${#answers} == 0 )); then
    log_error "--review-secrets asks what to do with each finding and needs a terminal."
    log_error "Run it from an interactive shell: flakelab backup --review-secrets"
    exit 1
  fi

  if [[ ! -s "${GATE_HELD_FILE}" ]]; then
    log_ok "Nothing has been held back from the state root."
    return 0
  fi
  gate_decisions_load

  local -a entries=()
  local -i settled=0
  local line kind fp rule desc redacted key record_sha file live_path entry_id preview decision
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    gate_read_held "${line}"
    [[ -n "${fp}" ]] || continue
    # A held entry whose winning decision is `keep` only exists after a
    # --revisit-keeps run put it back on the table: offer it again. allow and
    # delete rulings stay settled (deletes go through the pending path above).
    decision="$(gate_decision "${fp}")"
    if [[ -n "${decision}" && "${decision}" != keep ]]; then
      settled=$(( settled + 1 ))
      continue
    fi
    entries+=("${line}")
  done < "${GATE_HELD_FILE}"

  # Before the per-finding loop AND the nothing-to-review exit: a delete ruled
  # elsewhere has settled its fingerprint, so the loop below never sees it.
  gate_apply_pending_deletes

  local -i total=${#entries}
  if (( total == 0 )); then
    log_ok "No undecided findings left to review (${settled} already decided)."
    gate_prune_held
    return 0
  fi

  # One question per FINGERPRINT: a pasted block lands in as many records as it
  # has commands, all of them the same secret, and each is unanswerable on its own.
  local -A group=()
  local -a fps=()
  for line in "${entries[@]}"; do
    gate_read_held "${line}"
    [[ -n "${group[${fp}]:-}" ]] || fps+=("${fp}")
    group[${fp}]="${group[${fp}]:-}${line}"$'\n'
  done

  log_info "=== ${total} record(s) in ${#fps} finding(s) held back from the state root ==="
  log_warn "Nothing here has been synced. The state root is at ${STATE_ROOT:-<none>}."
  log_info "history keys are the zsh history epoch (\`: <epoch>:<n>;\` lines in ~/.zsh_history)"
  echo ""

  # `delete` is carried out per RECORD and recorded only after the group's last
  # record has been dealt with.
  local -A del_failed=() del_where=() del_ids=()
  local -a del_order=() glines=() rendered=() dates=()
  local -i gi=0 gtotal=${#fps} failures_before=0
  local gfp gline where when span grule gdesc ans
  for gfp in "${fps[@]}"; do
    gi=$(( gi + 1 ))
    glines=(${(f)group[${gfp}]})
    rendered=()
    dates=()
    grule=""
    gdesc=""
    for gline in "${glines[@]}"; do
      gate_read_held "${gline}"
      [[ -n "${preview}" ]] || preview="${redacted}"
      when="$(gate_entry_date "${kind}" "${key}" "${live_path}")"
      dates+=("${when}")
      [[ -n "${grule}" ]] || { grule="${rule}"; gdesc="${desc}" }
      where="${key}"
      [[ "${kind}" == transcript ]] && where="${file}"
      rendered+=("  ${kind} ${when} (${where})")
      rendered+=("    ${preview}")
    done
    dates=("${(@o)dates}")
    span="${dates[1]}"
    (( ${#dates} > 1 )) && span="${dates[1]} – ${dates[-1]}"
    print -r -- "[${gi}/${gtotal}] ${grule} ${gdesc} — ${#glines} record(s), ${span}"
    print -rl -- "${rendered[@]}"

    if ${interactive}; then
      print -n -- "  [d]elete from local files / [k]eep local, never sync / [a]llow, sync as-is / [s]kip? "
      read -r ans || ans=s
    else
      asked=$(( asked + 1 ))
      ans="${answers[asked]:-s}"
      print -r -- "  answer: ${ans}"
    fi
    case "${ans}" in
      d|D) ;;
      k|K)
        gate_decision_record "${gfp}" keep
        log_ok "Kept local; it will never be synced."
        ;;
      a|A)
        gate_decision_record "${gfp}" allow
        log_ok "Allowed; the next backup syncs it as it is."
        ;;
      *)
        log_info "Skipped; the whole group stays held back and will be offered again."
        ;;
    esac

    if [[ "${ans}" == (d|D) ]]; then
      # The RULING is recorded now, application may be pending: a record in a
      # file that cannot be rewritten yet (a live session's transcript) stays
      # held under the delete and every later --review-secrets retries it via
      # gate_apply_pending_deletes — before this, a failed scrub left the old
      # decision standing and a `keep` could never be revised into a delete.
      gate_settle_delete_here "${gfp}"
      del_order+=("${gfp}")
      for gline in "${glines[@]}"; do
        gate_read_held "${gline}"
        del_ids[${gfp}]="${del_ids[${gfp}]:-} ${entry_id}"
        if [[ "${kind}" == transcript ]]; then
          gate_scrub_transcript "${live_path}" "${gfp}"
          if ! ${GATE_SCRUB_OK}; then
            del_failed[${gfp}]=1
            [[ -n "${del_where[${gfp}]:-}" ]] || del_where[${gfp}]="${file}"
          fi
        else
          # A record in none of this box's files settles (it may have come from a
          # conflict copy); a rewrite that FAILED left it in place and must not.
          failures_before=${FAILURES}
          gate_delete_history_record "${key}" "${record_sha}"
          if (( FAILURES > failures_before )); then
            del_failed[${gfp}]=1
            [[ -n "${del_where[${gfp}]:-}" ]] || del_where[${gfp}]="the local history"
          fi
        fi
      done
    fi
    echo ""
  done

  # Settled only when EVERY record carrying the fingerprint went through:
  # gate_prune_held keys on the fingerprint, so a partial success would drop
  # the entries whose scrub failed and nothing would ever offer them again.
  local dfp settled_id
  for dfp in "${del_order[@]}"; do
    if [[ -n "${del_failed[${dfp}]:-}" ]]; then
      record_failure "Could not remove the finding from ${del_where[${dfp}]} yet (a live session's file refuses a rewrite); the delete ruling stands and every later --review-secrets retries it"
      continue
    fi
    for settled_id in ${=del_ids[${dfp}]}; do
      [[ -n "${settled_id}" ]] && GATE_SETTLED_IDS[${settled_id}]=1
    done
    gate_settle_delete_here "${dfp}"
  done

  gate_prune_held
  return 0
}

# Drop the settled entries from the held list. `allow` and `keep` settle by the
# decision alone; a `delete` names bytes in files this box owns and leaves only
# when this run accounted for it (GATE_SETTLED_IDS) — pruning it on the
# decision alone would retire the only thing that remembers to offer it.
gate_prune_held() {
  [[ -f "${GATE_HELD_FILE}" ]] || return 0
  gate_decisions_load
  local tmp line decision kind fp rule desc redacted key record_sha file live_path entry_id preview
  if ! tmp="$(mktemp)"; then
    record_failure "Could not tidy the held list (${GATE_HELD_FILE})"
    return 0
  fi
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    gate_read_held "${line}"
    decision="$(gate_decision "${fp}")"
    if [[ "${decision}" == allow || "${decision}" == keep ]]; then
      continue
    fi
    if [[ "${decision}" == delete && -n "${GATE_SETTLED_IDS[${entry_id}]:-}" ]]; then
      continue
    fi
    print -r -- "${line}" >> "${tmp}"
  done < "${GATE_HELD_FILE}"
  if ! place_atomically "${tmp}" "${GATE_HELD_FILE}"; then
    rm -f "${tmp}"
    record_failure "Could not tidy the held list (${GATE_HELD_FILE})"
    return 0
  fi
  rm -f "${tmp}"
  chmod 600 "${GATE_HELD_FILE}" 2> /dev/null || true
  return 0
}
