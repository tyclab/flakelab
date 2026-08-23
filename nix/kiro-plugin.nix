# Where the kiroPluginRepo checkout lives, derived ONCE.
#
# Two consumers need it and used to derive it separately: nix/home/default.nix
# (which clones into it and installs ~/.kiro from it) and nix/scripts.nix (which
# exports FLAKELAB_KIRO_PLUGIN_* for `flakelab doctor` to measure against). Two
# copies of one derivation is how a doctor ends up diagnosing a path no
# activation ever writes.
#
# The path follows the GitLab group structure `flakelab clone` and the ansible
# provisioning already use, so nothing clones the same repo to a second place.
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
  # `group/sub/repo`, no `.git`. Empty when plugins are disabled, which is what
  # makes `flakelab doctor` skip its kiro-plugin checks.
  path = if repo == "" then "" else lib.removeSuffix ".git" afterHost;
  # Absolute checkout path, or "" when disabled.
  dir = if path == "" then "" else "/home/${cfg.username}/git/${path}";
  # The same thing as null rather than "", for the consumers that branch on it.
  dirOrNull = if dir == "" then null else dir;
}
