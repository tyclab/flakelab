# WSL target layer: the NixOS-WSL settings and the hazards that come with them.
# mkSystem selects this file together with nixos-wsl.nixosModules.default when
# `target = "wsl"` (flake.nix `targetModules`); everything portable lives in
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

  # WSL interop (known-issues.md): terminating ANY systemd distro wipes
  # the kernel-global WSLInterop binfmt handler for EVERY distro. There is NO
  # safe in-distro heal (manual re-register breaks the next systemd boot, and
  # only a VM restart rescues an already-running sibling): recovery is
  # `wsl --shutdown` from Windows, by the user. The Ansible predecessor
  # prevents the wipe by baking systemd=false into its cached image — NixOS
  # requires systemd, so this path instead avoids lifecycle ops where possible
  # (`flakelab build-distro` never terminates) and warns loudly where not
  # (`flakelab test-provision`).

  # WSL keeps its ext4 in a VHDX that grows on demand and never shrinks on its
  # own, which is what makes the nix.gc / nix.optimise timers in
  # nix/configuration.nix load-bearing here: uncollected store garbage is
  # permanent Windows-side disk.

  # stateVersion records the release whose stateful defaults this system adopted;
  # it stays put when the nixpkgs channel moves, or those defaults change under it.
  system.stateVersion = "25.11";
}
