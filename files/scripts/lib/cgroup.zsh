# The cgroup walk wsl-init-cgroup and nix-doctor share. Sourced, not executed.

first_unsearchable() {
  local dir="$1" part mode
  [[ "$2" == / ]] && return 1
  for part in "${(@s:/:)${2#/}}"; do
    dir+="/${part}"
    mode="$(stat -c %a -- "${dir}" 2> /dev/null)" || { print -r -- "${dir#"$1"}"; return 2 }
    (( 8#${mode} & 1 )) || { print -r -- "${dir#"$1"}"; return 0 }
  done
  return 1
}
