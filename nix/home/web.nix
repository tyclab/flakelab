# The browser front end (remote-sessions.md): `flakelab web`, the dashboard
# over the accounts and the sessions, and ttyd, a terminal in a browser tab
# attached to the `agents` tmux session. Both are user services, bound to the
# address flakelab.web.bind names (127.0.0.1 unless it is the box's WireGuard
# address), and both are behind the same token: the dashboard as a bearer,
# ttyd as basic auth (user `flakelab`, the token as the password). Off unless
# flakelab.web.enable; the terminal off unless flakelab.web.terminal too.
{
  lib,
  pkgs,
  osConfig,
  ...
}:
let
  cfg = osConfig.flakelab;
  scripts = import ../scripts.nix { inherit pkgs cfg; };
  web = cfg.web.enable;
  terminal = cfg.web.enable && cfg.web.terminal;
  tokenFile = "%h/.local/state/flakelab/web/token";
  terminalUrl = "http://${cfg.web.bind}:${toString cfg.web.terminalPort}/";
  neverRestartedByActivation = {
    Unit."X-RestartIfChanged" = false;
    Service."X-RestartIfChanged" = false;
  };
  # ttyd takes its credential on the command line only; the token file is
  # read at start, so the same token opens both. The entrypoint attaches the
  # agents session (creating it when absent), never a bare shell.
  ttydStart = pkgs.writeShellScript "flakelab-ttyd" ''
    tok="$(cat "$1")" || exit 1
    exec ${pkgs.ttyd}/bin/ttyd -i ${lib.escapeShellArg cfg.web.bind} -p ${toString cfg.web.terminalPort} \
      -W -c "flakelab:$tok" -t titleFixed=agents \
      ${pkgs.tmux}/bin/tmux new-session -A -s ${lib.escapeShellArg cfg.web.tmuxSession}
  '';
in
{
  systemd.user.services = lib.optionalAttrs web {
    flakelab-web = lib.recursiveUpdate neverRestartedByActivation {
      Unit.Description = "flakelab: the dashboard on ${cfg.web.bind}:${toString cfg.web.port}";
      Service = {
        ExecStart = "${scripts.web}/bin/web --bind ${lib.escapeShellArg cfg.web.bind} --port ${toString cfg.web.port}"
          + lib.optionalString terminal " --terminal-url ${lib.escapeShellArg terminalUrl}";
        Restart = "on-failure";
        RestartSec = "5s";
      };
      Install.WantedBy = [ "default.target" ];
    };
  }
  // lib.optionalAttrs terminal {
    flakelab-ttyd = lib.recursiveUpdate neverRestartedByActivation {
      Unit = {
        Description = "flakelab: a browser terminal on the agents tmux session, ${cfg.web.bind}:${toString cfg.web.terminalPort}";
        # The dashboard makes the token on its first start.
        After = [ "flakelab-web.service" ];
        Wants = [ "flakelab-web.service" ];
      };
      Service = {
        ExecStart = "${ttydStart} ${tokenFile}";
        Restart = "on-failure";
        RestartSec = "5s";
      };
      Install.WantedBy = [ "default.target" ];
    };
  };
}
