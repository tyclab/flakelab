# The clone identity: the first sshKeys entry that exists on disk, resolved when
# the snippet runs. One definition for the activation steps (nix/home/default.nix)
# and the `flakelab clone` wrapper (nix/scripts.nix), so the two cannot pick
# different keys. Gating on the first name alone would park clones on a box that
# carries only a later one. Leaves _cloneKey empty when no configured key exists.
{ lib, sshKeys }:
''
  _cloneKey=""
  for _k in ${lib.concatMapStringsSep " " lib.escapeShellArg sshKeys}; do
    if [ -f "$HOME/.ssh/$_k" ]; then _cloneKey="$HOME/.ssh/$_k"; break; fi
  done
''
