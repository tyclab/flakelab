# state-sync.zsh — what moves between the payload, the state root and $HOME:
# the history merge, the memory mirror and its index union, and the grow-only
# transcript copy. Sourced by nix-backup, which defines every global and helper
# it reads.

# ---------------------------------------------------------------------------
# History merging
# ---------------------------------------------------------------------------

# One deduplicated, timestamp-ordered record per command. Records are
# NUL-terminated so the ENTRY, not the line, is the unit of sorting — a
# line-oriented sort tore the continuation lines of multi-line commands away
# from their header. Two sorts: `sort -zu -t: -k2` would dedupe on the KEY and
# drop distinct commands sharing a timestamp, so dedupe whole records first,
# then order by epoch with -s. LC_ALL=C: a locale-aware sort errors on bytes it
# cannot decode.
merge_history_records() {
  LC_ALL=C tr -d '\0' | LC_ALL=C awk '
    BEGIN { ORS = "\0" }
    # `[0-9]+:[0-9]+;`: the second field is the elapsed seconds, not a constant 0.
    /^: [0-9]+:[0-9]+;/ {
      if (entry != "") print entry "\n"
      entry = $0
      next
    }
    # A continuation line before any header belongs to no command: dropped, not grafted.
    { if (entry == "") next; entry = entry "\n" $0 }
    END { if (entry != "") print entry "\n" }
  ' | LC_ALL=C sort -z -u | LC_ALL=C sort -z -s -t: -k2,2n | LC_ALL=C tr -d '\0'
}

# Non-empty and stable: feeding the merge its own output reproduces it byte for byte.
history_merge_ok() {
  local candidate="$1"
  [[ -s "${candidate}" ]] || return 1
  merge_history_records < "${candidate}" | cmp -s - "${candidate}"
}

# Conflict copies a sync client left beside one file — the other machine's
# write that lost the race. Sets `reply`.
sync_conflict_copies() {
  local merged="$1" f
  reply=()
  for f in "${merged:h}"/"${merged:t}"*(N.); do
    [[ "${f}" == "${merged}" ]] && continue
    is_sync_artifact "${f:t}" && reply+=("${f}")
  done
  return 0
}

# Remove conflict copies once their lines are folded into the file they sat beside.
fold_conflict_copies() {
  local label="$1" c
  shift
  for c in "$@"; do
    if rm -f "${c}"; then
      log_ok "Removed folded ${label} conflict copy: ${c:t}"
    else
      log_warn "Could not remove folded ${label} conflict copy: ${c}"
    fi
  done
  return 0
}

merge_zsh_history() {
  local instance_history="${BACKUP_SHELL}/.zsh_history"
  # --state-only never writes the payload, so its instance copy can be days
  # stale; the live history is the input that actually holds what was typed.
  ${STATE_ONLY} && instance_history="${HOME_DIR}/.zsh_history"
  local merged_history
  merged_history="$(merged_history_path)"

  if [[ ! -f "${instance_history}" ]]; then
    return 0
  fi
  if state_unavailable; then
    log_warn "State root unavailable; merged history not updated this run"
    return 0
  fi

  # No scanner means no write to the state root at all, not a write nothing looked at.
  if state_enabled && ! gate_guard; then
    return 0
  fi

  # Union order: the current merged file, the payload's pre-state-root merge,
  # the conflict copies beside the merged file, this box's instance history.
  local -a inputs=()
  [[ -f "${merged_history}" ]] && inputs+=("${merged_history}")
  if state_enabled && [[ -f "${LEGACY_MERGED}" ]]; then
    inputs+=("${LEGACY_MERGED}")
  fi
  sync_conflict_copies "${merged_history}"
  local -a conflicts=("${reply[@]}")
  inputs+=("${conflicts[@]}")
  inputs+=("${instance_history}")

  if ${DRY_RUN}; then
    log_dry "Would merge ${instance_history} into ${merged_history}"
    if state_enabled; then
      gate_preview_history "${inputs[@]}"
    fi
    return 0
  fi

  ensure_dir "${merged_history:h}"

  # Input sizes are logged: a merge that produces nothing is otherwise mute.
  local merged_bytes=0 instance_bytes
  if [[ -f "${merged_history}" ]]; then
    if ! merged_bytes="$(wc -c < "${merged_history}")"; then
      record_failure "Could not read ${merged_history}; merged history not updated this run"
      return 0
    fi
  fi
  if ! instance_bytes="$(wc -c < "${instance_history}")"; then
    record_failure "Could not read ${instance_history}; merged history not updated this run"
    return 0
  fi

  # The RAW union holds every secret the merge has ever seen and is built
  # outside both roots; only filtered bytes ever land in the synced folder.
  local raw
  if ! raw="$(mktemp)"; then
    record_failure "Could not create a work file for the history merge"
    return 0
  fi

  if ! cat "${inputs[@]}" | merge_history_records > "${raw}"; then
    rm -f "${raw}"
    record_failure "History merge pipeline failed (inputs ${merged_bytes}B merged + ${instance_bytes}B instance); kept existing ${merged_history}"
    return 0
  fi

  local candidate="${raw}"
  local -i held=0
  if state_enabled; then
    if ! gate_history_candidate "${raw}"; then
      rm -f "${raw}" "${GATE_CANDIDATE}"
      return 0
    fi
    candidate="${GATE_CANDIDATE}"
    held=${GATE_FILTER_HELD}
  fi

  # Every record held filters down to an empty file: a hold, not a broken merge.
  if (( held > 0 )) && [[ ! -s "${candidate}" ]]; then
    rm -f "${raw}" "${candidate}"
    GATE_HELD_COUNT=$(( GATE_HELD_COUNT + GATE_FILTER_COUNTABLE ))
    log_warn "Secret gate: every merged history record was held back; ${merged_history} left as it was"
    return 0
  fi

  if ! history_merge_ok "${candidate}"; then
    rm -f "${raw}" "${candidate}"
    record_failure "History merge rejected (empty or unstable) from ${merged_bytes}B merged + ${instance_bytes}B instance; kept existing ${merged_history}"
    return 0
  fi

  if (( held > 0 )); then
    GATE_HELD_COUNT=$(( GATE_HELD_COUNT + GATE_FILTER_COUNTABLE ))
    log_warn "Secret gate: ${held} history record(s) held back from ${merged_history}"
  fi
  if ! place_atomically "${candidate}" "${merged_history}"; then
    rm -f "${raw}" "${candidate}"
    record_failure "Could not place merged history: ${merged_history}"
    return 0
  fi
  rm -f "${raw}" "${candidate}"
  chmod 600 "${merged_history}" 2> /dev/null || record_failure "Cannot set mode 600 on ${merged_history}"
  STATE_WROTE=true
  local placed_bytes="?"
  placed_bytes="$(wc -c < "${merged_history}")" || placed_bytes="?"
  log_ok "Merged history into ${merged_history} (${placed_bytes}B from ${merged_bytes}B + ${instance_bytes}B)"

  fold_conflict_copies history "${conflicts[@]}"
}

# A union with the live file: the home history holds everything typed since the
# last backup, and a plain copy — --force included — would destroy it.
restore_zsh_history() {
  if state_unavailable; then
    log_warn "State root unavailable; shell history not restored this run"
    local -a payload_copies=("${BACKUP_SHELL}/.zsh_history")
    [[ -f "${LEGACY_MERGED}" ]] && payload_copies+=("${LEGACY_MERGED}")
    log_warn "The payload copy (${(j:, :)payload_copies}) can still be restored by running with FLAKELAB_STATE_ROOT unset"
    return 0
  fi
  local backup_history
  backup_history="$(merged_history_path)"

  # Conflict copies are read (not removed — the backup run owns the folder's
  # tidiness), whether or not the merged file itself is there: a lost race can
  # leave a folder holding nothing but the other machine's copy.
  local -a extra=()
  sync_conflict_copies "${backup_history}"
  extra=("${reply[@]}")

  if [[ ! -f "${backup_history}" ]]; then
    backup_history="${LEGACY_MERGED}"
    [[ -f "${backup_history}" ]] || backup_history="${BACKUP_SHELL}/.zsh_history"
  fi

  # The payload's merge is an INPUT, not only a fallback: `--restore --from`
  # repoints LEGACY_MERGED at another repo's payload, which a populated state
  # root would otherwise never read. After the fallback, so `cat` never gets it twice.
  if state_enabled && [[ -f "${LEGACY_MERGED}" && "${LEGACY_MERGED}" != "${backup_history}" ]]; then
    extra+=("${LEGACY_MERGED}")
  fi

  local -a srcs=()
  [[ -f "${backup_history}" ]] && srcs+=("${backup_history}")
  srcs+=("${extra[@]}")
  if (( ${#srcs[@]} == 0 )); then
    return 0
  fi

  local dst="${HOME_DIR}/.zsh_history"

  if ${DRY_RUN}; then
    log_dry "Would merge ${backup_history} into ${dst}"
    return 0
  fi

  local build
  if ! build="$(mktemp)"; then
    record_failure "Could not create a work file for the history merge"
    return 0
  fi
  if ! {
    [[ -f "${dst}" ]] && cat "${dst}"
    cat "${srcs[@]}"
  } | merge_history_records > "${build}"; then
    rm -f "${build}"
    record_failure "History merge failed; kept existing ${dst}"
    return 0
  fi
  if ! history_merge_ok "${build}"; then
    rm -f "${build}"
    record_failure "History merge rejected (empty or unstable); kept existing ${dst}"
    return 0
  fi
  if ! place_atomically "${build}" "${dst}"; then
    rm -f "${build}"
    record_failure "Could not place restored history: ${dst}"
    return 0
  fi
  rm -f "${build}"
  chmod 600 "${dst}" 2> /dev/null || record_failure "Cannot set mode 600 on ${dst}"
  log_ok "Restored history, merged with existing: ${dst}"
}

# ---------------------------------------------------------------------------
# Claude memory
# ---------------------------------------------------------------------------

# Exact-line union of N index files onto the LAST argument. The FIRST input keeps
# its line order and only lines the later ones add are appended, so once every
# side holds the same set the output stops changing. Always returns 0; failure
# is signalled through FAILURES, which callers read before removing a folded copy.
merge_memory_index() {
  # With one argument awk would read stdin and hang on a terminal nobody is at.
  if (( $# < 2 )); then
    record_failure "merge_memory_index needs a destination and at least one input"
    return 0
  fi
  local dst="${@[-1]}"
  local -a inputs=("${@[1,-2]}")

  local build
  if ! build="$(mktemp)"; then
    record_failure "Could not merge memory index: ${dst}"
    return 0
  fi
  if LC_ALL=C awk '!seen[$0]++' "${inputs[@]}" > "${build}" && place_atomically "${build}" "${dst}"; then
    rm -f "${build}"
    chmod 644 "${dst}" 2> /dev/null || record_failure "Cannot set mode 644 on ${dst}"
    log_ok "Merged memory index: ${dst}"
    return 0
  fi
  rm -f "${build}"
  record_failure "Could not merge memory index: ${dst}"
  return 0
}

# Mirror a memory directory and union MEMORY.md instead of copying it — the
# index is the one memory file every machine rewrites. backup: additive into a
# shared dir; existing lines, then the conflict copies', then ours; the copies
# are removed once folded. restore: local lines first, then the incoming index
# and its conflict copies, which stay (the backup run owns the state root's tidiness).
sync_memory_dir() {
  local mode="$1" src="$2" dst="$3"
  if [[ "${mode}" == backup ]]; then
    if [[ ! -d "${src}" ]] || ${DRY_RUN}; then
      backup_dir "${src}" "${dst}" false
      return 0
    fi
  else
    [[ -d "${src}" ]] || return 0
    if ${DRY_RUN}; then
      log_dry "${src}/ -> ${dst}/ (MEMORY.md merged)"
      return 0
    fi
  fi

  local index="${dst}/MEMORY.md" incoming="${src}/MEMORY.md" verb="restored"
  local -a conflicts=()
  if [[ "${mode}" == backup ]]; then
    verb="backed up"
    sync_conflict_copies "${index}"
  else
    sync_conflict_copies "${incoming}"
  fi
  conflicts=("${reply[@]}")

  # The index the mirror is about to overwrite. A snapshot that fails skips the
  # directory entirely: mirroring would put one box's index over the other's.
  local before=""
  if [[ -f "${index}" ]]; then
    if ! before="$(mktemp)" || ! cp "${index}" "${before}"; then
      rm -f "${before}"
      record_failure "Could not snapshot memory index for merge: ${index} — ${src} not ${verb} this run"
      return 0
    fi
  fi

  if [[ "${mode}" == backup ]]; then
    backup_dir "${src}" "${dst}" false
  else
    restore_dir "${src}" "${dst}"
  fi

  local -a inputs=()
  [[ -n "${before}" ]] && inputs+=("${before}")
  if [[ "${mode}" == backup ]]; then
    inputs+=("${conflicts[@]}")
    [[ -f "${incoming}" ]] && inputs+=("${incoming}")
  else
    [[ -f "${incoming}" ]] && inputs+=("${incoming}")
    inputs+=("${conflicts[@]}")
  fi
  # One input is whatever is on disk already — except a lone conflict copy on
  # backup, which is promoted rather than left beside an index that never learned its lines.
  local merge=false
  (( ${#inputs} > 1 )) && merge=true
  [[ "${mode}" == backup ]] && (( ${#conflicts} > 0 )) && merge=true
  if ${merge}; then
    if [[ "${mode}" == restore ]] && is_nix_managed "${index}"; then
      log_warn "Owned by the flake, not restoring: ${index}"
    else
      local failures_before=${FAILURES}
      merge_memory_index "${inputs[@]}" "${index}"
      if [[ "${mode}" == backup ]] && (( FAILURES == failures_before )); then
        fold_conflict_copies "memory index" "${conflicts[@]}"
      fi
    fi
  fi
  [[ -n "${before}" ]] && rm -f "${before}"
  return 0
}

# ---------------------------------------------------------------------------
# Claude transcripts
# ---------------------------------------------------------------------------

# Whether the last sync_transcript placed bytes; the gate's redaction warn reads it.
SYNC_TRANSCRIPT_WROTE=false

# Grow-only copy of one append-only transcript, either direction, --force
# included: the daily timer runs on both boxes. LINES, not bytes: redaction
# usually lengthens a line, so by size a restore would put the older redacted
# copy over an intact local file. Equal is a no-op — neither side is provably newer.
sync_transcript() {
  local src="$1"
  local dst="$2"
  SYNC_TRANSCRIPT_WROTE=false

  local src_size src_lines dst_lines
  if ! src_lines="$(wc -l < "${src}")"; then
    record_failure "Could not read transcript: ${src}"
    return 0
  fi
  if [[ -f "${dst}" ]]; then
    if ! dst_lines="$(wc -l < "${dst}")"; then
      record_failure "Could not read transcript copy: ${dst}"
      return 0
    fi
    (( src_lines <= dst_lines )) && return 0
  fi
  src_size="$(wc -c < "${src}")" || src_size="?"

  if ${DRY_RUN}; then
    log_dry "${src} -> ${dst} (${src_size}B)"
    return 0
  fi

  ensure_dir "${dst:h}"
  # A live session is being appended to: snapshot it, then copy and verify THAT.
  local snap
  if ! snap="$(mktemp)"; then
    record_failure "Could not create a work file for transcript: ${src}"
    return 0
  fi
  if ! cp "${src}" "${snap}"; then
    rm -f "${snap}"
    record_failure "Could not read transcript: ${src}"
    return 0
  fi
  if ! place_atomically "${snap}" "${dst}"; then
    rm -f "${snap}"
    record_failure "Transcript copy failed: ${src} -> ${dst}"
    return 0
  fi
  if ! verify_copy "${snap}" "${dst}"; then
    rm -f "${snap}"
    record_failure "Verification failed, transcript differs: ${dst}"
    return 0
  fi
  rm -f "${snap}"
  chmod 600 "${dst}" 2> /dev/null || record_failure "Cannot set mode 600 on ${dst}"
  SYNC_TRANSCRIPT_WROTE=true
  STATE_WROTE=true
  log_ok "Synced transcript: ${src:t} -> ${dst:h}"
  return 0
}

# Pull leg: state-root transcripts this box lacks, or that grew on another one.
# A local copy written to in the last PULL_FRESH_SECONDS is a live session
# appending through an open fd — sync_transcript places by rename, which would
# orphan that fd's inode and silently drop the session's tail — so freshness
# skips it; the next run picks it up once the session has gone quiet. The
# grow-only line rule inside sync_transcript still applies on top.
PULL_FRESH_SECONDS=600
pull_transcripts() {
  local transcript dst mtime
  local now
  if ! now="$(date +%s)"; then
    record_failure "Could not read the clock; transcripts not pulled this run"
    return 0
  fi
  for transcript in "${STATE_ROOT}"/claude/projects/*/*.jsonl(N.); do
    is_sync_artifact "${transcript:t}" && continue
    dst="${HOME_DIR}/.claude/projects/${transcript:h:t}/${transcript:t}"
    if [[ -f "${dst}" ]]; then
      if ! mtime="$(stat -c %Y "${dst}" 2> /dev/null)"; then
        record_failure "Could not stat transcript: ${dst}"
        continue
      fi
      if (( now - mtime < PULL_FRESH_SECONDS )); then
        log_info "Session still live, not pulled: ${dst:t}"
        continue
      fi
    fi
    sync_transcript "${transcript}" "${dst}"
  done
  return 0
}

# Every transcript staged and scanned in ONE gitleaks run, then synced through
# the redactor. Grow-only compares the CANDIDATE (redacted or not) against the
# synced copy, never the raw source.
backup_transcripts() {
  local -a srcs=() dsts=()
  local slug_dir transcript
  for slug_dir in "${HOME_DIR}"/.claude/projects/*(N/); do
    for transcript in "${slug_dir}"/*.jsonl(N.); do
      is_sync_artifact "${transcript:t}" && continue
      srcs+=("${transcript}")
      dsts+=("${STATE_ROOT}/claude/projects/${slug_dir:t}/${transcript:t}")
    done
  done
  (( ${#srcs} > 0 )) || return 0
  gate_guard || return 0

  local stage findings
  if ! stage="$(mktemp -d)" || ! findings="$(mktemp)"; then
    rm -rf "${stage}" "${findings}"
    record_failure "Secret gate: could not create work files for the transcript scan"
    return 0
  fi

  local -i i
  local staged
  for (( i = 1; i <= ${#srcs}; i++ )); do
    staged="${stage}/in/${i}"
    if ! mkdir -p "${staged}" || ! cp "${srcs[i]}" "${staged}/${srcs[i]:t}"; then
      rm -rf "${stage}" "${findings}"
      record_failure "Secret gate: could not stage transcript ${srcs[i]:t} for scanning"
      return 0
    fi
  done

  if ! gate_scan "${stage}/in" "${findings}"; then
    rm -rf "${stage}" "${findings}"
    record_failure "Secret gate scan failed (gitleaks); transcripts NOT written to ${STATE_ROOT} this run"
    return 0
  fi

  local held_file="${GATE_HELD_FILE}" candidate
  ${DRY_RUN} && held_file=""
  for (( i = 1; i <= ${#srcs}; i++ )); do
    staged="${stage}/in/${i}/${srcs[i]:t}"
    candidate="${stage}/out/${i}/${srcs[i]:t}"
    if ! mkdir -p "${candidate:h}"; then
      record_failure "Secret gate: could not stage transcript ${srcs[i]:t}"
      continue
    fi
    # The held entry names the LIVE transcript: the staging tree is gone by the review.
    if gate_redact_transcript "${staged}" "${findings}" "${candidate}" "${held_file}" "" "${srcs[i]}"; then
      sync_transcript "${candidate}" "${dsts[i]}"
      if (( GATE_REDACT_HELD > 0 )); then
        GATE_HELD_COUNT=$(( GATE_HELD_COUNT + GATE_REDACT_COUNTABLE ))
        if ${DRY_RUN}; then
          log_dry "Secret gate: would redact ${GATE_REDACT_HELD} secret(s) out of the synced copy of ${srcs[i]:t}"
        else
          local note=""
          ${SYNC_TRANSCRIPT_WROTE} || note="; synced copy unchanged"
          log_warn "Secret gate: ${GATE_REDACT_HELD} secret(s) held back from the synced copy of ${srcs[i]:t} (redacted${note})"
        fi
      fi
    else
      GATE_HELD_COUNT=$(( GATE_HELD_COUNT + ( GATE_REDACT_HELD > 0 ? GATE_REDACT_HELD : 1 ) ))
      if ${DRY_RUN}; then
        log_dry "Secret gate: would hold back ${srcs[i]:t} whole — the redaction cannot be verified"
      else
        log_warn "Secret gate: ${srcs[i]:t} held back whole — the redaction could not be verified (invalid JSON or a secret that could not be matched literally)"
      fi
    fi
  done

  rm -rf "${stage}" "${findings}"
  return 0
}
