This is a Proxmox guest: no Windows mount, cloud-init set the hostname and network at boot, and qemu-guest-agent talks to the hypervisor.

## Provisioning

There is no host-side provisioning script here — rebuild this box with `flakelab update`. The WSL-only verbs (`provision`, `build-distro`, `test-provision`, `distro-name`) are not on `flakelab --help`; nothing here needs them. Reboots are the operator's call, same as on any other machine.
