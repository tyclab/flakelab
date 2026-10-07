{ lib, sshKeys }:
''
  _cloneKey=""
  for _k in ${lib.concatMapStringsSep " " lib.escapeShellArg sshKeys}; do
    if [ -f "$HOME/.ssh/$_k" ]; then _cloneKey="$HOME/.ssh/$_k"; break; fi
  done
''
