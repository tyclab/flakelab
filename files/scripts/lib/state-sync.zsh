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
# write that lost the race. Two naming shapes exist: most clients append their
# marker after the full name (MEMORY.md_<host>_<date>_Conflict), but Synology
# Drive inserts it BEFORE the extension (MEMORY_<host>_<date>_Conflict.md), so
# a plain full-name prefix never pairs those. The stem+extension match is a
# heuristic: a sibling artifact sharing the stem and extension is taken as this
# file's conflict, which is exact for the one merged file each of these
# folders holds. Sets `reply`.
sync_conflict_copies() {
  local merged="$1" f
  local tail="${merged:t}" stem="" ext=""
  # Dotfiles (.zsh_history_merged) have no extension to insert before; for
  # them only the prefix shape applies.
  if [[ "${tail}" == ?*.* ]]; then
    ext="${tail##*.}"
    stem="${tail%.*}"
  fi
  reply=()
  # (D): the merged history is a dotfile, and so are its conflict copies.
  for f in "${merged:h}"/*(ND.); do
    [[ "${f}" == "${merged}" ]] && continue
    is_sync_artifact "${f:t}" || continue
    if [[ "${f:t}" == "${tail}"* ]]; then
      reply+=("${f}")
    elif [[ -n "${stem}" && "${f:t}" == "${stem}"*".${ext}" ]]; then
      reply+=("${f}")
    elif [[ -z "${stem}" && "${f:t}" == *"${tail}" ]]; then
      # Synology Drive on a dotfile: the whole name is the "extension", the
      # stem is empty, so the marker lands in FRONT of the name
      # (_<host>_<date>_Conflict.zsh_history_merged). Observed 2026-09-01,
      # a copy that then sat unfolded beside the merged history for a day.
      reply+=("${f}")
    fi
  done
  return 0
}

# Any path segment that is a sync artifact poisons the whole path: a Synology
# @eaDir tree can hold .jsonl-named litter, and a conflict-named directory
# must not have its contents mirrored as transcripts.
rel_path_is_sync_artifact() {
  local seg
  for seg in ${(s:/:)1}; do
    is_sync_artifact "${seg}" && return 0
  done
  return 1
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

# Deletions. A box records, after each pull, the topic files it holds. A file it
# then lacks while the state root still has it was deleted here: it goes from
# the state root too and leaves a tombstone dated the last time this box saw
# it. Every box removes a copy no newer than the tombstone — a copy edited after
# the deletion lifts it instead — so no backup writes a deleted memory back.
# Tombstones live beside the memory dir, not in it: the mirror never carries
# them into a home.
memory_seen_file() { print -r -- "${HOME_DIR}/.local/state/flakelab/state-sync/memory/$1.seen" }
memory_tombstone_dir() { print -r -- "${1:h}/memory-tombstones" }

# reply = the topic files under $1, relative: no MEMORY.md, no sync artifacts.
memory_topic_files() {
  local dir="$1" rel
  local -a found=()
  if [[ -d "${dir}" ]]; then
    while IFS= read -r rel; do
      [[ "${rel}" == MEMORY.md ]] && continue
      found+=("${rel}")
    done < <(cd "${dir}" && sync_artifact_find_args && \
      find . \( "${reply[@]}" \) -prune -o \( -type f -o -type l \) -printf '%P\n' 2> /dev/null)
  fi
  reply=("${found[@]}")
}

# $1 = this box's memory dir, $2 = the state root's. Every copy of a tombstoned
# file that is not newer than its tombstone goes; a newer copy on either side
# lifts the tombstone and stays.
apply_memory_tombstones() {
  local home_dir="$1" state_dir="$2" tombs rel tomb d newer
  tombs="$(memory_tombstone_dir "${state_dir}")"
  [[ -d "${tombs}" ]] || return 0
  memory_topic_files "${tombs}"
  for rel in "${reply[@]}"; do
    tomb="${tombs}/${rel}"
    newer=false
    for d in "${home_dir}" "${state_dir}"; do
      [[ -e "${d}/${rel}" && "${d}/${rel}" -nt "${tomb}" ]] && newer=true
    done
    if ${newer}; then
      if rm -f "${tomb}"; then
        log_ok "Tombstone lifted by a newer copy: ${rel}"
      else
        record_failure "Could not lift the tombstone: ${tomb}"
      fi
      continue
    fi
    for d in "${home_dir}" "${state_dir}"; do
      [[ -e "${d}/${rel}" ]] || continue
      if rm -f "${d}/${rel}"; then
        log_ok "Removed ${d}/${rel} (deleted on another box)"
      else
        record_failure "Could not remove the tombstoned copy: ${d}/${rel}"
      fi
    done
  done
  return 0
}

# $1 = this box's memory dir, $2 = the state root's, $3 = slug. A file this box
# held at its last pull, absent here now and still in the state root, was
# deleted here. A directory with nothing left in it, index included, is a
# reset, not a decision: nothing propagates and the pull refills it.
propagate_memory_deletions() {
  local home_dir="$1" state_dir="$2" slug="$3" seen rel tombs
  seen="$(memory_seen_file "${slug}")"
  [[ -f "${seen}" ]] || return 0
  local -a gone=()
  while IFS= read -r rel; do
    [[ -n "${rel}" ]] || continue
    [[ ! -e "${home_dir}/${rel}" && -e "${state_dir}/${rel}" ]] && gone+=("${rel}")
  done < "${seen}"
  (( ${#gone} > 0 )) || return 0
  local -a left=("${home_dir}"/*(ND))
  if (( ${#left} == 0 )); then
    log_warn "Memory directory is empty, not propagating ${#gone} deletion(s): ${home_dir}"
    return 0
  fi
  tombs="$(memory_tombstone_dir "${state_dir}")"
  for rel in "${gone[@]}"; do
    if [[ "${rel}" == */* ]]; then ensure_dir "${tombs}/${rel:h}"; else ensure_dir "${tombs}"; fi
    if ! rm -f "${state_dir}/${rel}"; then
      record_failure "Could not delete from the state root: ${state_dir}/${rel}"
      continue
    fi
    if print -r -- "deleted on ${DISTRO_NAME}, last seen $(date -r "${seen}" -Iseconds 2> /dev/null)" > "${tombs}/${rel}" \
      && touch -r "${seen}" "${tombs}/${rel}"; then
      log_ok "Deleted from the state root (removed on this box): ${rel}"
    else
      record_failure "Could not write the tombstone: ${tombs}/${rel}"
    fi
  done
  return 0
}

# What this box holds after its pull, for the next tick's deletion check.
record_memory_seen() {
  local home_dir="$1" slug="$2" seen build
  seen="$(memory_seen_file "${slug}")"
  memory_topic_files "${home_dir}"
  if ! build="$(mktemp)"; then
    record_failure "Could not create a work file for the memory seen list"
    return 0
  fi
  (( ${#reply} > 0 )) && print -rl -- "${reply[@]}" > "${build}"
  ensure_dir "${seen:h}"
  if ! place_atomically "${build}" "${seen}"; then
    rm -f "${build}"
    record_failure "Could not write the memory seen list: ${seen}"
    return 0
  fi
  rm -f "${build}"
  return 0
}

# One line per memory file. A line's identity is the file its link names
# (`- [title](file.md) — hook`); a line naming no file is its own identity. The
# first input's order holds and a file keeps the slot it first appeared in, but
# its TEXT comes from the --prefer input when that carries the file — the side
# whose topic files the mirror just placed — else from the first input to carry
# it. --kept names a file listing the topic files the mirror left alone: their
# line stays the first input's, so a hook follows its file whichever side won.
# --present names a file listing the topic files the destination holds: a line
# whose file is on neither side is dropped, so a deleted memory leaves the index
# with the file. So a hook edited in place replaces the old line instead of
# living beside it, and once every side holds the same lines the output stops
# changing. Always returns 0; failure is signalled through FAILURES, which
# callers read before removing a folded copy.
merge_memory_index() {
  local prefer="" kept="" present=""
  while (( $# > 0 )); do
    case "$1" in
      --prefer)  prefer="$2";  shift 2 ;;
      --kept)    kept="$2";    shift 2 ;;
      --present) present="$2"; shift 2 ;;
      *)         break ;;
    esac
  done
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
  if LC_ALL=C awk -v prefer="${prefer}" -v keptfile="${kept}" -v presentfile="${present}" '
      BEGIN {
        if (keptfile != "") {
          while ((getline rel < keptfile) > 0) kept["file:" rel] = 1
          close(keptfile)
        }
        if (presentfile != "") {
          while ((getline rel < presentfile) > 0) present["file:" rel] = 1
          close(presentfile)
        }
      }
      # A target with a scheme is a link, not a memory file: the line is its own identity.
      function key(line,    m) {
        if (match(line, /^- \[[^]]*\]\([^)]+\)/)) {
          m = substr(line, RSTART, RLENGTH)
          sub(/^- \[[^]]*\]\(/, "", m)
          sub(/\)$/, "", m)
          if (index(m, ":") == 0) return "file:" m
        }
        return "line:" line
      }
      {
        k = key($0)
        if (!(k in text)) {
          order[++n] = k
          text[k] = $0
          fixed[k] = (FILENAME == prefer) || (k in kept)
        } else if (FILENAME == prefer && !fixed[k]) {
          text[k] = $0
          fixed[k] = 1
        }
      }
      END {
        for (i = 1; i <= n; i++) {
          k = order[i]
          if (presentfile != "" && substr(k, 1, 5) == "file:" && !(k in present)) continue
          print text[k]
        }
      }
    ' "${inputs[@]}" > "${build}" && place_atomically "${build}" "${dst}"; then
    rm -f "${build}"
    chmod 644 "${dst}" 2> /dev/null || record_failure "Cannot set mode 644 on ${dst}"
    log_ok "Merged memory index: ${dst}"
    return 0
  fi
  rm -f "${build}"
  record_failure "Could not merge memory index: ${dst}"
  return 0
}

# Mirror a memory directory newest-wins and merge MEMORY.md instead of copying
# it — the index is the one memory file every machine rewrites. Topic files:
# additive, and a copy the destination changed since the last sync is kept, so
# a memory rewritten between this run's push and its pull survives the pull.
# Index: backup merges into the shared dir — existing lines, then the conflict
# copies', then ours, ours winning a file both name; the copies are removed once
# folded. restore: local lines first, then the incoming index (winning a file
# both name) and its conflict copies, which stay (the backup run owns the state
# root's tidiness).
sync_memory_dir() {
  local mode="$1" src="$2" dst="$3"
  if [[ "${mode}" == backup ]]; then
    if [[ ! -d "${src}" ]] || ${DRY_RUN}; then
      backup_dir "${src}" "${dst}" false true
      return 0
    fi
  else
    [[ -d "${src}" ]] || return 0
    if ${DRY_RUN}; then
      log_dry "${src}/ -> ${dst}/ (MEMORY.md merged)"
      return 0
    fi
  fi

  local home_dir="${dst}" state_dir="${src}"
  [[ "${mode}" == backup ]] && home_dir="${src}" state_dir="${dst}"
  local slug="${state_dir:h:t}"
  apply_memory_tombstones "${home_dir}" "${state_dir}"
  [[ "${mode}" == backup ]] && propagate_memory_deletions "${home_dir}" "${state_dir}" "${slug}"

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
    backup_dir "${src}" "${dst}" false true
  else
    restore_dir "${src}" "${dst}" true
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
      local -a prefer=()
      [[ -f "${incoming}" ]] && prefer=(--prefer "${incoming}")
      # The topic files the mirror kept keep their own hook, whichever side won.
      local kept=""
      if (( ${#MIRROR_KEPT_RELS} > 0 )) && kept="$(mktemp)"; then
        print -rl -- "${MIRROR_KEPT_RELS[@]}" > "${kept}"
        prefer+=(--kept "${kept}")
      fi
      # A line whose file the destination lacks after the mirror has no file anywhere.
      local present=""
      if present="$(mktemp)"; then
        memory_topic_files "${dst}"
        (( ${#reply} > 0 )) && print -rl -- "${reply[@]}" > "${present}"
        prefer+=(--present "${present}")
      fi
      merge_memory_index "${prefer[@]}" "${inputs[@]}" "${index}"
      [[ -n "${kept}" ]] && rm -f "${kept}"
      [[ -n "${present}" ]] && rm -f "${present}"
      if [[ "${mode}" == backup ]] && (( FAILURES == failures_before )); then
        fold_conflict_copies "memory index" "${conflicts[@]}"
      fi
    fi
  fi
  [[ -n "${before}" ]] && rm -f "${before}"
  [[ "${mode}" == restore ]] && record_memory_seen "${home_dir}" "${slug}"
  return 0
}

# ---------------------------------------------------------------------------
# Claude transcripts
# ---------------------------------------------------------------------------

# Whether the last sync_transcript placed bytes; the gate's redaction warn reads it.
SYNC_TRANSCRIPT_WROTE=false

# The uuid of the last complete entry that carries one — the message a copy ends
# on. From the tail only: a transcript is append-only, and a half-written last
# line (a live session mid-append) is skipped, not an error.
transcript_last_uuid() {
  tail -n 64 "$1" 2> /dev/null | jq -R -r 'fromjson? | .uuid? // empty' 2> /dev/null | tail -n 1
}

# Whether <src> continues <dst>: the entry <dst> ends on is somewhere in <src>.
# A copy ending on no id at all (metadata only) is continued by anything. Ids
# are never redacted, so a redacted copy answers the same as its source.
transcript_continues() {
  local src="$1" dst="$2" last
  last="$(transcript_last_uuid "${dst}")"
  [[ -n "${last}" ]] || return 0
  grep -q -F -- "\"${last}\"" "${src}" 2> /dev/null
}

# Copy <file> — a branch about to lose its path — beside the root it lives in,
# named after <named>, the transcript whose path it had: the state root's
# claude/diverged/ for a state-root copy (it replicates, and its bytes already
# passed a gate), ~/.local/state/flakelab/state-sync/diverged/ for a local one
# (raw, so it stays on this box). Outside claude/projects/ on purpose: neither
# leg syncs it again and Claude Code does not list it; `claude --resume <file>
# --fork-session` reopens it as a session of its own. Returns 1 when it could
# not be parked, and the caller must then leave the original where it is.
park_diverged_transcript() {
  local file="$1" named="${2:-$1}" rel dir parked stamp
  if [[ -n "${STATE_ROOT}" && "${named}" == "${STATE_ROOT}/claude/projects/"* ]]; then
    rel="${named#${STATE_ROOT}/claude/projects/}"
    dir="${STATE_ROOT}/claude/diverged"
  else
    rel="${named#${HOME_DIR}/.claude/projects/}"
    dir="${HOME_DIR}/.local/state/flakelab/state-sync/diverged"
  fi
  if ! stamp="$(date +%Y%m%dT%H%M%S)"; then
    record_failure "Could not read the clock; the diverged branch of ${rel} was not parked"
    return 1
  fi
  parked="${dir}/${rel%.jsonl}.${stamp}-${DISTRO_NAME}.jsonl"
  if ${DRY_RUN}; then
    log_dry "Diverged: would park ${file} at ${parked}"
    return 0
  fi
  ensure_dir "${parked:h}"
  if [[ ! -d "${parked:h}" ]] || ! cp "${file}" "${parked}" || ! verify_copy "${file}" "${parked}"; then
    rm -f "${parked}"
    record_failure "Could not park the diverged branch of ${rel}; ${file} was left in place"
    return 1
  fi
  chmod 600 "${parked}" 2> /dev/null || true
  log_warn "Diverged transcript ${rel}: the session was carried on in two places. The branch that lost its path is parked at ${parked} — reopen it with: claude --resume ${parked} --fork-session"
  return 0
}

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
  # A longer copy that does not continue the one it would replace is a fork —
  # the same session carried on in two places — not a newer state of it. The
  # loser is parked first, so the grow-only rule never destroys a branch.
  local diverged=false
  if [[ -f "${dst}" ]] && ! transcript_continues "${src}" "${dst}"; then
    diverged=true
  fi
  src_size="$(wc -c < "${src}")" || src_size="?"

  if ${DRY_RUN}; then
    ${diverged} && park_diverged_transcript "${dst}"
    log_dry "${src} -> ${dst} (${src_size}B)"
    return 0
  fi

  ensure_dir "${dst:h}"
  if ${diverged} && ! park_diverged_transcript "${dst}"; then
    return 0
  fi
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

# A transcript conflict copy in the state root is the other machine's gated
# write that lost the rename race — its bytes already passed that machine's
# secret gate, and folding moves them only within the root, so no rescan is
# needed. The same grow-only line rule decides: a copy with more lines than
# the base replaces it, otherwise the base stands; either way the copy is
# removed so it stops shadowing the file. A copy whose base is gone entirely
# is left in place — there is nothing safe to fold it into — and a copy that
# FORKS the base (it ends on an entry the base does not hold) is parked before
# it is removed, whichever of the two keeps the path. Runs before both legs so
# push and pull see the folded file.
fold_transcript_conflicts() {
  local base copy rel
  for base in "${STATE_ROOT}"/claude/projects/**/*.jsonl(N.); do
    rel="${base#${STATE_ROOT}/claude/projects/}"
    rel_path_is_sync_artifact "${rel}" && continue
    sync_conflict_copies "${base}"
    for copy in "${reply[@]}"; do
      local failures_before=${FAILURES}
      sync_transcript "${copy}" "${base}"
      # Not placed, and not contained in the base: a branch of its own, not a
      # stale write. Left in place when it cannot be parked.
      if ! ${DRY_RUN} && ! ${SYNC_TRANSCRIPT_WROTE} && ! transcript_continues "${base}" "${copy}"; then
        park_diverged_transcript "${copy}" "${base}" || continue
      fi
      if ! ${DRY_RUN} && (( FAILURES == failures_before )); then
        fold_conflict_copies transcript "${copy}"
      fi
    done
  done
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
  local transcript rel dst mtime
  local now
  if ! now="$(date +%s)"; then
    record_failure "Could not read the clock; transcripts not pulled this run"
    return 0
  fi
  # `**`: subagent transcripts live below the session file
  # (<slug>/<session>/subagents/*.jsonl), so one level misses them.
  for transcript in "${STATE_ROOT}"/claude/projects/**/*.jsonl(N.); do
    rel="${transcript#${STATE_ROOT}/claude/projects/}"
    rel_path_is_sync_artifact "${rel}" && continue
    dst="${HOME_DIR}/.claude/projects/${rel}"
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

# Every STAGED transcript scanned in ONE gitleaks run, then synced through
# the redactor. Grow-only compares the CANDIDATE (redacted or not) against the
# synced copy, never the raw source.
#
# Staging is incremental: redaction rewrites text WITHIN lines, so the synced
# copy always has the line count its source had when it was synced, and a
# source with no more lines than its synced copy is one sync_transcript would
# refuse anyway — comparing line counts up front skips the copy + gitleaks
# pass for it entirely. Without this the phase re-staged and re-scanned the
# whole corpus every run, which grew past what activation and a short timer
# tolerate (the home-manager timeout of 2026-09-01). Two consequences, both
# intended: a transcript held back whole has no synced copy and stays staged
# every run until a ruling frees it, and a partially-redacted transcript stops
# re-warning about already-held findings until it grows again. An unreadable
# source falls through to staging, where the existing failure paths name it.
backup_transcripts() {
  local -a srcs=() dsts=()
  local transcript rel dst src_lines dst_lines
  local -i unchanged=0
  local phase_started
  phase_started="$(date +%s)" || phase_started=""
  # `**` mirrors the pull leg: subagent transcripts sit below the session file.
  for transcript in "${HOME_DIR}"/.claude/projects/**/*.jsonl(N.); do
    rel="${transcript#${HOME_DIR}/.claude/projects/}"
    rel_path_is_sync_artifact "${rel}" && continue
    dst="${STATE_ROOT}/claude/projects/${rel}"
    if [[ -f "${dst}" ]] \
      && src_lines="$(wc -l < "${transcript}" 2> /dev/null)" \
      && dst_lines="$(wc -l < "${dst}" 2> /dev/null)" \
      && (( src_lines <= dst_lines )); then
      unchanged=$(( unchanged + 1 ))
      continue
    fi
    srcs+=("${transcript}")
    dsts+=("${dst}")
  done
  if (( ${#srcs} == 0 )); then
    (( unchanged > 0 )) && log_info "Transcripts: ${unchanged} unchanged, nothing to stage"
    return 0
  fi
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
          if [[ "${TRANSCRIPT_SECRETS}" == redact ]] && (( GATE_REDACT_COUNTABLE == 0 )); then
            log_info "Secret gate: redacted ${GATE_REDACT_HELD} secret(s) out of the synced copy of ${srcs[i]:t}${note}"
          else
            log_warn "Secret gate: ${GATE_REDACT_HELD} secret(s) held back from the synced copy of ${srcs[i]:t} (redacted${note})"
          fi
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
  # One journal line per run so a phase creeping back toward activation- and
  # timer-hostile durations is visible before it breaks something again.
  if [[ -n "${phase_started}" ]]; then
    local phase_ended
    if phase_ended="$(date +%s)"; then
      log_info "Transcripts: ${#srcs} staged and scanned, ${unchanged} unchanged, $(( phase_ended - phase_started ))s"
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Session side files
# ---------------------------------------------------------------------------

# What a transcript points at beside itself: the large tool outputs Claude Code
# spills to <slug>/<session>/tool-results/, a subagent's .meta.json next to its
# transcript. A session resumed without them still resumes, but every reference
# into them dangles. Write-once, so presence is the whole comparison: each is
# copied only to a side that lacks it, in either direction, and never again.
SIDE_UUID_RE='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

# Side files the gate could not clear, one relative path per line. Local and
# never synced: the files it names stay on this box, and are not re-scanned (or
# re-warned about) on every run.
side_held_file() { print -r -- "${HOME_DIR}/.local/state/flakelab/state-sync/side-files.held" }

# <slug>/<session uuid>/…/<file>: not a transcript, no sync artifact anywhere in
# it. The memory directory is not a session, so it never matches.
side_file_rel() {
  local rel="$1"
  local -a segs=("${(@s:/:)rel}")
  (( ${#segs} >= 3 )) || return 1
  [[ "${segs[2]}" =~ ${SIDE_UUID_RE} ]] || return 1
  [[ "${rel}" != *.jsonl ]] || return 1
  rel_path_is_sync_artifact "${rel}" && return 1
  return 0
}

# Push leg, through the same gate as the transcripts but as plain text: every
# reported secret is replaced literally with [REDACTED:<rule>], longest first so
# a shorter variant cannot leave the tail of a longer one behind. A file with a
# secret that cannot be found literally (the scanner reported it across a line
# break) is held back and recorded in side_held_file. The local file is never
# modified.
backup_side_files() {
  local f rel line held_file
  local -a srcs=() rels=()
  local -A held=()
  held_file="$(side_held_file)"
  if [[ -f "${held_file}" ]]; then
    while IFS= read -r line; do
      [[ -n "${line}" ]] && held[${line}]=1
    done < "${held_file}"
  fi
  for f in "${HOME_DIR}"/.claude/projects/*/*/**/*(N.); do
    rel="${f#${HOME_DIR}/.claude/projects/}"
    side_file_rel "${rel}" || continue
    [[ -e "${STATE_ROOT}/claude/projects/${rel}" ]] && continue
    [[ -n "${held[${rel}]:-}" ]] && continue
    srcs+=("${f}")
    rels+=("${rel}")
  done
  (( ${#srcs} > 0 )) || return 0
  if ${DRY_RUN}; then
    log_dry "Would push ${#srcs} session side file(s) through the secret gate"
    return 0
  fi
  gate_guard || return 0

  local stage findings
  if ! stage="$(mktemp -d)" || ! findings="$(mktemp)"; then
    rm -rf "${stage}" "${findings}"
    record_failure "Secret gate: could not create work files for the side-file scan"
    return 0
  fi
  local -i i j pushed=0 redacted=0 kept=0
  for (( i = 1; i <= ${#srcs}; i++ )); do
    if ! mkdir -p "${stage}/in/${i}" || ! cp "${srcs[i]}" "${stage}/in/${i}/${srcs[i]:t}"; then
      rm -rf "${stage}" "${findings}"
      record_failure "Secret gate: could not stage side file ${rels[i]} for scanning"
      return 0
    fi
  done
  if ! gate_scan "${stage}/in" "${findings}"; then
    rm -rf "${stage}" "${findings}"
    record_failure "Secret gate scan failed (gitleaks); session side files NOT written to ${STATE_ROOT} this run"
    return 0
  fi

  local staged candidate content dst start end rule desc match secret k clear
  local -a secrets=() rules=() by_len=()
  for (( i = 1; i <= ${#srcs}; i++ )); do
    staged="${stage}/in/${i}/${srcs[i]:t}"
    candidate="${staged}"
    secrets=()
    rules=()
    while IFS=$'\x01' read -r start end rule desc match secret; do
      [[ -n "${start}" ]] || continue
      [[ -n "${secret}" ]] || secret="${match}"
      secrets+=("${secret}")
      rules+=("${rule}")
    done < <(gate_findings_for_file "${findings}" "${staged}")
    if (( ${#secrets} > 0 )); then
      # $(cat; print x): a command substitution strips trailing newlines, the x keeps them.
      content="$(cat "${staged}"; print -n x)"
      content="${content%x}"
      clear=true
      for secret in "${secrets[@]}"; do
        [[ -n "${secret}" && "${content}" == *"${secret}"* ]] || clear=false
      done
      if ${clear}; then
        by_len=()
        for (( j = 1; j <= ${#secrets}; j++ )); do
          by_len+=("${#secrets[j]}:${j}")
        done
        for k in "${(@On)by_len}"; do
          j="${k#*:}"
          content="${content//"${secrets[j]}"/[REDACTED:${rules[j]}]}"
        done
        for secret in "${secrets[@]}"; do
          [[ "${content}" == *"${secret}"* ]] && clear=false
        done
      fi
      if ! ${clear}; then
        if ensure_dir "${held_file:h}" && print -r -- "${rels[i]}" >> "${held_file}"; then
          log_warn "Secret gate: session side file ${rels[i]} held back — its secret cannot be matched literally, so it stays on this box"
        else
          record_failure "Could not record the held side file ${rels[i]}"
        fi
        kept=$(( kept + 1 ))
        continue
      fi
      candidate="${stage}/out.${i}"
      if ! print -rn -- "${content}" > "${candidate}"; then
        record_failure "Secret gate: could not write the redacted copy of ${rels[i]}"
        continue
      fi
      redacted=$(( redacted + 1 ))
    fi
    dst="${STATE_ROOT}/claude/projects/${rels[i]}"
    ensure_dir "${dst:h}"
    if ! place_atomically "${candidate}" "${dst}"; then
      record_failure "Could not push the session side file ${rels[i]}"
      continue
    fi
    chmod 600 "${dst}" 2> /dev/null || record_failure "Cannot set mode 600 on ${dst}"
    pushed=$(( pushed + 1 ))
  done
  rm -rf "${stage}" "${findings}"
  (( pushed > 0 )) && STATE_WROTE=true
  log_info "Session side files: ${pushed} pushed (${redacted} redacted), ${kept} held on this box"
  return 0
}

# Pull leg: every side file the state root has and this box lacks. Its bytes
# already passed the pushing box's gate.
pull_side_files() {
  local f rel dst
  local -i pulled=0
  for f in "${STATE_ROOT}"/claude/projects/*/*/**/*(N.); do
    rel="${f#${STATE_ROOT}/claude/projects/}"
    side_file_rel "${rel}" || continue
    dst="${HOME_DIR}/.claude/projects/${rel}"
    [[ -e "${dst}" ]] && continue
    if ${DRY_RUN}; then
      log_dry "${f} -> ${dst}"
      continue
    fi
    ensure_dir "${dst:h}"
    if ! place_atomically "${f}" "${dst}"; then
      record_failure "Could not pull the session side file ${rel}"
      continue
    fi
    chmod 600 "${dst}" 2> /dev/null || record_failure "Cannot set mode 600 on ${dst}"
    pulled=$(( pulled + 1 ))
  done
  (( pulled > 0 )) && log_ok "Pulled ${pulled} session side file(s)"
  return 0
}

# ---------------------------------------------------------------------------
# Slug manifests and garbage collection
# ---------------------------------------------------------------------------

# Every box that syncs writes the list of Claude project slugs it currently
# holds; the union of all manifests is what the state root is allowed to keep.
# A slug no box claims — a renamed checkout's old name, a deleted project, a
# machine's leftovers — is an orphan that would otherwise replicate forever:
# the sync has no other notion of deletion.
manifest_dir() { print -r -- "${STATE_ROOT}/.flakelab-state-manifests" }

write_state_manifest() {
  state_enabled || return 0
  local dst
  dst="$(manifest_dir)/${DISTRO_NAME}"
  if ${DRY_RUN}; then
    log_dry "Would write the slug manifest: ${dst}"
    return 0
  fi
  local build slug_dir
  if ! build="$(mktemp)"; then
    record_failure "Could not create a work file for the slug manifest"
    return 0
  fi
  for slug_dir in "${HOME_DIR}"/.claude/projects/*(N/); do
    print -r -- "${slug_dir:t}" >> "${build}"
  done
  ensure_dir "${dst:h}"
  if ! place_atomically "${build}" "${dst}"; then
    rm -f "${build}"
    record_failure "Could not write the slug manifest: ${dst}"
    return 0
  fi
  rm -f "${build}"
  chmod 600 "${dst}" 2> /dev/null || true
  return 0
}

# Root slugs claimed by NO manifest are listed, and removed only under --force.
# Refuses to judge when any manifest is stale (that box may hold slugs its old
# manifest never recorded) or when none exist at all. The gate and shell
# folders are out of scope: GC touches only claude/projects/<slug> trees.
GC_MANIFEST_MAX_AGE_DAYS="${FLAKELAB_STATE_GC_MAX_AGE_DAYS:-7}"
do_state_gc() {
  log_info "=== State-root slug GC [${DISTRO_NAME}] ==="
  log_state_root
  echo ""
  if ! state_enabled; then
    log_error "--state-gc needs a usable state root"
    FAILURES=$(( FAILURES + 1 ))
    return 0
  fi

  local -a manifests=("$(manifest_dir)"/*(N.))
  if (( ${#manifests} == 0 )); then
    log_error "No slug manifests in $(manifest_dir) — run a backup or --state-only on every box first"
    FAILURES=$(( FAILURES + 1 ))
    return 0
  fi

  local m mtime now
  if ! now="$(date +%s)"; then
    record_failure "Could not read the clock; nothing collected"
    return 0
  fi
  local -A claimed=()
  local slug
  for m in "${manifests[@]}"; do
    if ! mtime="$(stat -c %Y "${m}" 2> /dev/null)"; then
      record_failure "Could not stat manifest ${m}; nothing collected"
      return 0
    fi
    if (( now - mtime > GC_MANIFEST_MAX_AGE_DAYS * 86400 )); then
      log_error "Manifest ${m:t} is older than ${GC_MANIFEST_MAX_AGE_DAYS} day(s) — that box has not synced; refusing to collect"
      FAILURES=$(( FAILURES + 1 ))
      return 0
    fi
    while IFS= read -r slug; do
      [[ -n "${slug}" ]] && claimed[${slug}]=1
    done < "${m}"
  done
  log_info "${#manifests} manifest(s), ${#claimed} slug(s) claimed"

  local -a orphans=()
  local slug_dir
  for slug_dir in "${STATE_ROOT}"/claude/projects/*(N/); do
    is_sync_artifact "${slug_dir:t}" && continue
    [[ -n "${claimed[${slug_dir:t}]:-}" ]] && continue
    orphans+=("${slug_dir}")
  done

  if (( ${#orphans} == 0 )); then
    log_ok "No orphaned slugs in the state root."
    return 0
  fi

  for slug_dir in "${orphans[@]}"; do
    if ${FORCE} && ! ${DRY_RUN}; then
      if rm -rf "${slug_dir}"; then
        log_ok "Removed orphaned slug: ${slug_dir:t}"
      else
        record_failure "Could not remove orphaned slug: ${slug_dir}"
      fi
    else
      log_warn "Orphaned (no box claims it): ${slug_dir:t}"
    fi
  done
  if ! ${FORCE} || ${DRY_RUN}; then
    log_info "Nothing removed. Re-run with --force to delete the ${#orphans} slug(s) above."
  fi
  return 0
}
