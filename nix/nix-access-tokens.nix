# Only the include path enters the store; the token is rendered at runtime.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.flakelab;
  scripts = import ./scripts.nix { inherit pkgs cfg; };
in
{
  # A missing token keeps public fetches anonymous.
  nix.extraOptions = ''
    !include ${scripts.nixAccessTokensFile}
  '';

  systemd.services.flakelab-nix-access-tokens = {
    description = "Render GH_TOKEN into the access-tokens file nix.conf includes";
    wantedBy = [ "multi-user.target" ];
    after = lib.optional (cfg.sopsSecretsFile != null) "sops-install-secrets.service";
    unitConfig.RequiresMountsFor = [ config.users.users.${cfg.username}.home ];
    serviceConfig = {
      Type = "oneshot";
      # Source the login's shell file as that user, never as root.
      User = cfg.username;
      UMask = "0077";
      # Other users may traverse the directory but cannot read the mode-600 file.
      RuntimeDirectory = "flakelab-nix";
      RuntimeDirectoryMode = "0755";
      RuntimeDirectoryPreserve = true;
      PrivateTmp = true;
      ExecStart = "${scripts.nix-access-tokens}/bin/flakelab-nix-access-tokens";
    };
  };
}
