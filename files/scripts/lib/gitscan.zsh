#!/usr/bin/env zsh

# gitscan.zsh — the one copy of what a repo sweep does before it reads a repo.
#
# Sourced (not executed) by gitchecker and gitcleaner. Those two answer opposite
# questions — one reports, one deletes — and must agree exactly on which repos
# are in scope, which tools are proven, and how a forge URL routes. A second copy
# of that agreement is a second answer to "which repos", and the cleaner would
# act on the set the checker never showed.
#
# What stays with the caller: parallelism, abort semantics, output, and every
# decision about what to do with a repo once it is found.
#
# Callers set GITSCAN_PROG before sourcing, or accept the fallback below; it is
# the prefix on every message from here.

# %x is this file, not the caller's $0 — git-net.zsh must resolve whether it is
# sourced from the repo or from the nix store copy the wrappers execute.
source "${${(%):-%x}:A:h}/git-net.zsh" || return 1

typeset -g GITSCAN_PROG="${GITSCAN_PROG:-gitscan}"

# A caller that promised its stdout is JSON has to keep that promise when it
# dies in preflight too. If jq itself is what is missing there is nothing to
# print with — the message on stderr is then the whole answer.
#
# `ok` and `aborted` are the two keys every document from either script carries,
# so a caller can branch on them before it knows which tool it ran.
typeset -g GITSCAN_DIE_JSON=0

gitscan_die() {
  print -r -u2 -- "${GITSCAN_PROG}: $*"
  (( GITSCAN_DIE_JSON )) && jq -n --arg reason "$*" \
    '{ok: false, aborted: {repo: null, reason: $reason, detail: ""}, repos: []}' 2>/dev/null
  exit 2
}

# gitscan_preflight — prove the always-needed tools before a single repo is
# touched, so a sweep never dies half-reported or half-applied. `gh` is not here:
# it is only ever reached for a github.com remote, so it is gated on the scanned
# set instead (gitscan_require_gh).
gitscan_preflight() {
  local bin
  for bin in git jq glab; do
    command -v "${bin}" >/dev/null 2>&1 \
      || gitscan_die "required binary not found on PATH: ${bin}"
  done
  # Tokens are loaded at shell start from ~/.config/tyc/secrets.env, so that is
  # where a failed probe gets fixed.
  glab auth status >/dev/null 2>&1 \
    || gitscan_die "glab is not authenticated — set GITLAB_TOKEN in ~/.config/tyc/secrets.env and start a new shell"
}

# gitscan_abs_roots <root>... — resolved roots into GITSCAN_ABS_ROOTS, dying on
# any that does not exist. A typo'd root must not read as "nothing to do here".
gitscan_abs_roots() {
  local root
  typeset -ga GITSCAN_ABS_ROOTS=()
  for root in "$@"; do
    [[ -d "${root}" ]] || gitscan_die "repos dir not found: ${root}"
    GITSCAN_ABS_ROOTS+=("${root:A}")
  done
}

# gitscan_timeouts — bound every network attempt when a timeout binary resolves.
# Kept as an array: zsh does not word-split a plain expansion, so a string
# prefix would be passed as one argv entry. Absent `timeout`/`gtimeout` the
# array stays empty and attempts are unbounded — that is the documented gap, not
# a silent one.
gitscan_timeouts() {
  local bin
  bin="$(command -v timeout || command -v gtimeout || true)"
  GITNET_TIMEOUT_CMD=()
  [[ -n "${bin}" ]] && GITNET_TIMEOUT_CMD=("${bin}" -k 5 30)
}

# gitscan_colors — colour only when stdout is a terminal, so a piped or
# redirected run stays parseable.
gitscan_colors() {
  if [[ -t 1 ]]; then
    typeset -g C_RESET=$'\e[0m' C_RED=$'\e[31m' C_GREEN=$'\e[32m'
    typeset -g C_YELLOW=$'\e[33m' C_CYAN=$'\e[36m' C_DIM=$'\e[2m'
  else
    typeset -g C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_DIM=""
  fi
}

# gitscan_ssh_mux <workdir> — reuse one connection per host. Without
# multiplexing every repo pays a full TCP+SSH handshake, and at four-figure repo
# counts gitlab.com starts timing connections out during banner exchange. An
# explicit GIT_SSH_COMMAND from the environment wins.
gitscan_ssh_mux() {
  local workdir="$1"
  [[ -n "${GIT_SSH_COMMAND-}" ]] && return 0
  export GIT_SSH_COMMAND="ssh ${GITNET_SSH_BASE} -o ControlMaster=auto -o ControlPath=${workdir}/ssh-%r@%h:%p -o ControlPersist=60"
}

# gitscan_discover <max-depth> <root>... — every repo under each root into
# GITSCAN_GITDIRS, with the root each one came from in GITSCAN_GITDIR_ROOTS at
# the same index. `-prune` so a repo's own history is never descended into.
#
# A worktree's `.git` is a FILE pointing into its parent's admin dir. gitchecker
# reports it as its own repo (it has its own HEAD and its own dirty state);
# gitcleaner must not, because deleting from there writes the parent's ref store
# while a checkout of one of those branches is live. GITSCAN_SKIP_WORKTREES=1
# selects the second reading.
gitscan_discover() {
  local max_depth="$1"; shift
  local root gd
  typeset -ga GITSCAN_GITDIRS=() GITSCAN_GITDIR_ROOTS=()
  for root in "$@"; do
    while IFS= read -r gd || [[ -n "${gd}" ]]; do
      [[ -z "${gd}" ]] && continue
      (( ${GITSCAN_SKIP_WORKTREES:-0} )) && [[ ! -d "${gd}" ]] && continue
      GITSCAN_GITDIRS+=("${gd}")
      GITSCAN_GITDIR_ROOTS+=("${root}")
    done < <(find "${root}" -maxdepth "${max_depth}" -name .git -prune -print 2>/dev/null | sort)
  done
}

# gitscan_require_gh <gitdir>... — gate `gh` on the scanned set, not the host: an
# all-GitLab tree must run without gh present. Reading configured remotes is
# local and stops at the first GitHub hit, so this still runs before any repo is
# fetched and the fail-fast guarantee holds.
gitscan_require_gh() {
  local gitdir
  for gitdir in "$@"; do
    case "$(git -C "${gitdir:h}" config --get remote.origin.url 2>/dev/null)" in
      *github.com[:/]*)
        command -v gh >/dev/null 2>&1 \
          || gitscan_die "a github.com remote is in scope but gh is not on PATH"
        gh auth status >/dev/null 2>&1 \
          || gitscan_die "gh is not authenticated — set GH_TOKEN in ~/.config/tyc/secrets.env and start a new shell"
        return 0 ;;
    esac
  done
  return 0
}

# gitscan_forge_of <url> — "<forge>\t<project>", rc 1 for a host neither CLI can
# query. Reads the *configured* remote URL, never `git remote get-url`, which
# applies url.<base>.insteadOf rewrites and would report the rewrite target's
# host instead of the real one.
gitscan_forge_of() {
  local url="$1" project=""
  case "${url}" in
    *gitlab.com[:/]*)
      project="${${url#*gitlab.com}#[:/]}"
      print -r -- "gitlab	${project%.git}" ;;
    *github.com[:/]*)
      project="${${url#*github.com}#[:/]}"
      print -r -- "github	${project%.git}" ;;
    *) return 1 ;;
  esac
}

# Paging cap. Ten pages of 100 is 1000 open MRs in one project; past that
# something is wrong with the project, not with this script. Hitting the cap is
# a failure rather than a truncation, because a truncated open-MR list is
# exactly what makes gitcleaner think an in-flight branch is stale.
# Both caps read the environment so a test can drive them to a size a stub can
# actually produce.
typeset -gi GITSCAN_MAX_PAGES=${GITSCAN_MAX_PAGES:-10}

# gh pages internally, so its cap is one number rather than a page count. Same
# meaning as GITSCAN_MAX_PAGES × 100, and reaching it is the same failure.
typeset -gi GITSCAN_GH_LIMIT=${GITSCAN_GH_LIMIT:-1000}

# gitscan_open_requests <forge> <project> — every open MR/PR as one JSON array
# in GITSCAN_FORGE_JSON; rc 1 with the reason in GITSCAN_FORGE_WHY and whatever
# came back in GITSCAN_FORGE_JSON.
#
# Paged to exhaustion, because one page of 100 is not the answer: gitchecker
# would under-report a busy project, and gitcleaner's open-MR guard — the only
# thing between a branch under review and `git branch -d` — would cover just the
# first hundred.
gitscan_open_requests() {
  local forge="$1" project="$2" body="" acc="[]"
  local -i page=1 n=0
  typeset -g GITSCAN_FORGE_JSON="" GITSCAN_FORGE_WHY=""

  # gh pages internally up to --limit, so one call covers the same ground. A
  # reply that fills the limit is indistinguishable from one that was cut off at
  # it, and both are the truncation this function refuses to return.
  if [[ "${forge}" == github ]]; then
    if ! gitnet_retry gh pr list --repo "${project}" --state open \
        --limit "${GITSCAN_GH_LIMIT}" --json number,title,headRefName,isDraft; then
      GITSCAN_FORGE_WHY="gh pr list failed (after retry, ${GITNET_WHY})"
      GITSCAN_FORGE_JSON="${GITNET_OUT}"
      return 1
    fi
    GITSCAN_FORGE_JSON="${GITNET_OUT}"
    [[ -z "${GITSCAN_FORGE_JSON//[[:space:]]/}" ]] && GITSCAN_FORGE_JSON="[]"
    n="$(print -r -- "${GITSCAN_FORGE_JSON}" | jq 'length' 2>/dev/null || print -n 0)"
    if (( n >= GITSCAN_GH_LIMIT )); then
      GITSCAN_FORGE_WHY="more than ${GITSCAN_GH_LIMIT} open PRs — refusing to work from a truncated list"
      return 1
    fi
    return 0
  fi

  while (( page <= GITSCAN_MAX_PAGES )); do
    if ! gitnet_retry glab mr list --repo "${project}" --output json \
        --per-page 100 --page "${page}"; then
      GITSCAN_FORGE_WHY="glab mr list failed (after retry, ${GITNET_WHY})"
      GITSCAN_FORGE_JSON="${GITNET_OUT}"
      return 1
    fi
    body="${GITNET_OUT}"
    [[ -z "${body//[[:space:]]/}" ]] && break
    # Both documents ride stdin, not --argjson: a busy project's MR list can
    # exceed ARG_MAX, and "argument list too long: jq" is not a parse failure.
    if ! acc="$({ print -r -- "${acc}"; print -r -- "${body}"; } | jq -s '.[0] + .[1]' 2>&1)"; then
      GITSCAN_FORGE_WHY="could not parse the open MR list"
      GITSCAN_FORGE_JSON="${acc}"
      return 1
    fi
    n="$(print -r -- "${body}" | jq 'length' 2>/dev/null || print -n 0)"
    (( n < 100 )) && break
    (( page++ ))
  done

  if (( page > GITSCAN_MAX_PAGES )); then
    GITSCAN_FORGE_WHY="more than $(( GITSCAN_MAX_PAGES * 100 )) open MRs — refusing to work from a truncated list"
    GITSCAN_FORGE_JSON="${acc}"
    return 1
  fi
  GITSCAN_FORGE_JSON="${acc}"
  return 0
}

# gitscan_branch_merged <forge> <project> <branch> — rc 0 when the forge has a
# merged MR/PR for exactly this source branch, rc 1 when it has none, rc 2 when
# it could not be asked.
#
# Asked per branch rather than against a list of merged MRs: that list is
# unbounded, so any page limit turns an older merge into "not merged". Candidates
# are few by construction — a branch that is an ancestor of nothing and whose
# upstream is gone — so one call each is cheap and exact.
gitscan_branch_merged() {
  local forge="$1" project="$2" branch="$3" n=0
  typeset -g GITSCAN_FORGE_WHY=""
  if [[ "${forge}" == gitlab ]]; then
    if ! gitnet_retry glab mr list --repo "${project}" --source-branch "${branch}" \
        --merged --output json --per-page 100; then
      GITSCAN_FORGE_WHY="glab mr list --merged failed for ${branch} (after retry, ${GITNET_WHY})"
      return 2
    fi
  else
    if ! gitnet_retry gh pr list --repo "${project}" --head "${branch}" \
        --state merged --limit 100 --json number; then
      GITSCAN_FORGE_WHY="gh pr list --state merged failed for ${branch} (after retry, ${GITNET_WHY})"
      return 2
    fi
  fi
  [[ -z "${GITNET_OUT//[[:space:]]/}" ]] && return 1
  if ! n="$(print -r -- "${GITNET_OUT}" | jq 'length' 2>&1)"; then
    GITSCAN_FORGE_WHY="could not parse the merged list for ${branch}: ${n}"
    return 2
  fi
  (( n > 0 )) && return 0
  return 1
}

# gitscan_jq <json> <filter> — parsed values into GITSCAN_JQ_OUT, rc 1 with the
# error in GITSCAN_JQ_ERR. Checked, never swallowed: an unparsable body would
# yield an empty list, and an empty list reads exactly like a legitimate "no
# open MRs" — the failure would arrive disguised as an answer. An empty body IS
# that legitimate answer and stays rc 0.
gitscan_jq() {
  local body="$1" filter="$2"
  typeset -g GITSCAN_JQ_OUT="" GITSCAN_JQ_ERR=""
  [[ -z "${body//[[:space:]]/}" ]] && return 0
  if ! GITSCAN_JQ_OUT="$(print -r -- "${body}" | jq -r "${filter}" 2>&1)"; then
    GITSCAN_JQ_ERR="${GITSCAN_JQ_OUT}"
    GITSCAN_JQ_OUT=""
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Fast-forward
# ---------------------------------------------------------------------------
# Both gitchecker and gitcleaner already `fetch --prune` before they reason, so
# they hold the freshly-computed ahead/behind that says whether a branch can move
# without a merge. Stopping short of the one `--ff-only` that follows just moved
# the work to a second command.
#
# Safety is a property of the branch, not of the tool:
#   strictly behind (ahead == 0, behind > 0) is the ONLY state that fast-forwards.
#   Everything else - diverged, ahead, gone, no upstream - is left alone.
# A branch that is not checked out moves without touching the working tree at
# all: `git fetch . <upstream>:<branch>` refuses a non-fast-forward without
# `+`, so git enforces the invariant rather than this code trusting its own
# arithmetic.
#
# GITSCAN_FF_OUT carries git's message for the caller's report.
GITSCAN_FF_OUT=""

# gitscan_ff_branch <repo> <branch> <upstream> <head_branch> <dirty> <allow_dirty>
# Returns 0 when the branch moved, 1 when it did not (reason in GITSCAN_FF_OUT).
gitscan_ff_branch() {
  local repo="$1" branch="$2" upstream="$3" head_branch="$4"
  local -i dirty="$5"
  local allow_dirty="$6"
  GITSCAN_FF_OUT=""

  if [[ "${branch}" != "${head_branch}" ]]; then
    # Not checked out: no working tree to disturb.
    if GITSCAN_FF_OUT="$(git -C "${repo}" fetch . "${upstream}:${branch}" 2>&1)"; then
      return 0
    fi
    return 1
  fi

  # Checked out. A dirty tree does not always block a fast-forward - git refuses
  # only when the merge would overwrite a modified path - but attempting it
  # silently is how a "checker" eats someone's edits, so it is opt-in.
  if (( dirty > 0 )) && [[ "${allow_dirty}" != true ]]; then
    GITSCAN_FF_OUT="working tree dirty (--ff-dirty, or answer yes, to try anyway)"
    return 1
  fi

  if GITSCAN_FF_OUT="$(git -C "${repo}" merge --ff-only "${upstream}" 2>&1)"; then
    return 0
  fi
  return 1
}
