## Provisioning

WSL2: Windows drives are under `/mnt/c/` and `/mnt/d/`. Use `xdg-open`/`BROWSER`
for browser/OAuth flows; never `--no-browser`, `wsl --shutdown` or `wsl --terminate`.
Distro lifecycle tests (`build-distro`, `test-provision`) run host-side in
expendable sessions, never one needing interop. See `known-issues.md`.
