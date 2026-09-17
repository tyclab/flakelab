This is a WSL2 distro: Windows drives are mounted at `/mnt/c/`, `/mnt/d/`.
`xdg-open <url|path>` opens the target in the Windows default browser or app, and `BROWSER` names the same command; there is no Linux browser to launch.

## Provisioning

`flakelab build-distro` and `flakelab test-provision` drive distro lifecycle from the host side and wipe host WSLInterop.
Never run them from a session that needs interop, and never run `wsl --shutdown` or `wsl --terminate`: they end every session in the distro or the VM.
