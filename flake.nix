{
  description = "flakelab — declarative NixOS-WSL developer environment";

  inputs = {
    # Aligned with the NixOS-WSL 2605.x release line, and all three inputs below
    # stay on it. The eval mismatch this comment used to anticipate came from
    # nixos-wsl tracking `main`, which follows nixos-unstable upstream: stable
    # nixpkgs was being fed module code built and tested against unstable. Moving
    # nixos-wsl to its release branch is the fix; moving nixpkgs to unstable was
    # the wrong direction, because it destabilises the other two to accommodate
    # one.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # Whole-package source for tools the stable channel lags on (see
    # unstableOverlay); keeps each package's hashes/build-support self-consistent
    # vs. splicing hashes.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-wsl = {
      # release-26.05, not `main`: upstream's own flake has `main` following
      # nixos-unstable and release-26.05 following nixos-26.05, so this is the
      # branch whose module code is tested against the nixpkgs pinned above.
      # (NixOS-WSL's flake how-to still shows `main`; that is fine for a config
      # tracking unstable, which this one is not.)
      url = "github:nix-community/NixOS-WSL/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Secrets are NOT managed here: tokens come from OpenBao at runtime via the
    # environment (see nix/home). Nothing secret in the repo or store.
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      nixos-wsl,
      home-manager,
      ...
    }:
    let
      system = "x86_64-linux";

      # Plain (un-overlaid) package set — what `formatter` and `checks` resolve
      # against. Deliberately not the overlaid set below: nothing a check runs
      # depends on pre-commit, and pulling the overlaid set in would make every
      # CI pipeline build pre-commit 4.6.2 from source for no gain.
      pkgs = nixpkgs.legacyPackages.${system};

      # Both lag the stable channel behind what this environment needs:
      # bitwarden-cli for a usable CLI, playwright-driver for the version the
      # browser-automation harness expects (see nix/home). Re-check on each
      # channel bump — if stable has caught up, drop the entry rather than carry
      # it.
      #
      # Imported with an explicit config rather than read off `legacyPackages`:
      # that attribute is a separate nixpkgs evaluation with DEFAULT config, so it
      # never sees the `allowUnfree` set in nix/configuration.nix. Both entries
      # here are free-licensed, so nothing breaks today — but the next unfree
      # package added to this overlay would fail with an unfree error pointing at
      # a setting that is already enabled, which is a bad hour for whoever hits
      # it. One eval, shared by both entries, honouring the same config as the
      # rest of the system.
      pkgsUnstable = import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };
      unstableOverlay = _final: _prev: {
        # opentofu: 26.05 ships 1.11.8, and an infra repo whose
        # tofu/providers.tf sets `required_version = ">= 1.12.0"` makes the
        # terraform_validate pre-commit hook (files: ^tofu/) fail on every
        # tofu/ commit made on a flakelab box - locally only, since CI runs its
        # own image. Unstable is on 1.12.5. Taken here rather than pinned by
        # version so it tracks the channel like the other two entries; the
        # requirement is a floor, not an exact pin.
        inherit (pkgsUnstable) bitwarden-cli opentofu playwright-driver;
      };

      # nixpkgs (both the pinned channel above and nixpkgs-unstable — the overlay
      # above cannot supply this one, it is the same 4.5.1 there too) still ships
      # pre-commit 4.5.1, which installs `language: node` hooks (markdownlint-cli2,
      # prettier here) via `npm install --ignore-prepublish`, a flag current npm
      # rejects outright (EUNKNOWNCONFIG) — every node hook is unbuildable upstream
      # of this override. Fixed in pre-commit 4.6.1 (node hooks installed via git
      # instead) and 4.6.2 (a follow-up for npm 11.x). Built on `prev.pre-commit`,
      # not the unstable overlay above, since unstable is on the same 4.5.1 and
      # buys nothing here. Drop this overlay once nixpkgs catches up to >= 4.6.2.
      preCommitOverlay = _final: prev: {
        pre-commit = prev.pre-commit.overridePythonAttrs (_old: {
          version = "4.6.2";
          src = prev.fetchFromGitHub {
            owner = "pre-commit";
            repo = "pre-commit";
            tag = "v4.6.2";
            hash = "sha256-aCEN9dVz/3lB2gy7U+6dVj3jSM7cmVsstOp+LHvYRsU=";
          };
          # The inherited pytestCheckHook suite targets 4.5.1's fixture set;
          # re-check on the next nixpkgs bump rather than chasing every failure
          # from a fixture mismatch this override introduces. Both flags are
          # load-bearing, for different reasons: pytest-check-hook's own
          # setup-hook gates solely on `dontUsePytestCheck` (not doCheck), so
          # without it the check phase still runs and fails looking for `git`;
          # `doCheck = false` is what drops nativeCheckInputs (dotnet-sdk,
          # coursier, gtk3, …) from the build closure in the first place.
          doCheck = false;
          dontUsePytestCheck = true;
        });
      };

      # The overlaid set, same two overlays the system gets (see mkSystem). Only
      # devShells uses it, and only preCommitOverlay is load-bearing there: a
      # `nix develop` shell must hand out the SAME pre-commit 4.6.2 the distro
      # runs, or the shell reproduces the EUNKNOWNCONFIG node-hook failure the
      # overlay exists to fix.
      pkgsDev = pkgs.extend (nixpkgs.lib.composeExtensions unstableOverlay preCommitOverlay);

      # One flake check per offline suite. `nix flake check` builds these, so CI
      # runs the suites; `make test` runs the same scripts directly against the
      # working tree (see Makefile) and stays the local gate.
      #
      # The suites need a writable HOME (they mktemp fixture repos and shell out
      # to git) and a rewrite the build sandbox forces: every suite is
      # `#!/usr/bin/env zsh` AND writes forge stubs and git hooks carrying that
      # same shebang, while the sandbox has neither /usr/bin/env nor a writable
      # root to create it in. Rewriting the interpreter in a COPY of
      # files/scripts covers the emitted shebangs as well as the suites' own,
      # and leaves the tracked scripts untouched — they run unmodified under
      # `make test`.
      #
      # The WHOLE tree is copied, not just files/scripts: nix-overlay-generate
      # reads `templates/overlay/` and `profiles/` out of the checkout it sits
      # in, and its suite asserts against the tracked template and the tracked
      # user_data.example.yaml on purpose — hand-made copies of either would
      # stop proving anything the moment the real ones changed. A scripts-only
      # copy puts that suite one directory below a repo root that does not
      # exist. Same layout as the working tree, so `make test` and this check
      # run the same code against the same files.
      suiteCheck =
        name:
        pkgs.runCommandLocal "flakelab-check-${name}"
          {
            nativeBuildInputs = with pkgs; [
              zsh
              git
              jq
              # `flock` for nix-backup, `script` for gitcleaner's TTY cases.
              util-linux
            ];
          }
          ''
            export HOME="$TMPDIR/home"
            mkdir -p "$HOME"
            git config --global user.name "flakelab check"
            git config --global user.email "check@example.invalid"
            git config --global init.defaultBranch main

            cp -r ${self} repo
            chmod -R u+w repo
            find repo/files/scripts -type f -exec \
              sed -i 's|#!/usr/bin/env zsh|#!${pkgs.zsh}/bin/zsh|g' {} +

            set -o pipefail
            zsh repo/files/scripts/test-${name} 2>&1 | tee suite.log

            # A suite that cannot find a tool skips the cases needing it and
            # still exits 0 — test-gitcleaner does exactly that for its twelve
            # pty assertions when script(1) is missing. Dropping an entry from
            # nativeBuildInputs above would then turn those into a silent green,
            # so a skip line is a check failure here.
            if grep -q '^  skip (' suite.log; then
              echo "check ${name}: the suite skipped cases — a tool is missing above" >&2
              exit 1
            fi

            touch $out
          '';

      # statix and deadnix as checks rather than `nix shell nixpkgs#...` in CI:
      # the linter version is now pinned by flake.lock, so a rule added upstream
      # lands in a reviewed lock bump instead of turning an unrelated MR red.
      # Run from the source root so statix.toml applies.
      nixLintCheck =
        name: tool: command:
        pkgs.runCommandLocal "flakelab-check-${name}" { nativeBuildInputs = [ tool ]; } ''
          cd ${self}
          ${command}
          touch $out
        '';

      # Resolve the selected profiles (userData.profiles) through profiles/ before
      # the value reaches the modules, so gitlabGroups / profileCliTools /
      # aliases / sessionVariables are the merged effective values.
      resolveUserData = import ./profiles/merge.nix { inherit (nixpkgs) lib; };

      # The declared field names, read out of the facade itself (nix/options.nix
      # is a plain module whose only output is `options.flakelab`, so importing it
      # here costs nothing and cannot drift from what the modules declare). Two
      # things below are built from this list: which userData keys become option
      # definitions, and which ones are typos.
      flakelabOptionNames =
        builtins.attrNames
          (import ./nix/options.nix { inherit (nixpkgs) lib; }).options.flakelab;

      # Keys profiles/merge.nix consumes BEFORE the module system exists — it
      # folds them into gitlabGroups / profileCliTools / customAliases /
      # sessionVariables — so they are legitimate in a userData attrset while
      # deliberately not being options.
      preModuleKeys = [
        "profiles"
        "teams"
        "teamCliTools"
      ];

      # The `attrsOf` options, whose userData value is mkDefault'ed PER KEY
      # rather than whole (see the mapping below). Named explicitly rather than
      # detected from the type: claudeAutoMode is `types.attrs`, and per-key
      # wrapping there would put the mkDefault marker attrset INSIDE the value
      # that gets serialised to settings.autoMode.
      perKeyDefaultOptions = [
        "sessionVariables"
        "customAliases"
        "claudeMcpServers"
      ];

      # The platform layer, one module list per target. A NixOS `imports` list
      # cannot be made conditional — the module system reads it before any
      # option has a value — so which platform a system is built for is decided
      # HERE, in the flake's `let`, and nowhere below.
      targetModules = {
        wsl = [
          nixos-wsl.nixosModules.default
          ./nix/targets/wsl.nix
        ];
        proxmox-vm = [ ./nix/targets/proxmox-vm.nix ];
      };

      # The only keys the second call form takes. Anything else is a field that
      # belongs inside `userData`, or a typo.
      callFormKeys = [
        "userData"
        "modules"
        "homeModules"
        "target"
      ];

      # Build a system from a userData attrset. A private overlay flake calls
      # `flakelab.lib.mkSystem { <real values> }` to keep personal data off this
      # (shareable) repo; the default config below uses the tracked placeholders
      # in nix/users/default.nix. See README "Where configuration lives".
      #
      # Two call forms:
      #   mkSystem { <userData fields> }                      — legacy, the whole
      #     argument IS the userData attrset; every existing overlay calls this.
      #   mkSystem { userData = {...}; modules = [...]; homeModules = [...]; }
      #     — the escape hatch: arbitrary NixOS modules and home-manager modules
      #     from the overlay, so nothing an overlay needs beyond userData's
      #     fields ever requires forking this repo.
      # The discriminator is the presence of a `userData` key: no userData
      # schema field has ever been called `userData`, so a legacy attrset can
      # never carry it. This line is what keeps the old form working — do not
      # add a userData field of that name.
      #
      # `target` rides on the OUTSIDE of both forms — `mkSystem { target = "…";
      # userData = {...}; }`, or as a top-level key of a legacy attrset —
      # because targetModules above is read before the option facade exists. It
      # is stripped from a legacy attrset for the same reason: the facade would
      # otherwise turn it into a second definition of a read-only option.
      #
      # Either way the fields are the DECLARED options in nix/options.nix: the
      # attrset is turned into option definitions below, so a wrong type or an
      # undeclared name aborts evaluation instead of quietly doing nothing.
      mkSystem =
        args:
        let
          newForm = args ? userData;
          target = args.target or "wsl";
          rawUserData = if newForm then args.userData else removeAttrs args [ "target" ];
          # throwIf rather than the attrset's own missing-attribute error, which
          # names neither the value nor the set of answers that would work.
          platformModules =
            nixpkgs.lib.throwIf (!(targetModules ? ${target}))
              "mkSystem: unknown target `${target}`. Known targets: ${nixpkgs.lib.concatStringsSep ", " (builtins.attrNames targetModules)} (see nix/targets/)."
              targetModules.${target};
          extraModules = if newForm then args.modules or [ ] else [ ];
          extraHomeModules = if newForm then args.homeModules or [ ] else [ ];
          userData = resolveUserData rawUserData;

          # The typo class the option facade kills inside `modules` (the module
          # system rejects an undeclared `flakelab.*` itself) reaches the attrset
          # form too: `instalKiro = true` used to evaluate cleanly and do
          # nothing at all, because every read site had an `or` fallback.
          unknownKeys = builtins.filter (
            k: !(builtins.elem k flakelabOptionNames) && !(builtins.elem k preModuleKeys)
          ) (builtins.attrNames userData);

          # `modules` / `homeModules` in a LEGACY attrset is not a typo — it is
          # the second call form written without its `userData = ` wrapper, and
          # sending that reader to nix/options.nix to look for a `modules` field
          # is the wrong direction entirely.
          looksLikeNewForm = builtins.any (k: k == "modules" || k == "homeModules") unknownKeys;
          unknownKeysMessage =
            "mkSystem: unknown userData key(s): ${nixpkgs.lib.concatStringsSep ", " unknownKeys}. "
            + (
              if looksLikeNewForm then
                "`modules` and `homeModules` are not userData fields — they belong to the second call form: mkSystem { userData = { <fields> }; modules = [ ... ]; homeModules = [ ... ]; }."
              else
                "Every field is a declared option — see nix/options.nix for the names, types and what each one does."
            );

          # The mirror of the above for the second call form: a misspelt
          # `homeModule` (or a field left outside the `userData` wrapper) would
          # otherwise be dropped in silence by the `args.modules or [ ]` reads.
          unknownArgKeys =
            if newForm then
              builtins.filter (k: !(builtins.elem k callFormKeys)) (builtins.attrNames args)
            else
              [ ];
        in
        nixpkgs.lib.throwIf (unknownArgKeys != [ ])
          "mkSystem: unknown argument(s) to the { target, userData, modules, homeModules } call form: ${nixpkgs.lib.concatStringsSep ", " unknownArgKeys}. Those four are the only keys it takes; every per-user field goes INSIDE userData (schema: nix/options.nix)."
          (
            nixpkgs.lib.throwIf (unknownKeys != [ ]) unknownKeysMessage (
              nixpkgs.lib.nixosSystem {
                inherit system;
                modules =
                  platformModules
                  ++ [
                    home-manager.nixosModules.home-manager
                    ./nix/options.nix
                    {
                      # Names the source of these definitions, so a type error reads
                      # "In `flakelab mkSystem userData attrset'" instead of blaming the
                      # flake's own store path, which tells nobody which file to edit.
                      _file = "flakelab mkSystem userData attrset (schema: nix/options.nix)";

                      # userData reaches the modules as option DEFINITIONS rather than as
                      # an argument: nix/options.nix declares every field, so the module
                      # system type-checks each value and rejects a name nothing declares.
                      # mkDefault, because the escape hatch has to be able to win — an
                      # overlay passing `modules = [ { flakelab.installKiro = false; } ]`
                      # sets it at normal priority and outranks the attrset.
                      #
                      # For the three attrsOf options (perKeyDefaultOptions above) the
                      # mkDefault goes on each KEY instead of the whole set, so a module
                      # adding `flakelab.sessionVariables.FOO` gets userData's entries PLUS
                      # FOO rather than silently wiping the rest — priority filtering runs
                      # over an option's whole definition list before the type merges it,
                      # so a whole-value mkDefault would have been dropped entire.
                      # The tradeoff, deliberate: their container definition now sits at
                      # NORMAL priority, so replacing such a set wholesale from a module
                      # needs `mkForce`, and a module that mkDefault's the whole set loses
                      # to userData. Adding and overriding individual keys, which is what
                      # overlays actually do, both work.
                      # Lists (gitlabGroups, claudePlugins, …) stay whole-value: a module
                      # definition REPLACES them.
                      flakelab = nixpkgs.lib.mapAttrs (
                        n: v:
                        if builtins.elem n perKeyDefaultOptions then
                          nixpkgs.lib.mapAttrs (_: nixpkgs.lib.mkDefault) v
                        else
                          nixpkgs.lib.mkDefault v
                      ) (nixpkgs.lib.filterAttrs (n: _: builtins.elem n flakelabOptionNames) userData);
                    }
                    {
                      # The only definition this read-only option ever gets: the
                      # modules above were already chosen from it, so anything
                      # able to override it here would describe a system nobody
                      # built.
                      flakelab.target = target;
                    }
                    {
                      nixpkgs.overlays = [
                        unstableOverlay
                        preCommitOverlay
                      ];
                    }
                    {
                      home-manager = {
                        useGlobalPkgs = true;
                        useUserPackages = true;
                        # Home Manager aborts activation outright when a generated file
                        # would clobber an existing unmanaged one ("Keeping your ~ safe
                        # from harm" in its manual) — and it does so BEFORE any activation
                        # entry runs, so nothing is logged and the health check never gets
                        # a chance to explain it. This flake owns ~/.npmrc (nix/home/packages.nix
                        # sets npm's prefix there), a path many homes already have as a
                        # plain file, so without this a migrated home fails its next
                        # rebuild on a bare collision error. Move the stranger aside
                        # instead of refusing to activate.
                        backupFileExtension = "hm-bak";
                        # The one place the resolved attrset is still read directly.
                        # This is an attribute NAME, and this module is a literal
                        # attrset in the flake's `let` — `config` is not in scope
                        # here to read the option from. (nix/configuration.nix, which
                        # IS a module function, keys `users.users` on
                        # `config.flakelab.username` instead; that is safe because the
                        # flakelab definitions come from the plain attrset above, which
                        # depends on no config.) The home modules read
                        # `osConfig.flakelab.username` like every other field.
                        #
                        # Consequence worth knowing: `flakelab.username` is the ONE
                        # option the modules escape hatch cannot usefully override.
                        # `modules = [ { flakelab.username = "other"; } ]` moves the
                        # NixOS-side reads but not this attribute name, leaving the
                        # home config attached to the old user. Change
                        # `userData.username`, not the option.
                        #
                        # The `or throw` is for message quality only: without it an
                        # omitted username fails as a bare "attribute missing"
                        # against a store path, before the option system ever gets to
                        # say which field is required.
                        users.${
                          userData.username or (throw "mkSystem: userData.username is required — see nix/options.nix")
                        } =
                          {
                            imports = [ ./nix/home ] ++ extraHomeModules;
                          };
                      };
                    }
                    ./nix/configuration.nix
                  ]
                  ++ extraModules;
              }
            )
          );
    in
    {
      # Reusable builder for private overlay flakes (see nix/users/default.nix).
      lib.mkSystem = mkSystem;

      nixosConfigurations.default = mkSystem (import ./nix/users);

      # The same placeholders on the other target, so `nix flake check` has a
      # second system to instantiate and an adopter has a shape to copy. Both
      # dropped fields are Windows-side: a PVE guest has no C:\Users folder, and
      # the placeholder repoPath names a mount that does not exist there.
      nixosConfigurations.proxmox-vm = mkSystem {
        target = "proxmox-vm";
        userData = removeAttrs (import ./nix/users) [ "windowsUsername" ] // {
          repoPath = "/home/youruser/git/flakelab-config";
        };
      };

      # `nix fmt` — pinned by flake.lock, so CI and the distro format identically.
      # nixfmt-tree, not nixfmt-rfc-style: nixfmt deprecated being handed a
      # directory, and this treefmt wrapper is what it points at instead.
      formatter.${system} = pkgs.nixfmt-tree;

      # `nix flake check` — the six offline suites, the two nix linters, and two
      # eval-time assertions. `targets` INSTANTIATES both systems (it forces
      # their toplevel drvPath) and builds neither, so the set still finishes
      # without realising a single system output.
      checks.${system} = {
        gitchecker = suiteCheck "gitchecker";
        gitcleaner = suiteCheck "gitcleaner";
        gitpublisher = suiteCheck "gitpublisher";
        nix-backup = suiteCheck "nix-backup";
        nix-overlay-generate = suiteCheck "nix-overlay-generate";
        flakelab-cli = suiteCheck "flakelab-cli";
        statix = nixLintCheck "statix" pkgs.statix "statix check .";
        deadnix = nixLintCheck "deadnix" pkgs.deadnix "deadnix --fail .";

        # An entry of `profiles` may be a profile ATTRSET instead of a registry
        # name — how a private overlay keeps its real profiles in its own
        # checkout. Nothing else in this repo takes that branch, and the offline
        # suites structurally cannot: suiteCheck gives them no `nix`. So it is
        # asserted here, at eval time, where a regression reddens even a
        # `nix flake check --no-build`.
        profiles-merge =
          let
            merged = resolveUserData {
              profiles = [
                "example"
                {
                  gitlabGroups = [ "inline-group" ];
                  profileCliTools = [ "inline-tool" ];
                }
              ];
            };
          in
          assert
            merged.gitlabGroups == [
              "example-group"
              "inline-group"
            ];
          assert
            merged.profileCliTools == [
              "ansible"
              "inline-tool"
            ];
          pkgs.runCommandLocal "flakelab-check-profiles-merge" { } "touch $out";

        # The target seam. Every module picked its platform from
        # `flakelab.target`, so the two systems must differ in exactly the ways
        # nix/targets/ says they do — and both must still evaluate. Same
        # eval-time shape as profiles-merge above.
        targets =
          let
            wsl = self.nixosConfigurations.default.config;
            vm = self.nixosConfigurations.proxmox-vm.config;
            hasPkg = cfg: name: builtins.any (p: (p.pname or "") == name) cfg.environment.systemPackages;
          in
          assert wsl.flakelab.target == "wsl";
          assert wsl.wsl.enable;
          assert hasPkg wsl "wsl-open";
          assert vm.flakelab.target == "proxmox-vm";
          assert !(vm ? wsl);
          assert !(hasPkg vm "wsl-open");
          assert vm.services.cloud-init.enable;
          # default_user has to ARRIVE ALONGSIDE the module's own system_info
          # defaults, not replace them — the whole reason it is an mkDefault.
          assert vm.services.cloud-init.settings.system_info.default_user.name == vm.flakelab.username;
          assert vm.services.cloud-init.settings.system_info.distro == "nixos";
          assert vm.services.qemuGuest.enable;
          assert vm.users.users.${vm.flakelab.username}.isNormalUser;
          assert !vm.services.openssh.settings.PasswordAuthentication;
          # Forcing the drvPath evaluates every module of both systems, their
          # assertions included, and builds neither.
          assert builtins.isString wsl.system.build.toplevel.drvPath;
          assert builtins.isString vm.system.build.toplevel.drvPath;
          pkgs.runCommandLocal "flakelab-check-targets" { } "touch $out";
      };

      # `nix develop` — the tooling this repo's gates need, at the versions
      # flake.lock pins. pre-commit comes from pkgsDev, so it is the 4.6.2 the
      # overlay fixes rather than nixpkgs' broken 4.5.1.
      devShells.${system}.default = pkgsDev.mkShell {
        packages = with pkgsDev; [
          pre-commit
          statix
          deadnix
          shellcheck
          zsh
          jq
          gnumake
        ];
        # To stderr: `nix develop -c <cmd>` is a legitimate way to run one
        # command, and a banner on stdout prefixes whatever that command prints.
        shellHook = ''
          echo "flakelab dev shell — 'make test' (offline suites), 'nix flake check' (suites + nix lint), 'pre-commit run --all-files'" >&2
        '';
      };

      packages.${system} = {
        # Build the importable distro tarball (produces `nixos.wsl` in CWD):
        #   sudo nix run .#wslImage
        wslImage = self.nixosConfigurations.default.config.system.build.tarballBuilder;

        # The history scan CI runs (`nix run .#gitleaks`). Exposed here so it
        # comes from the nixpkgs revision flake.lock pins rather than a moving
        # channel ref: a rule added upstream then arrives with a reviewed lock
        # bump instead of reddening an unrelated pull request.
        inherit (pkgs) gitleaks;
      };

      # `nix flake init -t github:tyclab/flakelab` scaffolds a copy of this repo
      # — the fork-and-edit path. The overlay template below is the recommended
      # one.
      templates.default = {
        path = ./.;
        description = "Declarative NixOS-WSL dev environment — edit nix/users/default.nix";
      };

      # The recommended path (README "Where configuration lives") is a small
      # PRIVATE overlay that calls `flakelab.lib.mkSystem`, so personal values
      # never reach this shared repo:
      #   nix flake new -t github:tyclab/flakelab#overlay flakelab-config
      # The scaffold's flakelab input names this repo. Both generators rewrite
      # that one marked line to a local `path:` instead —
      # `setup-wsl-nix.ps1 init` on Windows, and
      # `files/scripts/nix-overlay-generate` on Linux and macOS, which also
      # fills every value in from a user_data.yaml.
      templates.overlay = {
        path = ./templates/overlay;
        description = "Private flakelab overlay — real values, git-ignored secrets, profiles preselected";
      };
    };
}
