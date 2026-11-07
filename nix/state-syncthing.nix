# The state root replicated by Syncthing through one untrusted hub (options.nix
# stateSyncthing). Null contributes nothing. The box holds plaintext; the hub
# holds the folder Receive Encrypted, so it never gets the password. An optional
# trustedHub gets the folder without the password, so it holds plaintext too.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.flakelab;
  st = cfg.stateSyncthing;
  trusted = st.trustedHub;
  home = config.users.users.${cfg.username}.home;
  secretDir = "/run/flakelab-syncthing";
  passwordFile = "${secretDir}/${st.folderId}.password";
  configDir = if st.configDir != null then st.configDir else "${home}/.config/syncthing";
  # The one line that reads the password out of the render, as a script of its
  # own so checks.state-syncthing can run it against a fixture: the first
  # `KEY=` line wins, a CR from a CRLF file is dropped, and the key is literal in
  # the pattern because its option type allows an identifier only.
  readPassword = pkgs.writeShellScript "flakelab-syncthing-password-read" ''
    sed -n 's/^${st.passwordEnvKey}=//p' "$1" | tr -d '\r' | head -n 1
  '';
  # What only the transcript sync writes (files/scripts/lib/state-sync.zsh): a
  # session's transcript and its <session uuid>/ folder of subagent transcripts
  # and tool results, both beside the memory/ and memory-tombstones/ the same
  # project slug holds, plus the parked branches and the Codex sessions. (?d)
  # lets Syncthing remove a leftover that alone keeps a folder another box
  # deleted from going here too.
  transcriptIgnores = [
    "// flakelab: stateTranscripts is off on this box. syncthing-init rewrites this file."
    "(?d)/claude/projects/*/*.jsonl"
    "(?d)/claude/projects/*/????????-????-????-????-????????????"
    "(?d)/claude/diverged"
    "(?d)/codex/sessions"
    "(?d)/codex/diverged"
  ];
in
{
  config = lib.mkIf (st != null) {
    assertions = [
      {
        assertion = cfg.stateRoot != null && !(lib.hasPrefix "/mnt/" cfg.stateRoot);
        message = "flakelab.stateSyncthing needs stateRoot on a Linux path: Syncthing's watcher and its temp files do not work on a /mnt Windows mount.";
      }
      {
        assertion = cfg.sopsSecretsFile != null;
        message = "flakelab.stateSyncthing reads the folder password from the sops render: set sopsSecretsFile.";
      }
      {
        assertion = trusted == null || (trusted.name != st.hubName && trusted.deviceId != st.hubDeviceId);
        message = "flakelab.stateSyncthing.trustedHub needs a name and device ID other than the hub's (hubName, hubDeviceId): the plaintext replica must be a device of its own.";
      }
    ];

    services.syncthing = {
      enable = true;
      user = cfg.username;
      group = "users";
      dataDir = home;
      inherit configDir;
      # The index database is large and not secret: it stays in the home even when
      # configDir sits on a small key-only disk.
      databaseDir = "${home}/.local/state/syncthing";
      inherit (st) guiAddress;
      openDefaultPorts = false;
      # The declared hub and folder are the whole config: a device or folder added
      # in the GUI is dropped at the next start.
      overrideDevices = true;
      overrideFolders = true;
      settings = {
        options.urAccepted = -1;
        devices = {
          ${st.hubName} = {
            id = st.hubDeviceId;
            addresses = st.hubAddresses;
          };
        }
        // lib.optionalAttrs (trusted != null) {
          ${trusted.name} = {
            id = trusted.deviceId;
            inherit (trusted) addresses;
          };
        };
        folders.${st.folderId} = {
          path = cfg.stateRoot;
          # The hub gets ciphertext under the password. The trusted device gets plaintext
          # and goes in as a bare name: an attrset entry would carry the submodule's
          # encryptionPasswordFile = null, which syncthing-init fails to render.
          devices = [
            {
              name = st.hubName;
              encryptionPasswordFile = passwordFile;
            }
          ]
          ++ lib.optional (trusted != null) trusted.name;
          # A box without stateTranscripts never reads the transcript trees, so they
          # stay off its disk. Never null, which syncthing-init would skip: with
          # transcripts on it posts an empty list, and Syncthing deletes .stignore.
          ignorePatterns = lib.optionals (!cfg.stateTranscripts) transcriptIgnores;
        };
      };
    };

    # A configDir off the home (a backup-excluded disk) is made for the user, and both
    # services wait for its mount rather than write the key onto the disk beneath.
    systemd.tmpfiles.rules = lib.mkIf (st.configDir != null) [
      "d ${configDir} 0700 ${cfg.username} users -"
    ];
    systemd.services.syncthing.unitConfig.RequiresMountsFor = [ configDir ];
    systemd.services.syncthing-init.unitConfig.RequiresMountsFor = [ configDir ];

    # syncthing-init reads the password with jq --rawfile, so it must be one line with
    # no newline, readable by the user it runs as, and in place before it starts.
    systemd.services.flakelab-syncthing-password = {
      description = "flakelab: the state-root folder password for syncthing-init";
      after = [ "sops-install-secrets.service" ];
      wants = [ "sops-install-secrets.service" ];
      before = [ "syncthing-init.service" ];
      requiredBy = [ "syncthing-init.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
      };
      path = [
        pkgs.coreutils
        pkgs.gnused
      ];
      script = ''
        value="$(${readPassword} /run/secrets/flakelab-env)"
        if [ -z "$value" ]; then
          echo "${st.passwordEnvKey} is missing from /run/secrets/flakelab-env: seal it into the overlay's secrets file first" >&2
          exit 1
        fi
        install -d -m 0700 -o ${cfg.username} -g users ${secretDir}
        printf '%s' "$value" > ${passwordFile}.new
        chown ${cfg.username}:users ${passwordFile}.new
        chmod 0400 ${passwordFile}.new
        mv -f ${passwordFile}.new ${passwordFile}
      '';
    };
  };
}
