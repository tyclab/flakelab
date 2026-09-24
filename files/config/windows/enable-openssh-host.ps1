# Reach a WSL distro from another machine (remote-sessions.md, phase 4).
#
# Nothing runs inside the distro: NixOS-WSL forces the firewall off and a
# NAT'd distro is reachable from the LAN only through the host anyway. The
# clean route is OpenSSH Server on the Windows host, listening on the
# WireGuard address only, and a login that lands in the distro. Run once in
# an elevated PowerShell; every line is idempotent.
#
# Then, from any SSH client on the tunnel (a phone included):
#   ssh <user>@<host's WireGuard address> -t wsl.exe -d <distro> -- zsh -lc "flakelab sessions --attach"
# or make that the account's shell for good (last block).

$WgSubnet = "10.66.0.0/24"   # the WireGuard network the host is on
$Distro   = "NixOS"          # `flakelab distro-name` inside WSL prints it

# 1. The server, started at boot.
if ((Get-WindowsCapability -Online -Name 'OpenSSH.Server*').State -ne 'Installed') {
  Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
}
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd

# 2. The firewall: port 22 from the tunnel only. The capability's own rule
#    ("OpenSSH SSH Server (sshd)") allows every network; disable it.
Get-NetFirewallRule -DisplayName 'OpenSSH SSH Server (sshd)' -ErrorAction SilentlyContinue | Disable-NetFirewallRule
if (-not (Get-NetFirewallRule -Name 'flakelab-sshd-wireguard' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name 'flakelab-sshd-wireguard' -DisplayName 'OpenSSH Server (WireGuard only)' `
    -Direction Inbound -Protocol TCP -LocalPort 22 -RemoteAddress $WgSubnet -Action Allow -Profile Any
}

# 3. Keys only. An administrator's keys live in the machine-wide file, not in
#    ~/.ssh/authorized_keys (the sshd_config Windows ships says so).
$AuthKeys = "$env:ProgramData\ssh\administrators_authorized_keys"
if (-not (Test-Path $AuthKeys)) { New-Item -ItemType File -Path $AuthKeys | Out-Null }
# Paste the phone's / laptop's public key into $AuthKeys, then:
icacls $AuthKeys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" | Out-Null
$Cfg = "$env:ProgramData\ssh\sshd_config"
$Text = Get-Content $Cfg -Raw
if ($Text -notmatch '(?m)^PasswordAuthentication no') { Add-Content $Cfg "`nPasswordAuthentication no" }
if ($Text -notmatch '(?m)^PubkeyAuthentication yes')  { Add-Content $Cfg "`nPubkeyAuthentication yes" }
Restart-Service sshd

# 4. Optional: land in the distro's shell on every login instead of cmd.exe.
#    (Per user; `ssh host` then is a Linux shell, and `-t wsl.exe ...` is not needed.)
# New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShell -PropertyType String -Force `
#   -Value 'C:\Windows\System32\wsl.exe'
# New-ItemProperty -Path 'HKLM:\SOFTWARE\OpenSSH' -Name DefaultShellCommandOption -PropertyType String -Force `
#   -Value "-d $Distro --"
