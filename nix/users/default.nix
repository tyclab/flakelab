# Neutral placeholders, git-tracked because flakes evaluate tracked files only; never secrets.
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
