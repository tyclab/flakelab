{
  config,
  lib,
  pkgs,
  ...
}:
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

  # The shim runs this before systemd: known-issues.md, "No user manager".
  system.activationScripts.flakelab-wsl-init-cgroup.text = "${scripts.wsl-init-cgroup}/bin/flakelab-wsl-init-cgroup";

  # WSLg lists what /usr/share/applications holds in the Windows Start menu,
  # under the distro's name. Only Herdr's entry, from its store path:
  # wsl.startMenuLaunchers would list every desktop file of the system, and reads
  # the user's profile through an /etc that activation has not replaced yet.
  system.activationScripts.flakelab-herdr-launcher.text =
    let
      desktop = "/usr/share/applications/herdr-app.desktop";
      icon = "/usr/share/icons/hicolor/scalable/apps/herdr-app.svg";
    in
    if config.flakelab.installHerdrApp then
      ''
        ${pkgs.coreutils}/bin/install -Dm644 ${pkgs.herdr-app}/share/applications/herdr-app.desktop ${desktop}
        ${pkgs.coreutils}/bin/install -Dm644 ${pkgs.herdr-app}/share/icons/hicolor/scalable/apps/herdr-app.svg ${icon}
      ''
    else
      "${pkgs.coreutils}/bin/rm -f ${desktop} ${icon}";

  # Binding X0 itself pins the old socket when weston restarts. WSL already
  # mounts its directory unless a separate /tmp mount hides it.
  systemd.suppressedSystemUnits = lib.optionals (
    !config.boot.tmp.useTmpfs
    && !(config.fileSystems ? "/tmp")
    && !(builtins.any (mount: mount.where == "/tmp") config.systemd.mounts)
  ) [ "tmp-.X11\\x2dunix-X0.mount" ];

  # WSL generates this shutdown guard with ExecStart=/bin/true, which NixOS
  # does not provide. Keep the generated ordering, mount condition and ExecStop
  # (including WSL's chosen automount root); only replace the startup command.
  systemd.services.wsl-mnt-guard = {
    overrideStrategy = "asDropin";
    # Restarting the active guard mid-switch would run its shutdown action and change /mnt/wsl propagation.
    restartIfChanged = false;
    serviceConfig.ExecStart = [
      ""
      "${pkgs.coreutils}/bin/true"
    ];
  };

  # Pinned to the release whose stateful defaults this system adopted.
  system.stateVersion = "25.11";
}
