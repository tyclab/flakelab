# Optional sops-nix wiring: one age-encrypted dotenv file from the overlay,
# decrypted at activation into /run/secrets. Null `sopsSecretsFile` contributes
# nothing. The host age identity is enrolled by runbook, never generated here.
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
  config = lib.mkIf (cfg.sopsSecretsFile != null) {
    sops = {
      defaultSopsFile = cfg.sopsSecretsFile;
      # Not the activation-script variant: a key on its own filesystem decrypts on
      # switch and then fails every boot with `cannot read keyfile`.
      useSystemdActivation = true;
      age = {
        keyFile = cfg.sopsAgeKeyFile;
        generateKey = false;
        # Do not derive from SSH host keys: they sit on the root disk and rotate
        # with a re-image, silently orphaning the file.
        sshKeyPaths = [ ];
      };
      gnupg.sshKeyPaths = [ ];
      secrets.tyc-env = {
        # Renders the whole decrypted file; there is no per-key lookup on this path.
        format = "dotenv";
        # Explicit, not sops-nix's default: the shell contract depends on it.
        mode = "0400";
        owner = cfg.username;
      };
    };

    # Enrolment and rotation tools on the box that uses them.
    environment.systemPackages = [
      pkgs.sops
      pkgs.age
    ];
  };
}
