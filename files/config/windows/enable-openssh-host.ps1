# Remote access via OpenSSH on the Windows host, WireGuard only: NixOS-WSL forces the distro firewall off.
$WgSubnet = "10.66.0.0/24"   # the WireGuard network the host is on
$Distro   = "NixOS"          # `flakelab distro-name` inside WSL prints it

# 1. The server, started at boot.
if ((Get-WindowsCapability -Online -Name 'OpenSSH.Server*').State -ne 'Installed') {
  Add-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0'
}
Set-Service -Name sshd -StartupType Automatic
Start-Service sshd

# 2. Port 22 from the tunnel only; the capability's own rule allows every network.
Get-NetFirewallRule -DisplayName 'OpenSSH SSH Server (sshd)' -ErrorAction SilentlyContinue | Disable-NetFirewallRule
if (-not (Get-NetFirewallRule -Name 'flakelab-sshd-wireguard' -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name 'flakelab-sshd-wireguard' -DisplayName 'OpenSSH Server (WireGuard only)' `
    -Direction Inbound -Protocol TCP -LocalPort 22 -RemoteAddress $WgSubnet -Action Allow -Profile Any
}

# 3. Keys only. An administrator's keys live in the machine-wide file, not ~/.ssh/authorized_keys.
$AuthKeys = "$env:ProgramData\ssh\administrators_authorized_keys"
if (-not (Test-Path $AuthKeys)) { New-Item -ItemType File -Path $AuthKeys | Out-Null }
# Paste the phone's / laptop's public key into $AuthKeys, then:
icacls $AuthKeys /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" | Out-Null
$Cfg = "$env:ProgramData\ssh\sshd_config"
$Text = Get-Content $Cfg -Raw
if ($Text -notmatch '(?m)^PasswordAuthentication no') { Add-Content $Cfg "`nPasswordAuthentication no" }
if ($Text -notmatch '(?m)^PubkeyAuthentication yes')  { Add-Content $Cfg "`nPubkeyAuthentication yes" }
Restart-Service sshd
