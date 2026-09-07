# Folds userData.profiles into effective gitlabGroups, profileCliTools,
# customAliases and sessionVariables; `teams` / `teamCliTools` are older aliases.
{ lib }:
userData:
let
  registry = import ./default.nix;
  known = builtins.attrNames registry;
  profiles = userData.profiles or userData.teams or [ ];

  # An entry is either a registry name or a profile attrset an overlay imports itself.
  selected = map (
    p:
    if builtins.isAttrs p then
      p
    else
      registry.${p}
        or (throw "profiles: unknown profile '${p}' (known: ${lib.concatStringsSep ", " known})")
  ) profiles;

  # Warn, not error: a fork wanting no profiles at all is legitimate.
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
