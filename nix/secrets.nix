# Optional sops-nix: one age-encrypted dotenv decrypted into /run/secrets; the host identity is enrolled by runbook.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.flakelab;
  keyFiles = lib.filterAttrs (_: file: file != null) cfg.sopsKeyFiles;
in
{
  config = lib.mkIf (cfg.sopsSecretsFile != null) {
    sops = {
      defaultSopsFile = cfg.sopsSecretsFile;
      # Not the activation-script variant: a key on its own filesystem decrypts on
      # switch and then fails every boot with `cannot read keyfile`.
      useSystemdActivation = true;
      age = {
        keyFile = cfg.sopsAgeKeyFile;
        generateKey = false;
        # Not from SSH host keys: they sit on the root disk and rotate with a re-image, silently orphaning the file.
        sshKeyPaths = [ ];
      };
      gnupg.sshKeyPaths = [ ];
      secrets.flakelab-env = {
        # Renders the whole decrypted file; there is no per-key lookup on this path.
        format = "dotenv";
        # Explicit, not sops-nix's default: the shell contract depends on it.
        mode = "0400";
        owner = cfg.username;
        restartUnits = lib.optional (keyFiles != { }) "flakelab-sops-key-files.service";
      };
    };

    systemd.services.flakelab-sops-key-files = lib.mkIf (keyFiles != { }) {
      description = "Split the sops key files out of the render";
      wantedBy = [ "multi-user.target" ];
      after = [ "sops-install-secrets.service" ];
      path = [ pkgs.coreutils ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.username;
        UMask = "0077";
      };
      script = ''
        set -a; . <(tr -d '\r' < ${config.sops.secrets.flakelab-env.path}); set +a
      ''
      + lib.concatStrings (
        lib.mapAttrsToList (name: file: ''
          _f=${lib.escapeShellArg "/home/${cfg.username}/${file}"}
          mkdir -p "$(dirname "$_f")"
          if [ -n "''${${name}:-}" ]; then printf '%s\n' "''$${name}" > "$_f.tmp" && mv "$_f.tmp" "$_f"; else rm -f "$_f"; fi
        '') keyFiles
      );
    };

    # Enrolment and rotation tools on the box that uses them.
    environment.systemPackages = [
      pkgs.sops
      pkgs.age
    ];
  };
}
