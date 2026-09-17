# The one copy of "this overlay directory becomes a repository": one commit on
# main, no remote, autocrlf off. Sourced, not executed, by nix-overlay-generate,
# nix-update and nix-doctor; setup-wsl-nix.ps1 carries the PowerShell twin
# (Get-OverlayGitLeaks), because it runs where there is no zsh.
#
# The overlay holds the SSH key, secrets.env and the backup payload, and only
# its .gitignore keeps them out of `git add`. Every caller KEEPS a .gitignore
# that is already there, so that file is not evidence of anything: it can predate
# a template entry or never have been the template at all. The measure is the
# template this flakelab ships - whatever the first commit would carry that the
# template ignores is a leak, and the commit does not happen. One thing the
# template ignores is committed on purpose: the sops ciphertext (README,
# "Secrets": `sopsSecretsFile = ./secrets/secrets.env`), re-included by the
# overlay's own `!secrets/secrets.env`. It passes only when it IS ciphertext.
#
# Needs zsh, coreutils and git, nothing else: the generator's wrapper pins no more.

typeset -ga OVERLAYGIT_CANDIDATES=() OVERLAYGIT_LEAKS=()
typeset -g OVERLAYGIT_WHY=""

# overlaygit_is_sops_dotenv <file> - true when every line is what `sops encrypt`
# writes for a dotenv: an encrypted value or comment, an empty value, or sops's
# own metadata, with the MAC and version present. A plaintext value anywhere
# fails, a `_unencrypted` key included: that suffix is sops's contract, and this
# is about what reaches a commit. The metadata keys are the ones sops writes -
# its settings and one `__`-flattened block per key service - not any `sops_`
# name, or `sops_token=<plaintext>` would ride through the one deliberate
# exception. A key service sops grows later is a refusal until it is added here.
overlaygit_is_sops_dotenv() {
  setopt localoptions extendedglob
  local _f="$1" _line _val
  local -i _mac=0 _ver=0
  [[ -f "${_f}" && -r "${_f}" ]] || return 1
  while IFS= read -r _line || [[ -n "${_line}" ]]; do
    _line="${_line%$'\r'}"
    [[ -z "${_line}" ]] && continue
    if [[ "${_line}" == '#'* ]]; then
      [[ "${_line}" == '#ENC['*']' ]] || return 1
      continue
    fi
    [[ "${_line}" == *=* ]] || return 1
    _val="${_line#*=}"
    case "${_line%%=*}" in
      sops_mac) [[ "${_val}" == 'ENC['*']' ]] || return 1; _mac=1 ;;
      sops_version) [[ -n "${_val}" ]] || return 1; _ver=1 ;;
      sops_lastmodified|sops_mac_only_encrypted|sops_shamir_threshold) ;;
      sops_(un|)encrypted_(suffix|regex|comment_regex)) ;;
      sops_(age|pgp|kms|gcp_kms|azure_kv|hc_vault|key_groups)__*) ;;
      *) [[ -z "${_val}" || "${_val}" == 'ENC[AES256_GCM,data:'*',iv:'*',tag:'*',type:'*']' ]] || return 1 ;;
    esac
  done < "${_f}"
  (( _mac && _ver ))
}

# overlaygit_leaks <dir> <template .gitignore> - fills OVERLAYGIT_CANDIDATES with
# what a first `git add -A` in <dir> would stage and OVERLAYGIT_LEAKS with the
# ones the template ignores. Read-only: the listing runs from a scratch git dir
# pointed at <dir> as its work tree, so nothing is staged and no .git appears in
# the overlay before the answer is known. Returns 1, OVERLAYGIT_WHY set, when
# git could not answer - which is a refusal, never an empty list.
overlaygit_leaks() {
  local _d="$1" _tpl="$2" _probe _raw _p
  local -i _rc=0
  local -a _hits
  OVERLAYGIT_CANDIDATES=() OVERLAYGIT_LEAKS=() OVERLAYGIT_WHY=""
  _probe="$(mktemp -d)" || { OVERLAYGIT_WHY="mktemp failed"; return 1 }
  {
    git init -q "${_probe}" 2> /dev/null || { OVERLAYGIT_WHY="git init of the scratch repository failed"; return 1 }
    # -C, with the work tree as `.`: ls-files prints paths relative to the directory
    # git runs in and only below it, so from a caller standing inside the overlay
    # the list shrank to that subtree - named from there, matching nothing later.
    # stderr goes to a file, never into the capture: git warns on a SUCCESSFUL
    # listing too (a directory it cannot open), and folded into NUL-separated
    # data the warning becomes part of the first path.
    _raw="$(git -C "${_d}" --git-dir="${_probe}/.git" --work-tree=. -c core.quotePath=false \
      ls-files -o --exclude-standard -z 2> "${_probe}/err")" \
      || { OVERLAYGIT_WHY="listing ${_d} failed: $(< "${_probe}/err")"; return 1 }
    OVERLAYGIT_CANDIDATES=(${(0)_raw})
    (( ${#OVERLAYGIT_CANDIDATES} )) || return 0
    # The template alone decides here: as the scratch repository's info/exclude,
    # with --no-index, the overlay's own .gitignore is nowhere in the lookup.
    mkdir -p "${_probe}/.git/info" && cp -- "${_tpl}" "${_probe}/.git/info/exclude" \
      || { OVERLAYGIT_WHY="cannot read ${_tpl}"; return 1 }
    _raw="$(print -rN -- "${OVERLAYGIT_CANDIDATES[@]}" \
      | git -C "${_probe}" -c core.quotePath=false check-ignore --no-index --stdin -z 2> "${_probe}/err")" || _rc=$?
    # 1 is check-ignore's "none of them is ignored".
    (( _rc <= 1 )) || { OVERLAYGIT_WHY="check-ignore failed: $(< "${_probe}/err")"; return 1 }
    _hits=(${(0)_raw})
    # Only a dotenv can be the sops exception, so only those are opened: a payload
    # the .gitignore missed is thousands of hits, on a 9p mount, on every update.
    for _p in "${_hits[@]}"; do
      [[ "${_p:t}" == *.env ]] && overlaygit_is_sops_dotenv "${_d}/${_p}" && continue
      OVERLAYGIT_LEAKS+=("${_p}")
    done
    return 0
  } always {
    rm -rf -- "${_probe}"
  }
}

# overlaygit_adopt <dir> <template .gitignore> <commit message>
#   0  a repository now: one commit on main, no remote, autocrlf off
#   1  git failed, OVERLAYGIT_WHY says where; the .git this call made is gone again
#   2  <dir>/.git is already there - not this function's to touch, readable or not
#   3  no <dir>/.gitignore
#   4  no template to measure against
#   5  OVERLAYGIT_LEAKS holds what the first commit would have carried
#   6  <dir> is not a directory - a mount that is not up, not an overlay to adopt
# All or nothing: <dir> ends up with the finished repository or with no .git at
# all, an interrupt included, because a half-made one reads as "a repository with
# uncommitted changes" to every later run and is never adopted again. Only what
# was checked is staged - the list, not `add -A` - so a file that appears between
# the check and the add is not in the commit. Signing and hooks are off: the
# identity is flakelab@localhost, and the operator's global config (gpgsign, a
# hooksPath) must not decide whether an overlay gets its history.
overlaygit_adopt() {
  setopt localoptions localtraps
  local _d="$1" _tpl="$2" _msg="$3" _out
  OVERLAYGIT_LEAKS=() OVERLAYGIT_WHY=""
  [[ -n "${_d}" && -d "${_d}" ]] || return 6
  [[ -e "${_d}/.git" || -L "${_d}/.git" ]] && return 2
  [[ -f "${_d}/.gitignore" ]] || return 3
  [[ -f "${_tpl}" ]] || return 4
  overlaygit_leaks "${_d}" "${_tpl}" || return 1
  (( ${#OVERLAYGIT_LEAKS} )) && return 5
  (( ${#OVERLAYGIT_CANDIDATES} )) || { OVERLAYGIT_WHY="nothing in ${_d} to commit"; return 1 }

  trap 'rm -rf -- "${_d}/.git"; exit 130' INT TERM HUP
  if _out="$(git -C "${_d}" init -q --initial-branch=main 2>&1)" \
    && _out="$(git -C "${_d}" config core.autocrlf false 2>&1)" \
    && _out="$(print -rN -- "${OVERLAYGIT_CANDIDATES[@]}" \
         | git -C "${_d}" --literal-pathspecs add --pathspec-from-file=- --pathspec-file-nul 2>&1)" \
    && _out="$(git -C "${_d}" -c user.name=flakelab -c user.email=flakelab@localhost \
         -c commit.gpgsign=false commit -q --no-verify -m "${_msg}" 2>&1)"; then
    return 0
  fi
  OVERLAYGIT_WHY="${_out}"
  rm -rf -- "${_d}/.git"
  return 1
}
