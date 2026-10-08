# Shared by activation and the `flakelab clone` wrapper so both pick the same key: the first sshKeys entry on disk.
{ lib, sshKeys }:
''
  _cloneKey=""
  for _k in ${lib.concatMapStringsSep " " lib.escapeShellArg sshKeys}; do
    if [ -f "$HOME/.ssh/$_k" ]; then _cloneKey="$HOME/.ssh/$_k"; break; fi
  done
''
