# Small tool convergences: the npm 12 pin and the Bitwarden CLI endpoint.
#
# Both activation entries here are already named in health.nix's
# flakelabHealthCheck entryAfter list. Any entry added to this module must be
# appended there too (or use `lib.hm.dag.entryBefore [ "flakelabHealthCheck" ]`),
# or the health check stops being the last entry and reports on work that has
# not run yet.
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

  # npm pin (parity with wslkube 9875c2f): Node 24 bundles npm 11.x, which
  # breaks pre-commit's `language: node` hooks — pre-commit installs them via
  # `npm install -g git+file://<cache>` and npm 11 refuses its own install with
  # EALLOWGIT, blocking EVERY commit in repos with a node hook. npm 12 fixes it
  # and supports node ^24.15.0. See wslkube variables.yaml for the full trail.
  # renovate: datasource=npm depName=npm
  npmVersion = "12.0.2";

  # The vault lives in the EU region; the bw CLI defaults to the US endpoint
  # and `bw login` fails against it (parity with wslkube's bitwarden_server).
  inherit (cfg) bitwardenServer;
in
{
  # ── npm 12 pin (npmVersion in the let above) ───────────────────────────────
  # `npm install -g` into the Nix store is read-only, so the pinned npm lands in
  # ~/.npm-global (NPM_CONFIG_PREFIX, sessionVariables) and its bin dir is
  # PREPENDED to PATH in .zshenv (envExtra, zsh.nix) so it beats the bundled npm 11
  # from the nix profile in every zsh context, including pre-commit hook installs.
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

  # ── Bitwarden CLI region (bitwardenServer in the let above) ────────────────
  # `bw config server` drops the stored session when the endpoint changes, so
  # read the current value and only write when the CLI actually points
  # elsewhere. Local config write, no network — a failure is a defect, not a
  # deferral.
  # null (the default) skips the activation entirely rather than asserting an
  # endpoint: rewriting someone's region on every rebuild is only correct for a
  # fleet that declared one.
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
