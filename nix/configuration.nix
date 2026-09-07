# The system layer every target shares; what a single platform needs lives in
# nix/targets/, which mkSystem picks by `target`.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  networking.hostName = lib.mkDefault config.flakelab.hostName;

  # en_US stays available alongside the configured locale.
  i18n.defaultLocale = config.flakelab.locale;
  i18n.supportedLocales = [
    "${config.flakelab.locale}/UTF-8"
    "en_US.UTF-8/UTF-8"
  ];

  virtualisation.docker.enable = true;
  users.users.${config.flakelab.username} = {
    extraGroups = [ "docker" ];
    # Home Manager writes ~/.zshrc but does not change the login shell, so without
    # this the distro lands in bash and no initContent runs.
    shell = pkgs.zsh;
    # Every `wsl.exe -u <user> -- …` is its own logind session, and user@<uid>
    # stops shortly after the last one ends, taking the ssh-agent and its loaded
    # key with it: the provisioner's second switch, the clone sweep and the
    # backup timer all ran into an empty agent. Lingering keeps user@<uid> up.
    linger = true;
  };

  # Makes zsh a valid login shell; the interactive config is in nix/home/zsh.nix.
  programs.zsh.enable = true;

  # Keeps large contiguous blocks available: without it a fragmented VM cannot
  # allocate a WSL session's ring buffer and every new session stalls on the
  # vsock accept timeout.
  boot.kernel.sysctl."vm.compaction_proactiveness" = 60;

  # Runs the foreign dynamic binaries with no nixpkgs path (the Kiro CLI installer).
  programs.nix-ld.enable = true;

  # The dev toolchain is per-user, in nix/home/packages.nix.
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
    # Inline rather than in nix/targets/wsl.nix, which would reorder the whole
    # system path.
    ++ lib.optional (config.flakelab.target == "wsl") pkgs.wsl-open
    ++ (with pkgs; [
      dnsutils
      gnumake
      gcc
    ]);

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  nixpkgs.config.allowUnfree = true;

  # Timers, not rebuild steps. By age, not generation count: the rollback this repo
  # relies on is `flakelab backup`'s payload snapshots.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  # Hardlinks identical store files.
  nix.optimise = {
    automatic = true;
    dates = [ "weekly" ];
  };
}
