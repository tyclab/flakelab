# Example profile: copy it to `profiles/<name>.nix`; the file name is the profile name.
# A key merge.nix does not read aborts evaluation, so a typo cannot drop silently.
{
  gitlabGroups = [ "example-group" ];

  # CLI tools its repos need.
  profileCliTools = [ "ansible" ];

  # Shell aliases and non-secret env vars for its hosts.
  customAliases = { };
  sessionVariables = { };
}
