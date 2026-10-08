# Example profile: copy to `profiles/<name>.nix` and add the name to default.nix.
{
  gitlabGroups = [ "example-group" ];

  # CLI tools its repos need.
  profileCliTools = [ "ansible" ];

  # Shell aliases and non-secret env vars for its hosts.
  customAliases = { };
  sessionVariables = { };
}
