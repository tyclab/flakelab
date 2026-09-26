# The browser front end (remote-sessions.md): `flakelab web`, the dashboard
# over the accounts and the sessions, and ttyd, a terminal in a browser tab
# attached to the `agents` tmux session. Both are user services. The
# dashboard binds the address flakelab.web.bind names (127.0.0.1 unless it
# is the box's WireGuard address) and holds the one token; ttyd listens on a
# Unix socket in the runtime directory with no credential of its own, and
# the dashboard is its only door: /terminal/ is tunnelled to it for a browser
# holding a session the API issued against the token. Nothing carries the
# token on a command line, and `flakelab web --rotate-token` replaces it
# with no restart. Off unless flakelab.web.enable; the terminal off unless
# flakelab.web.terminal too.
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
  # %t is the user's runtime directory; the socket sits in a 0700 directory
  # of its own there.
  socketDir = "%t/flakelab";
  socket = "${socketDir}/ttyd.sock";
  neverRestartedByActivation = {
    Unit."X-RestartIfChanged" = false;
    Service."X-RestartIfChanged" = false;
  };
  # The entrypoint attaches the agents session (creating it when absent),
  # never a bare shell. -b puts ttyd's page and its WebSocket under
  # /terminal, where the dashboard tunnels; -W makes the terminal writable.
  ttydStart = pkgs.writeShellScript "flakelab-ttyd" ''
    exec ${pkgs.ttyd}/bin/ttyd -i "$1" -b /terminal -W -t titleFixed=agents \
      ${pkgs.tmux}/bin/tmux new-session -A -s ${lib.escapeShellArg cfg.web.tmuxSession}
  '';
in
{
  assertions = [
    {
      assertion =
        !web
        || !(builtins.elem cfg.web.bind [
          "0.0.0.0"
          "::"
          "*"
          "0"
          ""
        ]);
      message = "flakelab.web.bind must name one address (127.0.0.1 or the box's WireGuard address), never every interface";
    }
  ];

  systemd.user.services =
    lib.optionalAttrs web {
      flakelab-web = lib.recursiveUpdate neverRestartedByActivation {
        Unit.Description = "flakelab: the dashboard on ${cfg.web.bind}:${toString cfg.web.port}";
        Service = {
          ExecStart =
            "${scripts.web}/bin/web --bind ${lib.escapeShellArg cfg.web.bind} --port ${toString cfg.web.port}"
            + lib.optionalString terminal " --terminal-socket ${socket}";
          Restart = "on-failure";
          RestartSec = "5s";
        };
        Install.WantedBy = [ "default.target" ];
      };
    }
    // lib.optionalAttrs terminal {
      flakelab-ttyd = lib.recursiveUpdate neverRestartedByActivation {
        Unit = {
          Description = "flakelab: a browser terminal on the agents tmux session, behind the dashboard";
          After = [ "flakelab-web.service" ];
          Wants = [ "flakelab-web.service" ];
        };
        Service = {
          ExecStart = "${ttydStart} ${socket}";
          RuntimeDirectory = "flakelab";
          RuntimeDirectoryMode = "0700";
          RuntimeDirectoryPreserve = true;
          UMask = "0077";
          Restart = "on-failure";
          RestartSec = "5s";
        };
        Install.WantedBy = [ "default.target" ];
      };
    };
}
