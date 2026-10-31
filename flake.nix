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
        # pre-commit: stable's installs node hooks with a flag current npm rejects
        # (EUNKNOWNCONFIG), so every node hook is unbuildable with it.
        inherit (pkgsUnstable)
          bitwarden-cli
          glab
          opentofu
          playwright-driver
          pre-commit
          ;
      };

      # The patch stays until upstream's installers drop the commit's GIT_* as its
      # own clones do: a cold hook cache in a linked worktree, or under `commit -a`,
      # otherwise gets the commit's index overwritten by npm's clone of the hook.
      # pre-commit/pre-commit#3773; #3774 covers npm only, pip's git+ deps leak too.
      preCommitOverlay = _final: prev: {
        pre-commit = prev.pre-commit.overridePythonAttrs (old: {
          patches = (old.patches or [ ]) ++ [ ./nix/pre-commit-installer-env.patch ];
          # No binary cache holds the patched build, so nixpkgs' suite would rerun
          # on every CI job; checks.pre-commit-installer-env covers the patch. Both
          # flags are needed: the pytest setup-hook gates only on dontUsePytestCheck,
          # while doCheck drops nativeCheckInputs from the closure.
          doCheck = false;
          dontUsePytestCheck = true;
        });
      };

      # Used only by devShells, which must hand out the same pre-commit the distro runs.
      pkgsDev = pkgs.extend (nixpkgs.lib.composeExtensions unstableOverlay preCommitOverlay);

      # tycswap: the account switcher for Claude Code and Codex logins, one static
      # Go binary named `tycswap`. Pinned to a release tag: `version` is the one
      # place it is written (the tag, the ldflag and the Windows asset derive from
      # it), and a bump needs all three hashes with it - a build with a stale hash
      # prints the new one, and checks.tycswap / checks.tycswap-windows fail in CI
      # rather than on a box's update.
      tycswap =
        let
          # renovate: datasource=github-releases depName=tyclab/tycswap extractVersion=^v(?<version>.*)$
          version = "0.8.3";
        in
        pkgs.buildGo127Module {
          pname = "tycswap";
          inherit version;
          src = pkgs.fetchFromGitHub {
            owner = "tyclab";
            repo = "tycswap";
            tag = "v${version}";
            hash = "sha256-xrETvIK08dWBQoWjFyt4XpVcL6isPjJACqNB3XXvQmU=";
          };
          vendorHash = "sha256-ltzD3JGwaMseO0RmUYVxA3pijVoSvp4gl2JJYyZPEPY=";
          subPackages = [ "cmd/tycswap" ];
          env.CGO_ENABLED = 0;
          ldflags = [
            "-s"
            "-w"
            "-X github.com/tyclab/tycswap/internal/version.Version=v${version}"
          ];
          # The upstream suite wants a writable HOME and minutes of wall clock; the
          # release is tested there, CI here builds the binary only.
          doCheck = false;
          meta.mainProgram = "tycswap";
        };
      # The same release's Windows binary: the tray `flakelab tray` installs on the
      # host of a WSL box (nix/scripts.nix, files/scripts/tycswap-tray.ps1). A
      # fixed-output fetch, so the exe a box runs is the one the hash names.
      tycswapWindows = pkgs.fetchurl {
        url = "https://github.com/tyclab/tycswap/releases/download/v${tycswap.version}/tycswap_v${tycswap.version}_windows_amd64.exe";
        hash = "sha256-yo34H0Q7/nj+XEB4Vfq+/PulHSEFE4ZEu176RdozZpw=";
      };
      tycswapOverlay = _final: _prev: { inherit tycswap tycswapWindows; };

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
                    ./nix/state-syncthing.nix
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
                        tycswapOverlay
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
      checks.${system} = import ./nix/checks.nix {
        inherit
          self
          pkgs
          pkgsDev
          pkgsUnstable
          nixpkgs
          system
          tycswap
          tycswapWindows
          resolveUserData
          mkSystem
          ;
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

        # `nix run .#tycswap -- --version` builds the switcher the distro installs.
        inherit tycswap;
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
