## Provisioning

Proxmox guest: no Windows mounts or WSL provisioning commands. Rebuild through
`flakelab update`; never reboot from an agent session. For seed bootstrap
failures, read `journalctl -u flakelab-bootstrap` and the flakelab README.
