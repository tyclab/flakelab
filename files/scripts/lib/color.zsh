# nix-backup's and nix-doctor's print -P colours, sourced. color_init <fd>... sets them only when every fd
# named is a terminal, NO_COLOR is empty (no-color.org) and TERM is not dumb (unset counts as dumb);
# otherwise they are empty, so a pipe, a file or the backup units' journal gets no escape codes.
color_init() {
  local fd on=true
  [[ -z "${NO_COLOR:-}" && "${TERM:-dumb}" != dumb ]] || on=false
  for fd in "$@"; do
    [[ -t ${fd} ]] || on=false
  done
  if ${on}; then
    typeset -g GREEN="%F{green}" YELLOW="%F{yellow}" RED="%F{red}" CYAN="%F{cyan}" RESET="%f"
  else
    typeset -g GREEN="" YELLOW="" RED="" CYAN="" RESET=""
  fi
}
