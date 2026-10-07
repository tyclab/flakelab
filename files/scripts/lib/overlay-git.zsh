
typeset -ga OVERLAYGIT_CANDIDATES=() OVERLAYGIT_LEAKS=()
typeset -g OVERLAYGIT_WHY=""

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
    mkdir -p "${_probe}/.git/info" && cp -- "${_tpl}" "${_probe}/.git/info/exclude" \
      || { OVERLAYGIT_WHY="cannot read ${_tpl}"; return 1 }
    _raw="$(print -rN -- "${OVERLAYGIT_CANDIDATES[@]}" \
      | git -C "${_probe}" -c core.quotePath=false check-ignore --no-index --stdin -z 2> "${_probe}/err")" || _rc=$?
    (( _rc <= 1 )) || { OVERLAYGIT_WHY="check-ignore failed: $(< "${_probe}/err")"; return 1 }
    _hits=(${(0)_raw})
    for _p in "${_hits[@]}"; do
      [[ "${_p:t}" == *.env ]] && overlaygit_is_sops_dotenv "${_d}/${_p}" && continue
      OVERLAYGIT_LEAKS+=("${_p}")
    done
    return 0
  } always {
    rm -rf -- "${_probe}"
  }
}

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

# overlaygit_payload_inside <dir> - fills OVERLAYGIT_PAYLOAD_INSIDE with what is
# still under <dir>/files/config from the layout that kept keys, secrets.env, the
# provisioning config and the backup payload INSIDE the overlay. .gitignore never
# protected those from nix: every `nix` command given the overlay as `path:`
# copies the whole directory into the world-readable store. They belong in
# <dir>-payload, and there is no migration - the callers name the one-time move.
typeset -ga OVERLAYGIT_PAYLOAD_INSIDE=()
overlaygit_payload_inside() {
  local _d="$1" _n
  OVERLAYGIT_PAYLOAD_INSIDE=()
  for _n in shared instances snapshots user_data.yaml .backup.lock .last-restore-kept; do
    [[ -e "${_d}/files/config/${_n}" ]] && OVERLAYGIT_PAYLOAD_INSIDE+=("files/config/${_n}")
  done
  (( ${#OVERLAYGIT_PAYLOAD_INSIDE} ))
}

