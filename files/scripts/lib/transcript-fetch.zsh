# Explicit recovery bypasses the age gate, never the grow-only or live-file guard.
fetch_claude_session() {
  local id="$1" f rel dst mtime now session local_session failures_before=${FAILURES}
  local -a matches=() files=()
  state_enabled || { record_failure "State root unavailable; session not fetched"; return 0 }
  transcripts_for claude
  for f in "${TX_STATE}"/*/"${id}.jsonl"(N.); do
    rel="${f#${TX_STATE}/}"
    rel_path_is_sync_artifact "${rel}" || matches+=("${f}")
  done
  if (( ${#matches} != 1 )); then
    record_failure "Expected one archived Claude session ${id}; found ${#matches}. No files fetched"
    return 0
  fi
  if ! now="$(date +%s)"; then
    record_failure "Could not read the clock; session not fetched"
    return 0
  fi
  session="${matches[1]}"
  local_session="${TX_HOME}/${session#${TX_STATE}/}"
  files=("${session}" "${session%.jsonl}"/**/*(N.))
  for f in "${files[@]}"; do
    if [[ "${f}" != "${session}" ]] && ! ${DRY_RUN} && [[ ! -f "${local_session}" ]]; then
      continue
    fi
    rel="${f#${TX_STATE}/}"
    rel_path_is_sync_artifact "${rel}" && continue
    dst="${TX_HOME}/${rel}"
    if [[ "${f}" == *.jsonl ]]; then
      if [[ -f "${dst}" ]]; then
        if ! mtime="$(stat -c %Y "${dst}" 2> /dev/null)"; then
          record_failure "Could not stat transcript: ${dst}"
          continue
        fi
        if (( now - mtime < PULL_FRESH_SECONDS )); then
          log_info "Session still live, not fetched: ${dst:t}"
          continue
        fi
      fi
      sync_transcript "${f}" "${dst}"
      if ${SYNC_TRANSCRIPT_WROTE}; then
        transcript_set_age "${dst}"
      fi
    else
      side_file_rel "${rel}" || continue
      [[ -e "${dst}" ]] && continue
      if ${DRY_RUN}; then
        log_dry "${f} -> ${dst}"
        continue
      fi
      ensure_dir "${dst:h}"
      if ! place_atomically "${f}" "${dst}" || ! verify_copy "${f}" "${dst}"; then
        record_failure "Could not fetch session side file ${rel}"
        continue
      fi
      chmod 600 "${dst}" || record_failure "Cannot set mode 600 on ${dst}"
      touch -r "${f}" "${dst}" || record_failure "Cannot set session side file age: ${dst}"
      log_ok "Fetched session side file: ${rel}"
    fi
  done
  transcript_lines_save
  if (( FAILURES == failures_before )); then
    if ${DRY_RUN}; then
      log_dry "Would fetch Claude session ${id} into ${TX_HOME}/${session:h:t}"
    else
      log_ok "Claude session available locally: ${id} — resume with: claude --resume ${id}"
    fi
  fi
  return 0
}
