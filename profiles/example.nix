# Example profile: one GitLab group and the CLI tools its repos need. Copy it to
# `profiles/<name>.nix` and add the name to default.nix to add another.
{
  gitlabGroups = [ "example-group" ];

  # These repos are Ansible-driven.
  profileCliTools = [ "ansible" ];

  # Left empty deliberately: alias bodies and host URLs depend on the real hosts,
  # which belong in the private overlay, not a shared profile.
  customAliases = { };
  sessionVariables = { };
}
