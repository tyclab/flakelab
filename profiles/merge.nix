# Folds userData.profiles into effective gitlabGroups, profileCliTools,
# customAliases and sessionVariables. Wired into flake.nix mkSystem.
#
# `teams` / `teamCliTools` are accepted as aliases so an overlay using the older
# field names evaluates unchanged.
#
# There are deliberately no `install*Mcp` booleans: each MCP server in
# nix/home/mcp.nix is gated on the presence of its non-secret env var, so a flag
# cannot drift from the config it gates.
{ lib }:
userData:
let
  registry = import ./default.nix;
  known = builtins.attrNames registry;
  profiles = userData.profiles or userData.teams or [ ];

  # An entry is either a name from the registry or a profile attrset itself, so a
  # private overlay can keep its real profiles in its own checkout and import
  # them here without adding them to this (shareable) registry.
  selected = map (
    p:
    if builtins.isAttrs p then
      p
    else
      registry.${p}
        or (throw "profiles: unknown profile '${p}' (known: ${lib.concatStringsSep ", " known})")
  ) profiles;

  # Selecting nothing is the silent failure this warns about: the key was renamed
  # `teams` -> `profiles`, so an overlay that sets neither still evaluates and
  # every profile's gitlabGroups and profileCliTools vanish with no output at
  # all - selecting a profile is the only thing that installs them. A warning,
  # not an error - a fork that wants none of them is legitimate.
  warnIfNoProfiles =
    lib.warnIf (profiles == [ ])
      "profiles: none selected, so profiles/ contributes nothing (known: ${lib.concatStringsSep ", " known}). Set `profiles = [ ... ]` in the flake that calls mkSystem.";

  collect = attr: alias: lib.concatMap (p: p.${attr} or p.${alias} or [ ]) selected;

  userCliTools = userData.profileCliTools or userData.teamCliTools or [ ];

  mergedGroups = lib.unique ((userData.gitlabGroups or [ ]) ++ collect "gitlabGroups" "gitlabGroups");
  mergedCliTools = lib.unique (userCliTools ++ collect "profileCliTools" "teamCliTools");

  # User values win on key collision: the overlay is the more specific source.
  mergedAliases = lib.foldl' (acc: p: (p.customAliases or { }) // acc) (userData.customAliases or { }
  ) selected;
  mergedSessionVars = lib.foldl' (
    acc: p: (p.sessionVariables or { }) // acc
  ) (userData.sessionVariables or { }) selected;
in
warnIfNoProfiles (
  userData
  // {
    gitlabGroups = mergedGroups;
    profileCliTools = mergedCliTools;
    customAliases = mergedAliases;
    sessionVariables = mergedSessionVars;
  }
)
