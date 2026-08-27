This is a WSL2 distro: Windows drives are mounted at `/mnt/c/`, `/mnt/d/`.

## Provisioning

`flakelab build-distro` and `flakelab test-provision` drive distro lifecycle from the host side and wipe host WSLInterop.
Never run them from a session that needs interop, and never run `wsl --shutdown` or `wsl --terminate` — hand back to the operator.
