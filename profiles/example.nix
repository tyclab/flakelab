# Example profile: copy to `profiles/<name>.nix` and add the name to default.nix.
# A key merge.nix does not read aborts evaluation, so a typo cannot drop silently.
{
  gitlabGroups = [ "example-group" ];

  # CLI tools its repos need.
  profileCliTools = [ "ansible" ];

  # Shell aliases and non-secret env vars for its hosts.
  customAliases = { };
  sessionVariables = { };
}
