# Mark a bare command typed at an interactive prompt. A program in a tmux
# window can have a tty too, so the PATH launcher cannot infer this on its own.
[[ -o interactive && -z ${ZSH_EXECUTION_STRING+x} ]] || return 0
autoload -Uz add-zsh-hook

_flakelab_claude_clear() {
  unset FLAKELAB_CLAUDE_PROMPT_PID
}

_flakelab_claude_preexec() {
  _flakelab_claude_clear
  if [[ $1 =~ '^[[:space:]]*claude[[:space:]]*$' ]] &&
     (( ! ${+aliases[claude]} && ! ${+galiases[claude]} && ! ${+functions[claude]} )); then
    # A shell configured for a particular provider or identity keeps it.
    local key
    for key in CLAUDE_CONFIG_DIR CLAUDE_SECURESTORAGE_CONFIG_DIR CLAUDE_CODE_OAUTH_TOKEN \
      CLAUDE_CODE_OAUTH_TOKEN_FILE_DESCRIPTOR CLAUDE_CODE_API_KEY_FILE_DESCRIPTOR \
      ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_CUSTOM_HEADERS ANTHROPIC_BASE_URL \
      CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_FOUNDRY; do
      (( ${+parameters[$key]} )) && return 0
    done
    (( ${#parameters[(I)ANTHROPIC_*_BASE_URL]} )) && return 0
    export FLAKELAB_CLAUDE_PROMPT_PID=$$
  fi
}

add-zsh-hook preexec _flakelab_claude_preexec
add-zsh-hook precmd _flakelab_claude_clear
