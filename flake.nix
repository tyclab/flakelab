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

      # tycswap: the account switcher for Claude Code and Codex logins, one static
      # Go binary named `tycswap`. Pinned to a release tag: `version` is the one
      # place it is written (the tag and the ldflag derive from it), and a bump
      # needs both hashes with it - a build with a stale hash prints the new one,
      # and checks.tycswap fails in CI rather than on a box's update.
      tycswap =
        let
          # renovate: datasource=github-releases depName=tyclab/tycswap extractVersion=^v(?<version>.*)$
          version = "0.4.0";
        in
        pkgs.buildGoModule {
          pname = "tycswap";
          inherit version;
          src = pkgs.fetchFromGitHub {
            owner = "tyclab";
            repo = "tycswap";
            tag = "v${version}";
            hash = "sha256-G4q3YzxjRj7ZQ3ockO29MiK0rAO/59epygtsggXGxbk=";
          };
          vendorHash = "sha256-A87i6YailHyI4ocgqlgy9MQ3RzQ6sA6abi7DUkCOG+Y=";
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
      tycswapOverlay = _final: _prev: { inherit tycswap; };

      # One flake check per offline suite, so CI runs them; `make test` runs the same
      # scripts against the working tree. The shebang rewrite is required because the
      # sandbox has no /usr/bin/env, and the suites emit that shebang themselves.
      # The whole tree is copied, not just files/scripts: nix-overlay-generate reads
      # templates/overlay/ and profiles/ out of the checkout it sits in.
      suiteCheck = suiteCheckWith [ ];
      # A suite that runs the real `nix` gets it here, against a dummy store:
      # evaluation needs none, and the sandbox has no daemon to reach.
      suiteCheckWith =
        extraInputs: name:
        pkgs.runCommandLocal "flakelab-check-${name}"
          {
            nativeBuildInputs =
              with pkgs;
              [
                zsh
                git
                jq
                util-linux
                # test-clone-repos generates a throwaway key: the sweep refuses to
                # start unless it can prove the key needs no agent.
                openssh
              ]
              ++ extraInputs;
            NIX_CONFIG = "store = dummy://\nexperimental-features = nix-command";
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
      checks.${system} = {
        # The pinned switcher builds: a tag bump with a stale hash fails here, not
        # on a box's `flakelab update`.
        inherit tycswap;
        clone-repos = suiteCheck "clone-repos";
        gh-repos = suiteCheck "gh-repos";
        gitchecker = suiteCheck "gitchecker";
        gitcleaner = suiteCheck "gitcleaner";
        gitpublisher = suiteCheck "gitpublisher";
        nix-backup = suiteCheck "nix-backup";
        nix-overlay-generate = suiteCheck "nix-overlay-generate";
        # The --help sweep runs `mcp`, a python3 program.
        flakelab-cli = suiteCheckWith [ pkgs.python3 ] "flakelab-cli";
        claude-sessions = suiteCheck "claude-sessions";
        notify = suiteCheck "notify";
        # The suite; the launcher as installed, against a fixture account; the
        # account and the headless browser registered in both clients' rendered
        # configuration; and that browser server driven end to end.
        mcp =
          let
            suite = suiteCheckWith [ pkgs.python3 ] "mcp";
            fixtureServer = {
              url = "https://example.invalid/mcp";
              callbackPort = 18871;
            };
            client = import ./nix/mcp-clients.nix {
              inherit pkgs;
              cfg = {
                mcpShared = {
                  gateway = null;
                  servers.fixture = fixtureServer;
                };
                mcpBrowsers.headless = false;
              };
            };
            fixture = self.nixosConfigurations.default.extendModules {
              modules = [
                {
                  flakelab.mcpShared = {
                    gateway = "operator@devbox";
                    servers.fixture = fixtureServer;
                  };
                  flakelab.mcpBrowsers.headless = true;
                }
              ];
            };
            hm = fixture.config.home-manager.users.${fixture.config.flakelab.username};
            claudeMerge = pkgs.writeText "mcp-claude-activation" (
              nixpkgs.lib.replaceStrings [ "$HOME" ] [ "$fixtureHome" ] hm.home.activation.claudeMcpMerge.data
            );
            codexSettings = fixture.config.environment.etc."codex/config.toml".source;
            headlessShell = fixture.pkgs.playwright-driver.browsersJSON.chromium-headless-shell;
          in
          pkgs.runCommandLocal "flakelab-check-mcp-installed"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.jq
                pkgs.python3
                pkgs.remarshal
              ];
            }
            ''
              test -e ${suite}
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"
              ${client.launcher}/bin/flakelab-mcp --help > help.txt
              grep -q import-codex help.txt
              ${client.launcher}/bin/flakelab-mcp status | jq -e '. == [{"name":"fixture","credentials":"login-required"}]'
              if ${client.launcher}/bin/flakelab-mcp connect fixture 2> connect.err; then exit 1; fi
              grep -q 'login required' connect.err

              export fixtureHome="$TMPDIR/fixture" DRY_RUN_CMD=
              mkdir -p "$fixtureHome"
              bash -euo pipefail ${claudeMerge}
              jq -e '.mcpServers.fixture | .type == "stdio" and (.command | endswith("/bin/flakelab-mcp")) and .args == ["connect", "fixture"]' "$fixtureHome/.claude.json"
              toml2json ${codexSettings} | jq -e '.mcp_servers.fixture | (.command | endswith("/bin/flakelab-mcp")) and .args == ["connect", "fixture"]'
              config="$(grep -o '/nix/store/[^ ]*-flakelab-mcp.json' "$(jq -r .mcpServers.fixture.command "$fixtureHome/.claude.json")")"
              jq -e '.gateway == "operator@devbox" and .servers.fixture.callbackPort == 18871' "$config"

              jq -e '.mcpServers."playwright-headless" | .type == "stdio" and (.command | endswith("/bin/flakelab-playwright-headless")) and .args == []' "$fixtureHome/.claude.json"
              toml2json ${codexSettings} | jq -e '.mcp_servers."playwright-headless".command | endswith("/bin/flakelab-playwright-headless")'
              headless="$(jq -r '.mcpServers."playwright-headless".command' "$fixtureHome/.claude.json")"
              # Hosts launch with the Chromium sandbox on; only this check turns it off,
              # because Ubuntu 23.10+ runners deny the user namespaces it needs.
              config="$(grep -o '/nix/store/[^ ]*-playwright-headless.json' "$headless")"
              jq -e '.browser.launchOptions | has("chromiumSandbox") | not' "$config"
              if grep -q sandbox "$headless"; then exit 1; fi
              FLAKELAB_MCP_HEADLESS="$headless" FLAKELAB_MCP_HEADLESS_ARGS=--no-sandbox \
                FLAKELAB_MCP_HEADLESS_VERSION=${headlessShell.browserVersion} \
                python3 ${./files/scripts}/lib/test-mcp.py -v HeadlessBrowserTest
              touch "$out"
            '';
        # The dashboard's suite runs the server on loopback and talks to it.
        web = suiteCheckWith [
          pkgs.python3
          pkgs.curl
        ] "web";
        # The input report reads the lock with `nix eval`, which is under test too.
        nix-update = suiteCheckWith [ pkgs.nix ] "nix-update";
        nix-doctor = suiteCheck "nix-doctor";
        switch-result = suiteCheck "switch-result";
        wsl-init-cgroup = suiteCheck "wsl-init-cgroup";
        xdg-open = suiteCheck "xdg-open";
        # The hook installer drives `make install-hooks` where a repo has the target.
        activate-hooks = suiteCheckWith [ pkgs.gnumake ] "activate-hooks";
        report-stale-repos = suiteCheck "report-stale-repos";
        nix-provision = suiteCheck "nix-provision";
        codex-config =
          let
            manifest = builtins.toFile "codex-mcp-fixture.json" (
              builtins.toJSON {
                mcpServers = {
                  docs = {
                    type = "http";
                    url = "https://docs.example.invalid/mcp";
                  };
                  local = {
                    command = "example-mcp";
                    env_vars = [ "XDG_RUNTIME_DIR" ];
                    tools.inspect = {
                      output_token_limit = 512;
                      approval_mode = "approve";
                    };
                  };
                };
              }
            );
            fixture = self.nixosConfigurations.default.extendModules {
              modules = [
                {
                  flakelab = {
                    codexMcpSources = [ manifest ];
                    codexAutoReview = true;
                    codexReadOnlyTools.docs = [ "search" ];
                    codexSettings = {
                      model = "fixture-model";
                      tui.status_line = [ "git-branch" ];
                      permissions.flakelab.filesystem."/fixture/credentials" = "deny";
                      apps.fixture.tools.search.approval_mode = "approve";
                    };
                  };
                }
              ];
            };
            hm = fixture.config.home-manager.users.${fixture.config.flakelab.username};
            settings = fixture.config.environment.etc."codex/config.toml".source;
            enforced = fixture.extendModules {
              modules = [
                {
                  flakelab = {
                    codexEnforcePermissions = true;
                    codexSettings.auto_review.policy = "fixture reviewer policy";
                  };
                }
              ];
            };
            enforcedSettings = enforced.config.environment.etc."codex/config.toml".source;
            requirements = enforced.config.environment.etc."codex/requirements.toml".source;
            oldConfig = pkgs.writeText "codex-config" ''model = "fixture-model"'';
            migrate = pkgs.writeText "codex-writable-config-activation" (
              nixpkgs.lib.replaceStrings [ "$HOME" ] [ "$fixtureHome" ]
                hm.home.activation.codexWritableConfig.data
            );
            baseline = self.nixosConfigurations.default.config;
          in
          assert !baseline.home-manager.users.${baseline.flakelab.username}.programs.codex.enable;
          assert hm.programs.codex.package == null;
          assert hm.programs.codex.skills == { };
          assert hm.programs.codex.context == "";
          assert hm.programs.codex.settings == { };
          assert !(hm.home.file ? ".codex/config.toml");
          assert !(baseline.environment.etc ? "codex/config.toml");
          assert fixture.config.flakelab.claudeAutoMode == baseline.flakelab.claudeAutoMode;
          pkgs.runCommandLocal "flakelab-check-codex-config"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.remarshal
                pkgs.jq
              ];
            }
            ''
              toml2json ${settings} > settings.json
              jq -e '
                .model == "fixture-model" and .tui.status_line == ["git-branch"]
                and (.mcp_servers.docs | has("type") | not)
                and .mcp_servers.local.env_vars == ["XDG_RUNTIME_DIR"]
                and .mcp_servers.docs.tools.search.approval_mode == "approve"
                and .mcp_servers.local.default_tools_approval_mode == "prompt"
                and .mcp_servers.local.tools.inspect.output_token_limit == 512
                and .mcp_servers.local.tools.inspect.approval_mode == "prompt"
                and .approvals_reviewer == "auto_review"
                and .default_permissions == "flakelab"
                and .permissions.flakelab.extends == ":workspace"
                and .permissions.flakelab.network.enabled == false
                and .permissions.flakelab.filesystem["/fixture/credentials"] == "deny"
                and .apps._default.approvals_reviewer == "auto_review"
                and .apps._default.default_tools_approval_mode == "prompt"
                and .apps.fixture.tools.search.approval_mode == "approve"
                and (has("sandbox_mode") | not)
                and (has("sandbox_workspace_write") | not)
                and (has("auto_review") | not)
              ' settings.json
              toml2json ${enforcedSettings} | jq -e '
                .default_permissions == "flakelab"
                and (has("permissions") | not)
                and (has("auto_review") | not)
              '
              toml2json ${requirements} | jq -e '
                .allowed_approval_policies == ["on-request"]
                and .allowed_approvals_reviewers == ["auto_review"]
                and .default_permissions == "flakelab"
                and .allowed_permission_profiles == {"flakelab":true, ":read-only":true}
                and .permissions.flakelab.extends == ":workspace"
                and .permissions.flakelab.filesystem["/fixture/credentials"] == "deny"
                and .guardian_policy_config == "fixture reviewer policy"
                and (.rules.prefix_rules | length) == 17
                and (.rules.prefix_rules | all(.decision == "prompt" or .decision == "forbidden"))
                and (.rules.prefix_rules | any(.pattern == [{"token":"git"},{"token":"push"},{"token":"--mirror"}] and .decision == "forbidden"))
              '
              test -s ${hm.home.file.".codex/rules/flakelab.rules".source}
              export fixtureHome="$TMPDIR/codex-home" DRY_RUN_CMD=""
              mkdir -p "$fixtureHome/.codex"
              ln -s ${oldConfig} "$fixtureHome/.codex/config.toml"
              DRY_RUN_CMD=echo bash ${migrate}
              test -L "$fixtureHome/.codex/config.toml"
              test "$(find "$fixtureHome" -type f | wc -l)" -eq 0
              bash ${migrate}
              test ! -L "$fixtureHome/.codex/config.toml"
              test -w "$fixtureHome/.codex/config.toml"
              test "$(stat -c %a "$fixtureHome/.codex/config.toml")" = 600
              cmp ${oldConfig} "$fixtureHome"/.codex/config.toml.before-system-defaults.*
              printf '[projects."/fixture"]\ntrust_level = "trusted"\n' > "$fixtureHome/.codex/config.toml"
              cp "$fixtureHome/.codex/config.toml" expected
              bash ${migrate}
              cmp expected "$fixtureHome/.codex/config.toml"
              export fixtureHome="$TMPDIR/new-codex-home"
              bash ${migrate}
              test -w "$fixtureHome/.codex/config.toml"
              touch $out
            '';
        claude-mcp-exclusion =
          let
            fixture = self.nixosConfigurations.default.extendModules {
              modules = [
                {
                  flakelab = {
                    sessionVariables.WHATSAPP_BRIDGE_HOST = "localhost:8180";
                    whatsappMcpDir = "/example/whatsapp-mcp-server";
                    claudeMcpDisabledServers = [ "whatsapp" ];
                    claudeMcpServers.custom = {
                      command = "example-mcp";
                    };
                  };
                }
              ];
            };
            hm = fixture.config.home-manager.users.${fixture.config.flakelab.username};
            # Isolate the generated activation entry without changing the test
            # process's HOME or accessing any live Claude account files.
            rendered =
              name: sys:
              pkgs.writeText name (
                nixpkgs.lib.replaceStrings [ "$HOME" ] [ "$fixtureHome" ]
                  sys.config.home-manager.users.${sys.config.flakelab.username}.home.activation.claudeMcpMerge.data
              );
            entry = rendered "claude-mcp-exclusion-activation" fixture;
            # The generation before: one more declared server.
            earlier = rendered "claude-mcp-earlier-activation" (
              fixture.extendModules {
                modules = [
                  {
                    flakelab.claudeMcpServers.retired = {
                      command = "retired-mcp";
                      args = [
                        "--dir"
                        "/example/retired-value"
                      ];
                    };
                  }
                ];
              }
            );
            # A generation that renders no server at all.
            none = rendered "claude-mcp-none-activation" self.nixosConfigurations.default;
          in
          assert nixpkgs.lib.hasInfix "whatsapp" hm.home.activation.claudeMcpMerge.data;
          pkgs.runCommandLocal "flakelab-check-claude-mcp-exclusion"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.jq
              ];
            }
            ''
              export fixtureHome="$TMPDIR/fixture" DRY_RUN_CMD=
              mkdir -p "$fixtureHome"
              printf '%s\n' '{"account":{"opaque":"sentinel"},"mcpServers":{"whatsapp":{"command":"old"},"manual":{"command":"keep"}}}' > "$fixtureHome/.claude.json"
              bash -euo pipefail ${entry}
              jq -e '.account.opaque == "sentinel" and (.mcpServers | has("whatsapp") | not) and .mcpServers.manual.command == "keep" and .mcpServers.custom.command == "example-mcp"' "$fixtureHome/.claude.json"
              cp "$fixtureHome/.claude.json" before.json
              bash -euo pipefail ${entry}
              cmp before.json "$fixtureHome/.claude.json"
              test "$(stat -c %a "$fixtureHome/.claude.json")" = 600

              # fresh <name>: an empty fixture home with the same paths under it.
              fresh() {
                export fixtureHome="$TMPDIR/$1"
                mkdir -p "$fixtureHome"
                claudeJson="$fixtureHome/.claude.json"
                record="$fixtureHome/.local/state/flakelab/activation-rendered/claude-mcp-servers.json"
              }

              echo "a missing record removes nothing"
              fresh no-record
              printf '%s\n' '{"mcpServers":{"retired":{"command":"earlier"}}}' > "$claudeJson"
              bash -euo pipefail ${entry}
              jq -e '.mcpServers | .retired.command == "earlier" and .custom.command == "example-mcp"' "$claudeJson"
              jq -e '. == ["custom"]' "$record"

              echo "a server one generation rendered and the next does not is removed, a hand-added one survives both"
              fresh generations
              printf '%s\n' '{"mcpServers":{"manual":{"command":"keep"}}}' > "$claudeJson"
              bash -euo pipefail ${earlier}
              jq -e '.mcpServers | .retired.command == "retired-mcp" and .manual.command == "keep"' "$claudeJson"
              bash -euo pipefail ${entry}
              jq -e '.mcpServers | (has("retired") | not) and .custom.command == "example-mcp" and .manual.command == "keep"' "$claudeJson"

              echo "the record holds the rendered names, no values, mode 600"
              jq -e '. == ["custom"]' "$record"
              test "$(stat -c %a "$record")" = 600
              bash -euo pipefail ${earlier}
              jq -e '. == ["custom", "retired"]' "$record"
              if grep -q -e retired-mcp -e retired-value -e example-mcp "$record"; then exit 1; fi

              echo "a generation that renders no server removes the last ones rendered"
              bash -euo pipefail ${none}
              jq -e '.mcpServers == {"manual":{"command":"keep"}}' "$claudeJson"
              jq -e '. == []' "$record"

              echo "no server rendered and no ~/.claude.json: none is created"
              fresh none
              bash -euo pipefail ${none}
              test ! -e "$claudeJson"
              touch $out
            '';
        # settings.json is Claude's own file as much as ours, so the rendered claudeSettings
        # entry runs across two generations: the env keys and the statusline the first
        # one wrote and the second no longer renders go, the user's own stay.
        claude-settings-prune =
          let
            later = self.nixosConfigurations.default;
            earlier = later.extendModules {
              modules = [
                {
                  flakelab = {
                    claudePlugins = [
                      "mcp-playwright"
                      "mcp-whatsapp"
                      "statusbar@fixture-market"
                    ];
                    sessionVariables.WHATSAPP_BRIDGE_HOST = "bridge.example.invalid:8180";
                    whatsappMcpDir = "/example/whatsapp-mcp-server";
                  };
                }
              ];
            };
            entry =
              name: sys:
              pkgs.writeText name
                sys.config.home-manager.users.${sys.config.flakelab.username}.home.activation.claudeSettings.data;
            entryEarlier = entry "claude-settings-earlier-activation" earlier;
            entryLater = entry "claude-settings-later-activation" later;
          in
          pkgs.runCommandLocal "flakelab-check-claude-settings-prune"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.jq
              ];
            }
            ''
              export DRY_RUN_CMD=
              # fresh <name>: an empty HOME with the same paths under it.
              fresh() {
                export HOME="$TMPDIR/$1"
                mkdir -p "$HOME/.claude"
                settings="$HOME/.claude/settings.json"
                record="$HOME/.local/state/flakelab/activation-rendered/claude-settings-env.json"
                warnLog="$HOME/.local/state/flakelab/activation-failures"
              }
              base='["CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY","DISABLE_ERROR_REPORTING","DISABLE_FEEDBACK_COMMAND"]'

              echo "a missing record removes nothing"
              fresh no-record
              echo '{"env":{"WHATSAPP_MCP_DIR":"/earlier","MY_VAR":"mine"}}' > "$settings"
              bash -euo pipefail ${entryLater}
              jq -e '.env | .WHATSAPP_MCP_DIR == "/earlier" and .MY_VAR == "mine"' "$settings" > /dev/null
              jq -e --argjson b "$base" '. == $b' "$record" > /dev/null

              echo "env keys and the statusline one generation rendered and the next does not are removed, the user's survive both"
              fresh generations
              echo '{"env":{"MY_VAR":"mine"}}' > "$settings"
              bash -euo pipefail ${entryEarlier}
              jq -e '.env | .MY_VAR == "mine" and .WHATSAPP_MCP_DIR == "/example/whatsapp-mcp-server" and .PLAYWRIGHT_MCP_EXTENSION == "true"' "$settings" > /dev/null
              jq -e '.statusLine.command | test("/statusbar/\\*/ \\| sort -V \\| tail -1\\)statusline-command\\.sh\"$")' "$settings" > /dev/null
              bash -euo pipefail ${entryLater}
              jq -e --argjson b "$base" '.env | keys == ($b + ["MY_VAR"] | sort)' "$settings" > /dev/null
              jq -e 'has("statusLine") | not' "$settings" > /dev/null
              test ! -e "$warnLog"

              echo "the record holds the rendered names, no values, mode 600"
              jq -e --argjson b "$base" '. == $b' "$record" > /dev/null
              test "$(stat -c %a "$record")" = 600
              bash -euo pipefail ${entryEarlier}
              jq -e --argjson b "$base" '. == ($b + ["PLAYWRIGHT_MCP_BROWSER","PLAYWRIGHT_MCP_EXECUTABLE_PATH","PLAYWRIGHT_MCP_EXTENSION","WHATSAPP_BRIDGE_HOST","WHATSAPP_MCP_DIR","WHATSAPP_MCP_TOOLSETS"])' "$record" > /dev/null
              if grep -q -e bridge.example.invalid -e whatsapp-mcp-server -e chrome.exe -e core,send "$record"; then exit 1; fi

              echo "an env key added by hand after flakelab stopped rendering it survives"
              bash -euo pipefail ${entryLater}
              jq '.env.WHATSAPP_MCP_DIR = "/by-hand"' "$settings" > settings.tmp
              mv settings.tmp "$settings"
              bash -euo pipefail ${entryLater}
              jq -e '.env.WHATSAPP_MCP_DIR == "/by-hand"' "$settings" > /dev/null

              echo "a statusline of the user's own survives both generations"
              fresh own-statusline
              echo '{"statusLine":{"type":"command","command":"my-statusline"}}' > "$settings"
              bash -euo pipefail ${entryEarlier}
              jq -e '.statusLine.command == "my-statusline"' "$settings" > /dev/null
              bash -euo pipefail ${entryLater}
              jq -e '.statusLine.command == "my-statusline"' "$settings" > /dev/null

              echo "a settings.json jq cannot read warns and keeps the record"
              fresh failed-merge
              bash -euo pipefail ${entryEarlier}
              echo 'not-json' > "$settings"
              bash -euo pipefail ${entryLater}
              grep -q 'could not update' "$warnLog"
              grep -qx 'not-json' "$settings"
              jq -e '. | length == 9' "$record" > /dev/null
              touch $out
            '';
        # Remote Control follows claudeRemoteControl alone: the agent bundle writes
        # the permission mode and nothing of Remote Control, so a box can have
        # either without the other. Both entries run against a settings.json the
        # user set the four vars in.
        claude-remote-control =
          let
            activation =
              attrs:
              let
                sys =
                  (self.nixosConfigurations.default.extendModules { modules = [ { flakelab = attrs; } ]; }).config;
              in
              sys.home-manager.users.${sys.flakelab.username}.home.activation.claudeSettings.data;
            agentOnly = activation { claudeAgentDefaults = true; };
            remoteControlOnly = activation { claudeRemoteControl = true; };
            neither = activation { };
          in
          assert nixpkgs.lib.hasInfix ''.permissions.defaultMode = "auto"'' agentOnly;
          assert !nixpkgs.lib.hasInfix "remoteControlAtStartup" agentOnly;
          assert nixpkgs.lib.hasInfix ".remoteControlAtStartup = true" remoteControlOnly;
          assert !nixpkgs.lib.hasInfix "defaultMode" remoteControlOnly;
          assert !nixpkgs.lib.hasInfix "remoteControlAtStartup" neither;
          assert !nixpkgs.lib.hasInfix "defaultMode" neither;
          pkgs.runCommandLocal "flakelab-check-claude-remote-control"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.jq
              ];
            }
            ''
              export DRY_RUN_CMD=
              # fresh <name>: an empty HOME whose settings.json carries the four vars.
              fresh() {
                export HOME="$TMPDIR/$1"
                mkdir -p "$HOME/.claude"
                settings="$HOME/.claude/settings.json"
                echo '{"env":{"DISABLE_TELEMETRY":"1","DO_NOT_TRACK":"1","CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC":"1","DISABLE_GROWTHBOOK":"1"}}' > "$settings"
              }
              vars='["CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC","DISABLE_GROWTHBOOK","DISABLE_TELEMETRY","DO_NOT_TRACK"]'

              echo "the agent bundle alone: auto mode, no Remote Control, the four vars stay"
              fresh agent-only
              bash -euo pipefail ${pkgs.writeText "claude-agent-only-activation" agentOnly}
              jq -e '.permissions.defaultMode == "auto" and .skipAutoPermissionPrompt == true' "$settings" > /dev/null
              jq -e 'has("remoteControlAtStartup") | not' "$settings" > /dev/null
              jq -e --argjson v "$vars" '[.env[$v[]]] == ["1","1","1","1"]' "$settings" > /dev/null

              echo "claudeRemoteControl alone: Remote Control, the four vars go, no auto mode"
              fresh remote-control-only
              bash -euo pipefail ${pkgs.writeText "claude-remote-control-only-activation" remoteControlOnly}
              jq -e '.remoteControlAtStartup == true' "$settings" > /dev/null
              jq -e --argjson v "$vars" '[.env | has($v[])] == [false,false,false,false]' "$settings" > /dev/null
              jq -e '(.permissions | has("defaultMode") | not) and (has("skipAutoPermissionPrompt") | not)' "$settings" > /dev/null
              touch $out
            '';
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
            hasPkg =
              cfg: name: builtins.any (p: (p.pname or p.name or "") == name) cfg.environment.systemPackages;
            webOn =
              system: bind:
              (system.extendModules {
                modules = [
                  {
                    flakelab.web = {
                      enable = nixpkgs.lib.mkForce true;
                      bind = nixpkgs.lib.mkForce bind;
                    };
                  }
                ];
              }).config;
            webOnTunnel = webOn self.nixosConfigurations.proxmox-vm "10.66.0.2";
            webOnLoopback = webOn self.nixosConfigurations.proxmox-vm "127.0.0.1";
            webOnTunnelWsl = webOn self.nixosConfigurations.default "10.66.0.2";
          in
          assert wsl.flakelab.target == "wsl";
          assert wsl.wsl.enable;
          assert hasPkg wsl "xdg-open";
          assert vm.flakelab.target == "proxmox-vm";
          assert !(vm ? wsl);
          assert !(hasPkg vm "xdg-open");
          # The boot step that chooses systemd's cgroup exists on wsl only, and runs
          # the wrapper that pins its PATH.
          assert nixpkgs.lib.hasSuffix "/bin/flakelab-wsl-init-cgroup"
            wsl.system.activationScripts.flakelab-wsl-init-cgroup.text;
          assert !(vm.system.activationScripts ? flakelab-wsl-init-cgroup);
          assert vm.services.cloud-init.enable;
          # default_user must arrive alongside the module's own system_info defaults.
          assert vm.services.cloud-init.settings.system_info.default_user.name == vm.flakelab.username;
          assert vm.services.cloud-init.settings.system_info.distro == "nixos";
          assert vm.services.qemuGuest.enable;
          assert vm.users.users.${vm.flakelab.username}.isNormalUser;
          assert !vm.services.openssh.settings.PasswordAuthentication;
          # The dashboard's port is open only for a bind off loopback, and only on the VM:
          # the guest's firewall leaves sshd alone, and wsl cannot open a port from inside.
          assert !(builtins.elem vm.flakelab.web.port vm.networking.firewall.allowedTCPPorts);
          assert builtins.elem webOnTunnel.flakelab.web.port webOnTunnel.networking.firewall.allowedTCPPorts;
          assert
            !(builtins.elem webOnLoopback.flakelab.web.port webOnLoopback.networking.firewall.allowedTCPPorts);
          assert
            !(builtins.elem webOnTunnelWsl.flakelab.web.port webOnTunnelWsl.networking.firewall.allowedTCPPorts);
          # A release asset cannot carry the home-manager closure.
          assert self.packages.${system}.proxmoxImage.passthru.config.home-manager.users == { };
          # Forcing the drvPath evaluates every module of both systems, and builds neither.
          assert builtins.isString wsl.system.build.toplevel.drvPath;
          assert builtins.isString vm.system.build.toplevel.drvPath;
          pkgs.runCommandLocal "flakelab-check-targets" { } "touch $out";

        # The activation record flakelab-switch-result reads: the snippet must run last
        # in both systems, and the generated text - run under the activation script's
        # own ERR trap - must record a failure before it, a clean run, and survive a
        # directory it cannot write without failing the activation itself.
        activation-result =
          let
            lastSnippet =
              cfg:
              let
                lines = builtins.filter builtins.isString (builtins.split "\n" cfg.system.activationScripts.script);
                heads = builtins.filter (l: builtins.match "#### Activation script snippet .*" l != null) lines;
              in
              builtins.elemAt heads (builtins.length heads - 1);
            head = "#### Activation script snippet flakelab-activation-result:";
            wsl = self.nixosConfigurations.default.config;
            vm = self.nixosConfigurations.proxmox-vm.config;
            snippet = pkgs.writeText "flakelab-activation-result" wsl.system.activationScripts.flakelab-activation-result.text;
          in
          assert lastSnippet wsl == head;
          assert lastSnippet vm == head;
          pkgs.runCommandLocal "flakelab-check-activation-result" { nativeBuildInputs = [ pkgs.bash ]; } ''
            set -u
            run() { # <run dir> <preceding snippet>
              sed "s|/run/flakelab|$1|g" ${snippet} > snippet.sh
              bash -c "_status=0; trap '_status=1 _localstatus=\$?' ERR; systemConfig=$PWD/sys; $2; source ./snippet.sh; exit \$_status"
            }
            mkdir sys
            want_init="$(s="$(< /proc/1/stat)"; s="''${s##*) }"; set -- $s; echo "''${20}")"

            mkdir ok; run "$PWD/ok" true || { echo "a clean activation exited non-zero" >&2; exit 1; }
            grep -qx 'status=0' ok/activation || { echo "clean run not recorded as 0" >&2; exit 1; }
            grep -qx "system=$PWD/sys" ok/activation || { echo "system not recorded" >&2; exit 1; }
            grep -qx "init=$want_init" ok/activation || { echo "init start not recorded" >&2; cat ok/activation >&2; exit 1; }

            mkdir bad; if run "$PWD/bad" false; then echo "a failed snippet before it did not fail the activation" >&2; exit 1; fi
            grep -qx 'status=1' bad/activation || { echo "the earlier failure not recorded" >&2; exit 1; }

            mkdir ro; chmod 500 ro
            run "$PWD/ro/sub" true 2> ro.err || { echo "an unwritable record failed the activation" >&2; exit 1; }
            grep -q 'could not record' ro.err || { echo "an unwritable record went unreported" >&2; exit 1; }
            touch $out
          '';

        # Claude and its marketplaces update themselves; nothing here pins them, so
        # the switches that could stop them are asserted. The rendered
        # claudeAutoUpdates entry runs against absent, populated and malformed state.
        claude-auto-updates =
          let
            fixture = self.nixosConfigurations.default.extendModules {
              modules = [
                {
                  flakelab.claudePluginMarketplaces = [
                    {
                      name = "fixture-market";
                      url = "git@example.invalid:group/fixture-market.git";
                    }
                  ];
                }
              ];
            };
            hm = fixture.config.home-manager.users.${fixture.config.flakelab.username};
            entry = pkgs.writeText "claude-auto-updates-activation" hm.home.activation.claudeAutoUpdates.data;
          in
          pkgs.runCommandLocal "flakelab-check-claude-auto-updates"
            {
              nativeBuildInputs = [
                pkgs.bash
                pkgs.jq
              ];
            }
            ''
              export HOME="$TMPDIR/home" DRY_RUN_CMD=
              mkdir -p "$HOME/.claude/plugins"
              claudeJson="$HOME/.claude.json"
              known="$HOME/.claude/plugins/known_marketplaces.json"
              warnLog="$HOME/.local/state/flakelab/activation-failures"
              activate() { bash -euo pipefail ${entry}; }

              echo "absent state files stay absent"
              activate
              test ! -e "$claudeJson"
              test ! -e "$known"
              test ! -e "$warnLog"

              echo "the native installer's autoUpdates=false is switched on, the rest kept"
              echo '{"installMethod":"native","autoUpdates":false,"autoUpdatesProtectedForNative":true,"keep":1}' > "$claudeJson"
              echo '{"fixture-market":{"source":{"source":"git","url":"git@example.invalid:group/fixture-market.git"},"lastUpdated":"x"},"other":{"source":{"source":"github","repo":"o/r"}}}' > "$known"
              activate
              jq -e '.autoUpdates == true and .keep == 1 and .installMethod == "native"' "$claudeJson" > /dev/null
              test "$(stat -c %a "$claudeJson")" = 600
              jq -e '.["fixture-market"] | .autoUpdate == true and .lastUpdated == "x"' "$known" > /dev/null
              jq -e '.other | has("autoUpdate") | not' "$known" > /dev/null
              test ! -e "$warnLog"

              echo "a malformed marketplace registry warns and is left alone"
              echo 'not-json' > "$known"
              activate
              grep -qx 'not-json' "$known"
              grep -q 'could not enable auto-update for the Claude marketplaces' "$warnLog"

              touch $out
            '';

        # The CLI installers fetch a script and pipe it into a shell. Without pipefail a
        # failed fetch hands the shell an empty script, which exits 0: nothing installed,
        # nothing deferred, and the health check then fails on the missing binary. Each
        # rendered entry runs here as an offline switch, whose failures must all be
        # deferred - a flakelab-warn entry fails the rebuild.
        cli-installers =
          let
            sys = self.nixosConfigurations.default.config;
            hm = sys.home-manager.users.${sys.flakelab.username};
            entry = name: pkgs.writeText "${name}-activation" hm.home.activation.${name}.data;
          in
          # Codex's sandbox takes bwrap from PATH, not the store path of a dependency.
          assert builtins.elem pkgs.bubblewrap hm.home.packages;
          pkgs.runCommandLocal "flakelab-check-cli-installers" { nativeBuildInputs = [ pkgs.bash ]; } ''
            set -u
            export DRY_RUN_CMD=
            # fresh <name>: an empty HOME to activate against.
            fresh() {
              export HOME="$TMPDIR/$1"
              mkdir -p "$HOME/.local/bin"
            }
            activate() { bash -euo pipefail "$1"; }
            # stub <name> <script body>: an installed CLI.
            stub() {
              printf '#!%s\n%s\n' "$(command -v bash)" "$2" > "$HOME/.local/bin/$1"
              chmod +x "$HOME/.local/bin/$1"
            }
            deferred() { grep -q -- "$1" "$HOME/.local/state/flakelab/activation-deferred"; }
            nothingDeferred() { test ! -e "$HOME/.local/state/flakelab/activation-deferred"; }
            noWarn() { test ! -e "$HOME/.local/state/flakelab/activation-failures"; }
            # Offline on a builder without the sandbox too: a failing curl, exported so
            # the entry's inner bash takes it over the store curl on its PATH.
            offline() { curl() { return 6; }; export -f curl; }
            offline

            echo "claude: an offline first install is deferred"
            fresh claude-absent
            activate ${entry "installClaudeCode"}
            test ! -e "$HOME/.local/bin/claude"
            deferred "Claude Code not installed"
            noWarn

            echo "codex: an offline first install is deferred"
            fresh codex-absent
            activate ${entry "installCodexCli"}
            test ! -e "$HOME/.local/bin/codex"
            deferred "Codex CLI not installed"
            noWarn

            echo "codex: an offline update is deferred and keeps the installed CLI"
            fresh codex-stale
            stub codex 'echo stale'
            activate ${entry "installCodexCli"}
            test "$("$HOME/.local/bin/codex")" = stale
            deferred "Codex CLI not updated"
            noWarn

            # The fetch returns a stand-in installer that records what the real one
            # would be run with.
            echo "codex: the installer runs unprompted, with ~/.local/bin on PATH"
            fresh codex-online
            curl() {
              printf '%s\n' \
                'printf "%s\n" "$PATH" > "$HOME/installer-path"' \
                'printf "%s\n" "''${CODEX_NON_INTERACTIVE-}" > "$HOME/installer-prompt"' \
                'touch "$HOME/.local/bin/codex" && chmod +x "$HOME/.local/bin/codex"'
            }
            export -f curl
            activate ${entry "installCodexCli"}
            offline
            test -x "$HOME/.local/bin/codex"
            case ":$(cat "$HOME/installer-path"):" in *":$HOME/.local/bin:"*) ;; *) exit 1 ;; esac
            test "$(cat "$HOME/installer-prompt")" = 1
            nothingDeferred
            noWarn

            touch $out
          '';

        # Both backup units must keep the escape hatch in both sections. Forced on,
        # or the units would not render and the check would pass vacuously. The state
        # sync also stands without the daily pass, its SessionEnd push follows it
        # (written while it is scheduled, absent while it is not), and the session
        # autosave is on by default with neither.
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
            syncOnly = self.nixosConfigurations.default.extendModules {
              modules = [
                {
                  flakelab = {
                    backupAutostart = nixpkgs.lib.mkForce false;
                    stateRoot = nixpkgs.lib.mkForce "/tmp/flakelab-check-state";
                    stateSyncInterval = nixpkgs.lib.mkForce "5min";
                  };
                }
              ];
            };
            hmSync = syncOnly.config.home-manager.users.${syncOnly.config.flakelab.username};
            plain = self.nixosConfigurations.default.config;
            hmPlain = plain.home-manager.users.${plain.flakelab.username};
            # Both halves: the command handed to jq, and the fragment that writes it.
            pushes =
              h:
              let
                inherit (h.home.activation.claudeSettings) data;
              in
              nixpkgs.lib.hasInfix "--no-block flakelab-state-sync.service" data
              && nixpkgs.lib.hasInfix "command: $push" data;
          in
          assert units.flakelab-backup.Unit."X-RestartIfChanged" == false;
          assert units.flakelab-backup.Service."X-RestartIfChanged" == false;
          assert units.flakelab-state-sync.Unit."X-RestartIfChanged" == false;
          assert units.flakelab-state-sync.Service."X-RestartIfChanged" == false;
          assert units.flakelab-state-sync.Service.Type == "oneshot";
          assert hm.systemd.user.timers.flakelab-state-sync.Timer.OnUnitActiveSec == "30min";
          assert hmSync.systemd.user.services ? flakelab-state-sync;
          assert !(hmSync.systemd.user.services ? flakelab-backup);
          assert !(hmSync.systemd.user.timers ? flakelab-backup);
          assert hmSync.systemd.user.timers.flakelab-state-sync.Timer.OnUnitActiveSec == "5min";
          assert pushes hmSync;
          assert !(pushes hmPlain);
          assert
            hmPlain.systemd.user.services.flakelab-sessions-autosave.Service."X-RestartIfChanged" == false;
          assert hmPlain.systemd.user.timers.flakelab-sessions-autosave.Timer.OnUnitActiveSec == "5min";
          pkgs.runCommandLocal "flakelab-check-state-sync-decouple" { } "touch $out";

        # The state root under Syncthing: stateRoot is the one folder, shared with the
        # hub under the password file, which a oneshot writes before syncthing-init reads it.
        state-syncthing =
          let
            box = self.nixosConfigurations.default.extendModules {
              modules = [
                {
                  flakelab = {
                    stateRoot = nixpkgs.lib.mkForce "/home/check/flakelab-state";
                    sopsSecretsFile = nixpkgs.lib.mkForce ./nix/secrets.nix;
                    stateSyncthing = {
                      hubDeviceId = "AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH";
                      hubName = "hub";
                      passwordEnvKey = "CHECK_STATE_PASSWORD";
                    };
                  };
                }
              ];
            };
            # configDir on a backup-excluded disk: made for the user, and waited for.
            offHome = box.extendModules {
              modules = [ { flakelab.stateSyncthing.configDir = "/var/lib/check-secrets/syncthing"; } ];
            };
            inherit (box.config.services) syncthing;
            folder = syncthing.settings.folders.flakelab-state;
            pw = box.config.systemd.services.flakelab-syncthing-password;
            plain = self.nixosConfigurations.default.config;
          in
          assert syncthing.enable;
          assert syncthing.user == plain.flakelab.username;
          assert syncthing.guiAddress == "127.0.0.1:8384";
          assert folder.path == "/home/check/flakelab-state";
          assert
            (builtins.head folder.devices).encryptionPasswordFile
            == "/run/flakelab-syncthing/flakelab-state.password";
          assert builtins.elem "syncthing-init.service" pw.requiredBy;
          assert builtins.elem "syncthing-init.service" pw.before;
          assert nixpkgs.lib.hasInfix "flakelab-syncthing-password-read /run/secrets/tyc-env" pw.script;
          assert !plain.services.syncthing.enable;
          assert
            syncthing.configDir
            == "${box.config.users.users.${plain.flakelab.username}.home}/.config/syncthing";
          assert offHome.config.services.syncthing.configDir == "/var/lib/check-secrets/syncthing";
          assert
            offHome.config.services.syncthing.databaseDir
            == "${box.config.users.users.${plain.flakelab.username}.home}/.local/state/syncthing";
          assert builtins.elem "d /var/lib/check-secrets/syncthing 0700 ${plain.flakelab.username} users -"
            offHome.config.systemd.tmpfiles.rules;
          assert builtins.elem "/var/lib/check-secrets/syncthing"
            offHome.config.systemd.services.syncthing.unitConfig.RequiresMountsFor;
          # The reader the unit runs, against a render shaped like sops writes it:
          # CRLF endings, a key that is a prefix of the wanted one, two definitions.
          pkgs.runCommandLocal "flakelab-check-state-syncthing"
            {
              inherit (pw) script;
              passAsFile = [ "script" ];
            }
            ''
              reader="$(grep -o '/nix/store/[^ ]*-flakelab-syncthing-password-read' "$scriptPath" | head -n 1)"
              printf 'OTHER=x\r\nCHECK_STATE_PASSWORD_OLD=stale\r\nCHECK_STATE_PASSWORD=first=value\r\nCHECK_STATE_PASSWORD=second\r\n' > render
              test "$("$reader" render)" = 'first=value'
              printf 'OTHER=x\n' > empty
              test -z "$("$reader" empty)"
              touch "$out"
            '';

        # A program's OSC 52 copy inside a nested tmux, the session on a box reached
        # over ssh from another tmux, lands in the outer tmux, which passes it on to
        # its terminal. With the default set-clipboard (external) both drop it.
        tmux-clipboard =
          let
            sys = self.nixosConfigurations.default.config;
            hm = sys.home-manager.users.${sys.flakelab.username};
            conf = hm.xdg.configFile."tmux/tmux.conf".source;
          in
          pkgs.runCommandLocal "flakelab-check-tmux-clipboard" { nativeBuildInputs = [ pkgs.tmux ]; } ''
            export HOME=$TMPDIR TMUX_TMPDIR=$TMPDIR
            inner="sleep 1; printf '\033]52;c;Y29waWVk\a'; sleep 30"
            tmux -L outer -f ${conf} new-session -d -x 120 -y 30 \
              "TERM=tmux-256color tmux -L inner -f ${conf} new-session \"$inner\""
            for _ in $(seq 100); do
              [ "$(tmux -L outer show-buffer 2>/dev/null)" = copied ] && break
              sleep 0.1
            done
            got="$(tmux -L outer show-buffer 2>/dev/null || true)"
            tmux -L inner kill-server 2>/dev/null || true
            tmux -L outer kill-server 2>/dev/null || true
            [ "$got" = copied ] || { echo "the copy never reached the outer tmux (got: '$got')"; exit 1; }
            touch $out
          '';

        # Keys, cleartext secrets and the backup payload live BESIDE the overlay: nix
        # copies the overlay directory whole into the world-readable store on every
        # command it is given, and no .gitignore stops that. The default has to stay
        # outside repoPath, and an overlay that points backupRoot back inside must
        # fail to evaluate rather than quietly undo it.
        payload-outside-overlay =
          let
            sys = self.nixosConfigurations.default;
            cfg = sys.config.flakelab;
            scriptsOf =
              c:
              import ./nix/scripts.nix {
                inherit (sys) pkgs;
                cfg = c;
              };
            inside = root: builtins.tryEval (scriptsOf (cfg // { backupRoot = root; })).nix-backup.drvPath;
          in
          assert !(inside "${cfg.repoPath}/files/config").success;
          assert !(inside cfg.repoPath).success;
          assert (inside "${cfg.repoPath}-elsewhere").success;
          pkgs.runCommandLocal "flakelab-check-payload-outside-overlay" { } ''
            grep -q '^export FLAKELAB_BACKUP_ROOT=${cfg.repoPath}-payload$' \
              ${(scriptsOf cfg).nix-backup}/bin/nix-backup
            touch $out
          '';

        # `flakelab clone` takes no options, and says so: an ignored --help started
        # the whole fetch-and-rebase sweep. Both shapes of the generated script, the
        # one with groups to sweep and the one with nothing configured.
        clone-args =
          let
            sys = self.nixosConfigurations.default;
            cfg = sys.config.flakelab;
            cloneOf =
              c:
              (import ./nix/scripts.nix {
                inherit (sys) pkgs;
                cfg = c;
              }).nix-clone-repos;
            withWork = cloneOf (cfg // { gitlabGroups = [ "example/group" ]; });
            withGithub = cloneOf (
              cfg
              // {
                cloneGithub = true;
                githubOwners = [ "example-owner" ];
              }
            );
            githubOff = cloneOf (cfg // { githubOwners = [ "example-owner" ]; });
            noWork = cloneOf (
              cfg
              // {
                gitlabGroups = [ ];
                repos = [ ];
              }
            );
          in
          pkgs.runCommandLocal "flakelab-check-clone-args" { } ''
            for s in ${withWork}/bin/nix-clone-repos ${withGithub}/bin/nix-clone-repos ${githubOff}/bin/nix-clone-repos ${noWork}/bin/nix-clone-repos; do
              "$s" --help > out
              grep -q '^Usage: flakelab clone$' out
              rc=0
              "$s" --dry-run 2> err || rc=$?
              test "$rc" = 2
              grep -q "takes no arguments (got '--dry-run')" err
            done
            grep -q 'gh-repos --owner example-owner' ${withGithub}/bin/nix-clone-repos
            ! grep -q 'gh-repos' ${githubOff}/bin/nix-clone-repos
            touch $out
          '';

        # The auto-switch timer is tycswap's `tycswap auto --once` on a user timer,
        # present only when an interval is set and the binary is installed; the
        # quota hook follows the same switch. The global compinit stays off
        # (oh-my-zsh runs one).
        tycswap-timer =
          let
            inherit (nixpkgs) lib;
            ext =
              attrs: self.nixosConfigurations.default.extendModules { modules = [ { flakelab = attrs; } ]; };
            hmOf = sys: sys.config.home-manager.users.${sys.config.flakelab.username};
            timersOf = sys: (hmOf sys).systemd.user.timers;
            settingsOf = sys: (hmOf sys).home.activation.claudeSettings.data;
            doctorOf =
              sys:
              (import ./nix/scripts.nix {
                inherit (sys) pkgs;
                cfg = sys.config.flakelab;
              }).nix-doctor;
            on = ext { tycswapAutoSwitchInterval = "5min"; };
            bad = ext {
              installTycswap = false;
              tycswapAutoSwitchInterval = "2min";
            };
            # A statusline is rendered only with a statusbar plugin; this system has one.
            statusline = ext {
              claudePluginMarketplaces = [
                {
                  name = "tools";
                  url = "https://example.invalid/tools.git";
                }
              ];
              claudePlugins = [ "statusbar@tools" ];
            };
          in
          assert
            !(builtins.hasAttr "flakelab-tycswap-autoswitch" (timersOf self.nixosConfigurations.default));
          assert (timersOf on).flakelab-tycswap-autoswitch.Timer.OnUnitActiveSec == "5min";
          assert
            builtins.match ".*/bin/(cswap|tycswap) auto --once --json" (
              lib.concatStringsSep " " (
                lib.toList (hmOf on).systemd.user.services.flakelab-tycswap-autoswitch.Service.ExecStart
              )
            ) != null;
          assert lib.any (a: !a.assertion && lib.hasInfix "tycswapAutoSwitchInterval" a.message)
            (hmOf bad).assertions;
          assert lib.hasInfix "--arg tycswapHook" (settingsOf on);
          assert !(lib.hasInfix "--arg tycswapHook" (settingsOf self.nixosConfigurations.default));
          assert lib.hasInfix "-accounts/bin/accounts auto " (settingsOf on);
          # The statusline is the plugin command itself: the retired tee was a store
          # script whose text (and its accounts ingest) the activation never carried.
          assert lib.hasInfix "statusline-command.sh" (settingsOf statusline);
          assert !self.nixosConfigurations.default.config.programs.zsh.enableGlobalCompInit;
          pkgs.runCommandLocal "flakelab-check-tycswap-timer" { } ''
            grep -q '^export FLAKELAB_TYCSWAP_AUTOSWITCH=false$' ${doctorOf self.nixosConfigurations.default}/bin/nix-doctor
            grep -q '^export FLAKELAB_TYCSWAP_AUTOSWITCH=true$' ${doctorOf on}/bin/nix-doctor
            grep -q '^export FLAKELAB_INSTALL_TYCSWAP=true$' ${doctorOf on}/bin/nix-doctor
            touch $out
          '';

        # The prompt's git segment is oh-my-zsh's git_prompt_info, which a theme
        # colours: rendered here with the configured one (synchronously; the prompt
        # itself fills it in asynchronously). An overlay's theme still wins.
        zsh-git-prompt =
          let
            hmOf = sys: sys.config.home-manager.users.${sys.config.flakelab.username};
            omz = (hmOf self.nixosConfigurations.default).programs.zsh.oh-my-zsh;
            other = self.nixosConfigurations.default.extendModules {
              modules = [ { home-manager.sharedModules = [ { programs.zsh.oh-my-zsh.theme = "agnoster"; } ]; } ];
            };
          in
          assert (hmOf other).programs.zsh.oh-my-zsh.theme == "agnoster";
          pkgs.runCommandLocal "flakelab-check-zsh-git-prompt"
            {
              nativeBuildInputs = [
                pkgs.zsh
                pkgs.git
              ];
            }
            ''
              export HOME=$TMPDIR
              git init -q -b main "$TMPDIR/repo"
              cd "$TMPDIR/repo"
              got="$(ZSH=${omz.package}/share/oh-my-zsh ZSH_THEME=${omz.theme} zsh -fc '
                DISABLE_AUTO_UPDATE=true ZSH_DISABLE_COMPFIX=true ZSH_CACHE_DIR=$TMPDIR/omz
                zstyle ":omz:alpha:lib:git" async-prompt no
                source $ZSH/oh-my-zsh.sh
                print -rn -- "$(git_prompt_info)"')"
              case "$got" in *'git:('*main*) ;; *) echo "no git segment: '$got'"; exit 1 ;; esac
              case "$got" in *'%{'*) ;; *) echo "the git segment is uncoloured: '$got'"; exit 1 ;; esac
              touch $out
            '';

        # `gh auth login` and `glab auth login` cannot write their credential helper
        # into a store link, so git-ssh.nix declares it. Read back through git, because
        # the shape is the point: the empty value has to come first or it resets the
        # forge helper too, and without it a general credential.helper is handed the
        # forge token to keep.
        forge-credential-helper =
          let
            sys = self.nixosConfigurations.default.config;
            hm = sys.home-manager.users.${sys.flakelab.username};
            rendered = hm.xdg.configFile."git/config".source;
          in
          pkgs.runCommandLocal "flakelab-check-forge-credential-helper" { nativeBuildInputs = [ pkgs.git ]; }
            ''
              for pair in github.com=gh gist.github.com=gh gitlab.com=glab; do
                host="https://''${pair%=*}" tool="''${pair#*=}"
                got="$(git config --file ${rendered} --get-all "credential.$host.helper")"
                exe="''${got#$'\n'!}"
                exe="''${exe% auth git-credential}"
                if [ "$got" != $'\n'"!$exe auth git-credential" ] \
                  || [ "''${exe##*/}" != "$tool" ] || [ ! -x "$exe" ]; then
                  echo "credential.$host.helper is not [empty, !<store $tool> auth git-credential]:" >&2
                  printf '%s\n' "$got" >&2
                  exit 1
                fi
              done
              touch $out
            '';

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
