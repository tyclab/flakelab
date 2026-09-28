# WSL target layer: the NixOS-WSL settings; everything portable lives in
# nix/configuration.nix.
{ config, pkgs, ... }:
let
  scripts = import ../scripts.nix {
    inherit pkgs;
    cfg = config.flakelab;
  };
in
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

  # The NixOS-WSL init shim runs the activation before it execs systemd, so this is
  # the last point at which the cgroup systemd roots its tree in can still be chosen.
  # A distro started inside a cgroup its users cannot enter would get no user
  # manager at all (files/scripts/wsl-init-cgroup, known-issues.md). A switch runs
  # it too, and it leaves at once there.
  system.activationScripts.flakelab-wsl-init-cgroup.text = "${scripts.wsl-init-cgroup}/bin/flakelab-wsl-init-cgroup";

  # Do not terminate a distro from in here: it wipes WSLInterop for every distro
  # and only `wsl --shutdown` from Windows recovers it (known-issues.md).

  # Pinned to the release whose stateful defaults this system adopted.
  system.stateVersion = "25.11";
}
