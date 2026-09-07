# Proxmox VM target layer: what a PVE guest needs and a WSL distro does not;
# everything portable lives in nix/configuration.nix.
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
  # Without both in the initrd the root device by label never appears and the guest
  # lands in emergency mode, whichever controller PVE gave it.
  imports = [ "${modulesPath}/profiles/qemu-guest.nix" ];

  services.cloud-init = {
    enable = true;
    network.enable = true;
    # mkDefault, so this merges with the module's own system_info instead of
    # replacing it. Without default_user the login cloud-init creates has no `wheel`
    # and every `become` on the box fails.
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

  # networkd sorts cloud-init's static unit ahead of the NixOS dhcp fallback, so the
  # address PVE assigned survives the boot.
  networking.useNetworkd = true;

  services.qemuGuest.enable = true;
  # NixOS' root filesystem does not thaw, so a vzdump asking for an fs-freeze waits
  # forever; `-b` refuses every freeze entry point and PVE falls back to a
  # crash-consistent snapshot. Do not use `-freeze-list`: an empty list freezes all.
  systemd.services.qemu-guest-agent.serviceConfig.ExecStart =
    lib.mkForce "${config.services.qemuGuest.package}/bin/qemu-ga --statedir /run/qemu-ga -b guest-fsfreeze-freeze,guest-fsfreeze-freeze-list,guest-fsfreeze-thaw,guest-fsfreeze-status";

  # Keys only; cloud-init seeds the operator key at first boot.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # The uid is pinned because cloud-init reuses the account it finds at 1000 rather
  # than creating a second beside it.
  users.users.${cfg.username} = {
    isNormalUser = true;
    uid = lib.mkDefault 1000;
    extraGroups = [ "wheel" ];
  };

  # `become` and `sudo nixos-rebuild` both run with no one at the keyboard.
  security.sudo.wheelNeedsPassword = lib.mkDefault false;

  # The interpreter the fleet's host_vars pins, and the CLI a bad boot is read with.
  environment.systemPackages = [
    pkgs.python3
    pkgs.cloud-init
  ];

  # By label on a single growing partition, as the seed image is built, so PVE's
  # disk size is what the guest ends up with.
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

  # OVMF, and an image installed offline where there are no EFI variables to write.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = false;
  # The only console is the serial one PVE attaches, with nobody at it.
  boot.kernelParams = [ "console=ttyS0" ];
  boot.loader.timeout = 1;

  time.timeZone = lib.mkDefault "UTC";

  # One generic qcow2 an operator imports before any overlay exists. A variant, not a
  # toplevel import: a toplevel `system.build.image` collides with every variant
  # beside it. diskSize stays `auto`, and boot.growPartition fills PVE's disk.
  image.modules.proxmox-vm-seed = {
    imports = [ "${modulesPath}/virtualisation/disk-image.nix" ];
    image.format = "qcow2";
    # No home-manager in the seed: the closure is past what a release asset can carry,
    # and its activation needs credentials a generic image cannot have.
    home-manager.users = lib.mkForce { };
    # Above the useradd range, so cloud-init's login gets uid 1000.
    users.users.${cfg.username}.uid = lib.mkForce 65000;
  };

  # First boot after something drops /etc/flakelab/bootstrap.env: clone the private
  # overlay and switch into it. The marker below, not the image, makes it run once.
  systemd.services.flakelab-bootstrap = {
    description = "Clone the flakelab overlay and switch this system into it";
    wantedBy = [ "multi-user.target" ];
    wants = [ "network-online.target" ];
    after = [
      "network-online.target"
      "cloud-final.service"
    ];
    # Required: the switch below starts multi-user.target from inside this unit, so
    # with default dependencies it blocks on its own caller forever.
    unitConfig = {
      ConditionPathExists = [
        "/etc/flakelab/bootstrap.env"
        "!/var/lib/flakelab/bootstrapped"
      ];
      DefaultDependencies = false;
    };
    conflicts = [ "shutdown.target" ];
    before = [ "shutdown.target" ];
    # The switch runs inside this unit, which switch-to-configuration would stop.
    restartIfChanged = false;
    stopIfChanged = false;
    path = with pkgs; [
      coreutils
      getent
      util-linux
      gitMinimal
      gnugrep
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
      TimeoutStartSec = "2h";
    };
    script = ''
      set -euo pipefail

      # bootstrap.env wins; a seed built from an overlay that states its own
      # remote (flakelab.overlayUrl) needs no OVERLAY_URL line at all.
      OVERLAY_URL="''${OVERLAY_URL:-${lib.optionalString (cfg.overlayUrl != null) cfg.overlayUrl}}"
      : "''${OVERLAY_URL:?flakelab-bootstrap: OVERLAY_URL is required in /etc/flakelab/bootstrap.env (or flakelab.overlayUrl in the overlay the seed was built from)}"
      OVERLAY_REF="''${OVERLAY_REF:-main}"
      OVERLAY_ATTR="''${OVERLAY_ATTR:-default}"
      BOOTSTRAP_USER="''${BOOTSTRAP_USER:-${cfg.username}}"

      # systemd reads EnvironmentFile= itself, so a leading `~/` arrives literally.
      # The passwd entry, not `/home/<user>`: root and a moved home resolve elsewhere.
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

      # Probed as BOOTSTRAP_USER, not root: a root-owned copy passes only to fail
      # later on `Permission denied (publickey)`, which names neither file nor remedy.
      # EX_TEMPFAIL, because the key is seeded after first boot and this unit reruns.
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

      # PATH and GIT_SSH_COMMAND are passed explicitly: a PAM session may rewrite PATH.
      as_user() {
        runuser -u "$BOOTSTRAP_USER" -- ${pkgs.coreutils}/bin/env \
          PATH="$PATH" GIT_SSH_COMMAND="$GIT_SSH_COMMAND" "$@"
      }

      if [ -d "$REPO_PATH/.git" ]; then
        # A moved overlay must reach the fetch below, or a second run refreshes from
        # the remote the first recorded and reports success.
        as_user git -C "$REPO_PATH" remote set-url origin "$OVERLAY_URL"
        as_user git -C "$REPO_PATH" fetch origin "$OVERLAY_REF"
        as_user git -C "$REPO_PATH" checkout --force FETCH_HEAD
      else
        as_user mkdir -p "$(dirname "$REPO_PATH")"
        as_user git clone --branch "$OVERLAY_REF" "$OVERLAY_URL" "$REPO_PATH"
      fi

      # Day-two `flakelab update` fetches with the user's own known_hosts, so without
      # this it dies on "Host key verification failed" with the deploy key in place.
      if [ -n "$OVERLAY_KNOWN_HOSTS" ]; then
        user_kh="$BOOTSTRAP_HOME/.ssh/known_hosts"
        as_user mkdir -p "$BOOTSTRAP_HOME/.ssh"
        as_user chmod 700 "$BOOTSTRAP_HOME/.ssh"
        as_user touch "$user_kh"
        as_user chmod 600 "$user_kh"
        while IFS= read -r line || [ -n "$line" ]; do
          case "$line" in "" | "#"*) continue ;; esac
          grep -qxF -- "$line" "$user_kh" \
            || printf '%s\n' "$line" | as_user tee -a "$user_kh" > /dev/null
        done < "$OVERLAY_KNOWN_HOSTS"
      fi

      # A root-written lock makes the user's next `nix` command there fail.
      as_user nix flake lock "path:$REPO_PATH"

      # rc 4 is an installed and activated generation that warned along the way, so the
      # marker is written; 2 and anything else are not, and the next boot retries.
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

  # Pinned to the release whose stateful defaults this system adopted.
  system.stateVersion = "26.05";
}
