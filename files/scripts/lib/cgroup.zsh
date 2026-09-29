# The cgroup walk wsl-init-cgroup and nix-doctor share. Sourced, not executed.

# first_unsearchable <tree> <cgroup>: a user manager reaches its own cgroup
# through every directory above it. Prints the first directory of <cgroup>,
# from the top, that other users may not search (status 0); none, status 1;
# one whose mode cannot be read, printed with status 2.
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
