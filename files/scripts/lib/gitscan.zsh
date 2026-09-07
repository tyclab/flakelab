#!/usr/bin/env zsh

# The one copy of what a repo sweep does before it reads a repo. Sourced, not
# executed, by gitchecker and gitcleaner, which must agree exactly on which repos
# are in scope; what to do with a repo once found stays with the caller.

# %x is this file, not the caller's $0: it must resolve from the repo and from the
# nix store copy alike.
source "${${(%):-%x}:A:h}/git-net.zsh" || return 1

typeset -g GITSCAN_PROG="${GITSCAN_PROG:-gitscan}"

# A caller that promised JSON on stdout must keep that promise when it dies in
# preflight too; with jq itself missing, stderr is the whole answer.
typeset -g GITSCAN_DIE_JSON=0

gitscan_die() {
  print -r -u2 -- "${GITSCAN_PROG}: $*"
  (( GITSCAN_DIE_JSON )) && jq -n --arg reason "$*" \
    '{ok: false, aborted: {repo: null, reason: $reason, detail: ""}, repos: []}' 2>/dev/null
  exit 2
}

# gitscan_preflight — prove the always-needed tools before a repo is touched, so a
# sweep never dies half-applied. `gh` is gated on the scanned set instead.
gitscan_preflight() {
  local bin
  for bin in git jq glab; do
    command -v "${bin}" >/dev/null 2>&1 \
      || gitscan_die "required binary not found on PATH: ${bin}"
  done
  glab auth status >/dev/null 2>&1 \
    || gitscan_die "glab is not authenticated — set GITLAB_TOKEN in ~/.config/tyc/secrets.env and start a new shell"
}

# gitscan_abs_roots <root>... — resolved roots into GITSCAN_ABS_ROOTS; a typo'd root
# dies rather than reading as "nothing to do here".
gitscan_abs_roots() {
  local root
  typeset -ga GITSCAN_ABS_ROOTS=()
  for root in "$@"; do
    [[ -d "${root}" ]] || gitscan_die "repos dir not found: ${root}"
    GITSCAN_ABS_ROOTS+=("${root:A}")
  done
}

# gitscan_timeouts — bound every network attempt when a timeout binary resolves;
# absent one, attempts are unbounded. An array, because zsh does not word-split.
gitscan_timeouts() {
  local bin
  bin="$(command -v timeout || command -v gtimeout || true)"
  GITNET_TIMEOUT_CMD=()
  [[ -n "${bin}" ]] && GITNET_TIMEOUT_CMD=("${bin}" -k 5 30)
}

# gitscan_colors — colour only at a terminal, so a piped run stays parseable.
gitscan_colors() {
  if [[ -t 1 ]]; then
    typeset -g C_RESET=$'\e[0m' C_RED=$'\e[31m' C_GREEN=$'\e[32m'
    typeset -g C_YELLOW=$'\e[33m' C_CYAN=$'\e[36m' C_DIM=$'\e[2m'
  else
    typeset -g C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_DIM=""
  fi
}

# gitscan_ssh_mux <workdir> — one connection per host; without it a large sweep
# times out during banner exchange. An explicit GIT_SSH_COMMAND wins.
gitscan_ssh_mux() {
  local workdir="$1"
  [[ -n "${GIT_SSH_COMMAND-}" ]] && return 0
  export GIT_SSH_COMMAND="ssh ${GITNET_SSH_BASE} -o ControlMaster=auto -o ControlPath=${workdir}/ssh-%r@%h:%p -o ControlPersist=60"
}

# gitscan_discover <max-depth> <root>... — every repo under each root into
# GITSCAN_GITDIRS, with its root at the same index in GITSCAN_GITDIR_ROOTS.
# GITSCAN_SKIP_WORKTREES=1 drops worktrees, whose .git points into the parent's
# admin dir: deleting from there writes the parent's ref store under a live checkout.
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

# gitscan_require_gh <gitdir>... — gate `gh` on the scanned set, not the host, so an
# all-GitLab tree runs without it. Local reads only, so fail-fast still holds.
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
# query. Must be the configured URL, not `git remote get-url`, which applies
# insteadOf rewrites and would report the rewrite target's host.
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

# Paging cap; hitting it is a failure, not a truncation, because a truncated
# open-MR list is what makes gitcleaner think an in-flight branch is stale.
# Both caps read the environment so a test can drive them down.
typeset -gi GITSCAN_MAX_PAGES=${GITSCAN_MAX_PAGES:-10}

# gh pages internally, so its cap is one number rather than a page count.
typeset -gi GITSCAN_GH_LIMIT=${GITSCAN_GH_LIMIT:-1000}

# gitscan_open_requests <forge> <project> — every open MR/PR as one JSON array in
# GITSCAN_FORGE_JSON; rc 1 with the reason in GITSCAN_FORGE_WHY. Paged to
# exhaustion: gitcleaner's open-MR guard must not cover only the first page.
gitscan_open_requests() {
  local forge="$1" project="$2" body="" acc="[]"
  local -i page=1 n=0
  typeset -g GITSCAN_FORGE_JSON="" GITSCAN_FORGE_WHY=""

  # A reply filling --limit is indistinguishable from one cut off at it, and both
  # are the truncation this function refuses to return.
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
    # Via stdin, not --argjson: a busy project's MR list can exceed ARG_MAX.
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

# gitscan_branch_merged <forge> <project> <branch> — rc 0 when the forge has a merged
# MR/PR for exactly this source branch, 1 when it has none, 2 when it could not be
# asked. Per branch, because a paged list of merged MRs turns an older merge into
# "not merged".
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

# gitscan_jq <json> <filter> — parsed values into GITSCAN_JQ_OUT, rc 1 with the error
# in GITSCAN_JQ_ERR. Never swallow it: an unparsable body yields an empty list, which
# reads exactly like a legitimate "no open MRs". An empty body is that answer, rc 0.
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

# Fast-forward. Strictly behind (ahead == 0, behind > 0) is the only state that
# fast-forwards; diverged, ahead, gone and no-upstream are left alone. Without `+`,
# `git fetch . <upstream>:<branch>` refuses a non-fast-forward, so git enforces that
# rather than this code trusting its own arithmetic.
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
    if GITSCAN_FF_OUT="$(git -C "${repo}" fetch . "${upstream}:${branch}" 2>&1)"; then
      return 0
    fi
    return 1
  fi

  # Checked out: a dirty tree does not always block a fast-forward, but attempting
  # it silently is how a checker eats someone's edits, so it is opt-in.
  if (( dirty > 0 )) && [[ "${allow_dirty}" != true ]]; then
    GITSCAN_FF_OUT="working tree dirty (--ff-dirty, or answer yes, to try anyway)"
    return 1
  fi

  if GITSCAN_FF_OUT="$(git -C "${repo}" merge --ff-only "${upstream}" 2>&1)"; then
    return 0
  fi
  return 1
}
