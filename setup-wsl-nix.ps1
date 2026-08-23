<#
.SYNOPSIS
    Provisions a fresh NixOS-WSL developer distro from the private overlay flake.

.DESCRIPTION
    The logic lives here, in the versioned repo. The overlay named by -FlakeRef
    carries only what must not be pushed here: flake.nix (username, git identity,
    GitLab groups, profiles, sessionVariables), secrets.env and the SSH keys.

    ONE command does all of it, because every value the overlay needs is already
    in a wslkube-shaped user_data.yaml: `provision` GENERATES the overlay flake
    from that config and harvests secrets.env out of the same file, then imports
    and applies. With a wslkube checkout next door it needs no arguments; on a
    machine without one, -Config names the config file. Nothing to hand-edit.

    FRESH PC, NO CONFIG: in an interactive console `provision` asks for the four
    values a config cannot do without (Linux user, git name, git mail, profiles)
    and writes them as <overlay>\files\config\user_data.yaml - the same schema
    -Config takes - then carries on. That file is found again on every later run
    (edit it, re-run with -Force to regenerate the flake). Without a console the
    refusal below stands: there is nobody to answer.

    Commands:
      generate   Write the overlay (skeleton + a flake GENERATED from the config)
                 and STOP - what `provision` does first, on its own, so the
                 profile can be read or `nix eval`-ed before anything is imported.
      init       Overlay skeleton with PLACEHOLDERS (flake.nix + .gitignore + the
                 SSH key folder) from templates/overlay, for writing the flake by
                 hand. Only needed when there is no user_data.yaml to generate it
                 from. Nothing else touches WSL.
      provision  Full run: generate the overlay flake from the config, seed
                 secrets.env + the SSH key from it, bootstrap, then restore the
                 `flakelab backup` payload and clone the GitLab groups. The fresh-PC
                 command.
      bootstrap  Download/import the base image and apply the overlay with TWO
                 `nixos-rebuild switch` runs (see Invoke-Bootstrap for why),
                 seeding the SSH key + secrets.env and loading the key into the
                 distro's ssh-agent in between.
      migrate    ONE-OFF pull of remaining state out of a wslkube-provisioned
                 checkout: secrets.env from its user_data.yaml, then
                 `flakelab backup --restore --from`. wslkube stays READ-ONLY and a
                 done-marker makes it one-off.
      status     Show what is present, what is missing, and interop health.

    WARNING (known-issues.md): `nixos-rebuild` boots systemd and wipes WSL
    interop VM-wide. Run from an expendable Windows terminal. After each switch
    the script probes interop, names the reason it is broken, and offers
    `wsl --shutdown` - which heals it and KILLS EVERY WSL SESSION in the VM.
    Declining right after the first switch stops provisioning (nothing is seeded
    yet) and prints how to resume; -Shutdown answers yes up front; a
    non-interactive run only warns and never shuts down by itself.

.PARAMETER FlakeRef
    The overlay flake to apply, and the source of the SSH key + secrets.env.
    Default: the sibling ../flakelab-config when it has a flake.nix.
    With no overlay there and no -Config, `provision`, `bootstrap` and
    `generate` REFUSE: the fallback is this repo, whose nix/users/default.nix
    holds PLACEHOLDERS, so applying it would create user 'youruser' with no
    keys, MCP servers, plugins or aliases. Only `status` still reports that
    fallback. `generate`/`provision` create the overlay from a config; `init`
    scaffolds it for hand-editing.

.PARAMETER Config
    A wslkube-shaped user_data.yaml. `generate`/`provision` build the overlay
    flake from it and harvest secrets.env from it, so nothing has to be
    hand-edited. Defaults to the sibling wslkube checkout's
    files\config\user_data.yaml; pass this on a machine that has no wslkube (start
    from files\config\user_data.example.yaml in this repo). It is the SAME schema
    either way - wslkube's own - so there is no second format to keep in sync.

    The generated flake is the profile from then on: it is never overwritten
    without -Force, so a hand-edit survives every later `provision`.

.PARAMETER Tarball
    Path to nixos.wsl. Downloaded from the NixOS-WSL releases when omitted.

.PARAMETER ImageUrl
    Override the base image URL (air-gapped mirror, pinned release).

.PARAMETER SshPassphrase
    Passphrase of the private key(s) under files\config\shared\ssh\keys. The
    SSH-dependent home-manager activation steps (kiro-plugin clone, Claude
    marketplace + plugins, the statusline that follows them) run from a systemd
    unit with no SSH_AUTH_SOCK, so without a loaded agent they can only DEFER.
    Pass this to load the key into the distro's ssh-agent with no prompt; passing
    it (even empty) suppresses the interactive prompt entirely, which is what
    makes an unattended run possible. Never echoed, never written to the overlay.

.PARAMETER SkipSecondSwitch
    Skip the second `nixos-rebuild switch`. Use when the SSH-dependent steps are
    already done - both switches are idempotent, the second just costs minutes.

.PARAMETER SkipCloneRepos
    Skip `flakelab clone` (faster iteration on provisioning issues).

.PARAMETER RestoreInstance
    The backup INSTANCE read by the overlay-payload restore - the `provision`
    step that runs `flakelab backup --restore` inside the new distro. That
    command looks for instances\<name> beside the overlay and defaults to the
    name of the distro it runs in, so a payload written under another name - a
    fresh 'flakelab' taking over the old 'NixOS' instance - restores only the
    SHARED categories until that name is passed here. A name the payload has no
    directory for is refused, listing the ones it has. Default: -DistroName.

    It does not reach the wslkube path: with a wslkube checkout present, that
    restore runs first and wins, and -WslkubeInstance is what names an instance
    there. Passing this one while that happens warns and changes nothing.

.PARAMETER CopyLiveCredentials
    Pre-authorise the credential copy. `provision`/`migrate` read LIVE tokens out
    of the config they provision from and the private key out of the running
    wslkube distro, and write them UNENCRYPTED into the overlay - so without this
    flag an interactive run asks first, and a non-interactive one skips the copy
    rather than doing it silently. Names of what would be copied are shown; values
    never are.

.PARAMETER Shutdown
    Answer yes up front to the `wsl --shutdown` this script offers after each
    rebuild. `nixos-rebuild` unregisters the kernel-global WSLInterop handler for
    EVERY distro in the VM (known-issues.md), and the only recovery is a shutdown
    - which also KILLS EVERY WSL SESSION.

.PARAMETER Force
    Overwrite existing overlay files on `init`, REGENERATE the overlay flake from
    the config on `generate` and `provision` (both keep an existing flake.nix
    without it, so a hand-edit survives), and re-run a completed `migrate`.

.PARAMETER DryRun
    Print every step without touching WSL, the overlay or the network.

.EXAMPLE
    # ONE command, wslkube checkout next door: flake, secrets and key all derived.
    .\setup-wsl-nix.ps1 provision
.EXAMPLE
    # ONE command on a machine with no wslkube - same schema, same result.
    .\setup-wsl-nix.ps1 provision -Config D:\configs\user_data.yaml
.EXAMPLE
    # Generate the overlay and stop, to read it (or `nix eval` it) first.
    .\setup-wsl-nix.ps1 generate -FlakeRef D:\scratch-overlay -Config D:\configs\user_data.yaml
.EXAMPLE
    .\setup-wsl-nix.ps1 init                  # hand-written overlay: ..\flakelab-config
.EXAMPLE
    # Fresh PC, start to finish, no config yet: four questions, then everything.
    .\setup-wsl-nix.ps1 provision -Shutdown
.EXAMPLE
    # Fresh PC with a prepared config (unattended, second machine).
    .\setup-wsl-nix.ps1 provision -Config D:\configs\user_data.yaml
.EXAMPLE
    # Fully non-interactive: no passphrase prompt, no interop confirmation.
    .\setup-wsl-nix.ps1 provision -SshPassphrase 'my-key-passphrase' -Shutdown
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('init', 'generate', 'provision', 'bootstrap', 'migrate', 'status')]
    [string]$Command = 'status',

    [string]$FlakeRef,
    [string]$Config,
    # 'flakelab' names new provisions after this repo. A machine already
    # registered under a different name keeps it, so pass that name here - a
    # default `provision` re-run would otherwise import a SECOND distro rather
    # than update the existing one. `wsl -l -v` lists the registrations
    # (status, migrate and ssh-agent seeding all target $DistroName).
    [string]$DistroName = 'flakelab',
    [string]$Tarball,
    [string]$ImageUrl,
    # Derived from the distro name so a second distro cannot import on top of the
    # first one's VHD.
    [string]$InstallDir = "$env:LOCALAPPDATA\WSL\$DistroName",
    [string]$SshPassphrase,
    # The PREDECESSOR distro `migrate` and the key/secrets seeding read from.
    # 'wslkube' is only the default name: a box that registered it under any
    # other name must pass that real name here, or every step that reads it is
    # skipped as "no such distro" and the run reports success with no key, no
    # secrets and no migrated state. `wsl -l -v` lists the registrations.
    [string]$WslkubeDistro = 'wslkube',
    [string]$WslkubeInstance = '',
    # The backup instance the restore step reads out of the overlay payload; see
    # .PARAMETER RestoreInstance. Defaults to this distro's own name, which is
    # what `flakelab backup --restore` uses when no instance is named.
    [string]$RestoreInstance = $DistroName,
    [switch]$CopyLiveCredentials,
    [switch]$SkipCloneRepos,
    [switch]$SkipSecondSwitch,
    [switch]$Shutdown,
    [switch]$Force,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'  # Invoke-WebRequest is ~10x slower with it
$started = Get-Date

# Whether -RestoreInstance was NAMED: its default is $DistroName, so the value
# alone cannot say whether the caller chose it, and the wslkube preemption
# warning below has to tell those apart.
$RestoreInstanceNamed = $PSBoundParameters.ContainsKey('RestoreInstance')
# The restore command single-quotes the instance name for the zsh it crosses
# into, and nothing can escape a single quote through that. Same refusal as
# ToWslPath, made here so it lands before the distro is built.
if ($RestoreInstance.Contains("'")) {
    throw ("-RestoreInstance {0}: a single quote in an instance name cannot cross the wsl.exe boundary. Rename the instance directory." -f $RestoreInstance)
}

if ($env:WSL_DISTRO_NAME) {
    throw "Run this from Windows PowerShell, not from inside WSL."
}

# Official NixOS-WSL base image (already contains nix; the rebuild runs in-distro).
$NixosWslRelease = 'https://github.com/nix-community/NixOS-WSL/releases/latest/download/nixos.wsl'

function Say([string]$m, [string]$c = 'Cyan') { Write-Host "> $m" -ForegroundColor $c }
function Warn([string]$m) { Write-Host "! $m" -ForegroundColor Yellow }
function Do-Step([string]$desc, [scriptblock]$block) {
    if ($DryRun) { Write-Host "  [dry-run] $desc" -ForegroundColor DarkGray; return }
    Write-Host "  $desc" -ForegroundColor DarkGray
    & $block
}
function ToWslPath([string]$p) {
    # Only a drive path converts: the distro reaches the Windows side at
    # /mnt/<letter>/... A UNC path - \\wsl$\... for a checkout on WSL's own
    # filesystem - has no drive letter, and taking its first character silently
    # produced '/mnt/\...', which exists nowhere and fails much later with nothing
    # pointing back here. The Ansible predecessor hardcoded '/mnt/c' instead, so a
    # checkout on any other drive broke the same way.
    if ($p -notmatch '^[A-Za-z]:[\\/]') {
        throw ('cannot convert "{0}" to a WSL path: it is not on a Windows drive. Keep this checkout and the overlay under C:\Users\<name>\git\, not on WSL''s own filesystem (\\wsl$\...).' -f $p)
    }
    # A space is fine everywhere now - it is percent-encoded into `path:` URLs
    # and single-quoted into every `sh -c` payload. A SINGLE QUOTE is not: it
    # terminates exactly the quoting those payloads rely on, and there is no
    # escape for it that survives the wsl.exe boundary. Refuse here, where the
    # path is first converted, rather than let the copy read the wrong file.
    if ($p.Contains("'")) {
        throw ('cannot convert "{0}" to a WSL path: a single quote in a directory name cannot cross the wsl.exe boundary. Rename the folder.' -f $p)
    }
    # A '#' is the flake-ref fragment delimiter, and the rebuild hands the overlay
    # path to --flake <path>#default as a bare argument - nix cuts it at the FIRST
    # '#' and applies some other flake, or none. ConvertTo-PathUrl percent-encodes
    # it for the path: URLs; a bare argument has no such cover.
    if ($p.Contains('#')) {
        throw ('cannot convert "{0}" to a WSL path: a "#" in a directory name is the flake-ref fragment delimiter, so --flake <path>#default would be cut there and rebuild a different flake. Rename the folder.' -f $p)
    }
    $drive = $p.Substring(0, 1).ToLower()
    return '/mnt/' + $drive + ($p.Substring(2) -replace '\\', '/')
}
# ConvertTo-PathUrl <wsl path> -> the path as the body of a `path:` flake URL.
#
# `path:` is a URL and nix parses it as one: a raw space makes the parse fail and
# nix falls back to reading the WHOLE string - scheme included - as a relative
# filesystem path, so the rebuild dies with "no such file or directory" naming a
# path with `path:` inside it. `#` and `?` are worse than broken: they are the
# fragment and query delimiters, so a checkout under a folder containing either
# is silently truncated. A checkout under C:\Users\First Last\ is the ordinary
# Windows case, which is why this is not theoretical.
#
# '%' goes FIRST or the escapes added after it are escaped again. .Replace, not
# -replace: no regex, no '$' capture references.
function ConvertTo-PathUrl([string]$p) {
    return $p.Replace('%', '%25').Replace(' ', '%20').Replace('#', '%23').Replace('?', '%3F')
}
function Test-Distro([string]$dn) {
    $list = @(Invoke-NativeQuiet 'wsl.exe' @('--list', '--quiet')) -replace "`0", '' -split "`r?`n" | ForEach-Object { $_.Trim() }
    return $list -contains $dn
}
# Every file this script hands to Linux must be LF-only. Set-Content emits CRLF:
# in secrets.env the CR lands INSIDE the quoted value (GITLAB_TOKEN comes out one
# byte too long and GitLab answers `invalid header field value for
# "Private-Token"` on every call), and an OpenSSH private key with CRLF line
# endings is rejected outright. UTF-8 without BOM - a BOM corrupts the first line
# just as badly.
function Write-LfFile([string]$Path, [string[]]$Lines) {
    $text = ($Lines -join "`n") + "`n"
    [IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding $false))
}
# Windows PowerShell 5.1 + ErrorActionPreference=Stop: redirecting a native
# command's stderr (`2>$null`, `2>&1`) turns EVERY stderr line into a TERMINATING
# NativeCommandError. Observed 2026-08-23: right after the first switch wsl.exe
# printed 'Failed to start the systemd user session for <user>' (transient - the
# user had just been created) and the interop probe's `2>$null` killed the whole
# provision. Every probe-style native call whose stderr is noise goes through
# here: stderr is dropped, stdout comes back, $LASTEXITCODE is still set.
function Invoke-NativeQuiet([string]$exe, [string[]]$argv) {
    $ErrorActionPreference = 'Continue'
    & $exe @argv 2>&1 | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
}
function Invoke-Wsl([string]$dn, [string]$asUser, [string[]]$cmd) {
    $wslArgs = @('-d', $dn)
    if ($asUser) { $wslArgs += @('-u', $asUser) }
    $wslArgs += @('--') + $cmd
    if ($DryRun) { Write-Host "  [dry-run] wsl.exe $($wslArgs -join ' ')" -ForegroundColor DarkGray; return }
    & wsl.exe @wslArgs
    if ($LASTEXITCODE -ne 0) { throw "wsl.exe failed (exit $LASTEXITCODE) for: $($cmd[0])" }
}

# The in-distro commands are subcommands of `flakelab` now (nix-clone-repos ->
# `flakelab clone`, nix-backup -> `flakelab backup`, and so on). This script
# cannot assume the target distro has them: `migrate` runs against a distro it
# did not just build, and an operator may point a fresh checkout of this script
# at a box provisioned before the CLI landed. So feature-detect.
#
# `if/then/else`, not `new || old`: a fallback chained on failure would rerun the
# work under the old name whenever the new command legitimately exited non-zero,
# turning a real error into a confusing double run. This branches on PRESENCE
# only, and whichever branch runs owns the exit status.
#
# The reverse direction - a pre-CLI copy of THIS script against a current distro
# - is covered by the deprecation shims in nix/cli.nix, which is why that list
# includes `nix-clone-repos` even though nobody types it: Invoke-CloneRepos only
# Warns on a non-zero exit, so a missing command there would report a successful
# provision over an empty ~/git.
function DistroCmd([string]$Sub, [string]$Legacy, [string]$CmdArgs = '') {
    $a = if ($CmdArgs) { " $CmdArgs" } else { '' }
    "if command -v flakelab >/dev/null 2>&1; then flakelab $Sub$a; else $Legacy$a; fi"
}

# ---------- paths ----------
$RepoWin = $PSScriptRoot
$RepoWsl = ToWslPath $RepoWin
$TemplateWin = Join-Path $RepoWin 'templates\overlay'

# The overlay injects the real identity via lib.mkSystem; this repo ships
# placeholders. `init` CREATES the overlay and `generate`/`provision` GENERATE its
# flake, so none of them may demand one; every other command applies it, and a
# missing flake there fails deep inside a rebuild.
if (-not $FlakeRef) {
    $siblingDir = Split-Path $RepoWin -Parent
    $FlakeRef = Join-Path $siblingDir 'flakelab-config'
    # Transitional: the sibling default was `wslnix-config` before the
    # 2026-08-21 rename, and every box provisioned before it still has that
    # directory. Without this the default misses, the fallback below silently
    # retargets the overlay at THIS repo, and a credential-writing command
    # copies cleartext tokens into the machinery checkout (observed 2026-08-22).
    # Delete this branch once the overlays are renamed.
    if (-not (Test-Path (Join-Path $FlakeRef 'flake.nix'))) {
        $legacyRef = Join-Path $siblingDir 'wslnix-config'
        if (Test-Path (Join-Path $legacyRef 'flake.nix')) {
            Warn "using the pre-rename overlay $legacyRef - rename it to flakelab-config, or pass -FlakeRef to silence this."
            $FlakeRef = $legacyRef
        }
    }
}
# Normalised before it exists, because Resolve-Path throws on a missing path and
# the whole point of generation is an overlay that is not there yet.
if (Test-Path $FlakeRef) { $FlakeRefFull = (Resolve-Path $FlakeRef).Path }
elseif ([IO.Path]::IsPathRooted($FlakeRef)) { $FlakeRefFull = [IO.Path]::GetFullPath($FlakeRef) }
else { $FlakeRefFull = [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $FlakeRef)) }

# wslkube is looked for beside the INTENDED overlay, which is the sibling checkout
# in the layout this script assumes (git root: flakelab, flakelab-config, wslkube).
# Resolving it before the overlay decision is what lets that decision ask whether
# there is a config to generate from.
$GitRoot = Split-Path $FlakeRefFull -Parent
$WslkubeWin = Join-Path $GitRoot 'wslkube'

# The config that drives BOTH the overlay flake and secrets.env: the sibling
# wslkube checkout's user_data.yaml, or -Config on a machine that has none. One
# schema either way - wslkube's - so there is nothing to keep in sync. Empty means
# no config was found, which is the only case that still needs hand-seeding.
if ($Config) {
    if (-not (Test-Path $Config)) { throw "-Config '$Config' not found" }
    $ConfigPath = (Resolve-Path $Config).Path
}
else {
    $ConfigPath = Join-Path $WslkubeWin 'files\config\user_data.yaml'
    # Then the overlay's own copy - what the first-run wizard below writes, or a
    # -Config the operator parked there - so a later `provision -Force` finds it.
    if (-not (Test-Path $ConfigPath)) { $ConfigPath = Join-Path $FlakeRefFull 'files\config\user_data.yaml' }
    if (-not (Test-Path $ConfigPath)) { $ConfigPath = '' }
}

# ---------- first-run wizard ----------
# A fresh PC with no overlay and no -Config used to be a refusal. In an
# interactive console `provision` asks for the four values a config cannot do
# without and writes them in the one schema everything else reads, under the
# overlay, so the next run (and -Force) finds them. Non-interactive runs and
# -DryRun (touches nothing) keep the refusal.
function Test-InteractiveConsole {
    return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected)
}

# Keys of profiles/default.nix (`name = import ./name.nix;`) - the list
# profiles/merge.nix resolves against. Read, not hard-coded, so the pick-list
# cannot drift from the profiles.
function Get-ProfileNames {
    $p = Join-Path $RepoWin 'profiles\default.nix'
    if (-not (Test-Path $p)) { return @() }
    return @([IO.File]::ReadAllLines($p) | ForEach-Object {
            if ($_ -match '^\s*([A-Za-z_][A-Za-z0-9_-]*)\s*=\s*import\s') { $Matches[1] }
        })
}

function Read-Answer([string]$prompt, [string]$default, [scriptblock]$valid, [string]$hint) {
    while ($true) {
        $shown = if ($default) { "  $prompt [$default]" } else { "  $prompt" }
        $v = [string](Read-Host $shown)
        if (-not $v.Trim() -and $default) { $v = $default }
        $v = $v.Trim()
        if ($v -and (& $valid $v)) { return $v }
        Write-Host "    $hint" -ForegroundColor Yellow
    }
}

# Single-quoted YAML scalar, the form Read-UserDataYaml unquotes (`''` -> `'`).
function ConvertTo-YamlQuoted([string]$s) { return "'" + ($s -replace "'", "''") + "'" }

function Invoke-ConfigWizard([string]$target) {
    Say "No overlay at $FlakeRefFull and no -Config. Four questions write one:" 'Green'
    Write-Host "    Everything else (locale, aliases, MCP servers, plugins, tokens) is optional -" -ForegroundColor DarkGray
    Write-Host "    add it to $target afterwards and re-run with -Force." -ForegroundColor DarkGray
    $git = Get-Command git -ErrorAction SilentlyContinue
    $nameDefault = if ($git) { [string](Invoke-NativeQuiet 'git' @('config', '--global', 'user.name')) } else { '' }
    $mailDefault = if ($git) { [string](Invoke-NativeQuiet 'git' @('config', '--global', 'user.email')) } else { '' }
    $userDefault = ([string]$env:USERNAME -replace '[^A-Za-z0-9_]', '').ToLower()
    $user = Read-Answer 'Linux username' $userDefault { param($v) $v -cmatch '^[a-z_][a-z0-9_]*$' } 'lowercase letters, digits, underscore - no dashes, no spaces'
    $name = Read-Answer 'Git full name' $nameDefault { param($v) $true } 'cannot be empty'
    $mail = Read-Answer 'Git email' $mailDefault { param($v) $v -match '^[^@\s]+@[^@\s]+\.[^@\s]+$' } 'one address, like you@example.com'
    $names = @(Get-ProfileNames)
    $profiles = @()
    if ($names.Count -gt 0) {
        Write-Host "    Profiles (each one installs its package set and clones its GitLab groups):" -ForegroundColor DarkGray
        for ($i = 0; $i -lt $names.Count; $i++) { Write-Host ("      {0}) {1}" -f ($i + 1), $names[$i]) }
        $pickDefault = if ($names.Count -eq 1) { $names[0] } else { '' }
        $profiles = Read-Answer 'Profiles (numbers or names, comma-separated)' $pickDefault {
            param($v)
            $chosen = @()
            foreach ($tok in ($v -split '[,\s]+' | Where-Object { $_ })) {
                $n = 0
                if ([int]::TryParse($tok, [ref]$n)) { if ($n -lt 1 -or $n -gt $names.Count) { return $false }; $chosen += $names[$n - 1] }
                elseif ($names -contains $tok) { $chosen += $tok }
                else { return $false }
            }
            $script:WizardProfiles = @($chosen | Select-Object -Unique)
            return ($script:WizardProfiles.Count -gt 0)
        } ("pick from: {0}" -f ($names -join ', '))
        $profiles = @($script:WizardProfiles)
    }
    else {
        Warn "no profiles/ entries in this checkout - the config needs at least one repo instead"
    }
    $repos = @()
    $reposRaw = [string](Read-Host '  Extra repos to clone (SSH URLs, space-separated; Enter = none)')
    foreach ($u in ($reposRaw -split '\s+' | Where-Object { $_ })) { $repos += $u }
    if ($profiles.Count -eq 0 -and $repos.Count -eq 0) {
        throw "no profile and no repo: the overlay would install no profile packages and clone nothing. Re-run and pick a profile or name a repo."
    }

    $lines = @(
        '# Written by setup-wsl-nix.ps1 provision on first run. Same schema as',
        '# flakelab/files/config/user_data.example.yaml - every optional key in there',
        '# (locale, aliases, env vars, plugins, MCP servers, extra repos) can be added',
        '# here. After editing:  .\setup-wsl-nix.ps1 provision -Force   regenerates',
        '# the overlay flake from this file. REAL TOKENS NEVER BELONG IN GIT.',
        '',
        "user: $user",
        "windows_username: $env:USERNAME",
        "gitfullname: $(ConvertTo-YamlQuoted $name)",
        "gitmail: $mail",
        'profiles:'
    )
    foreach ($pr in $profiles) { $lines += "  - $pr" }
    if ($profiles.Count -eq 0) { $lines[-1] = 'profiles: []' }
    if ($repos.Count -gt 0) {
        $lines += 'repos:'
        foreach ($u in $repos) { $lines += "  - rel_path: ''"; $lines += "    url: $(ConvertTo-YamlQuoted $u)" }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $target -Parent) | Out-Null
    Write-LfFile $target $lines
    Say "Config written: $target" 'Green'
    return $target
}

if (-not $ConfigPath -and $Command -eq 'provision' -and -not $DryRun -and
    -not (Test-Path (Join-Path $FlakeRefFull 'flake.nix')) -and (Test-InteractiveConsole)) {
    $ConfigPath = Invoke-ConfigWizard (Join-Path $FlakeRefFull 'files\config\user_data.yaml')
}
# A -Config that sits INSIDE a wslkube checkout names that checkout, so the
# migrate step pulls its backup payload from where the config came from rather
# than from an overlay sibling that need not exist. wsl-backup is the marker: the
# example config in THIS repo has the same layout but no such script.
if ($Config -and $ConfigPath -match '(?i)\\files\\config\\user_data[^\\]*\.yaml$') {
    $candidate = Split-Path (Split-Path (Split-Path $ConfigPath -Parent) -Parent) -Parent
    if (Test-Path (Join-Path $candidate 'files\scripts\wsl-backup')) { $WslkubeWin = $candidate }
}

$OverlayIsFallback = $false
$CanGenerate = (($Command -eq 'generate') -or ($Command -eq 'provision')) -and $ConfigPath
if ($Command -eq 'init' -or $CanGenerate) {
    $OverlayWin = $FlakeRefFull
}
elseif (Test-Path (Join-Path $FlakeRefFull 'flake.nix')) {
    $OverlayWin = $FlakeRefFull
}
else {
    # `migrate` and -CopyLiveCredentials pull the live private key and the
    # cleartext tokens out of a running distro and write them under the
    # OVERLAY. Falling back to this repo would put credentials inside the
    # machinery checkout - gitignored, but on a Windows drive and in a
    # directory that gets synced and shared. That is never what the caller
    # meant, so it is an error here rather than the warning below (observed
    # 2026-08-22: the rename moved the sibling default, the fallback fired,
    # and secrets.env landed in the checkout).
    if ($Command -eq 'migrate' -or $CopyLiveCredentials) {
        throw ("no overlay flake at $FlakeRef, and '$Command' writes credentials into the overlay - " +
               "refusing to write them into this repo. Pass -FlakeRef <your overlay>, " +
               "or create one first with: .\setup-wsl-nix.ps1 init")
    }
    # Everything that BUILDS a distro refuses too. This repo's own values are
    # placeholders - user 'youruser', no keys, no MCP servers, no plugins - and a
    # box provisioned from them is not a usable box: it is a distro registered
    # under the caller's chosen name, holding a user nobody asked for, that the
    # real run then has to be told to reuse. The warning below was not enough,
    # because a `provision` with no -Config and no sibling overlay is precisely
    # the fresh-PC invocation the .cmd menu's [P] entry makes.
    #
    # `status` is the exception: reporting the fallback IS its job, and it
    # changes nothing. It keeps $OverlayIsFallback, which Invoke-Status reads.
    if ($Command -ne 'status') {
        # `generate` applies nothing at all - it lands here only because there is
        # no config to generate FROM, so the placeholder wording below answers a
        # question it never asked.
        if ($Command -eq 'generate') {
            throw ("nothing to generate from: no -Config, no user_data.yaml beside the overlay, " +
                   "and no overlay flake at $FlakeRef to read instead. Pass  " +
                   ".\setup-wsl-nix.ps1 generate -Config <path to user_data.yaml>  " +
                   "(see files\config\user_data.example.yaml), or scaffold one to hand-edit with  " +
                   ".\setup-wsl-nix.ps1 init")
        }
        # `provision -Config`, not `$Command -Config`: only generate and provision
        # generate from a config (see $CanGenerate above), so telling a bootstrap
        # caller to add -Config would send them back into this same throw.
        throw ("no overlay flake at $FlakeRef, and '$Command' would apply this repo's PLACEHOLDER values " +
               "(user 'youruser', no keys, no MCP servers, no plugins). Three ways out: " +
               "run  .\setup-wsl-nix.ps1 provision  from an interactive console and answer its four questions, " +
               "generate an overlay from a config with  .\setup-wsl-nix.ps1 provision -Config <path to user_data.yaml>  " +
               "(see files\config\user_data.example.yaml; 'generate -Config' writes it without provisioning), " +
               "or point -FlakeRef at an overlay that already exists - the default is the sibling checkout " +
               "$FlakeRef, which  .\setup-wsl-nix.ps1 init  creates.")
    }
    $OverlayWin = $RepoWin
    $OverlayIsFallback = $true
    Warn "no overlay flake at $FlakeRef - this repo's PLACEHOLDER values (user 'youruser', no MCP servers, no plugins). No command but 'status' will apply them."
    Warn "Generate one from a config:  .\setup-wsl-nix.ps1 provision -Config <path to user_data.yaml>"
    Warn "Or write one by hand:  .\setup-wsl-nix.ps1 init"
}
$OverlayWsl = ToWslPath $OverlayWin
$OverlayFlakeWin = Join-Path $OverlayWin 'flake.nix'
$KeyDirWin = Join-Path $OverlayWin 'files\config\shared\ssh\keys'
$KeyWin = Join-Path $KeyDirWin 'id_ed25519'
# The path nix-backup already owns on both ends (files/scripts/nix-backup, the
# `secrets` shared category), so a migrated payload lands exactly where seeding
# reads it and no second location is invented.
$SecretsDirWin = Join-Path $OverlayWin 'files\config\shared\secrets'
$SecretsWin = Join-Path $SecretsDirWin 'secrets.env'
$Marker = Join-Path $OverlayWin '.migrated-from-wslkube'

# Username comes from the applied flake, not from a fixed file: the overlay sets
# it inline in flake.nix, this repo in nix/users/default.nix.
$UserSourceWin = Join-Path $OverlayWin 'nix\users\default.nix'
if (-not (Test-Path $UserSourceWin)) { $UserSourceWin = Join-Path $OverlayWin 'flake.nix' }
if (-not (Test-Path $UserSourceWin)) {
    # Nothing to read yet: `init` writes the flake this comes from, and
    # `generate`/`provision` generate it from the config and set this from the
    # same file (Set-OverlayFromConfig).
    $User = ''
}
else {
    $um = Select-String -Path $UserSourceWin -Pattern 'username\s*=\s*"([^"]+)"'
    if (-not $um) { throw "Could not read 'username' from $UserSourceWin" }
    $User = $um.Matches[0].Groups[1].Value
}

# NAMES of the runtime secrets ~/.config/tyc/secrets.env must define - the same
# set as files/config/secrets.env.example. Shared by the wslkube harvester and
# the manual-seed instructions; values never live here.
$SecretKeyNames = @('GITLAB_TOKEN', 'GH_TOKEN', 'HASS_TOKEN',
    'PROXMOX_TOKEN_ID', 'PROXMOX_TOKEN_SECRET',
    'SYNOLOGY_PASSWORD', 'SYNOLOGY_DEVICE_ID',
    'GRAFANA_SERVICE_ACCOUNT_TOKEN')
# Secret NAMES no longer harvested or asked for (the feature behind them is not
# shipped), but still never allowed into the flake: a config that carries one
# must not see it land in the world-readable store just because it left the list.
$RetiredSecretKeyNames = @('WHATSAPP_API_KEY')

# Non-secret counterparts of the above. They belong in the overlay's
# sessionVariables (declarative, in the shell env), NOT in secrets.env - each one
# is what GATES its MCP server in nix/home/mcp.nix, so a missing endpoint
# silently means a missing server.
$NonSecretKeyNames = @('HASS_URL', 'PROXMOX_API_URL', 'PROXMOX_VERIFY_SSL',
    'SYNOLOGY_HOST', 'SYNOLOGY_PORT', 'SYNOLOGY_HTTPS', 'SYNOLOGY_USERNAME',
    'GRAFANA_URL', 'WHATSAPP_BRIDGE_HOST')

# -SshPassphrase given (even as '') means "never prompt" - an unattended run must
# not block on a console read. Captured HERE because $PSBoundParameters inside a
# function is that function's bound set, not the script's. StrictMode: initialise
# everything before first use.
$SshPassphraseGiven = $PSBoundParameters.ContainsKey('SshPassphrase')
if (-not $SshPassphrase) { $SshPassphrase = '' }
$SshPassphraseResolved = $false

# Set once the overlay flake has been GENERATED from the config, which makes the
# non-secret half of custom_env_vars part of the flake by construction. StrictMode:
# initialise before first use.
$FlakeFromConfig = $false

# ---------- user_data.yaml -> overlay flake ----------
# wslkube's files/config/user_data.yaml is the ONE config schema here: the overlay
# flake is generated from it and secrets.env is harvested from it, so a flakelab-only
# format would be a second thing to keep in sync with wslkube forever.
#
# Parsed by hand because this must run on stock Windows PowerShell 5.1, which ships
# no YAML reader - and the file is flat: scalars, string lists, string maps
# (custom_env_vars) and lists of maps (custom_aliases, repos). Nothing deeper is
# supported, and nothing deeper is in the schema.
#
# All three scalar styles occur in real configs (`user: alice`, `giteditor: 'code'`,
# `"quoted"`), and an inline comment is not part of the value.
function ConvertFrom-YamlScalar([string]$raw) {
    $s = $raw.Trim()
    # Anchored and greedy: the closing quote is the last one before end-of-line or
    # the comment, so a value may itself contain '#' or the other quote character.
    if ($s -match "^'(.*)'\s*(?:#.*)?$") { return $Matches[1] -replace "''", "'" }
    if ($s -match '^"(.*)"\s*(?:#.*)?$') { return $Matches[1] -replace '\\"', '"' }
    return ($s -replace '\s+#.*$', '').Trim()
}

function Read-UserDataYaml([string]$path) {
    if (-not (Test-Path $path)) { throw "config not found: $path" }
    # Pass 1: top-level key -> its scalar, or the raw indented lines under it.
    $raw = [ordered]@{}
    $key = ''
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        if ($line.Trim() -eq '' -or $line -match '^\s*#') { continue }
        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$') {
            $key = $Matches[1]
            $raw[$key] = @{ Scalar = ''; Lines = @() }
            $v = $Matches[2].Trim()
            if ($v -ne '') { $raw[$key].Scalar = (ConvertFrom-YamlScalar $v) }
            continue
        }
        if ($key -and $line -match '^\s+\S') { $raw[$key].Lines += $line }
    }
    # Pass 2: a block is a list of maps if its first item carries a key, a string
    # list if it carries none, and a map otherwise.
    $out = [ordered]@{}
    foreach ($k in $raw.Keys) {
        $lines = @($raw[$k].Lines)
        if ($lines.Count -eq 0) {
            # Flow-style list - `profiles: [dev, ops]`, `gitlab_groups: ["x"]`.
            # YAML says it is a list; a reader that only knows the block form
            # keeps it as a SCALAR, and the scalar reaches the overlay as the
            # literal string "[dev, ops]": a profile of that name, unknown, or a
            # gitlabGroups entry nobody can clone. Simple lists only, which is
            # what a user_data.yaml carries: one level, no nesting, and a comma
            # inside a quoted element is not honoured (it splits). `[]` yields an
            # EMPTY list rather than a scalar - the point of writing it.
            $scalar = [string]$raw[$k].Scalar
            if ($scalar -match '^\[(.*)\]$') {
                $inner = $Matches[1]
                if ($inner.Trim() -eq '') { $out[$k] = @() }
                else {
                    $out[$k] = @($inner -split ',' |
                        ForEach-Object { ConvertFrom-YamlScalar $_ } |
                        Where-Object { $_ -ne '' })
                }
                continue
            }
            $out[$k] = $scalar
            continue
        }
        if ($lines[0] -match '^\s*-\s*[A-Za-z_][A-Za-z0-9_]*\s*:') {
            $items = @()
            $cur = $null
            foreach ($l in $lines) {
                if ($l -match '^\s*-\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$') {
                    $cur = [ordered]@{}
                    $cur[$Matches[1]] = (ConvertFrom-YamlScalar $Matches[2])
                    $items += $cur
                }
                elseif ($cur -and $l -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$') {
                    $cur[$Matches[1]] = (ConvertFrom-YamlScalar $Matches[2])
                }
            }
            $out[$k] = $items
        }
        elseif ($lines[0] -match '^\s*-\s*\S') {
            $out[$k] = @($lines |
                Where-Object { $_ -match '^\s*-\s*\S' } |
                ForEach-Object { ConvertFrom-YamlScalar ($_ -replace '^\s*-\s*', '') })
        }
        else {
            $m = [ordered]@{}
            foreach ($l in $lines) {
                if ($l -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$') { $m[$Matches[1]] = (ConvertFrom-YamlScalar $Matches[2]) }
            }
            $out[$k] = $m
        }
    }
    return $out
}

# StrictMode makes a missing key on an OrderedDictionary worth guarding once,
# centrally, rather than at every read site.
function Get-UserDataValue($ud, [string]$key) {
    if ($null -ne $ud -and $ud.Contains($key)) { return $ud[$key] }
    return $null
}

# The list form of the above. @($null) is a ONE-element array, so an absent key
# read straight into @() would emit a list with one empty entry - or warn about a
# phantom custom_aliases/repos item that is not in the file at all.
function Get-UserDataList($ud, [string]$key) {
    $v = Get-UserDataValue $ud $key
    if ($null -eq $v) { return @() }
    return @(@($v) | Where-Object { $null -ne $_ })
}

# wslkube splits its config across TWO files the way Ansible loads them:
# variables.yaml holds the shared defaults and user_data.yaml the per-host
# overrides, and main_playbook.yaml includes both. Reading only user_data.yaml
# therefore misses everything that was never host-specific - gitlab_groups,
# clone_exclude, claude_plugins, claude_plugin_marketplace all live in
# variables.yaml - and the generated overlay came out with no groups at all. That
# is not a visible failure: the flake still builds, and `flakelab clone` is
# GENERATED, so it bakes in "nothing to clone" and the box comes up with an empty
# ~/git. Layer the two here, user_data winning, exactly as Ansible does.
function Read-WslkubeConfig([string]$udPath, [string]$wslkubeRoot) {
    $ud = Read-UserDataYaml $udPath
    if (-not $wslkubeRoot) { return $ud }
    $varsPath = Join-Path $wslkubeRoot 'variables.yaml'
    if (-not (Test-Path $varsPath)) { return $ud }
    $vars = Read-UserDataYaml $varsPath
    $merged = [ordered]@{}
    foreach ($k in $vars.Keys) { $merged[$k] = $vars[$k] }
    foreach ($k in $ud.Keys) { $merged[$k] = $ud[$k] }
    return $merged
}

# group -> profile name, read out of profiles/<name>.nix rather than hard-coded,
# so the mapping cannot drift from the profiles themselves. wslkube has no notion
# of a profile: it lists gitlab_groups flat, and which of them a profile already
# brings is knowable only from the profile.
function Get-ProfileGroupMap {
    $map = [ordered]@{}
    $dir = Join-Path $RepoWin 'profiles'
    if (-not (Test-Path $dir)) { return $map }
    foreach ($f in Get-ChildItem -Path $dir -Filter '*.nix' -File) {
        if ($f.BaseName -eq 'default' -or $f.BaseName -eq 'merge') { continue }
        $text = [IO.File]::ReadAllText($f.FullName)
        if ($text -match 'gitlabGroups\s*=\s*\[([^\]]*)\]') {
            foreach ($m in [regex]::Matches($Matches[1], '"([^"]+)"')) { $map[$m.Groups[1].Value] = $f.BaseName }
        }
    }
    return $map
}

# .Replace, not -replace: a regex replacement string reads '$' as a group
# reference. Backslash goes first so the escapes added after it are not doubled;
# `${` is nix antiquotation, which a shell alias like `${FOO}` would otherwise
# trigger inside the flake.
function ConvertTo-NixString([string]$s) {
    return '"' + $s.Replace('\', '\\').Replace('"', '\"').Replace('${', '\${') + '"'
}
function ConvertTo-NixAttrName([string]$n) {
    if ($n -match "^[A-Za-z_][A-Za-z0-9_'-]*$") { return $n }
    return (ConvertTo-NixString $n)
}
function ConvertTo-NixBool([string]$v) {
    if ($v -match '^\s*(true|yes|on|1)\s*$') { return 'true' }
    return 'false'
}
function Format-NixList([string]$name, [string[]]$values, [string]$indent) {
    if ($values.Count -eq 0) { return @("$indent$name = [ ];") }
    if ($values.Count -eq 1) { return @("$indent$name = [ $(ConvertTo-NixString $values[0]) ];") }
    $out = @("$indent$name = [")
    foreach ($v in $values) { $out += "$indent  $(ConvertTo-NixString $v)" }
    return $out + @("$indent];")
}
function Format-NixAttrs([string]$name, $map, [string]$indent) {
    if ($null -eq $map -or $map.Keys.Count -eq 0) { return @() }
    $out = @("$indent$name = {")
    foreach ($k in $map.Keys) { $out += ("{0}  {1} = {2};" -f $indent, (ConvertTo-NixAttrName $k), (ConvertTo-NixString ([string]$map[$k]))) }
    return $out + @("$indent};")
}

# The profiles/ entries an overlay may select. Read from the directory rather than
# hard-coded, so adding profiles/<name>.nix is enough: a name this list does not
# contain aborts eval inside merge.nix, and a name silently DROPPED here means a
# box with none of that profile's CLI tools and none of its GitLab groups -
# selecting a profile is the only thing that installs either - and no output
# saying so.
function Get-KnownProfileName {
    $dir = Join-Path $RepoWin 'profiles'
    if (-not (Test-Path $dir)) { return @() }
    return @(Get-ChildItem -Path $dir -Filter '*.nix' -File |
        Where-Object { $_.BaseName -ne 'default' -and $_.BaseName -ne 'merge' } |
        Select-Object -ExpandProperty BaseName)
}

# The overlay flake, from the config. mkSystem does NOT layer this repo's
# nix/users/default.nix underneath (flake.nix reads it only for its OWN
# nixosConfigurations.default), so every option nix/options.nix declares WITHOUT
# a default - username and repoPath among them; that file is the schema of
# record, this comment deliberately does not keep a second copy of the list - has
# to be emitted here even when the config is silent about it, or evaluation
# aborts. A key that is neither a declared option nor profiles/teams/teamCliTools
# now aborts mkSystem by name, so emitting a misspelt one fails loudly.
#
# NO SECRET reaches this file. custom_env_vars is split on $SecretKeyNames - the
# same list secrets.env is built from - because the nix store is world-readable.
function New-OverlayFlakeText($ud, [string]$udPath) {
    $username = [string](Get-UserDataValue $ud 'user')
    if (-not $username) { throw "no 'user:' in $udPath - that is the Linux username, there is no sane default for it" }
    # wslkube asserts both of these too (main_playbook.yaml): git would otherwise
    # commit as a placeholder identity on every repo this box touches.
    $gitName = [string](Get-UserDataValue $ud 'gitfullname')
    $gitEmail = [string](Get-UserDataValue $ud 'gitmail')
    if (-not $gitName -or -not $gitEmail) { throw "no 'gitfullname:'/'gitmail:' in $udPath - the git identity has no default" }

    # windows_username is part of the schema; the path the overlay sits under is
    # the fallback, since C:\Users\<name>\git\<overlay> is where it already is.
    $windowsUser = [string](Get-UserDataValue $ud 'windows_username')
    if (-not $windowsUser) {
        $windowsUser = $env:USERNAME
        $mUser = [regex]::Match($OverlayWin, '(?i)\\Users\\([^\\]+)\\')
        if ($mUser.Success) { $windowsUser = $mUser.Groups[1].Value }
    }
    $locale = [string](Get-UserDataValue $ud 'userlocale')
    if (-not $locale) { $locale = 'en_US.UTF-8'; Warn "  no 'userlocale' in the config - locale defaults to $locale" }

    $body = @()
    $body += "        username = $(ConvertTo-NixString $username);"
    $body += "        gitName = $(ConvertTo-NixString $gitName);"
    $body += "        gitEmail = $(ConvertTo-NixString $gitEmail);"
    $body += "        locale = $(ConvertTo-NixString $locale);"
    # Both options are declared without a default, and `null` / `false` is what
    # "leave git's default" / "no autostart" mean - so absence is emitted, not
    # omitted.
    $editor = [string](Get-UserDataValue $ud 'giteditor')
    $body += if ($editor) { "        gitEditor = $(ConvertTo-NixString $editor);" } else { '        gitEditor = null;' }
    $body += "        backupAutostart = $(ConvertTo-NixBool ([string](Get-UserDataValue $ud 'backupautostart')));"
    # Both have a default (null / false), so they are emitted only when set.
    $stateRoot = [string](Get-UserDataValue $ud 'state_root')
    if ($stateRoot) {
        $body += '        # Shareable backup state (merged history, Claude memory) - a plain'
        $body += '        # directory your folder-sync client replicates. Never a git checkout.'
        $body += "        stateRoot = $(ConvertTo-NixString $stateRoot);"
        $stateTranscripts = [string](Get-UserDataValue $ud 'state_transcripts')
        if ($stateTranscripts) { $body += "        stateTranscripts = $(ConvertTo-NixBool $stateTranscripts);" }
    }

    $body += ''
    $body += '        # Derived from where the overlay sits - no human input.'
    $body += "        windowsUsername = $(ConvertTo-NixString $windowsUser);"
    $body += "        repoPath = $(ConvertTo-NixString $OverlayWsl);"
    $body += ''
    $body += '        # Keep this overlay and flakelab itself out of ~/git.'
    # wslkube's own clone_exclude is unioned in, not replaced: it names repos that
    # exist only on the Windows mount, and dropping it re-clones them into ~/git.
    $body += Format-NixList 'cloneExclude' @(
        @('flakelab', (Split-Path $OverlayWin -Leaf)) + @(Get-UserDataList $ud 'clone_exclude' | Where-Object { $_ }) |
            Select-Object -Unique) '        '

    # profiles/ entries, from `profiles:`; `team:`/`teams:` are accepted because
    # merge.nix still honours the old name and a wslkube config may carry it.
    $profiles = @()
    foreach ($k in @('profiles', 'teams', 'team')) {
        $profiles = @(Get-UserDataList $ud $k | Where-Object { $_ })
        if ($profiles.Count -gt 0) { break }
    }
    $known = @(Get-KnownProfileName)

    # A wslkube config carries NONE of those three keys - it has no profile concept
    # at all, only a flat gitlab_groups in variables.yaml. Derive the profiles from
    # it, so a migrated config selects them instead of silently selecting nothing:
    # a group a profile already declares becomes that profile, and whatever no
    # profile claims stays a personal group below.
    $groups = @(Get-UserDataList $ud 'gitlab_groups' | Where-Object { $_ })
    $groupMap = Get-ProfileGroupMap
    if ($profiles.Count -eq 0 -and $groups.Count -gt 0) {
        $derived = @()
        foreach ($g in $groups) { if ($groupMap.Contains($g)) { $derived += $groupMap[$g] } }
        $profiles = @($derived | Select-Object -Unique)
        if ($profiles.Count -gt 0) {
            Say ("  profiles derived from gitlab_groups: {0}" -f ($profiles -join ', '))
        }
    }
    # Groups a selected profile already brings would otherwise be listed twice.
    $personalGroups = @($groups | Where-Object { -not ($groupMap.Contains($_) -and $profiles -contains $groupMap[$_]) })

    $unknown = @($profiles | Where-Object { $known -notcontains $_ })
    if ($unknown.Count -gt 0) {
        throw ("unknown profile(s) in {0}: {1} - known: {2}" -f $udPath, ($unknown -join ', '), ($known -join ', '))
    }
    # `repos:` is the THIRD way a box gets repositories, and the only one an
    # adopter with no GitLab at all can use - a GitHub-only config names its
    # clones there and has neither profiles nor gitlab_groups. Counted here, and
    # only entries carrying a url: the emission below skips the url-less ones, so
    # counting raw entries would let the empty overlay through the refusal this
    # exists to make.
    $namedRepos = @(Get-UserDataList $ud 'repos' | Where-Object { [string](Get-UserDataValue $_ 'url') })
    # A config that selects no profile, names no group AND names no repo produces
    # a box with no profile packages and an empty ~/git, and every step still
    # reports success - the exact failure this repo shipped once already. There is
    # no legitimate reason to generate that overlay, so refuse rather than warn.
    if ($profiles.Count -eq 0 -and $personalGroups.Count -eq 0 -and $namedRepos.Count -eq 0) {
        throw ("no profiles, no gitlab_groups and no repos resolved from {0} - the overlay would install no profile packages and clone no repos. Add 'profiles:' (known: {1}), 'gitlab_groups:' or 'repos:'; a wslkube checkout keeps gitlab_groups in its variables.yaml, which is read only when the config sits inside that checkout." -f $udPath, ($known -join ', '))
    }
    # Still worth saying with `repos:` set - what is missing is the profile
    # packages, not the clones - so the text names what a profile brings and what
    # it does not.
    if ($profiles.Count -eq 0) {
        Warn ("  no profiles selected - the box gets NO profile packages or profile GitLab groups; 'repos:' entries are still cloned. Known: {0}" -f ($known -join ', '))
    }
    $body += ''
    $body += '        # profiles/ entries. Selecting a profile is the only thing that'
    $body += '        # installs its gitlabGroups and profileCliTools.'
    $body += Format-NixList 'profiles' $profiles '        '

    if ($personalGroups.Count -gt 0) {
        $body += ''
        $body += '        # Personal groups only - profile groups are unioned in by profiles/merge.nix.'
        $body += Format-NixList 'gitlabGroups' $personalGroups '        '
    }

    # sshkeyautoadd is space-separated in wslkube; the FIRST key is the git identity.
    $sshRaw = [string](Get-UserDataValue $ud 'sshkeyautoadd')
    if ($sshRaw) {
        $sshKeys = @($sshRaw -split '\s+' | Where-Object { $_ })
        if ($sshKeys.Count -gt 0) {
            $body += ''
            $body += '        # sshkeyautoadd: agent-loaded on login, first one is the git identity.'
            $body += Format-NixList 'sshKeys' $sshKeys '        '
        }
    }

    # `repos:` is a LIST of {rel_path,url} in the config and of {relPath,url} here.
    # These bypass cloneExclude, which is what naming a repo explicitly means.
    $repoLines = @()
    foreach ($r in (Get-UserDataList $ud 'repos')) {
        $url = [string](Get-UserDataValue $r 'url')
        if (-not $url) { Warn '  skipping a repos entry with no url'; continue }
        $rel = [string](Get-UserDataValue $r 'rel_path')
        $repoLines += ("          {{ relPath = {0}; url = {1}; }}" -f (ConvertTo-NixString $rel), (ConvertTo-NixString $url))
    }
    if ($repoLines.Count -gt 0) {
        $body += ''
        $body += '        # Extra repos beyond group discovery; relPath is relative to ~/git.'
        $body += '        repos = ['
        $body += $repoLines
        $body += '        ];'
    }

    # Claude plugins: wslkube keeps the always-on set (claude_plugins) and the
    # marketplace they resolve against in variables.yaml, and the opt-in MCP servers
    # (claude_mcp_plugins) in user_data.yaml. mkSystem takes ONE claudePlugins list,
    # so the two concatenate. Without the marketplace every install fails silently -
    # activation only warns - and the box comes up with zero plugins.
    $marketplace = Get-UserDataValue $ud 'claude_plugin_marketplace'
    if ($marketplace) {
        $mName = [string](Get-UserDataValue $marketplace 'name')
        $mUrl = [string](Get-UserDataValue $marketplace 'url')
        if ($mName -and $mUrl) {
            $body += ''
            # The PLURAL list is canonical; the singular claudePluginMarketplace is
            # only honoured when the list is empty, so a generated overlay emits the
            # form that does not depend on that fallback. wslkube has one
            # marketplace, hence a one-element list.
            $body += '        # Must match the `name` in the marketplace''s own marketplace.json.'
            $body += '        claudePluginMarketplaces = ['
            $body += '          {'
            $body += ("            name = {0};" -f (ConvertTo-NixString $mName))
            $body += ("            url = {0};" -f (ConvertTo-NixString $mUrl))
            $body += '          }'
            $body += '        ];'
        }
        else { Warn '  claude_plugin_marketplace has no name/url - skipping' }
    }
    $claudePlugins = @(
        @(Get-UserDataList $ud 'claude_plugins' | Where-Object { $_ }) +
        @(Get-UserDataList $ud 'claude_mcp_plugins' | Where-Object { $_ }) |
            Select-Object -Unique)
    if ($claudePlugins.Count -gt 0) {
        $body += ''
        $body += '        # claude_plugins (always on) + claude_mcp_plugins (opt-in MCP servers).'
        $body += Format-NixList 'claudePlugins' $claudePlugins '        '
    }

    # wslkube hardcodes both of these in its TASK files - the kiro repo in
    # tasks/kiro.yaml, the whatsapp server dir in tasks/claude.yaml - so a migrated
    # config carries neither and regeneration silently drops them. They are config
    # keys here instead of constants because both name a private repo path, which
    # has no place in a shareable template.
    $kiroRepo = [string](Get-UserDataValue $ud 'kiro_plugin_repo')
    if ($kiroRepo) {
        $body += ''
        $body += '        # Cloned and `make install-global`-ed into ~/.kiro on activation.'
        $body += ("        kiroPluginRepo = {0};" -f (ConvertTo-NixString $kiroRepo))
    }
    $whatsappDir = [string](Get-UserDataValue $ud 'whatsapp_mcp_dir')
    if ($whatsappDir) {
        $body += ''
        $body += '        # uv runs the whatsapp MCP server out of this checkout.'
        $body += ("        whatsappMcpDir = {0};" -f (ConvertTo-NixString $whatsappDir))
    }
    elseif ($claudePlugins -contains 'mcp-whatsapp') {
        Warn '  mcp-whatsapp is enabled but whatsapp_mcp_dir is unset - the server has no checkout to run from'
    }

    # custom_aliases is a LIST of {name,command} in the config and an ATTRSET here.
    $aliases = [ordered]@{}
    foreach ($a in (Get-UserDataList $ud 'custom_aliases')) {
        $n = [string](Get-UserDataValue $a 'name')
        $c = [string](Get-UserDataValue $a 'command')
        if ($n -and $c) { $aliases[$n] = $c } else { Warn '  skipping a custom_aliases entry with no name/command' }
    }
    if ($aliases.Keys.Count -gt 0) {
        $body += ''
        $body += Format-NixAttrs 'customAliases' $aliases '        '
    }

    # The non-secret half of custom_env_vars. The other half is secrets.env.
    $envVars = Get-UserDataValue $ud 'custom_env_vars'
    $session = [ordered]@{}
    if ($envVars) {
        foreach ($k in $envVars.Keys) {
            if (($SecretKeyNames + $RetiredSecretKeyNames) -contains $k) { continue }
            if ($envVars[$k]) { $session[$k] = $envVars[$k] }
        }
    }
    if ($session.Keys.Count -gt 0) {
        $body += ''
        $body += '        # NON-SECRET custom_env_vars only - the tokens went to secrets.env.'
        $body += '        # Each entry here is what GATES its MCP server in nix/home/mcp.nix.'
        $body += Format-NixAttrs 'sessionVariables' $session '        '
    }

    $head = @(
        '{',
        '  description = "Private flakelab overlay - generated from user_data.yaml (no secrets, no remote)";',
        '',
        '  # Local flakelab checkout - no auth, no fetch.',
        ("  inputs.flakelab.url = `"path:{0}`";" -f (ConvertTo-PathUrl $RepoWsl)),
        '',
        '  outputs =',
        '    { flakelab, ... }:',
        '    {',
        ("      # Generated by setup-wsl-nix.ps1 from {0}." -f $udPath),
        '      # From here on THIS file is the profile: edit it directly, or regenerate',
        '      # it with `provision -Force`, which overwrites whatever is here.',
        '      #',
        '      # Every field below is a DECLARED OPTION: flakelab/nix/options.nix lists',
        '      # them all with their types and what each one does, and that file is the',
        '      # schema this attrset is checked against - a misspelt key or a value of',
        '      # the wrong type aborts evaluation instead of being ignored.',
        '      #',
        '      # mkSystem does NOT layer flakelab/nix/users/default.nix underneath, so',
        '      # every option declared without a default is emitted below whether the',
        '      # config named it or not. Attrsets and lists REPLACE rather than merge;',
        '      # only gitlabGroups, profileCliTools, customAliases and sessionVariables',
        '      # are unioned, and only with the profile values from flakelab/profiles/.',
        '      #',
        '      # Need something no field covers? mkSystem also takes',
        '      # { userData = { ... }; modules = [ ... ]; homeModules = [ ... ]; }, and a',
        '      # modules entry may set any flakelab.* option: scalars and lists are',
        '      # replaced, while sessionVariables, customAliases and claudeMcpServers',
        '      # merge per key (replacing one wholesale needs lib.mkForce).',
        '      #',
        '      # No secrets: the nix store is world-readable. The tokens from the same',
        '      # config live in ~/.config/tyc/secrets.env instead.',
        '      nixosConfigurations.default = flakelab.lib.mkSystem {'
    )
    return $head + $body + @('      };', '    };', '}')
}

# Set while `provision` drives `bootstrap`, so the closing interop heal is offered
# ONCE, at the end of the whole run.
$InProvision = $false
# Cross-step outcomes. Deliberately flags, not return values: the wsl.exe calls
# these functions make write to the pipeline, so a returned $false arrives as the
# last element of an array that is itself truthy - and a declined heal would then
# read as "carry on".
$BootstrapStopped = $false
$PayloadRestored = $false

# ---------- interop ----------
# `binfmt_misc` is ONE kernel-global registry shared by every distro in the WSL2
# VM, and a `nixos-rebuild switch` unregisters `WSLInterop` for all of them
# (known-issues.md). Probed from INSIDE a distro, because that is where the
# handler is visible - `wsl.exe` keeps working from Windows either way, which is
# why this script survives a wipe while every other shell in the VM does not.
# Returns 'ok' / 'broken:<reason>' / 'unknown:<reason>' so callers can print the
# REASON rather than a bare verdict.
function Get-InteropState([string]$dn) {
    if (-not (Test-Distro $dn)) { return "unknown:distro '$dn' is not registered" }
    # WSLInterop-late is the name WSL uses when systemd owns binfmt registration,
    # so both spellings count as registered.
    $probe = @(
        'if [ ! -e /proc/sys/fs/binfmt_misc/WSLInterop ] && [ ! -e /proc/sys/fs/binfmt_misc/WSLInterop-late ]; then echo NOHANDLER;'
        'elif [ ! -x /mnt/c/Windows/System32/wsl.exe ]; then echo NOWSLEXE;'
        'elif /mnt/c/Windows/System32/wsl.exe --version >/dev/null 2>&1; then echo OK;'
        'else echo EXECFAIL; fi'
    ) -join ' '
    # wsl.exe emits UTF-16 NULs (known-issues.md) - strip them or the match fails.
    $out = @(Invoke-NativeQuiet 'wsl.exe' @('-d', $dn, '--', 'sh', '-c', $probe)) -replace "`0", ''
    $verdict = ($out | Where-Object { $_ -match '\S' } | Select-Object -Last 1)
    if (-not $verdict) { return "unknown:probe produced no output in '$dn' (wsl.exe exit $LASTEXITCODE)" }
    switch ($verdict.Trim()) {
        'OK' { return 'ok' }
        'NOHANDLER' {
            return "broken:no WSLInterop entry in /proc/sys/fs/binfmt_misc - the kernel-global handler was unregistered (a nixos-rebuild / systemd reload in this VM), so EVERY .exe call in EVERY distro fails with 'exec format error'"
        }
        'EXECFAIL' {
            return "broken:the handler is registered but calling wsl.exe from inside '$dn' failed - the interop socket is dead. Recover with 'wsl --shutdown' from a Windows terminal"
        }
        'NOWSLEXE' {
            return "broken:/mnt/c/Windows/System32/wsl.exe is not visible from '$dn' - the Windows drive is not mounted (automount disabled, or /mnt/c unmounted)"
        }
        default { return "unknown:unexpected probe result '$verdict' from '$dn'" }
    }
}

# Report interop for the target distro plus any ALREADY-RUNNING sibling (probing a
# stopped one would boot it, and booting is itself what re-registers the handler -
# so it would report health it just created). $runningOnly keeps `status`
# side-effect free: it never starts a distro just to look. $advisory marks a
# report nothing acts on, so a pre-existing wipe does not read as an error the
# operator is expected to fix right now.
function Show-InteropState([string]$when, [bool]$runningOnly = $false, [bool]$advisory = $false) {
    if ($DryRun) { Write-Host "  [dry-run] probe WSL interop ($when)" -ForegroundColor DarkGray; return $true }
    $running = @(@(Invoke-NativeQuiet 'wsl.exe' @('--list', '--running', '--quiet')) -replace "`0", '' |
        ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($runningOnly) { $probes = $running }
    else { $probes = @($DistroName) + @($running | Where-Object { $_ -ne $DistroName }) }
    $healthy = $true
    Say "interop check ($when)"
    if ($probes.Count -eq 0) {
        Write-Host '  [SKIP] no distro is running - nothing to probe (WSL re-registers the handler on VM boot)' -ForegroundColor DarkGray
        return $true
    }
    foreach ($dn in ($probes | Select-Object -Unique)) {
        $state = Get-InteropState $dn
        $kind = $state.Split(':', 2)[0]
        $why = if ($state -match ':') { $state.Split(':', 2)[1] } else { '' }
        switch ($kind) {
            'ok' { Write-Host ("  [ OK ] {0}: .exe calls work" -f $dn) -ForegroundColor DarkGray }
            'unknown' { Write-Host ("  [SKIP] {0}: {1}" -f $dn, $why) -ForegroundColor DarkGray }
            default {
                if ($advisory) { Write-Host ("  [WARN] {0}: {1}" -f $dn, $why) -ForegroundColor DarkGray }
                else { Warn ("[FAIL] {0}: {1}" -f $dn, $why) }
                $healthy = $false
            }
        }
    }
    if (-not $healthy) {
        if ($advisory) {
            # Recording the state we START from, so a wipe that was already there
            # is not blamed on this run. No action wanted: the rebuild below wipes
            # interop again, so healing now buys nothing.
            Write-Host '    Not blocking - the rebuild below wipes interop anyway. The heal is offered after the switch.' -ForegroundColor DarkGray
        }
        else {
            Write-Host "    Recovery: wsl --shutdown from Windows, then re-enter the distro (/init re-registers the handler on VM boot)." -ForegroundColor Yellow
            Write-Host "    Let WSL do the registering - do NOT echo into /proc/sys/fs/binfmt_misc/register. A hand-written entry is unmanaged state in a VM-global registry (known-issues.md)." -ForegroundColor DarkGray
        }
    }
    return $healthy
}

# -Shutdown forces `wsl --shutdown`; interactively we ask (naming the cost: every
# WSL session in the VM dies); non-interactively we only print, never block and
# never shut down on an agent's behalf (known-issues.md). $resumeHint is printed
# on a decline so the operator knows how to continue. Returns 'ok' (healthy or
# healed), 'declined' (operator said no - callers stop) or 'unattended' (nobody to
# ask - callers continue, the wipe only hurts other sessions, not this script).
function Invoke-InteropHeal([string]$resumeHint, [string]$when = 'after rebuild') {
    if ($DryRun) { Write-Host "  [dry-run] wsl --shutdown (heal interop, if confirmed)" -ForegroundColor DarkGray; return 'ok' }
    if (Show-InteropState $when) { return 'ok' }
    if ($Shutdown) { return (Invoke-WslShutdown) }
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        Warn 'no interactive console - not shutting down (an agent must hand this back to the operator). Heal later:  wsl --shutdown'
        return 'unattended'
    }
    Warn "'wsl --shutdown' heals this, and KILLS EVERY WSL SESSION IN THE VM - shells, agents, editors, running jobs."
    if ((Read-Host "Run 'wsl --shutdown' now? [y/N] (Enter = no)") -notmatch '^[Yy]') {
        Warn 'Interop stays wiped for every other distro. Heal when convenient:  wsl --shutdown'
        if ($resumeHint) { Write-Host ("    Then continue with:  {0}" -f $resumeHint) -ForegroundColor Yellow }
        return 'declined'
    }
    return (Invoke-WslShutdown)
}

function Invoke-WslShutdown {
    Say 'wsl --shutdown (heal interop - all WSL sessions die)'
    & wsl.exe --shutdown
    # Verify rather than assume: the shutdown is what re-registers the handler, and
    # when it does not, the reason is what the operator needs.
    if (-not (Show-InteropState 'after wsl --shutdown')) {
        Warn 'interop is STILL broken after the shutdown - a session may have restarted the VM mid-shutdown. Retry:  wsl --shutdown'
        return 'unattended'
    }
    return 'ok'
}

# ---------- ssh-agent (unattended provisioning) ----------
# `sshKeys` in the applied flake is the single source of truth for which keys this
# distro uses: the zsh hook in nix/home/zsh.nix loads exactly those, and the first
# one is the git/clone key the activation steps use with `ssh -i`. Read it here
# too, so seeding and agent-loading cover the same set. NAMES only.
# An overlay that omits the key gets [ "id_ed25519" ], the default the sshKeys
# option declares in nix/options.nix - so the fallback chain here mirrors what
# actually gets built instead of seeding nothing.
function Get-DeclaredSshKeyName {
    foreach ($src in @($UserSourceWin, (Join-Path $RepoWin 'nix\users\default.nix'))) {
        if (-not (Test-Path $src)) { continue }
        $list = [regex]::Match((Get-Content -Raw -Path $src), 'sshKeys\s*=\s*\[(?<body>[^\]]*)\]')
        if (-not $list.Success) { continue }
        $names = @([regex]::Matches($list.Groups['body'].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
        if ($names.Count -gt 0) { return $names }
    }
    return @('id_ed25519')
}

# Declared keys that are actually present. Enumerating the folder instead pulls in
# whatever else is lying there: a personal key with another passphrase fails
# `ssh-add`, and one failed load skips the SECOND switch, which is the only reason
# the agent gets loaded at all. Undeclared files are named and left alone.
function Get-OverlayPrivateKeyName {
    if (-not (Test-Path $KeyDirWin)) { return @() }
    $declared = @(Get-DeclaredSshKeyName)
    $present = @($declared | Where-Object { Test-Path (Join-Path $KeyDirWin $_) })
    $absent = @($declared | Where-Object { -not (Test-Path (Join-Path $KeyDirWin $_)) })
    if ($absent.Count -gt 0) { Warn ("flake declares sshKeys with no file in {0}: {1}" -f $KeyDirWin, ($absent -join ', ')) }
    $extra = @(Get-ChildItem -Path $KeyDirWin -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike '*.pub' -and $_.Name -notlike '.*' -and $_.Name -ne '.gitkeep' -and $declared -notcontains $_.Name } |
        Select-Object -ExpandProperty Name)
    if ($extra.Count -gt 0) {
        Write-Host ("  not seeded - the flake's sshKeys does not list: {0}" -f ($extra -join ', ')) -ForegroundColor DarkGray
    }
    return $present
}

# Ask for the passphrase ONCE, and only when there is a key to unlock and
# -SshPassphrase was not passed. Dry runs and non-interactive consoles never
# prompt - blocking would defeat the whole point.
function Resolve-SshPassphrase {
    if ($script:SshPassphraseResolved) { return }
    $script:SshPassphraseResolved = $true
    if ($script:SshPassphraseGiven) { return }
    if (@(Get-OverlayPrivateKeyName).Count -eq 0) { return }
    if ($DryRun) { Write-Host '  [dry-run] would prompt for the SSH key passphrase' -ForegroundColor DarkGray; return }
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        Warn "no -SshPassphrase and no interactive console - an encrypted key cannot be loaded. Pass -SshPassphrase for an unattended run."
        return
    }
    $sec = Read-Host "Passphrase for the SSH key(s) in $KeyDirWin (empty if the key has none)" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)
    try { $script:SshPassphrase = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
    if (-not $script:SshPassphrase) {
        $script:SshPassphrase = ''
        Write-Host ''
        Warn 'Your SSH key has no passphrase. This is a security risk - anyone who gets'
        Warn 'access to your key file can use it immediately. You can add a passphrase to'
        Warn 'the existing key without generating a new one:'
        Write-Host ("    ssh-keygen -p -f {0}" -f $KeyWin) -ForegroundColor Yellow
        Write-Host ''
    }
}

# The Linux side. Written to a file rather than squeezed through `wsl.exe -- sh -c`
# so nothing has to survive two layers of quoting; it carries NO secret (the
# passphrase arrives as argv[2], base64-encoded to dodge every quoting/encoding
# problem, and is never persisted on the Windows side). Single-quoted here-string:
# PowerShell must not expand $.
$AgentLoadScript = @'
#!/bin/sh
# Generated by setup-wsl-nix.ps1 - do not edit, it is deleted right after it runs.
set -u
KEYDIR="${1:-}"
PP_B64="${2:-}"
shift 2 2>/dev/null || true
# The remaining argv are the key FILENAMES the flake declares in `sshKeys`.
# Enumerating KEYDIR instead loads every file lying there, so one undeclared key
# with a different passphrase fails the load - and a failed load costs the SECOND
# nixos-rebuild, which is the whole point of loading the agent.

# nix/home/git-ssh.nix runs home-manager's `services.ssh-agent` as a systemd USER unit,
# and /run/user/<uid>/ssh-agent is exactly the socket home-manager activation
# probes. Deliberately NOT `eval $(ssh-agent)`: that starts a second, private
# agent which activation would never find.
systemctl --user start ssh-agent.service >/dev/null 2>&1 \
  || echo "WARN: 'systemctl --user start ssh-agent.service' failed (user systemd manager may not be up yet)"

SSH_AUTH_SOCK="/run/user/$(id -u)/ssh-agent"
export SSH_AUTH_SOCK
if [ ! -S "$SSH_AUTH_SOCK" ]; then
  echo "FAIL: no ssh-agent socket at $SSH_AUTH_SOCK - no key loaded"
  exit 3
fi

_tmpdir=$(mktemp -d) || exit 4
chmod 700 "$_tmpdir"
printf '%s' "$PP_B64" > "$_tmpdir/pp_b64"
chmod 600 "$_tmpdir/pp_b64"
printf '#!/bin/sh\nbase64 -d "%s/pp_b64"\n' "$_tmpdir" > "$_tmpdir/askpass"
chmod 700 "$_tmpdir/askpass"
SSH_ASKPASS_REQUIRE=force; export SSH_ASKPASS_REQUIRE
SSH_ASKPASS="$_tmpdir/askpass"; export SSH_ASKPASS

rc=0
found=0
for b in "$@"; do
  f="$KEYDIR/$b"
  if [ ! -f "$f" ]; then
    echo "WARN: $b declared in sshKeys but not in $KEYDIR"
    continue
  fi
  found=$((found + 1))
  # Fingerprint comes from the CLEARTEXT public half of the private key file, so
  # this works on an encrypted key and needs no passphrase.
  fp=$(ssh-keygen -lf "$f" </dev/null 2>/dev/null | cut -d' ' -f2)
  if [ -n "$fp" ] && ssh-add -l 2>/dev/null | grep -qF "$fp"; then
    echo "OK: $b already in agent"
    continue
  fi
  cp "$f" "$_tmpdir/key"
  chmod 400 "$_tmpdir/key"
  # setsid detaches from the controlling terminal so ssh-add cannot fall back to a
  # TTY prompt, and SSH_ASKPASS_REQUIRE=force makes it take the passphrase from
  # the helper instead. Output is swallowed: no key material, no passphrase.
  if setsid -w ssh-add "$_tmpdir/key" </dev/null >/dev/null 2>&1; then
    echo "OK: $b added"
  else
    echo "FAIL: $b rejected (wrong or missing passphrase?)"
    rc=1
  fi
  rm -f "$_tmpdir/key"
done

rm -f "$_tmpdir/pp_b64" "$_tmpdir/askpass"
rmdir "$_tmpdir" 2>/dev/null
[ "$found" -eq 0 ] && echo "WARN: none of the declared sshKeys exist in $KEYDIR"
if ssh-add -l >/dev/null 2>&1; then
  echo "AGENT: $(ssh-add -l 2>/dev/null | grep -c '^') key(s) loaded"
else
  echo "AGENT: empty"
fi
exit $rc
'@

# Loads every declared private key from the overlay key folder into the distro's
# ssh-agent without a prompt, so the SECOND nixos-rebuild finds a usable agent.
# Returns $true only when the agent ended up holding the keys.
function Add-SshKeyToAgent {
    $keys = @(Get-OverlayPrivateKeyName)
    if ($keys.Count -eq 0) { Warn "no private key in $KeyDirWin - nothing to load into the ssh-agent"; return $false }
    Resolve-SshPassphrase
    Say ("Loading {0} key(s) into the ssh-agent of '{1}' (non-interactive): {2}" -f $keys.Count, $DistroName, ($keys -join ', '))
    $keyDirWsl = "$OverlayWsl/files/config/shared/ssh/keys"
    if ($DryRun) {
        Write-Host ("  [dry-run] wsl -d {0} -u {1} -- sh {2}/.ssh-agent-load.sh {3} <passphrase-b64> {4}" -f $DistroName, $User, $OverlayWsl, $keyDirWsl, ($keys -join ' ')) -ForegroundColor DarkGray
        return $false
    }
    # Base64 keeps the passphrase argv-safe (letters, digits, + / =) whatever it
    # contains; it is never printed and never written to the overlay.
    $ppB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($SshPassphrase))
    $scriptWin = Join-Path $OverlayWin '.ssh-agent-load.sh'
    $ok = $false
    try {
        # LF only - a CRLF `#!/bin/sh` script dies with "bad interpreter".
        Write-LfFile $scriptWin ($AgentLoadScript -split "`r?`n")
        # Out-Host, not the pipeline: this function's return value must stay a
        # clean boolean, and native stdout would otherwise be part of it.
        & wsl.exe -d $DistroName -u $User -- sh "$OverlayWsl/.ssh-agent-load.sh" $keyDirWsl $ppB64 @keys | Out-Host
        $ok = ($LASTEXITCODE -eq 0)
        if (-not $ok) { Warn "agent load failed (exit $LASTEXITCODE) - SSH-dependent activation steps will DEFER again; check 'flakelab doctor' in the distro" }
    }
    finally { Remove-Item -Force -ErrorAction SilentlyContinue $scriptWin }
    return $ok
}

# ---------- seeding ----------
# The no-wslkube path, made actionable. NAMES ONLY - this script neither prints
# nor invents a value. Printed at most once: `provision` checks up front (before
# the long rebuild) and the seeding step checks again afterwards, and repeating
# nine token names buries the rest of the run.
$SeedInstructionsShown = $false
function Show-ManualSeedInstructions([string]$reason) {
    Warn $reason
    if ($script:SeedInstructionsShown) {
        Write-Host '    (see the seeding instructions above)' -ForegroundColor DarkGray
        return
    }
    $script:SeedInstructionsShown = $true
    Write-Host '    Optional - the steps that need them defer until they exist. To enable them later, provide:' -ForegroundColor Yellow
    Write-Host ("      1. private SSH key : {0}" -f $KeyWin) -ForegroundColor DarkGray
    Write-Host ("         (any further key named in the flake's sshKeys is copied and" ) -ForegroundColor DarkGray
    Write-Host ("          agent-loaded too; LF line endings only - OpenSSH rejects a CRLF key)") -ForegroundColor DarkGray
    Write-Host ("      2. secrets.env      : {0}" -f $SecretsWin) -ForegroundColor DarkGray
    Write-Host ("         copy {0} and fill it in (LF only), for these names:" -f (Join-Path $RepoWin 'files\config\secrets.env.example')) -ForegroundColor DarkGray
    foreach ($k in $SecretKeyNames) { Write-Host ("           {0}" -f $k) -ForegroundColor DarkGray }
    Write-Host ("    then inside the distro:  flakelab update   (and  flakelab doctor  to see what is still deferred)") -ForegroundColor DarkGray
    Write-Host ("    (With a wslkube checkout at {0}, 'migrate' seeds both for you.)" -f $WslkubeWin) -ForegroundColor DarkGray
}

# Overlay -> distro. Runs BETWEEN the two switches: before the first there is no
# Linux user and therefore no ~ to copy into, and the second switch is what
# consumes the key through the agent.
function Copy-OverlayFilesIntoDistro {
    if (Test-Path $KeyWin) {
        # Exactly the keys the flake declares in `sshKeys` (plus their .pub
        # halves), not everything in the folder: an undeclared key is another
        # identity the distro has no business holding, and the zsh hook would
        # never load it.
        #
        # The loop, the glob and the basename all run HERE rather than in the
        # payload: a `sh -c` string handed to wsl.exe loses its double quotes and
        # every $ expansion on the way. What crosses the boundary is literal paths
        # only - nothing left to expand, nothing to lose. Same reason
        # .ssh-agent-load.sh is a FILE run as `sh <file>`.
        #
        # SINGLE quotes around the overlay-side path, and single only: they are
        # the ones that survive the boundary, and without them a checkout under
        # C:\Users\First Last\ - the ordinary Windows layout - hands sh two words
        # and the copy silently reads the wrong file. ToWslPath refuses the
        # characters this quoting cannot carry.
        $keySrc = "$OverlayWsl/files/config/shared/ssh/keys"
        $names = @()
        foreach ($k in @(Get-OverlayPrivateKeyName)) {
            $names += $k
            if (Test-Path (Join-Path $KeyDirWin "$k.pub")) { $names += "$k.pub" }
        }
        $lines = @('set -e', 'mkdir -p ~/.ssh', 'chmod 700 ~/.ssh')
        foreach ($n in $names) {
            # The DESTINATION stays unquoted so `~` still expands, which means a
            # key filename with whitespace splits there however the source is
            # quoted - so refuse it loudly instead of copying the wrong thing.
            # A single quote in the NAME closes the quoting the source path relies
            # on, and that character ToWslPath cannot catch: it guards the overlay
            # path, not the file names inside it.
            if ($n -match "[\s']") { Warn "skipping '$n': whitespace or a single quote in a key filename cannot cross the wsl.exe boundary"; continue }
            $mode = if ($n -like '*.pub') { '644' } else { '600' }
            $lines += "cp '$keySrc/$n' ~/.ssh/$n"
            $lines += "chmod $mode ~/.ssh/$n"
        }
        Say "Seeding SSH key(s) into '$DistroName'"
        Invoke-Wsl $DistroName $User @('sh', '-c', ($lines -join '; '))
    }

    if (Test-Path $SecretsWin) {
        # ~/.config/tyc/secrets.env is what nix/home/zsh.nix sources at zsh start
        # and what every credentialed MCP server inherits from. Single-quoted for
        # the same reason as the key copy above: the overlay path may contain a
        # space, and only single quotes reach sh intact. The destination stays
        # bare so `~` still expands.
        Say 'Seeding secrets.env'
        Invoke-Wsl $DistroName $User @('sh', '-c', "set -e; mkdir -p ~/.config/tyc; chmod 700 ~/.config/tyc; cp '$OverlayWsl/files/config/shared/secrets/secrets.env' ~/.config/tyc/secrets.env; chmod 600 ~/.config/tyc/secrets.env")
    }

    $missing = @()
    if (-not (Test-Path $KeyWin)) { $missing += 'SSH key' }
    if (-not (Test-Path $SecretsWin)) { $missing += 'secrets.env' }
    if ($missing.Count -gt 0) {
        Show-ManualSeedInstructions ("overlay is missing {0} - the distro is built but unconfigured." -f ($missing -join ' + '))
    }
}

# ---------- rebuild ----------
# ONE `nixos-rebuild switch` against the overlay flake. Factored out because
# provisioning runs it TWICE (see Invoke-Bootstrap) and duplicating the
# safe.directory / flake.lock preamble would be a maintenance trap.
function Invoke-NixosRebuild([string]$why) {
    Say "nixos-rebuild switch - $why (reloads systemd and WILL wipe WSL interop VM-wide)"
    # A committed lock pins the NAR hash of the flakelab checkout the overlay points
    # at, so a fresh store - exactly what provisioning has - aborts with "NAR hash
    # mismatch" once that checkout has moved on. Only an UNTRACKED lock is dropped:
    # deleting a tracked one would dirty the operator's repo behind their back.
    $lockWin = Join-Path $OverlayWin 'flake.lock'
    # Initialized OUTSIDE the Test-Path block: the switch below regenerates the
    # lock, so the post-switch cleanup at the bottom reads $tracked even when no
    # lock existed up here - and under Set-StrictMode an unset variable throws.
    $tracked = $false
    $trackedKnown = $true
    if (Test-Path $lockWin) {
        # Trackedness needs a Windows-side git, which a fresh machine (the very
        # machine this script exists for) has no reason to carry - and under
        # ErrorActionPreference=Stop a bare `& git` on such a box kills the whole
        # provision with "git is not recognized". Without git the state is
        # UNKNOWN, and unknown gets the conservative branch: keep the lock and
        # say why, because deleting a lock that turns out to be tracked dirties
        # the operator's repo behind their back, while a kept-but-stale lock
        # fails loudly with the NAR-mismatch message whose remedy is named here.
        # (A folder copied together with its flakelab checkout has a MATCHING
        # lock, so on the copy-both-folders path this keeps a valid pin.)
        $gitCmd = Get-Command git -ErrorAction SilentlyContinue
        if (Test-Path (Join-Path $OverlayWin '.git')) {
            if ($gitCmd) {
                Invoke-NativeQuiet 'git' @('-C', $OverlayWin, 'ls-files', '--error-unmatch', 'flake.lock') | Out-Null
                $tracked = ($LASTEXITCODE -eq 0)
            }
            else { $trackedKnown = $false }
        }
        if ($tracked) {
            Warn "flake.lock is git-tracked in $OverlayWin. If the switch aborts with 'NAR hash mismatch', its pin of the local flakelab checkout is stale: git rm --cached flake.lock, add it to .gitignore, and re-run."
        }
        elseif (-not $trackedKnown) {
            Warn "no git on this Windows host, so whether $OverlayWin tracks flake.lock is unknown - keeping it. If the switch aborts with 'NAR hash mismatch', delete $lockWin and re-run."
        }
        else {
            Do-Step 'remove stale flake.lock (pins the mutable flakelab input)' { Remove-Item -Force $lockWin }
        }
    }
    # Root reads the overlay flake off the 9p mount, and nix resolves it with its
    # bundled libgit2, which refuses a repo owned by another uid - every /mnt/c
    # checkout, from root's point of view. Guarded so a second switch does not
    # append a duplicate [safe] block. Written with printf because the base image
    # has no git binary to run `git config`.
    Invoke-Wsl $DistroName 'root' @('sh', '-c', "mkdir -p /root && { grep -qsF 'directory = *' /root/.gitconfig || printf '[safe]\ndirectory = *\n' >> /root/.gitconfig; }")
    # `nix shell nixpkgs#git`: the base image has no git CLI, which nix needs to
    # lock a git+file: or git+ssh: overlay input - and that is what the overlay
    # uses to reference this checkout.
    Invoke-Wsl $DistroName 'root' @('env', 'NIX_CONFIG=experimental-features = nix-command flakes',
        'nix', 'shell', 'nixpkgs#git', '-c',
        'nixos-rebuild', 'switch', '--flake', "$OverlayWsl#default")
    # The switch ran as root, so any lock it just wrote is root-owned on the 9p
    # mount, and the operator's own `nix eval` / `nix flake check` against the
    # overlay then dies with "opening file ...flake.lock: Permission denied" as
    # soon as nix wants to update it.
    # $trackedKnown guards the unknown case (no Windows git + pre-existing lock):
    # deleting there could dirty a repo that does track its lock. A lock the
    # switch itself created is still removed - the block above never ran, so
    # $trackedKnown kept its $true initialization.
    if ((Test-Path $lockWin) -and $trackedKnown -and -not $tracked) {
        Do-Step 'remove the root-owned flake.lock the switch wrote' { Remove-Item -Force $lockWin }
    }
}

# ---------- commands ----------
# The overlay skeleton this script needs, from templates/overlay - the same source
# `nix flake new -t <this repo>#overlay` scaffolds, so there is one copy of the
# overlay layout, not two. Refuses to clobber what is there (-Force).
#
# Both entry points write it: `init` with the template's placeholder flake to
# hand-edit, and `generate`/`provision` with a flake generated from the config - so
# the one-command path gets the same .gitignore that keeps secrets.env and the key
# material out of git. $flakeText overrides the template's flake.nix; $null keeps it.
function New-OverlaySkeleton([string]$root, [string]$flakeText) {
    if ($root -eq $RepoWin) { throw "refusing to write the overlay over this repo - pass -FlakeRef <path to the overlay>" }
    if (-not (Test-Path (Join-Path $TemplateWin 'flake.nix'))) { throw "template not found at $TemplateWin" }
    Do-Step "mkdir $root\files\config\shared\ssh\keys" {
        New-Item -ItemType Directory -Force -Path (Join-Path $root 'files\config\shared\ssh\keys') | Out-Null
    }
    foreach ($name in @('flake.nix', '.gitignore')) {
        $dst = Join-Path $root $name
        if ((Test-Path $dst) -and -not $Force) { Warn "keeping existing $name (use -Force to overwrite)"; continue }
        if ($name -eq 'flake.nix' -and $flakeText) { $text = $flakeText }
        elseif ($name -eq 'flake.nix') {
            # The template's input URL names the PUBLIC mirror, which does not
            # resolve yet - so a bare `nix flake new -t <flakelab>#overlay` scaffold
            # still fails to lock, and substituting a real local path is what
            # makes the overlay buildable at all. This script is one of the two
            # places that knows that path (files/scripts/nix-overlay-generate is
            # the other).
            #
            # Keyed on the template's `flakelab-url:` marker, not on the URL: a
            # pattern matching the URL would silently no-op the day the default
            # changes, and the overlay would then point at the mirror with nothing
            # said. Line-wise rather than regex-replaced so a '$' in the path
            # cannot be read as a capture-group reference. Not finding the marker
            # exactly once is fatal - writing an overlay whose input URL was never
            # substituted is worse than not writing one.
            $lines = @(Get-Content -Path (Join-Path $TemplateWin $name))
            $idx = @(0..($lines.Count - 1) | Where-Object { $lines[$_] -match '#\s*flakelab-url:' })
            if ($idx.Count -ne 1) {
                throw "templates\overlay\flake.nix must carry exactly one '# flakelab-url:' anchor line (found $($idx.Count)) - the flakelab input URL cannot be substituted"
            }
            $lines[$idx[0]] = ('  inputs.flakelab.url = "path:{0}"; # flakelab-url: substitution anchor (setup-wsl-nix.ps1)' -f (ConvertTo-PathUrl $RepoWsl))
            $text = $lines -join "`n"
        }
        else { $text = Get-Content -Raw -Path (Join-Path $TemplateWin $name) }
        Do-Step "write $name" { Write-LfFile $dst ($text -split "`r?`n") }
    }
    $keep = Join-Path $root 'files\config\shared\ssh\keys\.gitkeep'
    if (-not (Test-Path $keep)) { Do-Step 'write files\config\shared\ssh\keys\.gitkeep' { Write-LfFile $keep @('') } }
}

# The hand-written path: skeleton plus a flake full of placeholders. Only needed
# when there is no user_data.yaml to generate the flake from - `provision` does all
# of this and fills in the values.
function Invoke-Init {
    Say "init overlay skeleton: $OverlayWin"
    New-OverlaySkeleton $OverlayWin $null
    Say 'Next:' 'Yellow'
    Write-Host ("  1. edit {0} - username, git identity, gitlabGroups, profiles, sessionVariables" -f $OverlayFlakeWin) -ForegroundColor DarkGray
    Write-Host  "     (or skip steps 1-3 entirely: 'provision -Config <user_data.yaml>' generates all of it)" -ForegroundColor DarkGray
    Write-Host ("  2. drop the private SSH key(s) named in sshKeys into {0}" -f $KeyDirWin) -ForegroundColor DarkGray
    Write-Host  "     (LF line endings only - OpenSSH rejects a CRLF private key)" -ForegroundColor DarkGray
    Write-Host ("  3. write {0} (from files\config\secrets.env.example), or let 'provision'/'migrate' harvest it from a config" -f $SecretsWin) -ForegroundColor DarkGray
    Write-Host ("  4. .\setup-wsl-nix.ps1 provision -FlakeRef {0}" -f $OverlayWin) -ForegroundColor DarkGray
}

# The one-command path: everything `init` leaves as a placeholder already exists in
# a wslkube-shaped user_data.yaml, so the flake is GENERATED from it instead of
# hand-edited. Written once - an existing flake is the profile and survives, so
# regenerating is an explicit -Force.
function Set-OverlayFromConfig([string]$udPath) {
    Say "overlay flake from config: $udPath"
    $ud = Read-WslkubeConfig $udPath $WslkubeWin
    $flakeExisted = Test-Path $OverlayFlakeWin
    New-OverlaySkeleton $OverlayWin ((New-OverlayFlakeText $ud $udPath) -join "`n")
    if ($flakeExisted -and -not $Force) {
        # An overlay still carrying the template's placeholders would build a distro
        # for a user called CHANGEME, which is worth saying out loud rather than
        # applying.
        if ((Get-Content -Raw -Path $OverlayFlakeWin) -match 'CHANGEME') {
            Warn "the kept flake.nix still has the template's CHANGEME placeholders - regenerate it from the config with -Force"
        }
        return
    }
    # The rest of the run copies files as the flake's user, which is the one this
    # generated flake just declared. The flag tells the secrets step that the flake
    # already carries every non-secret custom_env_var, so it has nothing to remind
    # anyone to paste.
    $script:User = [string](Get-UserDataValue $ud 'user')
    $script:FlakeFromConfig = $true
}

# Generation on its own, so the profile can be read (or `nix eval`-ed) before a
# single distro is imported. `provision` starts with exactly this step.
function Invoke-Generate {
    if (-not $ConfigPath) { throw "nothing to generate from - pass -Config <path to a user_data.yaml> (see files\config\user_data.example.yaml)" }
    Set-OverlayFromConfig $ConfigPath
    Say ("Overlay written: {0}" -f $OverlayWin) 'Green'
    # Encoded so the printed command is paste-safe as it stands: an unquoted
    # `path:/mnt/c/Users/First Last/...` splits at the space in any shell.
    Say ("Check it before applying:  nix eval path:{0}#nixosConfigurations.default.config.system.build.toplevel.drvPath" -f (ConvertTo-PathUrl $OverlayWsl)) 'Yellow'
    Say ("Then apply with:  .\setup-wsl-nix.ps1 provision -FlakeRef {0}" -f $OverlayWin) 'Yellow'
}

function Invoke-Bootstrap {
    Say "Bootstrap '$DistroName' from overlay: $OverlayWin (user: $User)"
    $wslVer = @(Invoke-NativeQuiet 'wsl.exe' @('--version')) -replace "`0", ''
    if (-not $wslVer) { throw "WSL not available. Run once: wsl --install --no-distribution" }
    # Baseline, so a wipe that was already there is not blamed on this run - and so
    # an operator who sees .exe failures mid-run knows which switch caused them.
    Show-InteropState 'before start' $true $true | Out-Null
    # Ask for the passphrase up front so an interactive run is not left waiting
    # behind a 20-minute rebuild.
    Resolve-SshPassphrase

    if (Test-Distro $DistroName) {
        Warn "distro '$DistroName' already exists - skipping import"
    }
    else {
        $tb = $Tarball
        if (-not $tb) {
            $url = if ($ImageUrl) { $ImageUrl } else { $NixosWslRelease }
            $tb = Join-Path $env:TEMP 'nixos.wsl'
            Do-Step "download base image: $url" { Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $tb }
        }
        Do-Step "mkdir $InstallDir" { New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null }
        Do-Step "wsl --import $DistroName" {
            & wsl.exe --import $DistroName $InstallDir $tb --version 2
            if ($LASTEXITCODE -ne 0) { throw "import failed (exit $LASTEXITCODE)" }
        }
    }

    # TWO switches, deliberately. The SSH-dependent home-manager activation steps
    # (kiro-plugin clone, the Claude marketplaces and plugins, and the statusline
    # that runs after them) need a loaded ssh-agent, and the key can only be copied
    # into ~ AFTER the Linux user exists - which is what the FIRST switch creates.
    # One switch therefore always runs those steps before any key is present and
    # they DEFER (non-fatally, and silently as far as the operator is concerned).
    # Order: switch #1 (user + system) -> terminate -> key/secrets -> load agent ->
    # switch #2, which re-runs activation and completes them. Both switches are
    # idempotent, so #2 is safe to repeat and -SkipSecondSwitch opts out.
    Invoke-NixosRebuild 'switch 1/2: create the user and the system generation'
    # The first switch on a fresh import creates the user, but the running instance
    # will not resolve it until restarted; the next wsl call cold-boots the new
    # config. Kept BEFORE the heal: terminating a systemd distro can wipe binfmt
    # again, so the shutdown below has to be the LAST lifecycle op or it heals
    # nothing.
    Do-Step "wsl --terminate $DistroName (apply new user)" { & wsl.exe --terminate $DistroName | Out-Null }
    # Declining stops the run: nothing has been seeded yet, and a second run
    # replays this cheaply (import skipped, warm store). An unattended run
    # continues - the wipe costs this script nothing, only the operator's other
    # sessions.
    if ((Invoke-InteropHeal ".\setup-wsl-nix.ps1 provision   # import is skipped, the run resumes from here") -eq 'declined') {
        Say "Stopped after switch 1/2 - the distro exists, nothing is seeded yet." 'Yellow'
        $script:BootstrapStopped = $true
        return
    }

    Copy-OverlayFilesIntoDistro
    $agentLoaded = Add-SshKeyToAgent

    if ($SkipSecondSwitch) {
        Warn "second switch skipped (-SkipSecondSwitch). If SSH steps are still deferred, run in the distro: flakelab update"
    }
    elseif ($DryRun -or $agentLoaded) {
        Invoke-NixosRebuild 'switch 2/2: complete the deferred SSH steps (kiro-plugin, Claude marketplaces + plugins, statusline)'
    }
    else {
        Warn "ssh-agent holds no key - skipping the second switch (it would only defer again)."
        Warn "Log in interactively once ('wsl -d $DistroName') and run: flakelab update"
    }
    # Switch 2 wiped interop again, so the run closes on the same gate. Under
    # `provision` it is deferred to the end of the whole run.
    if (-not $InProvision) { Invoke-InteropHeal '' 'at end of run' | Out-Null }
    Say "Applied '$DistroName'." 'Green'
}

# Restores whatever `flakelab backup` has staged in the overlay (gitconfig, ssh
# config, shell history, and secrets.env if it was backed up rather than
# hand-written). Non-fatal: a fresh PC has no payload yet, which is not an error.
function Restore-Backup {
    Say 'flakelab backup --restore (gitconfig, ssh config, shell history, secrets)'
    # An instance name with no directory beside the overlay restores the SHARED
    # categories, reports success, and looks exactly like a restore that worked -
    # the failure this flag exists to fix. Refuse it here, where the names that DO
    # exist can be listed. Only once there is a payload at all: a fresh PC has no
    # instances/ yet, which is the ordinary first run and not an error.
    $instRoot = Join-Path $OverlayWin 'files\config\instances'
    if ($RestoreInstance -and (Test-Path $instRoot) -and -not (Test-Path (Join-Path $instRoot $RestoreInstance))) {
        $have = @(Get-ChildItem -Path $instRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        $names = if ($have.Count -gt 0) { $have -join ', ' } else { '(none)' }
        $msg = ("no backup instance '{0}' under {1} - it holds: {2}. " -f $RestoreInstance, $instRoot, $names) +
               "Name the one to restore with  -RestoreInstance <name>  (the default is the distro name, $DistroName)."
        # A dry run reports and carries on: it touches nothing, and stopping it
        # would hide every later step from the operator checking the plan.
        if ($DryRun) { Warn $msg } else { throw $msg }
    }
    # Named only when it differs from this distro, which is already nix-backup's
    # own default: an in-distro nix-backup old enough to predate --instance exits
    # 1 on the unknown option, and the default run must stay exactly what it was.
    # -cne, not -ne: the payload directory is on a case-sensitive filesystem, so
    # 'nixos' and 'NixOS' are different instances and only one of them exists.
    $inst = if ($RestoreInstance -and $RestoreInstance -cne $DistroName) { " --instance '$RestoreInstance'" } else { '' }
    if ($inst) { Say "  restoring backup instance '$RestoreInstance'" 'DarkGray' }
    $cmd = DistroCmd 'backup' 'nix-backup' "--restore$inst"
    if ($DryRun) { Write-Host "  [dry-run] wsl -d $DistroName -u $User -- zsh -lc '$cmd'" -ForegroundColor DarkGray; return }
    & wsl.exe -d $DistroName -u $User -- zsh -lc $cmd
    if ($LASTEXITCODE -ne 0) { Warn "flakelab backup --restore (instance '$RestoreInstance') returned $LASTEXITCODE - nothing staged yet, or see its output above" }
}

# secrets.env is sourced from .zshrc (interactive only), so a login shell alone
# leaves GITLAB_TOKEN unset and `flakelab clone` hard-exits on its guard.
function Invoke-CloneRepos {
    if ($SkipCloneRepos) { Warn 'flakelab clone skipped (-SkipCloneRepos)'; return }
    Say 'flakelab clone (GitLab group discovery)'
    $cmd = '[ -r ~/.config/tyc/secrets.env ] && { set -a; . ~/.config/tyc/secrets.env; set +a; }; ' `
        + (DistroCmd 'clone' 'nix-clone-repos')
    if ($DryRun) { Write-Host "  [dry-run] wsl -d $DistroName -u $User -- zsh -lc '$cmd'" -ForegroundColor DarkGray; return }
    & wsl.exe -d $DistroName -u $User -- zsh -lc $cmd
    if ($LASTEXITCODE -ne 0) {
        Warn "flakelab clone failed - is GITLAB_TOKEN in ~/.config/tyc/secrets.env?"
    }
}

# ---------- migrate (one-off, from the Ansible predecessor) ----------
# The ancestor is the private wslkube repo this flake was migrated from: same layout
# (files/config/user_data.yaml carries the tokens in custom_env_vars,
# files/config/instances/<distro> carries the backup payload), and
# files/scripts/nix-backup already implements `--restore --from <repo> --instance
# <name>` for exactly this. Only the Windows half was missing.
function Get-WslkubeInstance {
    if ($WslkubeInstance) { return $WslkubeInstance }
    $instRoot = Join-Path $WslkubeWin 'files\config\instances'
    $cand = Get-ChildItem -Path $instRoot -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'kube') } |
        Sort-Object { @(Get-ChildItem -Path $_.FullName -Recurse -File -ErrorAction SilentlyContinue).Count } -Descending |
        Select-Object -First 1
    if ($cand) { return $cand.Name }
    return ''
}

# This step reads LIVE credentials out of the wslkube checkout and the running
# distro - every token in user_data.yaml plus the private SSH key - and writes
# them UNENCRYPTED into the overlay on the Windows mount. Cheap to redo, painful
# to do by accident, so it is consented to rather than assumed:
# -CopyLiveCredentials pre-authorises it for an unattended run, a non-interactive
# console without that flag skips it, and either way what gets copied is listed by
# NAME only.
function Confirm-CredentialCopy([string]$udPath, [int]$tokenCount = 0) {
    if ($CopyLiveCredentials -or $DryRun) { return $true }
    Warn 'about to copy LIVE credentials into the overlay, unencrypted on the Windows mount:'
    Write-Host ("    from  {0}" -f $udPath) -ForegroundColor DarkGray
    Write-Host ("      ->  {0}   ({1} token(s))" -f $SecretsWin, $tokenCount) -ForegroundColor DarkGray
    if (Test-Distro $WslkubeDistro) {
        Write-Host ("    from  {0}:~/.ssh (private key)" -f $WslkubeDistro) -ForegroundColor DarkGray
        Write-Host ("      ->  {0}" -f $KeyDirWin) -ForegroundColor DarkGray
    }
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        Warn 'no interactive console - skipping. Pass -CopyLiveCredentials to authorise it, or seed the two files yourself.'
        return $false
    }
    if ((Read-Host 'Copy them now? [y/N] (Enter = no)') -match '^[Yy]') { return $true }
    Warn 'skipped - nothing copied.'
    Show-ManualSeedInstructions 'credential copy declined.'
    return $false
}

function Set-OverlaySecretsAndKey([string]$udPath) {
    if ($udPath -and (Test-Path $udPath)) {
        $ud = Read-UserDataYaml $udPath
        $envVars = Get-UserDataValue $ud 'custom_env_vars'
        # custom_env_vars is where wslkube keeps them; a top-level key is accepted
        # too rather than silently dropping a token that is plainly there.
        $present = @($SecretKeyNames | Where-Object {
                [string](Get-UserDataValue $envVars $_) -or [string](Get-UserDataValue $ud $_)
            })
        # A config with no token at all - the first-run wizard writes exactly that -
        # has nothing to copy: no consent prompt, no nine "not in" lines. The steps
        # that want a token defer, which the seeding note below says once.
        if ($present.Count -eq 0) {
            Say "no token in $(Split-Path $udPath -Leaf) - secrets.env not written (optional; the steps that need one defer)"
            $lines = $null
        }
        elseif (-not (Confirm-CredentialCopy $udPath $present.Count)) { return }
        else { $lines = @('# Runtime secrets - generated by setup-wsl-nix.ps1. Git-ignored, NOT encrypted.') }
        foreach ($k in $present) {
            $val = [string](Get-UserDataValue $envVars $k)
            if (-not $val) { $val = [string](Get-UserDataValue $ud $k) }
            # A literal single quote cannot be represented inside the single-quoted
            # assignment below, and a secrets.env that breaks `source` takes every
            # token with it (`flakelab backup` skips such values for the same reason).
            if ($val.Contains("'")) { Warn "  $k contains a single quote - skipped"; continue }
            $lines += ("{0}='{1}'" -f $k, $val)
            Write-Host "  + $k" -ForegroundColor DarkGray
        }
        if ($null -ne $lines) {
            $missing = @($SecretKeyNames | Where-Object { $present -notcontains $_ })
            if ($missing.Count -gt 0) { Write-Host ("  not in the config (their steps defer): {0}" -f ($missing -join ', ')) -ForegroundColor DarkGray }
            Do-Step "mkdir $SecretsDirWin" { New-Item -ItemType Directory -Force -Path $SecretsDirWin | Out-Null }
            Do-Step "write secrets.env" { Write-LfFile $SecretsWin $lines }
        }

        # The non-secret endpoints are NOT secrets.env material: each one GATES its
        # MCP server in nix/home/mcp.nix, and they belong in the overlay flake's
        # `sessionVariables` (declarative, rebuilt into the shell). A flake GENERATED
        # from this config already carries them by construction, so the reminder is
        # for the hand-written overlay only, and only for what that flake does not
        # define. NAMES ONLY.
        $flakeText = if (Test-Path $OverlayFlakeWin) { Get-Content -Raw -Path $OverlayFlakeWin } else { '' }
        $found = @()
        if (-not $script:FlakeFromConfig) {
            $found = @($NonSecretKeyNames | Where-Object {
                    ($null -ne (Get-UserDataValue $envVars $_)) -and
                    ($flakeText -notmatch ("(?m)^\s*{0}\s*=" -f [regex]::Escape($_)))
                })
        }
        if ($found.Count -gt 0) {
            Warn "non-secret config in the config file - add to the FLAKE, not secrets.env:"
            Write-Host ("    Edit {0} and extend sessionVariables:" -f $OverlayFlakeWin) -ForegroundColor Yellow
            Write-Host "        sessionVariables = {" -ForegroundColor DarkGray
            foreach ($k in $found) {
                Write-Host ("          {0} = `"<value from {1}>`";" -f $k, $udPath) -ForegroundColor DarkGray
            }
            Write-Host "        };" -ForegroundColor DarkGray
            Write-Host ("    Or generate the whole flake from the config:  .\setup-wsl-nix.ps1 generate -Force -Config {0}" -f $udPath) -ForegroundColor DarkGray
            Write-Host ("    Then rebuild:  wsl -d {0} -u {1} -- zsh -lc 'flakelab update'" -f $DistroName, $User) -ForegroundColor DarkGray
        }
    }
    else { Warn "no user_data.yaml - skipping secrets.env" }

    if (-not (Test-Path $KeyWin)) {
        Do-Step "mkdir $KeyDirWin" { New-Item -ItemType Directory -Force -Path $KeyDirWin | Out-Null }
        if (Test-Distro $WslkubeDistro) {
            Do-Step "pull id_ed25519 from '$WslkubeDistro'" {
                $k = (& wsl.exe -d $WslkubeDistro -- sh -c "cat ~/.ssh/id_ed25519 2>/dev/null")
                # LF only: OpenSSH refuses a private key whose lines end in CRLF.
                if ($k) { Write-LfFile $KeyWin $k }
            }
        }
        if (-not (Test-Path $KeyWin)) { Write-Host "  no SSH key at $KeyWin (optional; the SSH-dependent steps defer)" -ForegroundColor DarkGray }
    }
}

# Runs `flakelab backup` inside the target distro, so the distro must already be built.
# Sets $PayloadRestored only when the restore actually ran - the marker depends on
# it, and a marker written after a no-op turns `migrate` into a silent skip from
# then on.
function Restore-FromWslkube {
    $script:PayloadRestored = $false
    if (-not (Test-Path $WslkubeWin)) { return }
    if (-not (Test-Distro $DistroName)) { Warn "distro '$DistroName' not present - build it first (provision/bootstrap)"; return }
    $wkWsl = ToWslPath $WslkubeWin
    # Capture the source distro's LIVE state (fresh backup) so the migration moves
    # current data, not a stale snapshot. -WslkubeInstance forces a named saved
    # instance instead.
    if ($WslkubeInstance) {
        $inst = $WslkubeInstance
    }
    elseif (Test-Distro $WslkubeDistro) {
        Say "Fresh backup of live '$WslkubeDistro' before migrating"
        Invoke-Wsl $WslkubeDistro '' @('zsh', "$wkWsl/files/scripts/wsl-backup", '--force')
        $inst = $WslkubeDistro
    }
    else {
        $inst = Get-WslkubeInstance
        Warn "source distro '$WslkubeDistro' not running - migrating last saved instance '$inst'"
    }
    if (-not $inst) { Warn "no wslkube instance found (pass -WslkubeInstance)"; return }
    Say "Migrating wslkube instance '$inst' into '$DistroName'"
    # --skip-conflicts: this runs over wsl.exe with no TTY, and the files that
    # differ are the ones activation rewrites here - they must keep the local
    # copy. Without it the restore exits 1 and the throw below skips the marker.
    Invoke-Wsl $DistroName $User @('zsh', '-lc', (DistroCmd 'backup' 'nix-backup' "--restore --skip-conflicts --from '$wkWsl' --instance '$inst'"))
    $script:PayloadRestored = $true
}

function Invoke-Migrate {
    if ((Test-Path $Marker) -and -not $Force) {
        Say "Already migrated: $(Get-Content $Marker -TotalCount 1). Use -Force to re-run." 'Green'; return
    }
    if (-not (Test-Path $WslkubeWin)) { throw "no wslkube checkout at $WslkubeWin - nothing to migrate from." }
    Say "Migrate wslkube -> nix (prep secrets/key, then flakelab backup --restore; wslkube stays READ-ONLY)"
    Set-OverlaySecretsAndKey $ConfigPath
    Restore-FromWslkube
    if ($PayloadRestored -or $DryRun) {
        # --skip-conflicts keeps local copies rather than failing, and that list
        # scrolls past in the restore's own output. Repeat it here, and put the
        # count in the marker, so "Migration done." can never be the whole story.
        $keptFile = Join-Path $OverlayWin 'files\config\.last-restore-kept'
        $kept = if (Test-Path $keptFile) { @(Get-Content $keptFile | Where-Object { $_.Trim() }) } else { @() }
        $note = if ($kept.Count -gt 0) { "; {0} file(s) kept local" -f $kept.Count } else { "" }
        Do-Step "write marker" { Write-LfFile $Marker ("migrated {0} via flakelab backup --from wslkube{1}" -f (Get-Date -Format o), $note) }
        if ($kept.Count -gt 0) {
            Warn ("{0} file(s) were NOT restored - the local copy was kept:" -f $kept.Count)
            foreach ($k in $kept) { Warn "    $k" }
            Warn "Those are rewritten by this box's activation or hold its own credentials. Pass -Force (flakelab backup --force) only if you mean to overwrite them."
        }
        Say "Migration done." 'Green'
    }
    else {
        Warn "no payload restored - not marking the migration done. Build the distro first, then re-run 'migrate'."
    }
}

function Invoke-Provision {
    Say "PROVISION: overlay flake from config -> seed prep -> switch 1 -> key/secrets + ssh-agent -> switch 2 -> restore -> clone" 'Green'
    $script:InProvision = $true
    if ($ConfigPath) {
        # ONE command: everything `init` leaves as a placeholder is in this config,
        # so the flake is generated instead of hand-edited, and the same file feeds
        # secrets.env. The credential copy is still consented to in
        # Set-OverlaySecretsAndKey.
        Set-OverlayFromConfig $ConfigPath
        Set-OverlaySecretsAndKey $ConfigPath
    }
    if (-not (Test-Path $KeyWin) -or -not (Test-Path $SecretsWin)) {
        # Checked up front, before the long rebuild: a -Config run on a fresh box has
        # no distro to pull a key from, and `migrate` is no fallback either - it
        # throws without a wslkube checkout.
        $what = @(); if (-not (Test-Path $KeyWin)) { $what += 'SSH key' }; if (-not (Test-Path $SecretsWin)) { $what += 'secrets.env' }
        $why = if ($ConfigPath) { "no {0} in the overlay ({1} carries none)." -f ($what -join ' and '), (Split-Path $ConfigPath -Leaf) }
        else { "no {0} in the overlay - no config to harvest them from (no -Config, no wslkube checkout at {1})." -f ($what -join ' and '), $WslkubeWin }
        Show-ManualSeedInstructions $why
    }
    Invoke-Bootstrap
    if ($BootstrapStopped) { return }
    # A wslkube checkout carries a richer payload (its own instance dirs), so it
    # wins; without one this falls back to whatever `flakelab backup` has staged in the
    # overlay, which on a fresh PC is nothing and not an error.
    Restore-FromWslkube
    if ($PayloadRestored) {
        # Silence here would read as "the instance you named was restored".
        if ($RestoreInstanceNamed) {
            Warn "-RestoreInstance '$RestoreInstance' was not used: the wslkube checkout's payload won. -WslkubeInstance names an instance there."
        }
    }
    else { Restore-Backup }
    Invoke-CloneRepos
    Invoke-InteropHeal '' 'at end of run' | Out-Null
    $elapsed = "{0:mm}m{0:ss}s" -f ([datetime]0 + ((Get-Date) - $started))
    Say "Provision done in $elapsed." 'Green'
    Say "Verify inside the distro:  wsl -d $DistroName -u $User -- zsh -lc 'flakelab doctor'" 'Yellow'
    Say "Start with: wsl -d $DistroName" 'Yellow'
}

function Invoke-Status {
    Say 'setup-wsl-nix status'
    $distroState = if (Test-Distro $DistroName) { 'present' } else { 'absent' }
    $overlayState = if ($OverlayIsFallback) { 'this repo - PLACEHOLDERS, run: init' }
    elseif (Test-Path (Join-Path $OverlayWin 'flake.nix')) { 'present' }
    else { 'MISSING (run: init)' }
    $keyState = if (Test-Path $KeyWin) { 'present' } else { 'MISSING' }
    $secretsState = if (Test-Path $SecretsWin) { 'present' } else { 'MISSING' }
    $payloadState = if (Test-Path (Join-Path $OverlayWin "files\config\instances\$DistroName")) { 'staged' } else { 'none' }
    $migratedState = if (Test-Path $Marker) { Get-Content $Marker -TotalCount 1 } else { 'no' }
    $wslkubeState = if (Test-Path $WslkubeWin) { $WslkubeWin } else { 'absent' }
    $configState = if ($ConfigPath) { $ConfigPath } else { 'none (pass -Config to generate the flake)' }
    Write-Host ("  overlay       : {0} ({1})" -f $OverlayWin, $overlayState)
    Write-Host ("  config        : {0}" -f $configState)
    Write-Host ("  linux user    : {0}" -f $User)
    Write-Host ("  declared keys : {0}" -f ((Get-DeclaredSshKeyName) -join ', '))
    Write-Host ("  distro '{0}' : {1}" -f $DistroName, $distroState)
    Write-Host ("  SSH key       : {0}" -f $keyState)
    Write-Host ("  secrets.env   : {0}" -f $secretsState)
    Write-Host ("  backup payload: {0}" -f $payloadState)
    Write-Host ("  wslkube       : {0}" -f $wslkubeState)
    Write-Host ("  migrated      : {0}" -f $migratedState)
    if ($overlayState -ne 'present') {
        if ($ConfigPath) { Warn "Next:  .\setup-wsl-nix.ps1 provision   (generates the overlay flake from $ConfigPath)" }
        else { Warn "Next:  .\setup-wsl-nix.ps1 provision -Config <path to user_data.yaml>   (or 'init' to write the flake by hand)" }
    }
    elseif ($distroState -eq 'absent') { Warn "Next:  .\setup-wsl-nix.ps1 provision" }
    # Cheapest place to answer "why do .exe calls fail in my shell?" - running
    # distros only, so `status` still starts nothing.
    Show-InteropState 'now' $true $true | Out-Null
}

switch ($Command) {
    'init' { Invoke-Init }
    'generate' { Invoke-Generate }
    'provision' { Invoke-Provision }
    'bootstrap' { Invoke-Bootstrap }
    'migrate' { Invoke-Migrate }
    default { Invoke-Status }
}
