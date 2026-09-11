{
  description = "flakelab — declarative NixOS-WSL developer environment";

  inputs = {
    # nixpkgs, nixos-wsl and home-manager must stay on the same release line: a
    # stable nixpkgs fed module code built against unstable is an eval mismatch.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    # Whole-package source for the tools the stable channel lags on.
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-wsl = {
      # Not `main`: upstream's `main` follows nixos-unstable.
      url = "github:nix-community/NixOS-WSL/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    home-manager = {
      url = "github:nix-community/home-manager/release-26.05";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Decrypts the optional overlay-held secrets file; the project tags no releases.
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      nixos-wsl,
      home-manager,
      sops-nix,
      ...
    }:
    let
      system = "x86_64-linux";

      # Un-overlaid on purpose: no check needs pre-commit, and the overlaid set
      # would make every CI pipeline build it from source.
      pkgs = nixpkgs.legacyPackages.${system};

      # Re-check on each channel bump: drop an entry stable has caught up with.
      # Imported with explicit config, not read off `legacyPackages`, which is a
      # separate evaluation that never sees nix/configuration.nix's allowUnfree.
      pkgsUnstable = import nixpkgs-unstable {
        inherit system;
        config.allowUnfree = true;
      };
      unstableOverlay = _final: _prev: {
        # opentofu: stable is below the `required_version` floor the infra repos set.
        # glab: stable predates the `ci status --wait` and `--jq` the agent skills use.
        inherit (pkgsUnstable)
          bitwarden-cli
          glab
          opentofu
          playwright-driver
          ;
      };

      # nixpkgs' pre-commit installs node hooks with a flag current npm rejects
      # (EUNKNOWNCONFIG), so every node hook is unbuildable without this override.
      # Drop it once nixpkgs, unstable included, reaches 4.6.2.
      preCommitOverlay = _final: prev: {
        pre-commit = prev.pre-commit.overridePythonAttrs (_old: {
          version = "4.6.2";
          src = prev.fetchFromGitHub {
            owner = "pre-commit";
            repo = "pre-commit";
            tag = "v4.6.2";
            hash = "sha256-aCEN9dVz/3lB2gy7U+6dVj3jSM7cmVsstOp+LHvYRsU=";
          };
          # The inherited test suite targets the packaged version's fixtures. Both
          # flags are needed: the pytest setup-hook gates only on dontUsePytestCheck,
          # while doCheck drops nativeCheckInputs from the closure.
          doCheck = false;
          dontUsePytestCheck = true;
        });
      };

      # Used only by devShells, which must hand out the same pre-commit the distro runs.
      pkgsDev = pkgs.extend (nixpkgs.lib.composeExtensions unstableOverlay preCommitOverlay);

      # One flake check per offline suite, so CI runs them; `make test` runs the same
      # scripts against the working tree. The shebang rewrite is required because the
      # sandbox has no /usr/bin/env, and the suites emit that shebang themselves.
      # The whole tree is copied, not just files/scripts: nix-overlay-generate reads
      # templates/overlay/ and profiles/ out of the checkout it sits in.
      suiteCheck =
        name:
        pkgs.runCommandLocal "flakelab-check-${name}"
          {
            nativeBuildInputs = with pkgs; [
              zsh
              git
              jq
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

            # A suite missing a tool skips cases and still exits 0, so a dropped
            # nativeBuildInputs entry would be a silent green: skips fail here.
            if grep -q '^  skip (' suite.log; then
              echo "check ${name}: the suite skipped cases — a tool is missing above" >&2
              exit 1
            fi

            touch $out
          '';

      # Checks rather than `nix shell` in CI, so flake.lock pins the linter version and
      # a new upstream rule lands in a reviewed bump. Run from the root for statix.toml.
      nixLintCheck =
        name: tool: command:
        pkgs.runCommandLocal "flakelab-check-${name}" { nativeBuildInputs = [ tool ]; } ''
          cd ${self}
          ${command}
          touch $out
        '';

      # Resolves profiles before the modules see the value, so the merged effective
      # values are what reaches them.
      resolveUserData = import ./profiles/merge.nix { inherit (nixpkgs) lib; };

      # Read out of the facade itself, so it cannot drift from what the modules declare.
      flakelabOptionNames =
        builtins.attrNames
          (import ./nix/options.nix { inherit (nixpkgs) lib; }).options.flakelab;

      # Consumed by profiles/merge.nix before the module system exists, so they are
      # legitimate userData keys and deliberately not options.
      preModuleKeys = [
        "profiles"
        "teams"
        "teamCliTools"
      ];

      # mkDefault'ed per key rather than whole. Listed, not type-detected: per-key
      # wrapping a `types.attrs` option would put the marker inside the serialised value.
      perKeyDefaultOptions = [
        "sessionVariables"
        "customAliases"
        "claudeMcpServers"
      ];

      # An `imports` list cannot be conditional, so the target is decided here in the
      # flake's `let` and nowhere below.
      targetModules = {
        wsl = [
          nixos-wsl.nixosModules.default
          ./nix/targets/wsl.nix
        ];
        proxmox-vm = [ ./nix/targets/proxmox-vm.nix ];
      };

      callFormKeys = [
        "userData"
        "modules"
        "homeModules"
        "target"
      ];

      # Build a system from a userData attrset, whose fields are the options declared
      # in nix/options.nix. Two call forms, discriminated by a `userData` key: the bare
      # attrset, or { target, userData, modules, homeModules }. Do not add a userData
      # field called `userData`: that is what keeps the bare form working.
      # `target` rides outside both forms, because targetModules is read before the
      # option facade exists.
      mkSystem =
        args:
        let
          newForm = args ? userData;
          target = args.target or "wsl";
          rawUserData = if newForm then args.userData else removeAttrs args [ "target" ];
          platformModules =
            nixpkgs.lib.throwIf (!(targetModules ? ${target}))
              "mkSystem: unknown target `${target}`. Known targets: ${nixpkgs.lib.concatStringsSep ", " (builtins.attrNames targetModules)} (see nix/targets/)."
              targetModules.${target};
          extraModules = if newForm then args.modules or [ ] else [ ];
          extraHomeModules = if newForm then args.homeModules or [ ] else [ ];
          userData = resolveUserData rawUserData;

          # The guard the module system already gives `modules`: an undeclared key
          # must abort rather than silently do nothing.
          unknownKeys = builtins.filter (
            k: !(builtins.elem k flakelabOptionNames) && !(builtins.elem k preModuleKeys)
          ) (builtins.attrNames userData);

          # Those two in a bare attrset are the second call form written without its
          # wrapper, not a typo, so they get their own message.
          looksLikeNewForm = builtins.any (k: k == "modules" || k == "homeModules") unknownKeys;
          unknownKeysMessage =
            "mkSystem: unknown userData key(s): ${nixpkgs.lib.concatStringsSep ", " unknownKeys}. "
            + (
              if looksLikeNewForm then
                "`modules` and `homeModules` are not userData fields — they belong to the second call form: mkSystem { userData = { <fields> }; modules = [ ... ]; homeModules = [ ... ]; }."
              else
                "Every field is a declared option — see nix/options.nix for the names, types and what each one does."
            );

          # Without this, a misspelt `homeModule` is dropped in silence by the
          # `args.modules or [ ]` reads.
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
                    # Inert until the overlay sets sopsSecretsFile.
                    sops-nix.nixosModules.sops
                    ./nix/secrets.nix
                    ./nix/options.nix
                    {
                      # So a type error names this attrset, not the flake's store path.
                      _file = "flakelab mkSystem userData attrset (schema: nix/options.nix)";

                      # userData reaches the modules as option definitions, so it is
                      # type-checked. mkDefault, so a module from the escape hatch wins.
                      # For the attrsOf options the mkDefault goes on each key, so a module
                      # adding one key does not wipe the rest; replacing such a set
                      # wholesale from a module therefore needs mkForce.
                      flakelab = nixpkgs.lib.mapAttrs (
                        n: v:
                        if builtins.elem n perKeyDefaultOptions then
                          nixpkgs.lib.mapAttrs (_: nixpkgs.lib.mkDefault) v
                        else
                          nixpkgs.lib.mkDefault v
                      ) (nixpkgs.lib.filterAttrs (n: _: builtins.elem n flakelabOptionNames) userData);
                    }
                    {
                      # The only definition this read-only option ever gets: the modules
                      # were already chosen from it.
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
                        # Without this, a home that already has a plain ~/.npmrc fails its
                        # next rebuild on a bare collision error, before anything is logged.
                        backupFileExtension = "hm-bak";
                        # An attribute name, and `config` is not in scope in this literal
                        # attrset, so the resolved userData is read directly here.
                        # Consequence: `flakelab.username` is the one option the modules
                        # escape hatch cannot usefully override - change userData.username.
                        # The `or throw` is for message quality only.
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
      lib.mkSystem = mkSystem;

      nixosConfigurations.default = mkSystem (import ./nix/users);

      # The same placeholders on the other target, minus the two Windows-side fields
      # a PVE guest has no equivalent for.
      nixosConfigurations.proxmox-vm = mkSystem {
        target = "proxmox-vm";
        userData = removeAttrs (import ./nix/users) [ "windowsUsername" ] // {
          repoPath = "/home/youruser/git/flakelab-config";
        };
      };

      # nixfmt-tree, not nixfmt-rfc-style: nixfmt deprecated being handed a directory.
      formatter.${system} = pkgs.nixfmt-tree;

      # The offline suites, the nix linters, and the eval-time assertions. `targets`
      # instantiates both systems and builds neither.
      checks.${system} = {
        gitchecker = suiteCheck "gitchecker";
        gitcleaner = suiteCheck "gitcleaner";
        gitpublisher = suiteCheck "gitpublisher";
        nix-backup = suiteCheck "nix-backup";
        nix-overlay-generate = suiteCheck "nix-overlay-generate";
        flakelab-cli = suiteCheck "flakelab-cli";
        claude-sessions = suiteCheck "claude-sessions";
        nix-update = suiteCheck "nix-update";
        statix = nixLintCheck "statix" pkgs.statix "statix check .";
        deadnix = nixLintCheck "deadnix" pkgs.deadnix "deadnix --fail .";

        # The inline-profile-attrset branch, which the offline suites structurally
        # cannot reach: suiteCheck gives them no `nix`.
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

        # The target seam: the two systems must differ exactly as nix/targets/ says,
        # and both must still evaluate.
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
          # default_user must arrive alongside the module's own system_info defaults.
          assert vm.services.cloud-init.settings.system_info.default_user.name == vm.flakelab.username;
          assert vm.services.cloud-init.settings.system_info.distro == "nixos";
          assert vm.services.qemuGuest.enable;
          assert vm.users.users.${vm.flakelab.username}.isNormalUser;
          assert !vm.services.openssh.settings.PasswordAuthentication;
          # A release asset cannot carry the home-manager closure.
          assert self.packages.${system}.proxmoxImage.passthru.config.home-manager.users == { };
          # Forcing the drvPath evaluates every module of both systems, and builds neither.
          assert builtins.isString wsl.system.build.toplevel.drvPath;
          assert builtins.isString vm.system.build.toplevel.drvPath;
          pkgs.runCommandLocal "flakelab-check-targets" { } "touch $out";

        # Both backup units must keep the escape hatch in both sections. Forced on,
        # or the units would not render and the check would pass vacuously.
        state-sync-decouple =
          let
            forced = self.nixosConfigurations.default.extendModules {
              modules = [
                {
                  flakelab = {
                    backupAutostart = nixpkgs.lib.mkForce true;
                    stateRoot = nixpkgs.lib.mkForce "/tmp/flakelab-check-state";
                    stateSyncInterval = nixpkgs.lib.mkForce "30min";
                  };
                }
              ];
            };
            hm = forced.config.home-manager.users.${forced.config.flakelab.username};
            units = hm.systemd.user.services;
          in
          assert units.flakelab-backup.Unit."X-RestartIfChanged" == false;
          assert units.flakelab-backup.Service."X-RestartIfChanged" == false;
          assert units.flakelab-state-sync.Unit."X-RestartIfChanged" == false;
          assert units.flakelab-state-sync.Service."X-RestartIfChanged" == false;
          assert units.flakelab-state-sync.Service.Type == "oneshot";
          assert hm.systemd.user.timers.flakelab-state-sync.Timer.OnUnitActiveSec == "30min";
          pkgs.runCommandLocal "flakelab-check-state-sync-decouple" { } "touch $out";

        # kiro-cli rewrites ~/.kiro/settings/cli.json itself (`kiro-cli settings` saves
        # by rename), which turns the store link into a regular file. Unforced, Home
        # Manager moves that aside to cli.json.hm-bak once, then fails the next
        # activation that finds the backup name taken. Forced, the checked-in baseline
        # simply wins again on every switch.
        kiro-cli-json =
          let
            sys = self.nixosConfigurations.default.config;
            hm = sys.home-manager.users.${sys.flakelab.username};
          in
          assert hm.home.file.".kiro/settings/cli.json".force;
          pkgs.runCommandLocal "flakelab-check-kiro-cli-json" { } "touch $out";

        # The sops seam: forced on it must render exactly the contract zsh.nix sources,
        # and at its null default it must contribute nothing.
        sops-optional =
          let
            forced = self.nixosConfigurations.default.extendModules {
              modules = [
                { flakelab.sopsSecretsFile = ./files/config/secrets.env.example; }
              ];
            };
            secret = forced.config.sops.secrets.tyc-env;
            # .zshenv, not .zshrc: a non-interactive `zsh -c` reads only the former,
            # so secrets placed in the interactive file strand every agent on the box.
            zshOf = sys: sys.config.home-manager.users.${sys.config.flakelab.username}.programs.zsh.envExtra;
            zshOn = zshOf forced;
            zshOff = zshOf self.nixosConfigurations.default;
            hasInfix = nixpkgs.lib.hasInfix;
          in
          assert secret.format == "dotenv";
          assert secret.path == "/run/secrets/tyc-env";
          assert secret.mode == "0400";
          assert secret.owner == forced.config.flakelab.username;
          assert !forced.config.sops.age.generateKey;
          assert forced.config.sops.age.sshKeyPaths == [ ];
          assert forced.config.sops.gnupg.sshKeyPaths == [ ];
          assert forced.config.sops.gnupg.home == null;
          assert forced.config.sops.useSystemdActivation;
          assert self.nixosConfigurations.default.config.sops.secrets == { };
          # Exactly one secrets source per box, no runtime fallback.
          assert hasInfix "/run/secrets/tyc-env" zshOn;
          assert !hasInfix ".config/tyc/secrets.env" zshOn;
          assert hasInfix ".config/tyc/secrets.env" zshOff;
          assert !hasInfix "/run/secrets/tyc-env" zshOff;
          pkgs.runCommandLocal "flakelab-check-sops-optional" { } "touch $out";

        # kiroMcpMerge reads the Claude marketplace clone, which is runtime data, under
        # Home Manager's `set -eu -o pipefail`. So the rendered entry itself runs here
        # against each state that clone can be in: absent (every first switch, where
        # installClaudePlugins defers until provisioning seeds a key), empty, valid and
        # malformed. A flakelab-warn entry fails the rebuild through flakelabHealthCheck,
        # so the three benign states also assert that none was written.
        kiro-mcp-merge =
          let
            fixture = self.nixosConfigurations.default.extendModules {
              modules = [
                # synology: the one server kiroMcpMerge single-sources from the clone.
                { flakelab.sessionVariables.SYNOLOGY_URL = "https://nas.example.invalid"; }
              ];
            };
            hm = fixture.config.home-manager.users.${fixture.config.flakelab.username};
            entry = pkgs.writeText "kiro-mcp-merge-activation" hm.home.activation.kiroMcpMerge.data;
          in
          pkgs.runCommandLocal "flakelab-check-kiro-mcp-merge"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.jq
              ];
            }
            ''
              export HOME="$TMPDIR/home" DRY_RUN_CMD=
              mkdir -p "$HOME"
              mcp="$HOME/.kiro/settings/mcp.json"
              root="$HOME/.claude/plugins/marketplaces"
              warnLog="$HOME/.local/state/flakelab/activation-failures"
              activate() { bash -euo pipefail ${entry}; }

              echo "absent marketplace root"
              activate
              jq -e '.mcpServers.synology.command == "sh"' "$mcp" > /dev/null
              test ! -e "$warnLog"

              echo "empty marketplace root"
              rm "$mcp"
              mkdir -p "$root"
              activate
              jq -e '.mcpServers.synology.command == "sh"' "$mcp" > /dev/null
              test ! -e "$warnLog"

              echo "a valid plugin definition wins, minus its env block"
              manifest="$root/fixture/plugins/mcp-synology/.mcp.json"
              mkdir -p "$(dirname "$manifest")"
              echo '{"mcpServers":{"synology":{"command":"market","args":["a"],"env":{"X":"''${X}"}}}}' > "$manifest"
              activate
              jq -e '.mcpServers.synology | .command == "market" and (has("env") | not)' "$mcp" > /dev/null
              test ! -e "$warnLog"

              echo "a malformed manifest warns and keeps the flakelab definition"
              echo 'not-json' > "$manifest"
              activate
              jq -e '.mcpServers.synology.command == "sh"' "$mcp" > /dev/null
              grep -q 'could not read the Claude marketplace MCP definitions' "$warnLog"

              touch $out
            '';
      };

      # The tooling this repo's gates need, at the versions flake.lock pins.
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
        # To stderr, or the banner prefixes what `nix develop -c <cmd>` prints.
        shellHook = ''
          echo "flakelab dev shell — 'make test' (offline suites), 'nix flake check' (suites + nix lint), 'pre-commit run --all-files'" >&2
        '';
      };

      packages.${system} = {
        # The importable distro tarball; `sudo nix run .#wslImage` writes nixos.wsl.
        wslImage = self.nixosConfigurations.default.config.system.build.tarballBuilder;

        # The Proxmox seed qcow2 release.yml publishes per tag: a variant of the same
        # system, so it carries no home-manager closure.
        proxmoxImage = self.nixosConfigurations.proxmox-vm.config.system.build.images.proxmox-vm-seed;

        # The history scan CI runs, from the pinned revision so a new upstream rule
        # arrives with a reviewed lock bump.
        inherit (pkgs) gitleaks;
      };

      # The fork-and-edit path; the overlay template below is the recommended one.
      templates.default = {
        path = ./.;
        description = "Declarative NixOS-WSL dev environment — edit nix/users/default.nix";
      };

      # The recommended path: a private overlay calling `flakelab.lib.mkSystem`, so
      # personal values never reach this shared repo.
      templates.overlay = {
        path = ./templates/overlay;
        description = "Private flakelab overlay — real values, git-ignored secrets, profiles preselected";
      };
    };
}
