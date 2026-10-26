# Home Manager entrypoint: imports the section modules and computes only what more
# than one of them shares, handed over via _module.args.flakelab.
# Everything derives from `osConfig`, never this module's own `config`, so the args
# passing cannot recurse - which ties these modules to home-manager-as-NixOS-module.
{
  lib,
  pkgs,
  osConfig,
  ...
}:
let
  cfg = osConfig.flakelab;

  # Installers are warn-not-fail, so they record too and the health check can act.
  # warnLog is a logic failure and fails the rebuild; deferredLog is work activation
  # structurally cannot do (network, locked agent) and is never fatal.
  stateDir = "$HOME/.local/state/flakelab";
  warnLog = "${stateDir}/activation-failures";
  deferredLog = "${stateDir}/activation-deferred";
  # The explicit `exit 0` is load-bearing: call sites are `cmd || flakelab-warn …`
  # under `set -e`, so failing here would abort activation with no message at all.
  mkReporter =
    name: log: prefix:
    pkgs.writeShellScript name ''
      set -uo pipefail
      export PATH="${lib.makeBinPath [ pkgs.coreutils ]}:$PATH"
      mkdir -p "$(dirname "${log}")" || true
      printf '%s%s\n' '${prefix}' "$*" >&2
      printf '%s\n' "$*" >> "${log}" || true
      exit 0
    '';
  flakelabWarn = mkReporter "flakelab-warn" warnLog "WARNING: ";
  flakelabDefer = mkReporter "flakelab-defer" deferredLog "DEFERRED: ";

  # A step that merges into a map of a file the user and the tool also write
  # records the key names it wrote there, never the values (env values can be
  # secrets). A name in the last record and not in this render is flakelab's to
  # remove; a name never recorded belongs to someone else and is left alone.
  # `load` sets _prev, [] when there is no readable record; `save` runs only
  # after the file was written, so a failed merge keeps the names for the next.
  renderedDir = "${stateDir}/activation-rendered";
  renderedRecord =
    name: target: keys:
    let
      record = "${renderedDir}/${name}.json";
      names = pkgs.writeText "flakelab-rendered-${name}.json" (builtins.toJSON keys);
    in
    {
      load = ''
        _prev="$(${pkgs.jq}/bin/jq -cs 'if length == 1 and (.[0] | type) == "array" then .[0] | map(strings) else error end' "${record}" 2>/dev/null)" || _prev='[]'
      '';
      save = ''
        { $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -d -m700 "${renderedDir}" \
            && $DRY_RUN_CMD ${pkgs.coreutils}/bin/install -m600 ${names} "${record}"; } || \
          ${flakelabWarn} "could not record the keys flakelab wrote to ${target} in ${record}."
      '';
    };

  # The activation unit has no SSH_AUTH_SOCK: use the user agent socket and record whether it holds a key.
  sshAgentPreamble = ''
    if [ -z "''${SSH_AUTH_SOCK:-}" ] && [ -S "/run/user/$(id -u)/ssh-agent" ]; then
      export SSH_AUTH_SOCK="/run/user/$(id -u)/ssh-agent"
    fi
    # 0 = no usable agent, so an SSH failure below is expected, not a defect.
    _sshReady=0
    if [ -n "''${SSH_AUTH_SOCK:-}" ] && ssh-add -l >/dev/null 2>&1; then
      _sshReady=1
    fi
  '';
  sshDefer = what: "${flakelabDefer} ${lib.escapeShellArg what}";

  inherit (cfg) sshKeys;
  # The clone identity, shared with the `flakelab clone` wrapper (nix/clone-key.nix).
  cloneKeyResolve = import ../clone-key.nix { inherit lib sshKeys; };

  # Activation must never restart the user units the modules below declare: it
  # would block on a running pass until home-manager times out, or kill a sync
  # mid-copy. Both sections, because sd-switch reads [Unit] and
  # switch-to-configuration reads [Service].
  neverRestartedByActivation = {
    Unit."X-RestartIfChanged" = false;
    Service."X-RestartIfChanged" = false;
  };

  # The one target fact the home modules need: whether there is a Windows side.
  isWsl = cfg.target == "wsl";

  inherit (cfg) installClaude installCodex;

  # One rule set for both agents: Claude Code reads ~/.claude/CLAUDE.md, Codex
  # ~/.codex/AGENTS.md, and neither reads the other's user-level file. Codex leaves
  # out the Claude-only permission tiers and the question-tool text, which
  # nix/codex-config.nix already puts in its developer_instructions.
  agentInstructions =
    let
      read = f: builtins.readFile ../../files/config/${f};
      target = read "claude/target-${cfg.target}.md";
      # Newline-terminated, or the END marker lands on the last line of the extra text.
      extra = lib.optionalString (cfg.claudeMdExtra != "") (
        "\n" + lib.removeSuffix "\n" cfg.claudeMdExtra + "\n"
      );
    in
    {
      claude = pkgs.writeText "claude-md-managed.md" (
        read "agent-instructions.md"
        + lib.optionalString cfg.questions.enable (read "question-instructions.md")
        + "\n"
        + target
        + "\n"
        + read "claude/auto-mode.md"
        + extra
      );
      codex = pkgs.writeText "codex-agents-md-managed.md" (
        read "agent-instructions.md" + "\n" + target + extra
      );
    };

  # A marker block, not a home.file: the tools and the user write these files too,
  # and anything outside the markers survives. Rewritten every activation. Every
  # failure is a warning, never an abort: activation runs under `set -e`, and a
  # store link (a home.file for the same path) must not stop the rest of it.
  writeManagedBlock = target: body: ''
    export PATH="${
      lib.makeBinPath [
        pkgs.gawk
        pkgs.coreutils
      ]
    }:$PATH"
    _md=${target}
    _tmp="$(mktemp)"
    if [ -L "$_md" ] && case "$(readlink -f "$_md")" in /nix/store/*) true ;; *) false ;; esac; then
      ${flakelabWarn} "$_md links into the Nix store, so another module owns it; the flakelab block is not written there."
    elif { [ ! -e "$_md" ] || awk '
        index($0, "<!-- BEGIN managed by flakelab -->") == 1 { skip = 1 }
        skip != 1 { print }
        index($0, "<!-- END managed by flakelab -->") == 1 { skip = 0 }
      ' "$_md" > "$_tmp"; } \
      && {
        cat "$_tmp"
        echo '<!-- BEGIN managed by flakelab -->'
        cat ${body}
        echo '<!-- END managed by flakelab -->'
      } > "$_tmp.new" \
      && $DRY_RUN_CMD mkdir -p -m 700 "$(dirname "$_md")" \
      && $DRY_RUN_CMD install -m644 "$_tmp.new" "$_md"; then
      :
    else
      ${flakelabWarn} "could not refresh the managed block in $_md."
    fi
    rm -f "$_tmp" "$_tmp.new"
  '';
in
{
  imports = [
    ./packages.nix
    ./zsh.nix
    ./backup.nix
    ./git-ssh.nix
    ./claude.nix
    ./codex.nix
    ./prune.nix
    ./tycswap.nix
    ./web.nix
    ./tooling.nix
    ./health.nix
  ];

  _module.args.flakelab = {
    inherit
      stateDir
      warnLog
      deferredLog
      flakelabWarn
      flakelabDefer
      renderedRecord
      sshAgentPreamble
      sshDefer
      isWsl
      sshKeys
      cloneKeyResolve
      neverRestartedByActivation
      installClaude
      installCodex
      agentInstructions
      writeManagedBlock
      ;
  };

  programs.home-manager.enable = true;
}
