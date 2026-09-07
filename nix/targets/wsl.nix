# WSL target layer: the NixOS-WSL settings; everything portable lives in
# nix/configuration.nix.
{ config, ... }:
{
  wsl = {
    enable = true;
    defaultUser = config.flakelab.username;
    wslConf = {
      automount.options = "metadata";
      interop = {
        enabled = true;
        appendWindowsPath = true;
      };
      network = {
        generateHosts = true;
        generateResolvConf = true;
      };
    };
  };

  # Do not terminate a distro from in here: it wipes WSLInterop for every distro
  # and only `wsl --shutdown` from Windows recovers it (known-issues.md).

  # Pinned to the release whose stateful defaults this system adopted.
  system.stateVersion = "25.11";
}
