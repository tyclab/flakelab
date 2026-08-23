# NixOS-WSL system layer. Per-user values are the declared `flakelab.*` options
# (nix/options.nix); mkSystem turns the userData attrset into definitions for
# them, so everything below is a plain config read.
{
  config,
  lib,
  pkgs,
  ...
}:
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

  # Run foreign (non-NixOS) dynamic binaries — the Kiro CLI install build and
  # any other downloaded tools used while bootstrapping/validating the migration.
  programs.nix-ld.enable = true;

  # WSL interop (known-issues.md): terminating ANY systemd distro wipes
  # the kernel-global WSLInterop binfmt handler for EVERY distro. There is NO
  # safe in-distro heal (manual re-register breaks the next systemd boot, and
  # only a VM restart rescues an already-running sibling): recovery is
  # `wsl --shutdown` from Windows, by the user. The Ansible predecessor
  # prevents the wipe by baking systemd=false into its cached image — NixOS
  # requires systemd, so this path instead avoids lifecycle ops where possible
  # (`flakelab build-distro` never terminates) and warns loudly where not
  # (`flakelab test-provision`).

  # System-level CLI utilities (the dev toolchain is per-user, in
  # nix/home/packages.nix).
  environment.systemPackages = with pkgs; [
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
    # Opens paths/URLs with the Windows default handler. Replaces wslu, which
    # 26.05 dropped after upstream discontinued and archived it.
    wsl-open
    dnsutils
    gnumake
    gcc
  ];

  # Enable flakes + the new nix CLI (needed for `nix flake check` / `nix build`).
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  nixpkgs.config.allowUnfree = true;

  # WSL keeps its ext4 in a VHDX that grows on demand and never shrinks on its
  # own, so store garbage is not reclaimed disk — it is permanent Windows-side
  # disk. Neither of these runs on a rebuild; they are timers.
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

  # stateVersion records the release whose stateful defaults this system adopted;
  # it stays put when the nixpkgs channel moves, or those defaults change under it.
  system.stateVersion = "25.11";
}
