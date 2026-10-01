# Neutral per-user placeholders; a private overlay calling `flakelab.lib.mkSystem`
# supplies the real values, and nix/options.nix documents every field.
# Git-tracked because flakes only evaluate tracked files; secrets never live here.
# Only the options with no default are set: everything else - the installs, the
# plugin lists, sessionVariables, the aliases - takes its default from
# nix/options.nix, which is where a reader should look it up.
{
  username = "youruser";
  gitName = "Your Name";
  gitEmail = "you@example.com";
  locale = "en_US.UTF-8";
  windowsUsername = "WindowsUser";
  repoPath = "/mnt/c/Users/WindowsUser/git/flakelab";

  gitEditor = null;

  backupAutostart = false;

  cloneExclude = [ "flakelab" ];
}
