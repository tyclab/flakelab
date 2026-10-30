#Requires -Version 5.1
<#
  The Windows side of `flakelab tray` (files/scripts/nix-tycswap-tray), run by
  PowerShell straight from the nix store over \\wsl.localhost, as the logged-in
  user, without elevation. It owns three things, each read back before it is
  touched, so a second run changes nothing:

  - %LOCALAPPDATA%\Programs\tycswap\tycswap.exe is the exe the flake pins (-Exe),
    byte for byte: a different one is renamed to .old (a running exe can be
    renamed, not overwritten) and the pin copied in. The tray itself runs with
    --no-update-check; the distro's binary follows the same pin.
  - The scheduled task io.github.tyclab.tycswap.remote starts at the user's
    logon, at once rather than from Explorer's startup queue, which runs the Run
    key entries one by one half a minute apart. Its first action starts the
    distro (conhost --headless keeps the console window off the screen), so the
    flakelab-tycswap-app service is up before the first terminal; its second is
    the tray. A failed action does not stop the next; a crashed tray is restarted
    three times a minute apart; the Task Scheduler service is the parent, so
    nothing in the tray's lineage belongs to WSL and `wsl --shutdown` cannot end
    it. The Run key value an earlier `--autostart on` wrote is removed: two
    starts would race for the tray's single-instance lock.
  - The tray runs: when no tycswap.exe from that path is running, the task is
    started, which is the same start a logon gets.

  -Mode status reports the three and changes nothing; it exits 1 when sync has
  work to do, which is what `flakelab doctor` reads. -DryRun with sync prints
  what would change.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Exe,
  [Parameter(Mandatory = $true)][string]$Version,
  [Parameter(Mandatory = $true)][int]$Port,
  [Parameter(Mandatory = $true)][string]$Token,
  [Parameter(Mandatory = $true)][string]$Distro,
  [ValidateSet('sync', 'status')][string]$Mode = 'sync',
  [switch]$DryRun
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$TaskName = 'io.github.tyclab.tycswap.remote'
$RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValue = 'io.github.tyclab.tycswap.remote'
if (-not $env:LOCALAPPDATA) { throw 'LOCALAPPDATA is not set; this must run as the logged-in user' }
$Dir = Join-Path $env:LOCALAPPDATA 'Programs\tycswap'
$Dest = Join-Path $Dir 'tycswap.exe'
$Old = "$Dest.old"
$Base = "http://127.0.0.1:$Port"
$TrayArgs = "app --remote $Base --token-file `"$Token`" --no-update-check"
$Conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
$WslArgs = "--headless `"$(Join-Path $env:SystemRoot 'System32\wsl.exe')`" -d $Distro --exec /run/current-system/sw/bin/true"
$User = "$env:USERDOMAIN\$env:USERNAME"

$Apply = ($Mode -eq 'sync') -and -not $DryRun
$script:Drift = 0
function Say([string]$line) { Write-Output "tray: $line" }
# Off: a fact sync will change. Prefixed by what this run does about it.
function Off([string]$what) {
  $script:Drift++
  if ($Mode -eq 'status') { Say "off: $what" } elseif ($DryRun) { Say "would $what" } else { Say $what }
}

function Running {
  @(Get-Process -Name tycswap -ErrorAction SilentlyContinue | Where-Object {
    try { $_.Path -eq $Dest } catch { $false }
  })
}

# 1. The exe.
$have = $null
if (Test-Path -LiteralPath $Dest) { $have = (Get-FileHash -LiteralPath $Dest -Algorithm SHA256).Hash }
if (-not (Test-Path -LiteralPath $Exe)) { throw "the pinned exe is not reachable from Windows: $Exe" }
$want = (Get-FileHash -LiteralPath $Exe -Algorithm SHA256).Hash
if ($have -eq $want) {
  Say "exe: tycswap $Version at $Dest"
} else {
  if ($have) { Off "install tycswap $Version over the exe at $Dest (a different build)" }
  else { Off "install tycswap $Version at $Dest (none there)" }
  if ($Apply) {
    $procs = @(Running)
    foreach ($p in $procs) { Stop-Process -Id $p.Id -Force; Say "stopped the running tray (pid $($p.Id)) for the install" }
    if ($procs.Count -gt 0) { Start-Sleep -Seconds 1 }
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    if (Test-Path -LiteralPath $Old) { Remove-Item -LiteralPath $Old -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $Dest) { Move-Item -LiteralPath $Dest -Destination $Old -Force }
    Copy-Item -LiteralPath $Exe -Destination $Dest
    Unblock-File -LiteralPath $Dest -ErrorAction SilentlyContinue
    if ((Get-FileHash -LiteralPath $Dest -Algorithm SHA256).Hash -ne $want) { throw "the copy at $Dest does not match the pin" }
    Say "installed tycswap $Version at $Dest"
  }
}
# A leftover of an earlier install, once nothing runs from it.
if ($Apply -and (Test-Path -LiteralPath $Old)) {
  $busy = @(Get-Process -Name tycswap -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -eq $Old } catch { $false } })
  if ($busy.Count -eq 0) { Remove-Item -LiteralPath $Old -Force -ErrorAction SilentlyContinue }
}

# 2. The task.
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$taskWhy = @()
if (-not $task) {
  $taskWhy += 'is not registered'
} else {
  $acts = @($task.Actions)
  if ($acts.Count -ne 2) { $taskWhy += "has $($acts.Count) action(s), not 2" }
  else {
    if ($acts[0].Execute -ne $Conhost -or $acts[0].Arguments -ne $WslArgs) { $taskWhy += 'starts the distro differently' }
    if ($acts[1].Execute -ne $Dest -or $acts[1].Arguments -ne $TrayArgs) { $taskWhy += 'starts the tray differently' }
  }
  $trs = @($task.Triggers)
  if ($trs.Count -ne 1 -or $trs[0].CimClass.CimClassName -ne 'MSFT_TaskLogonTrigger') { $taskWhy += 'does not start at logon' }
  elseif ($trs[0].UserId -and ($trs[0].UserId -split '\\')[-1] -ne $env:USERNAME) { $taskWhy += "starts at the logon of $($trs[0].UserId), not $User" }
  $s = $task.Settings
  if ($s.ExecutionTimeLimit -ne 'PT0S') { $taskWhy += "has a time limit ($($s.ExecutionTimeLimit))" }
  if ($s.DisallowStartIfOnBatteries -or $s.StopIfGoingOnBatteries) { $taskWhy += 'minds the battery' }
  if ($s.RestartCount -lt 1) { $taskWhy += 'is not restarted after a crash' }
  if ($s.MultipleInstances -ne 'IgnoreNew') { $taskWhy += "allows a second instance ($($s.MultipleInstances))" }
  if ($task.State -eq 'Disabled') { $taskWhy += 'is disabled' }
}
if ($taskWhy.Count -eq 0) {
  Say "task: $TaskName starts the distro and the tray at logon"
} else {
  Off "register the logon task $TaskName (it $($taskWhy -join '; '))"
  if ($Apply) {
    $a1 = New-ScheduledTaskAction -Execute $Conhost -Argument $WslArgs
    $a2 = New-ScheduledTaskAction -Execute $Dest -Argument $TrayArgs -WorkingDirectory $Dir
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $User
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable `
      -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $User -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action @($a1, $a2) -Trigger $trigger -Settings $settings -Principal $principal `
      -Description "flakelab: tycswap's Windows tray for the dashboard in the $Distro distro (flakelab tray)" -Force | Out-Null
    Say "registered $TaskName"
  }
}

# 3. The Run key an earlier hand registration left.
$run = Get-ItemProperty -Path $RunKey -Name $RunValue -ErrorAction SilentlyContinue
if ($run) {
  Off "remove the Run key value $RunValue (the task starts the tray now)"
  if ($Apply) { Remove-ItemProperty -Path $RunKey -Name $RunValue; Say "removed the Run key value $RunValue" }
} else {
  Say 'run key: none (the task is the only start)'
}

# 4. The tray.
$procs = @(Running)
if ($procs.Count -gt 0) {
  Say "running: pid $($procs[0].Id) since $($procs[0].StartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
} else {
  Off 'start the tray (none running)'
  if ($Apply) {
    Start-ScheduledTask -TaskName $TaskName
    $deadline = (Get-Date).AddSeconds(15)
    do { Start-Sleep -Milliseconds 500; $procs = @(Running) } while ($procs.Count -eq 0 -and (Get-Date) -lt $deadline)
    if ($procs.Count -gt 0) { Say "started the tray through the task (pid $($procs[0].Id))" }
    else { throw "the task ran but no tray appeared within 15 s; its last result: $((Get-ScheduledTaskInfo -TaskName $TaskName).LastTaskResult)" }
  }
}

if ($Mode -eq 'status' -and $script:Drift -gt 0) { exit 1 }
exit 0
