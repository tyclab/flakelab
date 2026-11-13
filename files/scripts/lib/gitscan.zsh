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
    || gitscan_die "glab is not authenticated — set GITLAB_TOKEN in the overlay's sops secrets (~/.config/flakelab/secrets.env on a box without them) and start a new shell"
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

# gitscan_timeouts — bound fetch/API attempts when a timeout binary resolves;
# absent one, attempts are unbounded. Push uses gitnet_push_once so this timer
# cannot kill its local hooks. An array, because zsh does not word-split.
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

# gitscan_discover <max-depth> <root>...: repos into GITSCAN_GITDIRS, roots at the same index in GITSCAN_GITDIR_ROOTS.
# GITSCAN_SKIP_WORKTREES=1 drops worktrees: deleting from one writes the parent's ref store under a live checkout.
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
          || gitscan_die "gh is not authenticated — set GH_TOKEN in the overlay's sops secrets (~/.config/flakelab/secrets.env on a box without them) and start a new shell"
        return 0 ;;
    esac
  done
  return 0
}

# gitscan_remote_gone <fetch output>: the forge answered that this project is not
# there (deleted, or not visible to this login): a fact about one repo, unlike a
# network failure, which leaves every result of the sweep in doubt.
gitscan_remote_gone() {
  [[ "$1" == *"could not be found or you don't have permission"* \
    || "$1" == *"Repository not found"* \
    || "$1" == *"does not appear to be a git repository"* ]]
}

# gitscan_forge_of <url>: "<forge>\t<project>", rc 1 for an unknown host. The configured URL, not
# `git remote get-url`, which applies insteadOf rewrites.
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
        --limit "${GITSCAN_GH_LIMIT}" --json number,title,headRefName,baseRefName,isDraft; then
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

# gitscan_branch_merged <forge> <project> <branch> <head>: rc 0 this tip merged, 1 none, 2 not asked.
# A historical merge of the same branch name cannot vouch for new local commits.
gitscan_branch_merged() {
  local forge="$1" project="$2" branch="$3" head="$4" field=sha n=0
  typeset -g GITSCAN_FORGE_WHY=""
  [[ -n "${head}" ]] || return 1
  if [[ "${forge}" == gitlab ]]; then
    if ! gitnet_retry glab mr list --repo "${project}" --source-branch "${branch}" \
        --merged --output json --per-page 100; then
      GITSCAN_FORGE_WHY="glab mr list --merged failed for ${branch} (after retry, ${GITNET_WHY})"
      return 2
    fi
  else
    field=headRefOid
    if ! gitnet_retry gh pr list --repo "${project}" --head "${branch}" \
        --state merged --limit 100 --json headRefOid; then
      GITSCAN_FORGE_WHY="gh pr list --state merged failed for ${branch} (after retry, ${GITNET_WHY})"
      return 2
    fi
  fi
  [[ -z "${GITNET_OUT//[[:space:]]/}" ]] && return 1
  if ! n="$(print -r -- "${GITNET_OUT}" | jq --arg head "${head}" --arg field "${field}" \
      '[.[] | select(.[$field] == $head)] | length' 2>&1)"; then
    GITSCAN_FORGE_WHY="could not parse the merged list for ${branch}: ${n}"
    return 2
  fi
  (( n > 0 )) && return 0
  return 1
}

# gitscan_forge_user <forge>: this login's name on the forge in GITSCAN_FORGE_USER, asked once per process.
# rc 2 with the reason in GITSCAN_FORGE_WHY.
typeset -gA GITSCAN_USER_OF=()
gitscan_forge_user() {
  local forge="$1" field=username
  typeset -g GITSCAN_FORGE_WHY="" GITSCAN_FORGE_USER=""
  if (( ${+GITSCAN_USER_OF[${forge}]} )); then
    GITSCAN_FORGE_USER="${GITSCAN_USER_OF[${forge}]}"
    return 0
  fi
  if [[ "${forge}" == gitlab ]]; then
    if ! gitnet_retry glab api user; then
      GITSCAN_FORGE_WHY="glab api user failed (after retry, ${GITNET_WHY})"
      return 2
    fi
  else
    field=login
    if ! gitnet_retry gh api user; then
      GITSCAN_FORGE_WHY="gh api user failed (after retry, ${GITNET_WHY})"
      return 2
    fi
  fi
  if ! gitscan_jq "${GITNET_OUT}" ".${field} // empty" || [[ -z "${GITSCAN_JQ_OUT}" ]]; then
    GITSCAN_FORGE_WHY="could not read this login's ${forge} user name"
    return 2
  fi
  GITSCAN_USER_OF[${forge}]="${GITSCAN_JQ_OUT}"
  GITSCAN_FORGE_USER="${GITSCAN_JQ_OUT}"
  return 0
}

# gitscan_can_administer <forge> <project>: rc 0 when this login administers the project (GitHub admin, GitLab
# Maintainer or Owner), 1 when it does not, 2 (GITSCAN_FORGE_WHY) when the forge was not asked. Push access is
# not the bar: a contributor allowed to push to someone else's project could delete that project's branches.
# An archived project takes no push, so nothing in it is this login's to clean. Leaves the project's number in
# GITSCAN_PROJECT_ID and the default branch the forge names in GITSCAN_PROJECT_DEFAULT.
gitscan_can_administer() {
  local forge="$1" project="$2" filter
  typeset -g GITSCAN_FORGE_WHY=""
  if [[ "${forge}" == gitlab ]]; then
    if ! gitnet_retry glab api "projects/${project//\//%2F}"; then
      GITSCAN_FORGE_WHY="glab api projects/${project} failed (after retry, ${GITNET_WHY})"
      return 2
    fi
    filter='([.permissions.project_access.access_level // 0, .permissions.group_access.access_level // 0] | max >= 40)
      and .archived != true'
  else
    if ! gitnet_retry gh api "repos/${project}"; then
      GITSCAN_FORGE_WHY="gh api repos/${project} failed (after retry, ${GITNET_WHY})"
      return 2
    fi
    filter='.permissions.admin == true and .archived != true'
  fi
  # An empty reply is no answer: read as "no rights" it would report a project with leftovers as current.
  if ! gitscan_jq "${GITNET_OUT}" "[(${filter}), (.id // \"\"), (.default_branch // \"\")] | @tsv" \
      || [[ -z "${GITSCAN_JQ_OUT}" ]]; then
    GITSCAN_FORGE_WHY="could not parse the project record of ${project}: ${GITSCAN_JQ_ERR:-empty reply}"
    return 2
  fi
  # Split on every tab: `read` folds an empty field into its neighbour.
  local -a field=("${(@ps:\t:)GITSCAN_JQ_OUT}")
  local admin="${field[1]-}" id="${field[2]-}" default="${field[3]-}"
  [[ "${admin}" == true ]] || return 1
  # GitLab names a request's source project by this number, not by path: without it "no open request built on
  # the branch" cannot be told from "the filter matched nothing".
  if [[ -z "${id}" ]]; then
    GITSCAN_FORGE_WHY="the project record of ${project} carries no id"
    return 2
  fi
  typeset -g GITSCAN_PROJECT_ID="${id}" GITSCAN_PROJECT_DEFAULT="${default}"
  return 0
}

# gitscan_branch_pinned <forge> <project> <project-id> <branch>: rc 0 when the server still needs this branch,
# 1 when it does not, 2 (GITSCAN_FORGE_WHY) when the forge was not asked. Needed means: the project protects
# it (branch protection, or a ruleset that applies to it: a long-lived branch, and one the delete would be
# refused for on every run), the server no longer has it, or an open request in another project is built on
# it. A fork's branch is the head of requests in its upstream, and the fork's own request list shows none of
# them: deleting the branch would close a request someone else is reviewing. On GitLab that query sees this
# login's requests only.
gitscan_branch_pinned() {
  local forge="$1" project="$2" project_id="$3" branch="$4" enc
  typeset -g GITSCAN_FORGE_WHY=""
  if [[ "${forge}" == gitlab ]]; then
    enc="$(jq -rn --arg b "${branch}" '$b | @uri')"
    if ! gitnet_retry glab api "projects/${project//\//%2F}/repository/branches/${enc}"; then
      # Gone since the fetch: not a branch to delete, and the next run's prune forgets it.
      [[ "${GITNET_OUT}" == *"404 Branch Not Found"* ]] && return 0
      GITSCAN_FORGE_WHY="glab api repository/branches failed for ${branch} (after retry, ${GITNET_WHY})"
      return 2
    fi
    if ! gitscan_jq "${GITNET_OUT}" 'if .protected == true then 1 else 0 end' || [[ -z "${GITSCAN_JQ_OUT}" ]]; then
      GITSCAN_FORGE_WHY="could not parse the branch record of ${branch}: ${GITSCAN_JQ_ERR:-empty reply}"
      return 2
    fi
    (( GITSCAN_JQ_OUT > 0 )) && return 0
    if ! gitnet_retry glab api \
        "merge_requests?scope=created_by_me&state=opened&per_page=100&source_branch=${enc}"; then
      GITSCAN_FORGE_WHY="glab api merge_requests failed for ${branch} (after retry, ${GITNET_WHY})"
      return 2
    fi
    if ! gitscan_jq "${GITNET_OUT}" '[.[] | select((.source_project_id | tostring) == $id)] | length' \
        --arg id "${project_id}"; then
      GITSCAN_FORGE_WHY="could not parse the open requests built on ${branch}: ${GITSCAN_JQ_ERR}"
      return 2
    fi
  else
    if ! gitnet_retry gh api graphql \
        -f query='query($o:String!,$n:String!,$r:String!){repository(owner:$o,name:$n){ref(qualifiedName:$r){branchProtectionRule{id} rules(first:1){totalCount} associatedPullRequests(states:OPEN,first:1){nodes{number}}}}}' \
        -f o="${project%%/*}" -f n="${project#*/}" -f r="refs/heads/${branch}"; then
      GITSCAN_FORGE_WHY="gh api graphql failed for ${branch} (after retry, ${GITNET_WHY})"
      return 2
    fi
    # A ref the server no longer has is not a branch to delete either: counted as needed.
    if ! gitscan_jq "${GITNET_OUT}" '.data.repository.ref | if . == null then 1 else
        (.associatedPullRequests.nodes | length) + (if .branchProtectionRule != null then 1 else 0 end)
        + (.rules.totalCount // 0) end'; then
      GITSCAN_FORGE_WHY="could not parse the open requests built on ${branch}: ${GITSCAN_JQ_ERR}"
      return 2
    fi
  fi
  # No body is no answer, and "nothing needs it" is the answer that deletes.
  if [[ -z "${GITSCAN_JQ_OUT}" ]]; then
    GITSCAN_FORGE_WHY="could not parse the open requests built on ${branch}: empty reply"
    return 2
  fi
  (( GITSCAN_JQ_OUT > 0 ))
}

# gitscan_request_end <forge> <project> <branch> <tip>: how this login's request from the branch ended on this
# tip, in GITSCAN_REQUEST_END: "merged", "closed", or "" when none of its requests in this project ended on it
# or any request of the branch is still open. rc 2, with the reason in GITSCAN_FORGE_WHY, when the forge was
# not asked. Every request of the branch is read, not one state: an open one among them means the branch is in
# use, and a tip no request ended on holds commits pushed since. Someone else's request does not make the
# branch this login's to remove, and a fork's request with the same branch name is another repository's branch.
gitscan_request_end() {
  local forge="$1" project="$2" branch="$3" tip="$4" filter me
  typeset -g GITSCAN_FORGE_WHY="" GITSCAN_REQUEST_END=""
  [[ -n "${tip}" ]] || return 0
  gitscan_forge_user "${forge}" || return 2
  me="${GITSCAN_FORGE_USER}"
  if [[ "${forge}" == gitlab ]]; then
    if ! gitnet_retry glab mr list --repo "${project}" --source-branch "${branch}" \
        --all --output json --per-page 100; then
      GITSCAN_FORGE_WHY="glab mr list --all failed for ${branch} (after retry, ${GITNET_WHY})"
      return 2
    fi
    filter='.[] | select(.source_project_id == .target_project_id)
      | [(.state // "" | if . == "merged" or . == "closed" then . else "open" end), (.sha // "-"),
         (.author.username // "-")] | @tsv'
  else
    if ! gitnet_retry gh pr list --repo "${project}" --head "${branch}" \
        --state all --limit 100 --json state,headRefOid,isCrossRepository,author; then
      GITSCAN_FORGE_WHY="gh pr list --state all failed for ${branch} (after retry, ${GITNET_WHY})"
      return 2
    fi
    filter='.[] | select(.isCrossRepository != true)
      | [(.state // "" | ascii_downcase | if . == "merged" or . == "closed" then . else "open" end),
         (.headRefOid // "-"), (.author.login // "-")] | @tsv'
  fi
  local body="${GITNET_OUT}"
  if ! gitscan_jq "${body}" 'length'; then
    GITSCAN_FORGE_WHY="could not parse the request list for ${branch}: ${GITSCAN_JQ_ERR}"
    return 2
  fi
  # A full page may be cut off, and a branch a hundred requests came from is a long-lived one, not a leftover:
  # kept. Not a failure, or that one branch would stop every run for good. Counted before any request is
  # filtered out, since the page fills with all of them.
  (( ${GITSCAN_JQ_OUT:-0} >= 100 )) && return 0
  if ! gitscan_jq "${body}" "${filter}"; then
    GITSCAN_FORGE_WHY="could not parse the request list for ${branch}: ${GITSCAN_JQ_ERR}"
    return 2
  fi
  [[ -z "${GITSCAN_JQ_OUT}" ]] && return 0
  gitscan_request_verdict "${GITSCAN_JQ_OUT}" "${tip}" "${me}"
  return 0
}

# gitscan_request_verdict <lines> <tip> <login>: GITSCAN_REQUEST_END from one branch's requests, one
# "<state>\t<head>\t<author>" per line: "" when any is open, else how the login's request ended on this tip.
gitscan_request_verdict() {
  local lines="$1" tip="$2" me="$3" state head author
  local -i merged=0 closed=0
  typeset -g GITSCAN_REQUEST_END=""
  while IFS=$'\t' read -r state head author; do
    [[ "${state}" == open ]] && return 0
    [[ "${head}" == "${tip}" ]] || continue
    [[ "${author}" == "${me}" ]] || continue
    [[ "${state}" == merged ]] && merged=1
    [[ "${state}" == closed ]] && closed=1
  done <<< "${lines}"
  if (( merged )); then
    GITSCAN_REQUEST_END=merged
  elif (( closed )); then
    GITSCAN_REQUEST_END=closed
  fi
  return 0
}

# gitscan_own_requests <project>: GitHub only. Every request this login opened in the project, from one query,
# as "<state>\t<head>\t<author>" lines per branch in GITSCAN_OWN_REQUESTS. rc 1 when the list fills the cap, so
# the caller asks per branch instead; rc 2 (GITSCAN_FORGE_WHY) when the forge was not asked. A fork carries its
# upstream's branches by the hundred, and one query per branch is hundreds of queries for a handful of requests.
# Another login's open request is not in this list: the caller's open-request list covers it.
gitscan_own_requests() {
  local project="$1" body branch rest
  typeset -gA GITSCAN_OWN_REQUESTS=()
  typeset -g GITSCAN_FORGE_WHY=""
  if ! gitnet_retry gh pr list --repo "${project}" --author "@me" --state all \
      --limit "${GITSCAN_GH_LIMIT}" --json state,headRefOid,headRefName,isCrossRepository,author; then
    GITSCAN_FORGE_WHY="gh pr list --author @me failed (after retry, ${GITNET_WHY})"
    return 2
  fi
  body="${GITNET_OUT}"
  if ! gitscan_jq "${body}" 'length'; then
    GITSCAN_FORGE_WHY="could not parse this login's request list for ${project}: ${GITSCAN_JQ_ERR}"
    return 2
  fi
  (( ${GITSCAN_JQ_OUT:-0} >= GITSCAN_GH_LIMIT )) && return 1
  if ! gitscan_jq "${body}" '.[] | select(.isCrossRepository != true)
      | [.headRefName, (.state // "" | ascii_downcase | if . == "merged" or . == "closed" then . else "open" end),
         (.headRefOid // "-"), (.author.login // "-")] | @tsv'; then
    GITSCAN_FORGE_WHY="could not parse this login's request list for ${project}: ${GITSCAN_JQ_ERR}"
    return 2
  fi
  [[ -z "${GITSCAN_JQ_OUT}" ]] && return 0
  while IFS=$'\t' read -r branch rest; do
    [[ -n "${branch}" ]] && GITSCAN_OWN_REQUESTS[${branch}]+="${rest}"$'\n'
  done <<< "${GITSCAN_JQ_OUT}"
  return 0
}

# gitscan_pushes_to_origin <repo> <forge> <project>: rc 0 when a push to origin lands in the project the forge
# was asked about. A push URL of its own (remote.origin.pushurl, url.*.pushInsteadOf) sends the delete to
# another repository than the one whose requests were read.
gitscan_pushes_to_origin() {
  local repo="$1" forge="$2" project="$3" fetch_url push_urls url
  fetch_url="$(git -C "${repo}" remote get-url origin 2>/dev/null)" || return 1
  push_urls="$(git -C "${repo}" remote get-url --push --all origin 2>/dev/null)" || return 1
  [[ "${push_urls}" == "${fetch_url}" ]] && return 0
  # Another spelling of the same project (https to fetch, ssh to push) is still that project.
  for url in "${(@f)push_urls}"; do
    [[ "$(gitscan_forge_of "${url}")" == "${forge}"$'\t'"${project}" ]] || return 1
  done
  return 0
}

# gitscan_remote_leftovers <repo> <forge> <project> <default> <open-requests-json>: the server branches
# finished requests left behind, as "<branch>\t<tip>\t<reason>" in GITSCAN_LEFTOVERS; rc 2 (GITSCAN_FORGE_WHY)
# when the forge was not asked. A forge deletes a source branch only for a merge it performs itself with that
# setting on: a setting that was off, a stacked request merged inside another, and every closed request
# leave theirs. Left alone: the default branch (the clone's and the one the forge names), an open request's
# branch, a branch an open request targets (a stacked request's base), a branch whose local copy has moved on
# from the server's tip, and a closed request's branch that is checked out (someone may be reworking it).
# Only in a project this login administers, and only for its own requests: a clone of someone else's project,
# or a colleague's branch, is not this login's to clean. A branch the server still needs stays as well
# (gitscan_branch_pinned), and so does everything when a push to origin goes somewhere else than the project
# asked. The forge is asked nothing when no branch is in question.
# gitchecker reports this list and gitcleaner deletes it, so the two never disagree about it.
gitscan_remote_leftovers() {
  local repo="$1" forge="$2" project="$3" default_branch="$4" open_json="$5"
  local tip ref branch local_tip line wt_dir="" candidate me project_id src tgt filter
  local -i bulk=0
  typeset -ga GITSCAN_LEFTOVERS=()
  typeset -a candidates=() open_srcs=() open_tgts=()
  typeset -A held=()
  gitscan_pushes_to_origin "${repo}" "${forge}" "${project}" || return 0
  if [[ "${forge}" == gitlab ]]; then
    filter='.[] | [(.source_branch // ""), (.target_branch // "")] | @tsv'
  else
    filter='.[] | [(.headRefName // ""), (.baseRefName // "")] | @tsv'
  fi
  if ! gitscan_jq "${open_json}" "${filter}"; then
    GITSCAN_FORGE_WHY="could not parse the open request list for ${project}: ${GITSCAN_JQ_ERR}"
    return 2
  fi
  # Arrays, looked up by exact element: on a one-line string the same lookup is a substring search.
  # Split on every tab: `read` folds an empty field into its neighbour.
  for line in "${(@f)GITSCAN_JQ_OUT}"; do
    src="${line%%$'\t'*}"; tgt="${line#*$'\t'}"
    [[ -n "${src}" ]] && open_srcs+=("${src}")
    [[ -n "${tgt}" && "${line}" == *$'\t'* ]] && open_tgts+=("${tgt}")
  done
  while IFS= read -r line; do
    case "${line}" in
      worktree\ *) wt_dir="${line#worktree }" ;;
      branch\ *)   [[ -d "${wt_dir}" ]] && held[${${line#branch }#refs/heads/}]=1 ;;
    esac
  done < <(git -C "${repo}" worktree list --porcelain 2>/dev/null)
  while IFS=$'\t' read -r tip ref; do
    branch="${ref#refs/remotes/origin/}"
    [[ -z "${branch}" || "${branch}" == HEAD || "${branch}" == "${default_branch}" ]] && continue
    (( ${open_srcs[(Ie)${branch}]} )) && continue
    # An open request merges into it: deleting it takes the base from under that request.
    (( ${open_tgts[(Ie)${branch}]} )) && continue
    if local_tip="$(git -C "${repo}" rev-parse --verify -q "refs/heads/${branch}" 2>/dev/null)"; then
      [[ "${local_tip}" == "${tip}" ]] || continue
    fi
    candidates+=("${tip}"$'\t'"${branch}")
  done < <(git -C "${repo}" for-each-ref --format='%(objectname)%09%(refname)' refs/remotes/origin/ 2>/dev/null)
  (( ${#candidates[@]} == 0 )) && return 0
  gitscan_can_administer "${forge}" "${project}"
  case $? in
    0) ;;
    1) return 0 ;;
    *) return 2 ;;
  esac
  project_id="${GITSCAN_PROJECT_ID}"
  gitscan_forge_user "${forge}" || return 2
  me="${GITSCAN_FORGE_USER}"
  if [[ "${forge}" == github ]]; then
    gitscan_own_requests "${project}"
    case $? in
      0) bulk=1 ;;
      1) ;;
      *) return 2 ;;
    esac
  fi
  for candidate in "${candidates[@]}"; do
    tip="${candidate%%$'\t'*}"; branch="${candidate#*$'\t'}"
    # The clone's origin/HEAD can be older than a default branch the project switched to.
    [[ "${branch}" == "${GITSCAN_PROJECT_DEFAULT}" ]] && continue
    if (( bulk )); then
      gitscan_request_verdict "${GITSCAN_OWN_REQUESTS[${branch}]-}" "${tip}" "${me}"
    else
      gitscan_request_end "${forge}" "${project}" "${branch}" "${tip}" || return 2
    fi
    [[ -z "${GITSCAN_REQUEST_END}" ]] && continue
    [[ "${GITSCAN_REQUEST_END}" == closed ]] && (( ${+held[${branch}]} )) && continue
    # Asked last, and only about a branch every other condition would delete.
    gitscan_branch_pinned "${forge}" "${project}" "${project_id}" "${branch}"
    case $? in
      0) continue ;;
      1) ;;
      *) return 2 ;;
    esac
    GITSCAN_LEFTOVERS+=("${branch}"$'\t'"${tip}"$'\t'"MR ${GITSCAN_REQUEST_END}, branch left on the server")
  done
  return 0
}

# gitscan_jq <json> <filter> [jq options] — parsed values into GITSCAN_JQ_OUT, rc 1 with the error
# in GITSCAN_JQ_ERR. Never swallow it: an unparsable body yields an empty list, which
# reads exactly like a legitimate "no open MRs". An empty body is that answer, rc 0.
gitscan_jq() {
  local body="$1" filter="$2"
  shift 2
  typeset -g GITSCAN_JQ_OUT="" GITSCAN_JQ_ERR=""
  [[ -z "${body//[[:space:]]/}" ]] && return 0
  if ! GITSCAN_JQ_OUT="$(print -r -- "${body}" | jq -r "$@" "${filter}" 2>&1)"; then
    GITSCAN_JQ_ERR="${GITSCAN_JQ_OUT}"
    GITSCAN_JQ_OUT=""
    return 1
  fi
  return 0
}

# Only strictly behind fast-forwards. Without `+`, `git fetch . <up>:<branch>` refuses a non-fast-forward,
# so git enforces it. GITSCAN_FF_OUT carries git's message for the caller's report.
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
