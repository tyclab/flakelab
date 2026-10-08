# Overlay dir -> repository: one commit on main, no remote, autocrlf off. Used by nix-overlay-generate, nix-update and
# nix-doctor; setup-wsl-nix.ps1 has the PowerShell twin (Get-OverlayGitLeaks). A leak is anything the first commit
# would carry that the shipped template ignores; only the sops ciphertext passes, and only when it IS ciphertext.
typeset -ga OVERLAYGIT_CANDIDATES=() OVERLAYGIT_LEAKS=()
typeset -g OVERLAYGIT_WHY=""

# True only when every line is sops dotenv output with MAC and version; a `_unencrypted` key or a non-sops `sops_`
# name fails. A key service sops adds later is a refusal until it is added here.
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

# overlaygit_leaks <dir> <template>: OVERLAYGIT_CANDIDATES (what `git add -A` would stage), OVERLAYGIT_LEAKS (those the
# template ignores). Read-only, via a scratch git dir. Returns 1 with OVERLAYGIT_WHY when git cannot answer.
overlaygit_leaks() {
  local _d="$1" _tpl="$2" _probe _raw _p
  local -i _rc=0
  local -a _hits
  OVERLAYGIT_CANDIDATES=() OVERLAYGIT_LEAKS=() OVERLAYGIT_WHY=""
  _probe="$(mktemp -d)" || { OVERLAYGIT_WHY="mktemp failed"; return 1 }
  {
    git init -q "${_probe}" 2> /dev/null || { OVERLAYGIT_WHY="git init of the scratch repository failed"; return 1 }
    # -C with work tree `.`: ls-files only lists below the cwd. stderr to a file: git warns on a successful
    # listing too, and in NUL-separated data the warning would become part of the first path.
    _raw="$(git -C "${_d}" --git-dir="${_probe}/.git" --work-tree=. -c core.quotePath=false \
      ls-files -o --exclude-standard -z 2> "${_probe}/err")" \
      || { OVERLAYGIT_WHY="listing ${_d} failed: $(< "${_probe}/err")"; return 1 }
    OVERLAYGIT_CANDIDATES=(${(0)_raw})
    (( ${#OVERLAYGIT_CANDIDATES} )) || return 0
    # The template alone decides: as info/exclude with --no-index, the overlay's own .gitignore is not consulted.
    mkdir -p "${_probe}/.git/info" && cp -- "${_tpl}" "${_probe}/.git/info/exclude" \
      || { OVERLAYGIT_WHY="cannot read ${_tpl}"; return 1 }
    _raw="$(print -rN -- "${OVERLAYGIT_CANDIDATES[@]}" \
      | git -C "${_probe}" -c core.quotePath=false check-ignore --no-index --stdin -z 2> "${_probe}/err")" || _rc=$?
    # 1 is check-ignore's "none of them is ignored".
    (( _rc <= 1 )) || { OVERLAYGIT_WHY="check-ignore failed: $(< "${_probe}/err")"; return 1 }
    _hits=(${(0)_raw})
    # Only a dotenv can be the sops exception: a missed payload is thousands of hits on a 9p mount.
    for _p in "${_hits[@]}"; do
      [[ "${_p:t}" == *.env ]] && overlaygit_is_sops_dotenv "${_d}/${_p}" && continue
      OVERLAYGIT_LEAKS+=("${_p}")
    done
    return 0
  } always {
    rm -rf -- "${_probe}"
  }
}

# overlaygit_adopt <dir> <template> <msg>: 0 adopted; 1 git failed (.git removed again); 2 .git exists; 3 no .gitignore;
# 4 no template; 5 leaks in OVERLAYGIT_LEAKS; 6 not a directory. All or nothing; stages only the checked list;
# signing and hooks off so the operator's global git config cannot decide it.
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

# overlaygit_payload_inside <dir>: old-layout payload still under <dir>/files/config. .gitignore never kept it out of
# the world-readable store (`path:` copies the whole dir); it belongs in <dir>-payload, no migration.
typeset -ga OVERLAYGIT_PAYLOAD_INSIDE=()
overlaygit_payload_inside() {
  local _d="$1" _n
  OVERLAYGIT_PAYLOAD_INSIDE=()
  for _n in shared instances snapshots user_data.yaml .backup.lock .last-restore-kept; do
    [[ -e "${_d}/files/config/${_n}" ]] && OVERLAYGIT_PAYLOAD_INSIDE+=("files/config/${_n}")
  done
  (( ${#OVERLAYGIT_PAYLOAD_INSIDE} ))
}

