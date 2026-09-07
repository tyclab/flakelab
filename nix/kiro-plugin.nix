# Where the kiroPluginRepo checkout lives, derived once for nix/home/default.nix and
# nix/scripts.nix so a doctor cannot diagnose a path no activation writes.
{ lib, cfg }:
let
  repo = if cfg.kiroPluginRepo == null then "" else cfg.kiroPluginRepo;
  afterHost =
    if lib.hasPrefix "http" repo then
      lib.last (lib.splitString "gitlab.com/" repo)
    else
      lib.last (lib.splitString ":" repo);
in
rec {
  # `group/sub/repo`, no `.git`; empty when plugins are disabled.
  path = if repo == "" then "" else lib.removeSuffix ".git" afterHost;
  dir = if path == "" then "" else "/home/${cfg.username}/git/${path}";
  dirOrNull = if dir == "" then null else dir;
}
