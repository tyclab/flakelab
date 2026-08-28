# Proxmox VM target layer: what a PVE guest needs and a WSL distro does not.
# mkSystem selects this file when `target = "proxmox-vm"` (flake.nix
# `targetModules`); everything portable lives in nix/configuration.nix.
{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}:
let
  cfg = config.flakelab;
in
{
  # virtio_blk / virtio_scsi in the INITRD: without them the root device by
  # label never appears and the guest lands in emergency mode, whichever disk
  # controller PVE was told to give it.
  imports = [ "${modulesPath}/profiles/qemu-guest.nix" ];

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
  # waits forever. `-b` refuses every freeze entry point — `-freeze-list` with an
  # empty list freezes everything too — which drops PVE back to a
  # crash-consistent snapshot; the agent has no option for this, hence the whole
  # ExecStart.
  systemd.services.qemu-guest-agent.serviceConfig.ExecStart =
    lib.mkForce "${config.services.qemuGuest.package}/bin/qemu-ga --statedir /run/qemu-ga -b guest-fsfreeze-freeze,guest-fsfreeze-freeze-list,guest-fsfreeze-thaw,guest-fsfreeze-status";

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

  # Ansible's interpreter at the /run/current-system/sw/bin/python3 the fleet's
  # host_vars pins, and the CLI a wrong boot is read with (`cloud-init status`).
  environment.systemPackages = [
    pkgs.python3
    pkgs.cloud-init
  ];

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

  # The seed: one generic qcow2 an operator imports before any overlay exists.
  # A VARIANT and not a toplevel import — images.nix warns when the toplevel
  # system defines `system.build.image`, because that definition then collides
  # with every variant beside it. `virtualisation.diskSize` stays `auto`, so the
  # image is as small as its closure and boot.growPartition fills whatever disk
  # PVE gives it.
  image.modules.proxmox-vm-seed = {
    imports = [ "${modulesPath}/virtualisation/disk-image.nix" ];
    image.format = "qcow2";
    # No home-manager in the seed. The full closure is 7.9 GiB — past what a
    # release asset can carry — and its activation would run installers against
    # credentials a generic image cannot have. The first `flakelab update` from
    # the overlay is what puts the home back.
    home-manager.users = lib.mkForce { };
    # Parked above the useradd range so the login cloud-init creates from PVE's
    # `user:` gets uid 1000, which the overlay then declares for it.
    users.users.${cfg.username}.uid = lib.mkForce 65000;
  };

  # First boot after something drops /etc/flakelab/bootstrap.env (the fleet's
  # Ansible play, or an operator by hand): clone the private overlay and switch
  # into it. Declared here rather than in the seed variant so a system already
  # built from an overlay carries it too — the marker below, not the image, is
  # what makes it run once.
  systemd.services.flakelab-bootstrap = {
    description = "Clone the flakelab overlay and switch this system into it";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "cloud-final.service"
    ];
    # DefaultDependencies=no is not tidiness: a target waits for everything it
    # Wants unless the wanted unit opts out (systemd.target(5)), and the
    # `nixos-rebuild switch` below starts multi-user.target from inside this
    # unit — so with the default the switch blocks on its own caller forever.
    # The explicit ordering above and below is all this unit ever needed.
    unitConfig = {
      ConditionPathExists = [
        "/etc/flakelab/bootstrap.env"
        "!/var/lib/flakelab/bootstrapped"
      ];
      DefaultDependencies = false;
    };
    conflicts = [ "shutdown.target" ];
    before = [ "shutdown.target" ];
    # `nixos-rebuild switch` runs INSIDE this unit, and switch-to-configuration
    # would otherwise stop the process that called it.
    restartIfChanged = false;
    stopIfChanged = false;
    path = with pkgs; [
      coreutils
      getent
      util-linux
      gitMinimal
      openssh
      nix
      nixos-rebuild
    ];
    environment = {
      HOME = "/root";
      NIX_PATH = lib.concatStringsSep ":" config.nix.nixPath;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      StateDirectory = "flakelab";
      EnvironmentFile = "/etc/flakelab/bootstrap.env";
      # A first switch downloads a whole home-manager closure over whatever
      # link the guest was given.
      TimeoutStartSec = "2h";
    };
    script = ''
      set -euo pipefail

      : "''${OVERLAY_URL:?flakelab-bootstrap: OVERLAY_URL is required in /etc/flakelab/bootstrap.env}"
      OVERLAY_REF="''${OVERLAY_REF:-main}"
      OVERLAY_ATTR="''${OVERLAY_ATTR:-default}"
      BOOTSTRAP_USER="''${BOOTSTRAP_USER:-${cfg.username}}"

      # systemd reads EnvironmentFile= itself, so a leading `~/` reaches this
      # script literally — and the fleet's play writes the paths in that form.
      # The passwd entry, not the `/home/<user>` convention: `root` and any
      # overlay that moves a home would otherwise resolve to a path nobody has.
      BOOTSTRAP_HOME="$(getent passwd "$BOOTSTRAP_USER" | cut -d: -f6 || true)"
      : "''${BOOTSTRAP_HOME:?flakelab-bootstrap: no passwd entry for BOOTSTRAP_USER=$BOOTSTRAP_USER}"

      expand_home() {
        case "$1" in
        "~/"*) printf '%s' "$BOOTSTRAP_HOME/''${1#*/}" ;;
        *) printf '%s' "$1" ;;
        esac
      }

      REPO_PATH="$(expand_home "''${REPO_PATH:-$BOOTSTRAP_HOME/git/flakelab-config}")"
      OVERLAY_SSH_IDENTITY="$(expand_home "''${OVERLAY_SSH_IDENTITY:-$BOOTSTRAP_HOME/.ssh/${builtins.head cfg.sshKeys}}")"
      OVERLAY_KNOWN_HOSTS="$(expand_home "''${OVERLAY_KNOWN_HOSTS:-}")"

      # As the clone identity, not as root: git reads this key as
      # BOOTSTRAP_USER, and a root-owned 0600 copy passes a root probe only to
      # hard-fail later with git's `Permission denied (publickey)`, which names
      # neither the file nor the remedy.
      # 75 (EX_TEMPFAIL) rather than a hard failure: on a fresh guest the key is
      # seeded after the first boot, and this unit is meant to be started again.
      if ! runuser -u "$BOOTSTRAP_USER" -- ${pkgs.coreutils}/bin/test -r "$OVERLAY_SSH_IDENTITY"; then
        echo "waiting for the overlay clone identity at $OVERLAY_SSH_IDENTITY — seed it, then \`systemctl start flakelab-bootstrap\`"
        exit 75
      fi

      if [ -n "$OVERLAY_KNOWN_HOSTS" ]; then
        host_keys="-o UserKnownHostsFile=$OVERLAY_KNOWN_HOSTS -o StrictHostKeyChecking=yes"
      else
        host_keys="-o StrictHostKeyChecking=accept-new"
      fi
      export GIT_SSH_COMMAND="ssh -i $OVERLAY_SSH_IDENTITY -o IdentitiesOnly=yes $host_keys"

      # runuser resets HOME to the target user's; PATH and GIT_SSH_COMMAND are
      # passed explicitly because a PAM session is free to rewrite the first.
      as_user() {
        runuser -u "$BOOTSTRAP_USER" -- ${pkgs.coreutils}/bin/env \
          PATH="$PATH" GIT_SSH_COMMAND="$GIT_SSH_COMMAND" "$@"
      }

      if [ -d "$REPO_PATH/.git" ]; then
        # A moved overlay has to reach the fetch below, or a second run
        # refreshes from the remote the first one recorded and reports success.
        as_user git -C "$REPO_PATH" remote set-url origin "$OVERLAY_URL"
        as_user git -C "$REPO_PATH" fetch origin "$OVERLAY_REF"
        as_user git -C "$REPO_PATH" checkout --force FETCH_HEAD
      else
        as_user mkdir -p "$(dirname "$REPO_PATH")"
        as_user git clone --branch "$OVERLAY_REF" "$OVERLAY_URL" "$REPO_PATH"
      fi

      # The lock stays the user's own file: one written by root makes their next
      # `nix` command in that checkout die on a permission denied.
      as_user nix flake lock "path:$REPO_PATH"

      # switch-to-configuration exits 4 when the generation is installed and
      # activated but something along the way warned — a unit that would not
      # start, or the per-user activation for a user who is logged in while the
      # switch runs, which is exactly the operator seeding the key over SSH and
      # starting this unit. That is a switch that happened, so the marker below
      # has to be written; 2 (the activation script itself failed) and anything
      # else are not, and the next boot runs this again.
      rc=0
      nixos-rebuild switch --flake "path:$REPO_PATH#$OVERLAY_ATTR" || rc=$?
      if [ "$rc" -eq 4 ]; then
        echo "switch activated with warnings (exit 4) — see journalctl -u nixos-rebuild-switch-to-configuration"
      elif [ "$rc" -ne 0 ]; then
        exit "$rc"
      fi

      touch /var/lib/flakelab/bootstrapped
      echo "switched into $OVERLAY_ATTR from $OVERLAY_URL ($OVERLAY_REF)"
    '';
  };

  # stateVersion records the release whose stateful defaults this system adopted;
  # it stays put when the nixpkgs channel moves, or those defaults change under it.
  system.stateVersion = "26.05";
}
