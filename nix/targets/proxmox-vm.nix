# Proxmox VM target layer: what a PVE guest needs and a WSL distro does not.
# mkSystem selects this file when `target = "proxmox-vm"` (flake.nix
# `targetModules`); everything portable lives in nix/configuration.nix.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.flakelab;
in
{
  # How PVE hands the guest its hostname, network and SSH keys.
  services.cloud-init = {
    enable = true;
    network.enable = true;
    # mkDefault so this merges with the module's own mkDefault system_info
    # (distro, network renderers) instead of replacing it. default_user is not
    # cosmetic: PVE's `user:` overrides the NAME, the groups and shell below
    # carry over, and without them the login cloud-init creates has no `wheel`
    # and every Ansible `become` on the box fails.
    settings.system_info = lib.mkDefault {
      default_user = {
        name = cfg.username;
        groups = [
          "wheel"
          "docker"
        ];
        shell = "${pkgs.zsh}/bin/zsh";
      };
    };
  };

  # PVE's cloud-init writes a static .network unit, which networkd sorts ahead
  # of the `99-…-dhcp` fallback NixOS generates — so the address PVE assigned is
  # the one that survives the boot.
  networking.useNetworkd = true;

  services.qemuGuest.enable = true;
  # NixOS' root filesystem does not thaw, so a vzdump that asks for an fs-freeze
  # waits forever. `-b` refuses the three freeze commands, which drops PVE back
  # to a crash-consistent snapshot; the agent has no option for this, hence the
  # whole ExecStart.
  systemd.services.qemu-guest-agent.serviceConfig.ExecStart =
    lib.mkForce "${config.services.qemuGuest.package}/bin/qemu-ga --statedir /run/qemu-ga -b guest-fsfreeze-freeze,guest-fsfreeze-thaw,guest-fsfreeze-status";

  # Keys only: the guest is reachable from the fleet, and cloud-init seeds the
  # operator key at first boot.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # The docker group and the zsh login shell come from nix/configuration.nix.
  # uid is pinned because cloud-init reuses the account it finds at 1000 rather
  # than creating a second one beside it.
  users.users.${cfg.username} = {
    isNormalUser = true;
    uid = lib.mkDefault 1000;
    extraGroups = [ "wheel" ];
  };

  # What NixOS-WSL sets for its own default user, for the same reason: Ansible
  # `become` and `sudo nixos-rebuild` both run with no one at the keyboard.
  security.sudo.wheelNeedsPassword = lib.mkDefault false;

  # Ansible's interpreter, at the /run/current-system/sw/bin/python3 the fleet's
  # host_vars pins.
  environment.systemPackages = [ pkgs.python3 ];

  # Root by label on a single growing partition, matching what the seed image is
  # built with, so PVE's disk size is what the guest ends up with.
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
  };
  fileSystems."/boot" = {
    device = "/dev/disk/by-label/ESP";
    fsType = "vfat";
  };
  boot.growPartition = true;

  # OVMF firmware, and an image installed offline where there are no EFI
  # variables to write.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;
  # The only console is the serial one PVE attaches, and nobody is at it to
  # choose a generation.
  boot.kernelParams = [ "console=ttyS0" ];
  boot.loader.timeout = 1;

  # The overlay sets its own through mkSystem's `modules`.
  time.timeZone = lib.mkDefault "UTC";

  # stateVersion records the release whose stateful defaults this system adopted;
  # it stays put when the nixpkgs channel moves, or those defaults change under it.
  system.stateVersion = "26.05";
}
