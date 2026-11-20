# The text of a captured line outside dim runs (a placeholder or hint is dim; typed text is not).
# Anything that is not a colour or attribute sequence counts as text.
visible() {
  local s="$1" out part params text
  local -a parts ps
  integer dim=0 k
  parts=("${(@ps:\e[:)s}")
  out="${parts[1]}"
  for part in "${(@)parts[2,-1]}"; do
    params="${part%%m*}" text="${part#*m}"
    if [[ "$part" != *m* || "$params" != [0-9\;]# ]]; then out+="?${part}"; continue; fi
    ps=("${(@s:;:)params}"); (( ${#ps} )) || ps=(0)
    for (( k = 1; k <= ${#ps}; k++ )); do
      case "${ps[k]}" in
        (|0|22) dim=0 ;;
        (2) dim=1 ;;
        (38|48|58) if [[ "${ps[k+1]}" == 2 ]]; then (( k += 4 )); elif [[ "${ps[k+1]}" == 5 ]]; then (( k += 2 )); fi ;;
      esac
    done
    (( dim )) || out+="$text"
  done
  # Claude puts a nonbreaking space after its prompt. Match the byte sequence
  # before using zsh's whitespace class, including in a service with LANG=C.
  print -r -- "${out//$'\xc2\xa0'/ }"
}
# Byte sequences, not a character class: the timer's service may run without a UTF-8 locale.
bare() { local t="$1"; t="${t//$'\xc2\xa0'/}"; t="${t//❯/}"; t="${t//[[:space:]]/}"; print -r -- "$t" }

typeset -a screen plain at
typeset -i i
# Captures pane $1; the input box is what sits between the last two rules.
look() {
  screen=("${(@f)$(tmux capture-pane -e -p -t "$1" 2>/dev/null)}")
  plain=("${(@)screen//$'\e'\[[0-9;]#m/}")
  at=()
  for (( i = 1; i <= ${#plain}; i++ )); do
    [[ "${plain[i]}" == [[:space:]]#(─)(#c3,)* ]] && at+=($i)
  done
  (( ${#at} >= 2 ))
}
box() { # the box's text outside dim runs, without prompt and blanks
  local out=""
  for (( i = at[-2] + 1; i < at[-1]; i++ )); do out+="$(visible "${screen[i]}")"; done
  bare "$out"
}
