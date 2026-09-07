# Small tool convergences: the npm pin and the Bitwarden CLI endpoint.
# An activation entry added here must also be named in health.nix's
# flakelabHealthCheck entryAfter list, or that check stops running last.
{
  lib,
  pkgs,
  osConfig,
  flakelab,
  ...
}:
let
  cfg = osConfig.flakelab;
  inherit (flakelab)
    flakelabWarn
    flakelabDefer
    ;

  # The npm nodejs bundles refuses pre-commit's node-hook install with EALLOWGIT,
  # blocking every commit in a repo with a node hook.
  # renovate: datasource=npm depName=npm
  npmVersion = "12.0.2";

  inherit (cfg) bitwardenServer;
in
{
  # The pinned npm lands in ~/.npm-global, whose bin dir .zshenv prepends so it beats
  # the nix profile's in every zsh context, hook installs included.
  home.activation.pinNpm = lib.hm.dag.entryAfter [ "writeBoundary" "flakelabWarnReset" ] ''
    export PATH="${
      lib.makeBinPath [
        pkgs.nodejs_24
        pkgs.coreutils
      ]
    }:$PATH"
    export NPM_CONFIG_PREFIX="$HOME/.npm-global"
    if [ "$("$NPM_CONFIG_PREFIX/bin/npm" --version 2>/dev/null || true)" != "${npmVersion}" ]; then
      $DRY_RUN_CMD npm install -g "npm@${npmVersion}" || \
        ${flakelabDefer} "npm ${npmVersion} pin failed: the npm registry was unreachable (offline?). Until it lands, pre-commit node hooks EALLOWGIT on the bundled npm 11. Retry: flakelab update"
    fi
  '';

  # `bw config server` drops the stored session when the endpoint changes, so only
  # write when the CLI actually points elsewhere. Null skips the activation entirely.
  home.activation.bwConfigServer = lib.hm.dag.entryAfter [ "writeBoundary" "flakelabWarnReset" ] (
    lib.optionalString (bitwardenServer != null) ''
      export PATH="${
        lib.makeBinPath [
          pkgs.bitwarden-cli
          pkgs.coreutils
        ]
      }:$PATH"
      if [ "$(bw config server 2>/dev/null || true)" != "${bitwardenServer}" ]; then
        $DRY_RUN_CMD bw config server "${bitwardenServer}" >/dev/null 2>&1 || \
          ${flakelabWarn} "could not point the Bitwarden CLI at ${bitwardenServer}; bw login will fail against its default endpoint."
      fi
    ''
  );
}
