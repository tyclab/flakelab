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
