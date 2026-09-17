# The system layer every target shares; what a single platform needs lives in
# nix/targets/, which mkSystem picks by `target`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  scripts = import ./scripts.nix {
    inherit pkgs;
    cfg = config.flakelab;
  };
in
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
    # key with it before the provisioner's second switch, the clone sweep, or the
    # backup timer can use it. Lingering keeps user@<uid> up.
    linger = true;
  };

  # The activation's own result, because nothing else keeps it: switch-to-configuration
  # reports a failed activation script as 2 but lets a unit failing after it
  # overwrite that with 4, and stage 2 and the NixOS-WSL init shim ignore the status
  # of the activation they run at boot. Ordered after every other snippet so
  # `$_status` - which the activation's ERR trap sets and `exit`s with - is final;
  # the init's start time tells this boot's record from one left in /run by an
  # earlier boot of a distro. flakelab-switch-result reads it. Written inside an
  # `if`, so a failure to record cannot itself fail the activation.
  system.activationScripts.flakelab-activation-result =
    lib.stringAfter
      (builtins.attrNames (
        removeAttrs config.system.activationScripts [
          "script"
          "flakelab-activation-result"
        ]
      ))
      ''
        _flakelab_status="$_status"
        if ! {
          _flakelab_init="$(< /proc/1/stat)" &&
            read -r -a _flakelab_init <<< "''${_flakelab_init##*) }" &&
            mkdir -p /run/flakelab &&
            printf 'status=%s\nsystem=%s\ninit=%s\n' "$_flakelab_status" "$(readlink -f "$systemConfig")" "''${_flakelab_init[19]}" \
              > /run/flakelab/activation.new &&
            mv -f /run/flakelab/activation.new /run/flakelab/activation
        }; then
          echo "flakelab: could not record this activation's result in /run/flakelab/activation" >&2
        fi
        unset _flakelab_status _flakelab_init
      '';

  # Makes zsh a valid login shell; the interactive config is in nix/home/zsh.nix.
  programs.zsh.enable = true;

  # Keeps large contiguous blocks available: without it a fragmented VM cannot
  # allocate a WSL session's ring buffer and every new session stalls on the
  # vsock accept timeout.
  boot.kernel.sysctl."vm.compaction_proactiveness" = 60;

  # Runs foreign dynamically linked binaries, such as the installed Claude Code.
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
    # system path. hiPrio, so an xdg-utils some later package drags in cannot
    # shadow the one opener that reaches Windows.
    ++ lib.optional (config.flakelab.target == "wsl") (lib.hiPrio scripts.xdg-open)
    ++ (with pkgs; [
      dnsutils
      gnumake
      gcc
    ])
    ++ [ scripts.switch-result ];

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
  nix.optimise = {
    automatic = true;
    dates = [ "weekly" ];
  };
}
