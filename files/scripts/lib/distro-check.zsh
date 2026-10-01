# The checks `flakelab build-distro` (build-dev-wsl-nix) and `flakelab
# test-provision` (test-provision-nix) run against a freshly built distro, in
# one place so the two cannot drift. Sourced, not executed. The caller sets
# _WSL_BIN and DISTRO_NAME; _CHECK_USER is the `-u <name>` pair the probes run
# as, empty for the distro's default user.

# print -P prompt-expands the whole string, so a `%` in a path, a branch or a
# URL-encoded hash reads as an escape (`%3D` prints a date), and print without -r
# turns `\t` in a Windows path into a tab. Only the colour is markup here.
_say() { print -rP -- "%F{$1}${2//\%/%%}%f" }

# Interop must be healthy before any lifecycle op (known-issues.md). systemd-binfmt
# names the entry WSLInterop-late (microsoft/WSL#13449), so both spellings count
# here and in the probe inside the distro.
interop_present() { [[ -e /proc/sys/fs/binfmt_misc/WSLInterop || -e /proc/sys/fs/binfmt_misc/WSLInterop-late ]] }

wsl_clean() { ${_WSL_BIN} "$@" | tr -d '\0\r'; }
_win() { local p="$1"; [[ "$p" == /mnt/[a-z]/* ]] && p="${(U)p[6]}:${p#/mnt/?}"; print -r -- "${p//\//\\}"; }

typeset -gi _pass=0 _fail=0
typeset -ga _CHECK_USER=()
_probe() { ${_WSL_BIN} -d "${DISTRO_NAME}" "${_CHECK_USER[@]}" -- "$@" 2>&1 }
_passed() { print -rP -- "  %F{green}[PASS]%f ${1//\%/%%}"; (( ++_pass )) }
_failed() { print -rP -- "  %F{red}[FAIL]%f ${1//\%/%%}"; (( ++_fail )) }
check() {
  local d="$1"; shift; local o
  if o=$(_probe "$@"); then
    _passed "$d"
  else
    _failed "$d"; [[ -n "$o" ]] && { local -a ol=("${(@f)o}"); print -rl -- "${(@)ol[1,3]/#/         }" }
  fi
}
check_contains() {
  local d="$1" e="$2"; shift 2; local o
  if o=$(_probe "$@") && [[ "$o" == *"$e"* ]]; then
    _passed "$d"
  else
    _failed "$d (want '${e//\%/%%}', got '${o//\%/%%}')"
  fi
}

# The flakelab CLI itself: nothing else in the lists would notice a router entry
# with no wrapper behind it, since every other probe resolves a command the CLI
# does not own. The expected verbs are read out of the router's own `_order`
# table rather than counted here, so a verb added there cannot leave this stale;
# every target-gated verb is a wsl one, and so is the distro under test.
check_flakelab_cli() {
  local router="$1" o
  local -a want=("${(@f)$(sed -n '/^_order=($/,/^)$/{/^  [a-z-]/p}' "$router" | tr -d ' ' | sort)}")
  check "flakelab on PATH" zsh -lc "command -v flakelab >/dev/null"
  o="$(_probe zsh -lc 'flakelab --help' | tr -d '\0\r' | sed -n 's/^  \([a-z-]*\)  .*/\1/p' | sort)"
  if (( ${#want} > 0 )) && [[ "$o" == "${(F)want}" ]]; then
    _passed "flakelab --help lists the router's ${#want} subcommands"
  else
    _failed "flakelab --help lists the router's subcommands (want '${(j: :)want}', got '${(j: :)${(f)o}}')"
  fi
  check "an unknown subcommand exits 2" zsh -lc "flakelab definitely-not-a-command >/dev/null 2>&1; [ \$? -eq 2 ]"
  check "flakelab update answers" zsh -lc "flakelab update --help >/dev/null 2>&1"
}

# The tally; true when every check passed.
check_summary() {
  local -i total=$(( _pass + _fail ))
  print ""
  if (( _fail == 0 )); then
    _say green "All ${total} checks passed."
  else
    _say red "${_fail}/${total} checks failed."
  fi
  (( _fail == 0 ))
}
