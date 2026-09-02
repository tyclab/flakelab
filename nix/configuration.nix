# The system layer every target shares. Per-user values are the declared
# `flakelab.*` options (nix/options.nix); mkSystem turns the userData attrset
# into definitions for them, so everything below is a plain config read.
#
# What a single platform needs — the NixOS-WSL settings, a Proxmox guest's
# cloud-init and bootloader, and each one's stateVersion — lives in
# nix/targets/, which mkSystem picks by `target`.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  networking.hostName = lib.mkDefault config.flakelab.hostName;

  # Locale (replaces tasks/locale.yaml), keeping the en_US baseline.
  i18n.defaultLocale = config.flakelab.locale;
  i18n.supportedLocales = [
    "${config.flakelab.locale}/UTF-8"
    "en_US.UTF-8/UTF-8"
  ];

  # Native Docker as a systemd service (replaces docker-ce + the start_docker hack).
  virtualisation.docker.enable = true;
  users.users.${config.flakelab.username} = {
    extraGroups = [ "docker" ];
    # Login shell = zsh (parity with tasks/zsh.yaml `user: shell: /bin/zsh`).
    # Home Manager writes ~/.zshrc but does NOT change the login shell, so
    # without this the distro lands in bash and none of the zsh initContent
    # (prompt, KUBECONFIG merge, env secrets export, backup) runs.
    shell = pkgs.zsh;
  };

  # Make zsh a valid login shell (adds it to /etc/shells + installs it
  # system-wide); the interactive config itself lives in nix/home/zsh.nix.
  programs.zsh.enable = true;

  # Keep large contiguous blocks available. A WSL session's Hyper-V socket
  # opens with a 512 KiB ring buffer (order-7, GFP_KERNEL, vmbus_alloc_ring);
  # on a VM that has run a day under memory pressure the buddy lists hold no
  # such block, the allocation fails and every new session stalls for the 10 s
  # vsock accept timeout (TYCBOOKELITE 2026-09-02: page allocation failures in
  # dmesg, 0.3 s launches right after `echo 1 > /proc/sys/vm/compact_memory`).
  # Proactive compaction lets kcompactd defragment in the background before an
  # allocation has to fail; kernel default 20, range 0-100. Harmless on the
  # Proxmox guest, where virtio has no such need but the cost is nil.
  boot.kernel.sysctl."vm.compaction_proactiveness" = 60;

  # Run foreign (non-NixOS) dynamic binaries — the Kiro CLI install build and
  # any other downloaded tools used while bootstrapping/validating the migration.
  programs.nix-ld.enable = true;

  # System-level CLI utilities (the dev toolchain is per-user, in
  # nix/home/packages.nix).
  environment.systemPackages =
    with pkgs;
    [
      git
      curl
      wget
      jq
      tree
      unzip
      zip
      file
      pwgen
      figlet
      grc
    ]
    # Opens paths/URLs with the Windows default handler (replaces wslu, which
    # 26.05 dropped), so it is WSL-only. Inline rather than a definition in
    # nix/targets/wsl.nix, which would land at that module's position and reorder
    # the whole system path.
    ++ lib.optional (config.flakelab.target == "wsl") pkgs.wsl-open
    ++ (with pkgs; [
      dnsutils
      gnumake
      gcc
    ]);

  # Enable flakes + the new nix CLI (needed for `nix flake check` / `nix build`).
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  nixpkgs.config.allowUnfree = true;

  # Store garbage is disk nothing reclaims on its own. Neither of these runs on
  # a rebuild; they are timers.
  #
  # 30 days rather than a generation count: the rollback this repo actually
  # relies on is `flakelab backup`'s payload snapshots, not old system generations,
  # and a month still leaves several boots' worth to roll back to.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  # Hardlinks identical store files. Cheap, and it compounds with the above on a
  # disk that only ever grows.
  nix.optimise = {
    automatic = true;
    dates = [ "weekly" ];
  };
}
