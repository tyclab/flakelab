# Folds userData.profiles into effective gitlabGroups, profileCliTools,
# customAliases and sessionVariables. `teams` / `teamCliTools` are the pre-rename
# spellings, still read for an overlay that has not moved (CHANGELOG: deprecated);
# new overlays write `profiles` / `profileCliTools`.
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

  # Every key read from a profile below; a downstream that collects more adds it here.
  profileKeys = [
    "gitlabGroups"
    "profileCliTools"
    "teamCliTools"
    "customAliases"
    "sessionVariables"
  ];
  strayKeys = lib.concatLists (
    lib.zipListsWith (
      p: s:
      let
        extra = lib.subtractLists profileKeys (builtins.attrNames s);
      in
      lib.optional (extra != [ ])
        "${if builtins.isAttrs p then "<inline>" else "'${p}'"}: ${lib.concatStringsSep ", " extra}"
    ) profiles selected
  );
  rejectStrayKeys =
    lib.throwIf (strayKeys != [ ])
      "profiles: unknown key(s) in profile ${lib.concatStringsSep "; " strayKeys} (read: ${lib.concatStringsSep ", " profileKeys})";

  userCliTools = userData.profileCliTools or userData.teamCliTools or [ ];

  mergedGroups = lib.unique (
    (userData.gitlabGroups or [ ]) ++ lib.concatMap (p: p.gitlabGroups or [ ]) selected
  );
  mergedCliTools = lib.unique (
    userCliTools ++ lib.concatMap (p: p.profileCliTools or p.teamCliTools or [ ]) selected
  );

  # User values win on key collision: the overlay is the more specific source.
  mergedAliases = lib.foldl' (acc: p: (p.customAliases or { }) // acc) (userData.customAliases or { }
  ) selected;
  mergedSessionVars = lib.foldl' (
    acc: p: (p.sessionVariables or { }) // acc
  ) (userData.sessionVariables or { }) selected;
in
rejectStrayKeys (
  warnIfNoProfiles (
    userData
    // {
      gitlabGroups = mergedGroups;
      profileCliTools = mergedCliTools;
      customAliases = mergedAliases;
      sessionVariables = mergedSessionVars;
    }
  )
)
