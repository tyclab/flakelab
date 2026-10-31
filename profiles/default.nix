# The registry: every profiles/<name>.nix is the profile <name>, so a new profile is
# one new file; selecting several yields their union. Not this file, which would list
# itself as a phantom `default` profile, nor merge.nix, a function.
let
  entries = builtins.readDir ./.;
  stem = builtins.match "(.+)\\.nix";
  isProfile =
    n: entries.${n} != "directory" && stem n != null && n != "default.nix" && n != "merge.nix";
in
builtins.listToAttrs (
  map (n: {
    name = builtins.head (stem n);
    value = import (./. + "/${n}");
  }) (builtins.filter isProfile (builtins.attrNames entries))
)
