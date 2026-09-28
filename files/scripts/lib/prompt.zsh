# lib/prompt.zsh — the questions a person at a terminal answers: pick from a
# list, type a line, say yes or no. Sourced by the menu and by every command
# that asks for an argument it was not given. Pure zsh plus stty: no picker
# binary to pin, and the same `read -k` the confirm prompts always used.
#
# Every prompt is for a terminal only. prompt_tty is the gate a caller asks
# first; without a terminal the caller keeps what it did before (refuse, take
# the default, need the flag), so an agent's shell, a pipe or a --json run
# never meets a prompt and never waits on one. FLAKELAB_NO_PROMPT=1 turns them
# off at a terminal too.
#
# Everything is drawn on stderr and answers land in globals, not on stdout, so
# a caller whose stdout is captured (`eval "$(flakelab accounts env)"`) still
# gets its prompt and its stdout stays data:
#   PROMPT_INDEX  the 1-based index prompt_choose picked
#   PROMPT_TEXT   the line prompt_input read
#   PROMPT_KEY    the key prompt_keys read, lowercased

typeset -g PROMPT_INDEX="" PROMPT_TEXT="" PROMPT_KEY=""
# A key read while telling Esc from an arrow that belongs to the next list:
# Esc pressed twice backs out twice.
typeset -g _PC_PENDING=""

prompt_tty() {
  [[ -t 0 && -t 2 && -z "${FLAKELAB_NO_PROMPT:-}" && "${TERM:-dumb}" != dumb ]]
}

# Colour only on a terminal and without NO_COLOR (no-color.org).
_prompt_style() {
  if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
    _PQ=$'\e[1;36m' _PB=$'\e[1m' _PD=$'\e[2m' _PH=$'\e[1;36m' _PA=$'\e[36m' _PR=$'\e[0m'
  else
    _PQ="" _PB="" _PD="" _PH="" _PA="" _PR=""
  fi
}

# The answered question, left on screen as one line: `? question › answer`.
_prompt_answered() {
  print -u2 -r -- "${_PQ}?${_PR} ${_PB}$1${_PR} ${_PD}›${_PR} ${_PA}$2${_PR}"
}

# prompt_choose's helpers. They read and set its locals (items, shown, query,
# cur, top, height, cols, drawn) through zsh's dynamic scope.
_pc_filter() {
  shown=()
  for (( i = 1; i <= ${#items}; i++ )); do
    [[ -z "$query" || "${(L)items[i]}" == *"${(L)query}"* ]] && shown+=($i)
  done
  cur=1; top=1
}

_pc_draw() {
  local out="" line w=$(( cols - 3 ))
  (( drawn > 1 )) && out+=$'\e['"$(( drawn - 1 ))"'A'
  out+=$'\r\e[J'"${_PQ}?${_PR} ${_PB}${question}${_PR} "
  if [[ -n "$query" ]]; then out+="${query}"; else out+="${_PD}type to filter${_PR}"; fi
  drawn=1
  if (( ${#shown} == 0 )); then
    out+=$'\n'"  ${_PD}no match${_PR}"; (( drawn++ ))
  else
    (( cur < top )) && top=$cur
    (( cur > top + height - 1 )) && top=$(( cur - height + 1 ))
    for (( i = top; i < top + height && i <= ${#shown}; i++ )); do
      line="${items[${shown[i]}]}"
      (( ${#line} > w )) && line="${line[1,w-1]}…"
      if (( i == cur )); then out+=$'\n'"${_PH}❯ ${line}${_PR}"; else out+=$'\n'"  ${line}"; fi
      (( drawn++ ))
    done
  fi
  out+=$'\n'"${_PD}↑↓ move · enter select · esc cancel"
  (( ${#shown} > height )) && out+=" · ${cur}/${#shown}"
  out+="${_PR}"
  (( drawn++ ))
  print -u2 -rn -- "$out"
}

# The rest of an escape sequence: a key that arrives within 50 ms of the Esc.
# zselect, because `read -t` on -u 0 answers at once with a NUL instead of
# waiting out its timeout.
_pc_more() {
  zselect -t 5 -r 0 2>/dev/null && read -rs -k 1 -u 0 "$1"
}

_pc_restore() {
  stty "$_pc_saved" 2>/dev/null
  print -u2 -n -- $'\e[?25h'
}

# prompt_choose <question> <label>... — an arrow-key list. Typing filters it
# (case-insensitive substring), Backspace and Ctrl-U edit the filter, ↑/↓
# move, Enter picks, Esc/Ctrl-C/Ctrl-D cancel. Sets PROMPT_INDEX; returns 1
# on cancel.
prompt_choose() {
  emulate -L zsh
  setopt localtraps
  local question="$1"; shift
  local -a items=("$@") shown=()
  local query="" key c1="" c2 size
  local -i cur=1 top=1 height rows=24 cols=80 drawn=0 i picked=0
  (( ${#items} > 0 )) || return 1
  _prompt_style
  zmodload zsh/zselect 2>/dev/null
  # A terminal that reports no size (0 0, a bare pty) keeps 24x80.
  size="$(stty size 2>/dev/null)" && [[ "$size" == <1->' '<1-> ]] && { rows=${size% *}; cols=${size#* } }
  height=$(( rows - 3 ))
  (( height > 15 )) && height=15
  (( height < 3 )) && height=3

  typeset -g _pc_saved="$(stty -g 2>/dev/null)"
  # Raw enough to see every key, Ctrl-C included, and restored on every way
  # out of this function (localtraps scopes the EXIT trap to it).
  trap _pc_restore EXIT
  trap 'return 130' HUP TERM
  stty -echo -icanon -isig min 1 time 0 2>/dev/null
  print -u2 -n -- $'\e[?25l'

  _pc_filter
  while true; do
    _pc_draw
    if [[ -n "$_PC_PENDING" ]]; then
      key="$_PC_PENDING"; _PC_PENDING=""
    else
      read -rs -k 1 -u 0 key || { picked=-1; break }
    fi
    case "$key" in
      $'\r'|$'\n') (( ${#shown} > 0 )) && { picked=${shown[cur]}; break } ;;
      $'\x03'|$'\x04') picked=-1; break ;;
      $'\e')
        # An arrow is Esc [ x (or Esc O x); Esc alone, or
        # followed by anything else (an Alt chord), cancels. A second Esc is
        # kept for the list that comes next.
        c1=""
        if ! _pc_more c1 || [[ "$c1" != [\[O] ]]; then
          [[ "${c1:-}" == $'\e' ]] && _PC_PENDING="$c1"
          picked=-1; break
        fi
        _pc_more c2 || continue
        case "$c2" in
          A) (( cur > 1 )) && (( cur-- )) ;;
          B) (( cur < ${#shown} )) && (( cur++ )) ;;
        esac
        ;;
      $'\x7f'|$'\b') [[ -n "$query" ]] && { query="${query[1,-2]}"; _pc_filter } ;;
      $'\x15') query=""; _pc_filter ;;
      [[:print:]]) query+="$key"; _pc_filter ;;
    esac
  done

  (( drawn > 1 )) && print -u2 -n -- $'\e['"$(( drawn - 1 ))"'A'
  print -u2 -n -- $'\r\e[J'
  if (( picked > 0 )); then
    PROMPT_INDEX=$picked
    _prompt_answered "$question" "${items[picked]}"
    return 0
  fi
  PROMPT_INDEX=""
  _prompt_answered "$question" "cancelled"
  return 1
}

# prompt_input <question> [default] — one line in the zsh line editor, the
# default already typed: Enter takes it, the usual editing keys work, Tab
# completes file names. A leading ~ is expanded. Sets PROMPT_TEXT; returns 1
# on Ctrl-C or Ctrl-D.
prompt_input() {
  emulate -L zsh
  setopt localtraps
  local question="$1" value="${2:-}"
  _prompt_style
  setopt zle 2>/dev/null
  zmodload zsh/zle 2>/dev/null
  trap 'return 130' INT
  vared -p "${_PQ}?${_PR} ${_PB}${question}${_PR} ${_PD}›${_PR} " value 2>/dev/null || { print -u2 -- ""; PROMPT_TEXT=""; return 1 }
  [[ "$value" == "~" || "$value" == "~/"* ]] && value="${HOME}${value#\~}"
  PROMPT_TEXT="$value"
  return 0
}

# prompt_keys <question> <choices> — one key, no Enter, the way gitcleaner has
# always asked: choices like "y/N/a/q", the capital one the default that Enter
# or any other key gives. Sets PROMPT_KEY lowercased.
prompt_keys() {
  emulate -L zsh
  local question="$1" choices="$2" key="" def="" c
  _prompt_style
  for c in ${(s:/:)choices}; do [[ "$c" == [[:upper:]] ]] && def="${(L)c}"; done
  print -u2 -rn -- "${_PQ}?${_PR} ${_PB}${question}${_PR} ${_PD}[${choices}]${_PR} "
  read -rs -k 1 -u 0 key || key=""
  key="${(L)key}"
  [[ "/${(L)choices}/" == *"/${key}/"* && -n "$key" ]] || key="$def"
  PROMPT_KEY="$key"
  print -u2 -r -- "${_PA}${key:-${def}}${_PR}"
  return 0
}

# prompt_confirm <question> — yes or no, No the default. 0 for yes.
prompt_confirm() {
  prompt_keys "$1" "y/N"
  [[ "$PROMPT_KEY" == y ]]
}

# prompt_ran <words...> — the command the answers amount to, so the flag form
# is there to copy next time: `→ flakelab sessions --start claude ~/git/x`.
prompt_ran() {
  emulate -L zsh
  _prompt_style
  print -u2 -r -- "${_PD}→ ${(j: :)${(q-)@}}${_PR}"
}
