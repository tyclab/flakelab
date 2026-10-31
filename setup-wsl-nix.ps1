<#
.SYNOPSIS
    Provisions a fresh NixOS-WSL developer distro from the private overlay flake.

.DESCRIPTION
    The logic lives here, in the versioned repo. The overlay named by -FlakeRef
    carries only what must not be pushed here: flake.nix (username, git identity,
    GitLab groups, profiles, sessionVariables), secrets.env and the SSH keys.

    ONE command does all of it, because every value the overlay needs is in one
    user_data.yaml (files\config\user_data.example.yaml is the schema):
    `provision` harvests secrets.env out of that config, imports the base image,
    GENERATES the overlay flake from the same file inside it with this checkout's
    files/scripts/nix-overlay-generate (the generator `flakelab overlay-gen`
    runs; there is no PowerShell copy), then applies. -Config names the config
    file; without it the copy beside the overlay is read. Nothing to hand-edit.

    FRESH PC, NO CONFIG: in an interactive console `provision` asks for the four
    values a config cannot do without (Linux user, git name, git mail, profiles)
    and writes them as <overlay>-payload\user_data.yaml - the same schema
    -Config takes - then carries on. That file is found again on every later run
    (edit it, re-run with -Force to regenerate the flake). Without a console the
    refusal below stands: there is nobody to answer.

    Commands:
      generate   Write the overlay (skeleton + a flake GENERATED from the config)
                 and STOP, so the profile can be read or `nix eval`-ed before
                 anything is applied. The generator runs inside the distro, so
                 this IMPORTS the base image first when -DistroName is not there
                 yet; the `provision` after it finds the distro and skips that.
      init       Overlay skeleton with PLACEHOLDERS (flake.nix + .gitignore + the
                 SSH key folder) from templates/overlay, for writing the flake by
                 hand. Only needed when there is no user_data.yaml to generate it
                 from. Unlike `generate`, it never touches WSL.
      provision  Full run: check the config, harvest secrets.env from it, import
                 the base image, generate the overlay flake from the config inside
                 it, bootstrap, then restore the `flakelab backup` payload and
                 clone the GitLab groups. The fresh-PC command. A config the
                 generator refuses stops the run after the import; re-running
                 skips the import.
      bootstrap  Download/import the base image and apply the overlay with TWO
                 `nixos-rebuild switch` runs (see Invoke-Bootstrap for why),
                 seeding the SSH key + secrets.env and loading the key into the
                 distro's ssh-agent in between.
      status     Show what is present, what is missing, and interop health.

    WARNING (known-issues.md): `nixos-rebuild` boots systemd and wipes WSL
    interop VM-wide. Run from an expendable Windows terminal. After each switch
    the script probes interop, names the reason it is broken, and offers
    `wsl --shutdown` - which heals it and KILLS EVERY WSL SESSION in the VM.
    Declining right after the first switch stops provisioning (nothing is seeded
    yet) and prints how to resume; -Shutdown answers yes up front; a
    non-interactive run only warns and never shuts down by itself.

    EXIT CODES: 1 - a step threw, a switch's verdict or the restarted boot's
    included. Otherwise the verdict flakelab-switch-result gives the distro as the
    run closes: 0 - applied. 4 - activated, with units not running (named there;
    inspect with systemctl status <unit>). 2, 3, 100 - activation failed,
    unverified, reboot required. A run stopped at a declined heal closes on the
    restarted boot's verdict. setup-wsl-nix.cmd passes the code on.

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
    A user_data.yaml (start from files\config\user_data.example.yaml in this
    repo). `generate`/`provision` hand it to files/scripts/nix-overlay-generate
    inside the distro, which writes the overlay flake, and `provision` harvests
    secrets.env from it, so nothing has to be hand-edited. Keys are lowercase,
    as YAML reads them: `User:` is not `user:`. Before anything is downloaded,
    the config must exist on a Windows drive, name user, gitfullname and gitmail,
    and name no target other than wsl; everything else is the generator's to
    check, inside the distro. Defaults to <overlay>-payload\user_data.yaml, the
    file the first-run questions write.

    The generated flake is the profile from then on: it is never overwritten
    without -Force, so a hand-edit survives every later `provision`.

.PARAMETER Tarball
    Path to nixos.wsl. Downloaded from the NixOS-WSL releases when omitted.

.PARAMETER ImageUrl
    Override the base image URL (air-gapped mirror, pinned release).

.PARAMETER SshPassphrase
    Passphrase of the private key(s) under <overlay>-payload\shared\ssh\keys. The
    SSH-dependent home-manager activation steps (the Claude marketplace +
    plugins, the statusline that follows them) run from a systemd
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

.PARAMETER CopyLiveCredentials
    Pre-authorise the credential copy. `provision` reads LIVE tokens out of the
    config it provisions from and writes them UNENCRYPTED into the overlay - so
    without this flag an interactive run asks first, and a non-interactive one
    skips the copy rather than doing it silently. Names of what would be copied
    are shown; values never are.

.PARAMETER Shutdown
    Answer yes up front to the `wsl --shutdown` this script offers after each
    rebuild. `nixos-rebuild` unregisters the kernel-global WSLInterop handler for
    EVERY distro in the VM (known-issues.md), and the only recovery is a shutdown
    - which also KILLS EVERY WSL SESSION.

.PARAMETER Force
    Overwrite existing overlay files on `init`, REGENERATE the overlay flake from
    the config on `generate` and `provision` (both keep an existing flake.nix
    without it, so a hand-edit survives).

.PARAMETER DryRun
    Print every step without touching WSL, the overlay or the network. The
    overlay flake is NOT generated: the generator runs inside the imported
    distro and a dry run imports nothing, so it prints the generator command,
    and the config gets only the early check (see -Config).

.EXAMPLE
    # ONE command: flake and secrets derived from the config.
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
    [ValidateSet('init', 'generate', 'provision', 'bootstrap', 'status')]
    [string]$Command = 'status',

    [string]$FlakeRef,
    [string]$Config,
    # A box registered under another name must pass it, or `provision` imports a SECOND distro.
    [string]$DistroName = 'flakelab',
    [string]$Tarball,
    [string]$ImageUrl,
    # Derived from the distro name so a second distro cannot import onto the first one's VHD.
    [string]$InstallDir = "$env:LOCALAPPDATA\WSL\$DistroName",
    [string]$SshPassphrase,
    # See .PARAMETER RestoreInstance; defaults to this distro's name, as `flakelab backup --restore` does.
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

# Nothing escapes a single quote across into zsh; refused before the distro is built.
if ($RestoreInstance.Contains("'")) {
    throw ("-RestoreInstance {0}: a single quote in an instance name cannot cross the wsl.exe boundary. Rename the instance directory." -f $RestoreInstance)
}

if ($env:WSL_DISTRO_NAME) {
    throw "Run this from Windows PowerShell, not from inside WSL."
}

$NixosWslRelease = 'https://github.com/nix-community/NixOS-WSL/releases/latest/download/nixos.wsl'

function Say([string]$m, [string]$c = 'Cyan') { Write-Host "> $m" -ForegroundColor $c }
# Payload lives BESIDE the overlay: nix copies the whole overlay into the world-readable store. Same as backupRoot.
function Get-PayloadRoot([string]$overlay) { return ($overlay.TrimEnd('\', '/') + '-payload') }
function Warn([string]$m) { Write-Host "! $m" -ForegroundColor Yellow }
function Do-Step([string]$desc, [scriptblock]$block) {
    if ($DryRun) { Write-Host "  [dry-run] $desc" -ForegroundColor DarkGray; return }
    Write-Host "  $desc" -ForegroundColor DarkGray
    & $block
}
function ToWslPath([string]$p) {
    # Only a drive path converts to /mnt/<letter>; a UNC path silently became '/mnt/\...'.
    if ($p -notmatch '^[A-Za-z]:[\\/]') {
        throw ('cannot convert "{0}" to a WSL path: it is not on a Windows drive. Keep this checkout and the overlay under C:\Users\<name>\git\, not on WSL''s own filesystem (\\wsl$\...).' -f $p)
    }
    # A single quote ends the quoting every `sh -c` payload relies on, and nothing escapes it across wsl.exe.
    if ($p.Contains("'")) {
        throw ('cannot convert "{0}" to a WSL path: a single quote in a directory name cannot cross the wsl.exe boundary. Rename the folder.' -f $p)
    }
    # --flake <path>#default is a bare argument: nix cuts at the first '#' and applies another flake.
    if ($p.Contains('#')) {
        throw ('cannot convert "{0}" to a WSL path: a "#" in a directory name is the flake-ref fragment delimiter, so --flake <path>#default would be cut there and rebuild a different flake. Rename the folder.' -f $p)
    }
    $drive = $p.Substring(0, 1).ToLower()
    return '/mnt/' + $drive + ($p.Substring(2) -replace '\\', '/')
}
# ConvertTo-PathUrl: body of a `path:` URL. A space breaks the parse, `#`/`?` silently truncate (C:\Users\First Last).
# '%' goes FIRST or later escapes are escaped again; .Replace, not -replace (no regex, no '$' references).
function ConvertTo-PathUrl([string]$p) {
    return $p.Replace('%', '%25').Replace(' ', '%20').Replace('#', '%23').Replace('?', '%3F')
}
function Test-Distro([string]$dn) {
    $list = @(Invoke-NativeQuiet 'wsl.exe' @('--list', '--quiet')) -replace "`0", '' -split "`r?`n" | ForEach-Object { $_.Trim() }
    return $list -contains $dn
}
# LF-only, UTF-8 without BOM: a CR lands inside secrets.env values (bad Private-Token header), CRLF keys are rejected.
function Write-LfFile([string]$Path, [string[]]$Lines) {
    $text = ($Lines -join "`n") + "`n"
    [IO.File]::WriteAllText($Path, $text, (New-Object System.Text.UTF8Encoding $false))
}
# PS 5.1 + Stop: redirecting a native command's stderr makes every stderr line terminating (killed a provision
# 2026-08-23). Probe-style native calls go through here: stderr dropped, stdout returned, $LASTEXITCODE set.
function Invoke-NativeQuiet([string]$exe, [string[]]$argv) {
    $ErrorActionPreference = 'Continue'
    & $exe @argv 2>&1 | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }
}
# $AllowExit: exit codes this call site handles itself; strict stays the default.
function Invoke-Wsl([string]$dn, [string]$asUser, [string[]]$cmd, [int[]]$AllowExit = @()) {
    $wslArgs = @('-d', $dn)
    if ($asUser) { $wslArgs += @('-u', $asUser) }
    $wslArgs += @('--') + $cmd
    if ($DryRun) { Write-Host "  [dry-run] wsl.exe $($wslArgs -join ' ')" -ForegroundColor DarkGray; return }
    & wsl.exe @wslArgs
    if ($LASTEXITCODE -ne 0 -and $AllowExit -notcontains $LASTEXITCODE) { throw "wsl.exe failed (exit $LASTEXITCODE) for: $($cmd[0])" }
}

$RepoWin = $PSScriptRoot
$RepoWsl = ToWslPath $RepoWin
$TemplateWin = Join-Path $RepoWin 'templates\overlay'

# `init` creates the overlay and `generate`/`provision` generate its flake; every other command needs one.
if (-not $FlakeRef) {
    $siblingDir = Split-Path $RepoWin -Parent
    $FlakeRef = Join-Path $siblingDir 'flakelab-config'
}
# Resolve-Path throws on a missing path, and generation targets an overlay that does not exist yet.
if (Test-Path $FlakeRef) { $FlakeRefFull = (Resolve-Path $FlakeRef).Path }
elseif ([IO.Path]::IsPathRooted($FlakeRef)) { $FlakeRefFull = [IO.Path]::GetFullPath($FlakeRef) }
else { $FlakeRefFull = [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $FlakeRef)) }

# One config drives the overlay flake and secrets.env; empty means hand-seeding.
if ($Config) {
    if (-not (Test-Path $Config)) { throw "-Config '$Config' not found" }
    $ConfigPath = (Resolve-Path $Config).Path
}
else {
    # The copy beside the overlay (beside, not in: it carries cleartext tokens).
    $ConfigPath = Join-Path (Get-PayloadRoot $FlakeRefFull) 'user_data.yaml'
    if (-not (Test-Path $ConfigPath)) { $ConfigPath = '' }
}

# First-run wizard: interactive `provision` asks for the four required values; non-interactive and -DryRun refuse.
function Test-InteractiveConsole {
    return ([Environment]::UserInteractive -and -not [Console]::IsInputRedirected)
}

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
    $ConfigPath = Invoke-ConfigWizard (Join-Path (Get-PayloadRoot $FlakeRefFull) 'user_data.yaml')
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
    # -CopyLiveCredentials writes live tokens under the overlay: falling back to this repo is an error
    # (observed 2026-08-22, secrets.env landed in the checkout).
    if ($CopyLiveCredentials) {
        throw ("no overlay flake at $FlakeRef, and '$Command' writes credentials into the overlay - " +
               "refusing to write them into this repo. Pass -FlakeRef <your overlay>, " +
               "or create one first with: .\setup-wsl-nix.ps1 init")
    }
    # Building from this repo's placeholders yields an unusable box, so it refuses; `status` only reports the fallback.
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
$PayloadWin = Get-PayloadRoot $OverlayWin
$PayloadWsl = ToWslPath $PayloadWin
$KeyDirWin = Join-Path $PayloadWin 'shared\ssh\keys'
$KeyWin = Join-Path $KeyDirWin 'id_ed25519'
# The path nix-backup already owns on both ends (files/scripts/nix-backup, the
# `secrets` shared category), so a restored payload lands exactly where seeding
# reads it and no second location is invented.
$SecretsDirWin = Join-Path $PayloadWin 'shared\secrets'
$SecretsWin = Join-Path $SecretsDirWin 'secrets.env'
# Old-layout payload under the overlay: not moved for the operator, but said, since nix still copies it into the store.
$OldPayloadHere = @('shared', 'instances', 'snapshots', 'user_data.yaml') |
    Where-Object { Test-Path (Join-Path $OverlayWin "files\config\$_") }
if ($OldPayloadHere -and -not $OverlayIsFallback) {
    Warn ("{0}\files\config still holds {1} - the layout from before {2}. Keys and secrets.env are read from {2} now, and every rebuild copies the overlay, that folder included, into the world-readable nix store." -f $OverlayWin, ($OldPayloadHere -join ', '), $PayloadWin)
    Warn ("Move it once:  New-Item -ItemType Directory -Force '{0}' | Out-Null; {1}" -f $PayloadWin, (($OldPayloadHere | ForEach-Object { "Move-Item '{0}' '{1}'" -f (Join-Path $OverlayWin "files\config\$_"), $PayloadWin }) -join '; '))
}

# With sopsSecretsFile the plaintext seed is deliberately ABSENT; checks demanding $SecretsWin must know that
# (mirrors nix-doctor's SOPS_RENDER branch).
function Get-SopsSecretsPath {
    $flakeWin = Join-Path $OverlayWin 'flake.nix'
    if (-not (Test-Path $flakeWin)) { return '' }
    # Anchored at line start: the template's commented-out switch must not read as enrolled.
    $m = @(Select-String -Path $flakeWin -Pattern '^\s*sopsSecretsFile\s*=\s*\.?/?([^;\s]+)\s*;')
    if ($m.Count -eq 0) { return '' }
    return (Join-Path $OverlayWin ($m[0].Matches[0].Groups[1].Value -replace '/', '\'))
}

# THE predicate for "does this box still need the plaintext seed?". A function,
# not a captured variable: `generate` writes flake.nix and `provision` writes
# secrets.env mid-run, so both inputs can change after startup.
function Test-SecretsSeedNeeded {
    if (Test-Path $SecretsWin) { return $false }
    $sops = Get-SopsSecretsPath
    return -not ($sops -and (Test-Path $sops))
}

$UserSourceWin = Join-Path $OverlayWin 'nix\users\default.nix'
if (-not (Test-Path $UserSourceWin)) { $UserSourceWin = Join-Path $OverlayWin 'flake.nix' }
# Read again once the generator has run: a kept, hand-edited flake names its own user.
function Get-OverlayUser {
    if (-not (Test-Path $UserSourceWin)) { return '' }
    $um = Select-String -Path $UserSourceWin -Pattern 'username\s*=\s*"([^"]+)"'
    if (-not $um) { throw "Could not read 'username' from $UserSourceWin" }
    return $um.Matches[0].Groups[1].Value
}
$User = Get-OverlayUser

# NAMES of the runtime secrets ~/.config/flakelab/secrets.env must define - the same
# set as files/config/secrets.env.example. Shared by the config harvester and
# the manual-seed instructions; values never live here.
$SecretKeyNames = @('GITLAB_TOKEN', 'GH_TOKEN', 'HASS_TOKEN',
    'PROXMOX_TOKEN_ID', 'PROXMOX_TOKEN_SECRET',
    'GRAFANA_SERVICE_ACCOUNT_TOKEN',
    'NTFY_URL', 'NTFY_TOKEN', 'NOTIFY_WEBHOOK_URL')
# Secret NAMES no longer harvested or asked for (the feature behind them is not
# shipped), but still never allowed into the flake: a config that carries one
# must not see it land in the world-readable store just because it left the list.
$RetiredSecretKeyNames = @('WHATSAPP_API_KEY', 'SYNOLOGY_PASSWORD', 'SYNOLOGY_DEVICE_ID')

# Non-secret counterparts belong in sessionVariables, not secrets.env; GRAFANA_URL/WHATSAPP_BRIDGE_HOST gate MCP servers.
$NonSecretKeyNames = @('HASS_URL', 'PROXMOX_API_URL', 'PROXMOX_VERIFY_SSL',
    'GRAFANA_URL', 'WHATSAPP_BRIDGE_HOST')

# A credential-shaped name is withheld too, whatever the config calls it: the word, not a substring, so
# MAX_OUTPUT_TOKENS stays; a location (_URL, _DIR, ...) names no secret. Kept identical to nix-overlay-generate's
# _secret_shape and _secret_exempt (test-nix-overlay-generate pins both); the named secrets first, as NTFY_URL is one.
$SecretNamePattern = '(^|_)(TOKEN|SECRET|PASSWORD|PASSWD|APIKEY|CREDENTIAL)(_|$)|API_KEY|PRIVATE_KEY'
$SecretNameExempt = '_(URL|DIR|FILE|PATH|HOST|NAMESPACE)$'
# A webhook's URL is its credential, so that word wins over the location suffix.
$SecretNameAlways = '(^|_)WEBHOOK(_|$)'
function Test-SecretName([string]$name) {
    if (($SecretKeyNames + $RetiredSecretKeyNames) -contains $name) { return $true }
    $n = $name.ToUpperInvariant()
    if ($n -match $SecretNameAlways) { return $true }
    if ($n -match $SecretNameExempt) { return $false }
    return ($n -match $SecretNamePattern)
}

# -SshPassphrase given (even '') means never prompt; captured here, as $PSBoundParameters in a function is its own.
$SshPassphraseGiven = $PSBoundParameters.ContainsKey('SshPassphrase')
if (-not $SshPassphrase) { $SshPassphrase = '' }
$SshPassphraseResolved = $false

# Set when the overlay flake is to be GENERATED from the config (none yet, or -Force),
# which makes the non-secret half of custom_env_vars part of the flake by construction.
# StrictMode: initialise before first use.
$FlakeFromConfig = $false
# Set by Confirm-ConfigBeforeImport: the config as the distro sees it, and the Windows user
# the generator is told (empty when the config names its own).
$ConfigWsl = ''
$GenWindowsUser = ''

# user_data.yaml is the one schema. Parsed by hand: PS 5.1 has no YAML reader, and the file is flat.
# Read here only for the early check and the secrets.env harvest: the overlay flake is
# files/scripts/nix-overlay-generate's, run inside the distro (Invoke-OverlayGenerator).
# A line outside that subset is named by number, never quoted: its value may be a token.
function ConvertFrom-YamlScalar([string]$raw) {
    $s = $raw.Trim()
    # Anchored and greedy, so a value may contain '#' or the other quote character.
    if ($s -match "^'(.*)'\s*(?:#.*)?$") { return $Matches[1] -replace "''", "'" }
    if ($s -match '^"(.*)"\s*(?:#.*)?$') { return $Matches[1] -replace '\\"', '"' }
    return ($s -replace '\s+#.*$', '').Trim()
}

# Read more than once by `provision` (the early check, then the secrets), reported once.
$YamlReported = @{}
function Read-UserDataYaml([string]$path) {
    if (-not (Test-Path $path)) { throw "config not found: $path" }
    $raw = [ordered]@{}
    $key = ''
    $unread = @()
    $n = 0
    foreach ($line in [IO.File]::ReadAllLines($path)) {
        $n++
        if ($line.Trim() -eq '' -or $line -match '^\s*#') { continue }
        if ($line -match '^([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$') {
            $key = $Matches[1]
            $raw[$key] = @{ Scalar = ''; Lines = @() }
            $v = $Matches[2].Trim()
            if ($v -ne '') { $raw[$key].Scalar = (ConvertFrom-YamlScalar $v) }
            continue
        }
        if ($key -and $line -match '^\s+\S') { $raw[$key].Lines += $line }
        elseif ($line.Trim() -notmatch '^(---|\.\.\.)$') { $unread += ("{0}: line {1} is not a top-level 'key: value' - not read" -f $path, $n) }
    }
    $out = [ordered]@{}
    foreach ($k in $raw.Keys) {
        $lines = @($raw[$k].Lines)
        $skipped = if ($lines.Count -gt 0 -and $raw[$k].Scalar -ne '') { 1 } else { 0 }
        if ($lines.Count -eq 0) {
            # Flow-style list (`[a, b]`, `[]` empty): kept as a scalar it would reach the overlay as a literal string.
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
            $keyCol = 0
            foreach ($l in $lines) {
                $col = ($l -replace '[A-Za-z_].*$', '').Length
                if ($cur -and $col -gt $keyCol) { $skipped++; continue }
                if ($l -match '^\s*-\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$') {
                    $keyCol = $col
                    $cur = [ordered]@{}
                    $cur[$Matches[1]] = (ConvertFrom-YamlScalar $Matches[2])
                    $items += $cur
                }
                elseif ($cur -and $l -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$') {
                    $cur[$Matches[1]] = (ConvertFrom-YamlScalar $Matches[2])
                }
                else { $skipped++ }
            }
            $out[$k] = $items
        }
        elseif ($lines[0] -match '^\s*-\s*\S') {
            $skipped += @($lines | Where-Object { $_ -notmatch '^\s*-' }).Count
            $out[$k] = @($lines |
                Where-Object { $_ -match '^\s*-\s*\S' } |
                ForEach-Object { ConvertFrom-YamlScalar ($_ -replace '^\s*-\s*', '') })
        }
        else {
            $m = [ordered]@{}
            foreach ($l in $lines) {
                if ($l -match '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*:\s*(.*)$') { $m[$Matches[1]] = (ConvertFrom-YamlScalar $Matches[2]) }
                else { $skipped++ }
            }
            $out[$k] = $m
        }
        if ($skipped -gt 0) { $unread += ("{0}: {1} line(s) under '{2}' are outside the flat YAML this reader parses - not read" -f $path, $skipped, $k) }
    }
    if (-not $YamlReported.ContainsKey($path)) {
        $YamlReported[$path] = $true
        foreach ($u in $unread) { Warn "  $u" }
    }
    return $out
}

function Get-UserDataValue($ud, [string]$key) {
    if ($null -ne $ud -and $ud.Contains($key)) { return $ud[$key] }
    return $null
}

# The generator reads the config inside the distro, so after the download and the import.
# What a config is most often refused for is refused here first: the identity nothing
# defaults, a target this script does not provision, a path the distro cannot reach.
# Profiles, shapes and the rest stay the generator's to judge, so the two cannot drift.
function Confirm-ConfigBeforeImport([string]$udPath) {
    $ud = Read-UserDataYaml $udPath
    # -cnotcontains: the generator reads keys as YAML does, case and all; this dictionary ignores case.
    $keys = @($ud.Keys)
    $absent = @(@('user', 'gitfullname', 'gitmail') | Where-Object { $keys -cnotcontains $_ -or -not [string]$ud[$_] })
    if ($absent.Count -gt 0) {
        $names = ($absent | ForEach-Object { "'$($_):'" }) -join ', '
        throw "no $names in $udPath - the Linux username and the git identity have no default (keys are lowercase)"
    }
    $target = [string](Get-UserDataValue $ud 'target')
    if ($target -and $target -ne 'wsl') {
        throw "target '$target' in $udPath - setup-wsl-nix.ps1 provisions wsl overlays only; write this one with files/scripts/nix-overlay-generate"
    }
    try { $script:ConfigWsl = ToWslPath $udPath }
    catch { throw "-Config: the generator reads it from inside the distro, which sees Windows drives only - $($_.Exception.Message)" }
    # From the C:\Users\<name> the overlay sits under, which the distro cannot tell; the config's own value wins.
    $script:GenWindowsUser = ''
    if ($keys -cnotcontains 'windows_username' -or -not [string]$ud['windows_username']) {
        $winUser = $env:USERNAME
        $mUser = [regex]::Match($OverlayWin, '(?i)\\Users\\([^\\]+)\\')
        if ($mUser.Success) { $winUser = $mUser.Groups[1].Value }
        # It crosses wsl.exe's login shell as an argument; the config's value is read from the file.
        if ($winUser -match '[''"$`\\]') { throw "Windows user name '$winUser' cannot cross the wsl.exe boundary - set windows_username in $udPath" }
        $script:GenWindowsUser = $winUser
    }
    if ((Test-Path $OverlayFlakeWin) -and -not $Force) {
        if ((Get-Content -Raw -Path $OverlayFlakeWin) -match 'CHANGEME') {
            Warn "the kept flake.nix still has the template's CHANGEME placeholders - regenerate it from the config with -Force"
        }
        return
    }
    # Until the generator writes the flake and Get-OverlayUser reads it back.
    $script:User = [string]$ud['user']
    $script:FlakeFromConfig = $true
}

$InProvision = $false
# Flags, not return values: wsl.exe output in the pipeline makes a returned $false a truthy array.
$BootstrapStopped = $false
$SwitchVerdict = $null
$CarriedUnits = @()
$ExitCode = 0

# binfmt_misc is VM-global and a switch unregisters WSLInterop for every distro; probed from inside one.
# Returns 'ok' / 'broken:<reason>' / 'unknown:<reason>'. WSLInterop-late (systemd-owned) counts too.
function Get-InteropState([string]$dn) {
    if (-not (Test-Distro $dn)) { return "unknown:distro '$dn' is not registered" }
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

# Interop for the target plus already-running siblings only: probing a stopped one boots it and re-registers the handler.
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
            Write-Host '    Not blocking - interop is checked again after the switch, with recovery offered if needed.' -ForegroundColor DarkGray
        }
        else {
            Write-Host "    Recovery: wsl --shutdown from Windows, then re-enter the distro (/init re-registers the handler on VM boot)." -ForegroundColor Yellow
            Write-Host "    Let WSL do the registering - do NOT echo into /proc/sys/fs/binfmt_misc/register. A hand-written entry is unmanaged state in a VM-global registry (known-issues.md)." -ForegroundColor DarkGray
        }
    }
    return $healthy
}

# -Shutdown forces `wsl --shutdown`; interactively ask (every WSL session dies); unattended only print, never shut down.
# Returns 'ok', 'declined' (callers stop) or 'unattended' (callers continue).
function Invoke-InteropHeal([string]$resumeHint, [string]$when = 'after rebuild') {
    if ($DryRun) { Write-Host "  [dry-run] wsl --shutdown (heal interop, if confirmed)" -ForegroundColor DarkGray; return 'ok' }
    if (Show-InteropState $when) { return 'ok' }
    if ($Shutdown) { return (Invoke-WslShutdown) }
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        Warn 'no interactive console - not shutting down (it kills every WSL session, so it never runs unattended). Heal later:  wsl --shutdown'
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
    if (-not (Show-InteropState 'after wsl --shutdown')) {
        Warn 'interop is STILL broken after the shutdown - a session may have restarted the VM mid-shutdown. Retry:  wsl --shutdown'
        return 'unattended'
    }
    return 'ok'
}

# `sshKeys` in the applied flake is the source of truth; absent, [ "id_ed25519" ] as options.nix declares.
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

# Declared keys only: an undeclared key with another passphrase fails ssh-add and skips the second switch.
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

# A file, not `sh -c`, to avoid two quoting layers; no secret in it (passphrase as base64 argv[2], never persisted).
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
  # The caller gates the SECOND switch on this exit code, so an agent that is
  # empty HERE has to fail: the socket died between the add and this probe, or
  # none of the declared keys was readable from KEYDIR. Reporting success sends
  # the switch into an empty agent - the SSH steps defer again, silently, and
  # the "log in once and run flakelab update" warning never prints.
  echo "AGENT: empty"
  rc=1
fi
exit $rc
'@

function Add-SshKeyToAgent {
    $keys = @(Get-OverlayPrivateKeyName)
    if ($keys.Count -eq 0) { Warn "no private key in $KeyDirWin - nothing to load into the ssh-agent"; return $false }
    Resolve-SshPassphrase
    Say ("Loading {0} key(s) into the ssh-agent of '{1}' (non-interactive): {2}" -f $keys.Count, $DistroName, ($keys -join ', '))
    $keyDirWsl = "$PayloadWsl/shared/ssh/keys"
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
        # LF only: a CRLF `#!/bin/sh` script dies with "bad interpreter".
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
    if (Test-SecretsSeedNeeded) {
        Write-Host ("      2. secrets.env      : {0}" -f $SecretsWin) -ForegroundColor DarkGray
        Write-Host ("         copy {0} and fill it in (LF only), for these names:" -f (Join-Path $RepoWin 'files\config\secrets.env.example')) -ForegroundColor DarkGray
        foreach ($k in $SecretKeyNames) { Write-Host ("           {0}" -f $k) -ForegroundColor DarkGray }
    }
    else {
        Write-Host ("      2. secrets.env      : not needed - sops-nix renders them from {0}" -f (Get-SopsSecretsPath)) -ForegroundColor DarkGray
    }
    Write-Host ("    then inside the distro:  flakelab update   (and  flakelab doctor  to see what is still deferred)") -ForegroundColor DarkGray
}

# Runs BETWEEN the switches: no ~ before the first, and the second consumes the key via the agent.
function Copy-OverlayFilesIntoDistro {
    if (Test-Path $KeyWin) {
        # Only declared keys (and .pub). The loop runs here: `sh -c` via wsl.exe loses double quotes and $ expansions.
        # Single quotes around the overlay path, the only ones that survive (C:\Users\First Last); ToWslPath refuses the rest.
        $keySrc = "$PayloadWsl/shared/ssh/keys"
        $names = @()
        foreach ($k in @(Get-OverlayPrivateKeyName)) {
            $names += $k
            if (Test-Path (Join-Path $KeyDirWin "$k.pub")) { $names += "$k.pub" }
        }
        $lines = @('set -e', 'mkdir -p ~/.ssh', 'chmod 700 ~/.ssh')
        foreach ($n in $names) {
            # The destination stays unquoted for `~`, so whitespace or a quote in a key name is refused.
            if ($n -match "[\s']") { Warn "skipping '$n': whitespace or a single quote in a key filename cannot cross the wsl.exe boundary"; continue }
            $mode = if ($n -like '*.pub') { '644' } else { '600' }
            $lines += "cp '$keySrc/$n' ~/.ssh/$n"
            $lines += "chmod $mode ~/.ssh/$n"
        }
        Say "Seeding SSH key(s) into '$DistroName'"
        Invoke-Wsl $DistroName $User @('sh', '-c', ($lines -join '; '))
    }

    if (Test-Path $SecretsWin) {
        # zsh.nix sources ~/.config/flakelab/secrets.env; source single-quoted (spaces), destination bare so `~` expands.
        Say 'Seeding secrets.env'
        Invoke-Wsl $DistroName $User @('sh', '-c', "set -e; mkdir -p ~/.config/flakelab; chmod 700 ~/.config/flakelab; cp '$PayloadWsl/shared/secrets/secrets.env' ~/.config/flakelab/secrets.env; chmod 600 ~/.config/flakelab/secrets.env")
    }

    $missing = @()
    if (-not (Test-Path $KeyWin)) { $missing += 'SSH key' }
    if (Test-SecretsSeedNeeded) { $missing += 'secrets.env' }
    if ($missing.Count -gt 0) {
        Show-ManualSeedInstructions ("no {0} in the overlay yet - the distro is built, and only the steps that need it wait." -f ($missing -join ' + '))
    }
}

function Invoke-NixosRebuild([string]$why) {
    Say "nixos-rebuild switch - $why (interop is checked after the switch)"
    # A committed lock pins a moved checkout's NAR hash ("NAR hash mismatch"); only an UNTRACKED lock is dropped.
    $lockWin = Join-Path $OverlayWin 'flake.lock'
    # Initialized outside the Test-Path block: the cleanup reads it, and StrictMode throws on unset.
    $tracked = $false
    $trackedKnown = $true
    if (Test-Path $lockWin) {
        # Without Windows git (a fresh PC; a bare `& git` would kill the run) trackedness is unknown: keep the lock and say why,
        # since deleting a tracked lock dirties the operator's repo.
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
    # nix's libgit2 refuses a repo owned by another uid (every /mnt/c checkout for root); printf: no git in the base image.
    Invoke-Wsl $DistroName 'root' @('sh', '-c', "mkdir -p /root && { grep -qsF 'directory = *' /root/.gitconfig || printf '[safe]\ndirectory = *\n' >> /root/.gitconfig; }")
    # A switch that got as far as activating exits 0, 2 or 4, and which of those
    # it was says nothing reliable (files/scripts/switch-result has why), so those
    # three go to the verdict. Anything else never activated and throws here.
    try {
        # `nix shell nixpkgs#git`: the base image has no git, which locking a git+ input needs.
        Invoke-Wsl $DistroName 'root' @('env', 'NIX_CONFIG=experimental-features = nix-command flakes',
            'nix', 'shell', 'nixpkgs#git', '-c',
            'nixos-rebuild', 'switch', '--flake', "path:$(ConvertTo-PathUrl $OverlayWsl)#default") -AllowExit @(2, 4)
        $switchRc = if ($DryRun) { 0 } else { $LASTEXITCODE }
        Get-SwitchResult @('--rc', "$switchRc")
        Confirm-SwitchResult ($why -split ':')[0] $switchRc
    }
    finally {
        # A root-written lock on 9p breaks the operator's nix commands; removed in a finally (nix locks before it builds).
        # $trackedKnown guards the unknown case; a lock the switch created is still removed.
        if ((Test-Path $lockWin) -and $trackedKnown -and -not $tracked) {
            Do-Step 'remove the root-owned flake.lock the switch wrote' {
                Remove-Item -Force -ErrorAction SilentlyContinue $lockWin
                if (Test-Path $lockWin) { Warn "could not remove $lockWin - delete it, or nix commands against the overlay die on 'Permission denied'" }
            }
        }
    }
}

# Bytes, not the pipeline: code-page decoding renames non-ASCII paths and a leak check must name them.
# stdout drained asynchronously, or a full pipe hangs check-ignore.
function Invoke-GitBytes([string[]]$argv, [byte[]]$stdin) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'git'
    $psi.Arguments = (@($argv | ForEach-Object { '"' + (($_ -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1') + '"' }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $out = New-Object System.IO.MemoryStream
    $copy = $proc.StandardOutput.BaseStream.CopyToAsync($out)
    $err = $proc.StandardError.ReadToEndAsync()
    if ($stdin) { $proc.StandardInput.BaseStream.Write($stdin, 0, $stdin.Length) }
    $proc.StandardInput.Close()
    $proc.WaitForExit()
    $copy.Wait()
    [pscustomobject]@{ ExitCode = $proc.ExitCode; Bytes = $out.ToArray(); Err = $err.Result }
}

# Twin of overlay-git.zsh's overlaygit_is_sops_dotenv, line for line.
function Test-SopsDotenv([string]$path) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    $mac = $false; $ver = $false
    foreach ($line in [System.IO.File]::ReadAllLines($path)) {
        if ($line -eq '') { continue }
        if ($line.StartsWith('#')) { if ($line -cnotmatch '^#ENC\[.*\]$') { return $false }; continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 0) { return $false }
        $key = $line.Substring(0, $eq); $val = $line.Substring($eq + 1)
        if ($key -ceq 'sops_mac') { if ($val -cnotmatch '^ENC\[.*\]$') { return $false }; $mac = $true }
        elseif ($key -ceq 'sops_version') { if ($val -eq '') { return $false }; $ver = $true }
        elseif ($key -cmatch '^sops_(lastmodified|mac_only_encrypted|shamir_threshold|(un)?encrypted_(suffix|regex|comment_regex)|(age|pgp|kms|gcp_kms|azure_kv|hc_vault|key_groups)__.*)$') { }
        elseif ($val -ne '' -and $val -cnotmatch '^ENC\[AES256_GCM,data:.*,iv:.*,tag:.*,type:.*\]$') { return $false }
    }
    return ($mac -and $ver)
}

# Twin of overlaygit_leaks: staged paths the TEMPLATE .gitignore ignores, via a scratch git dir (read-only).
# $null means git could not answer: a refusal, never "no leaks".
function Get-OverlayGitLeaks([string]$root) {
    $probe = Join-Path ([System.IO.Path]::GetTempPath()) ('flakelab-probe-' + [guid]::NewGuid().ToString('N'))
    try {
        $r = Invoke-GitBytes @('init', '-q', $probe) $null
        if ($r.ExitCode -ne 0) { return $null }
        $r = Invoke-GitBytes @('-C', $root, "--git-dir=$probe\.git", '--work-tree=.', '-c', 'core.quotePath=false',
            'ls-files', '-o', '--exclude-standard', '-z') $null
        if ($r.ExitCode -ne 0) { return $null }
        $result = [pscustomobject]@{ Candidates = $r.Bytes; Leaks = @() }
        if ($r.Bytes.Length -eq 0) { return $result }
        New-Item -ItemType Directory -Force -Path (Join-Path $probe '.git\info') | Out-Null
        Copy-Item -LiteralPath (Join-Path $TemplateWin '.gitignore') -Destination (Join-Path $probe '.git\info\exclude') -Force
        $h = Invoke-GitBytes @('-C', $probe, '-c', 'core.quotePath=false', 'check-ignore', '--no-index', '--stdin', '-z') $r.Bytes
        if ($h.ExitCode -gt 1) { return $null }
        $hits = @([System.Text.Encoding]::UTF8.GetString($h.Bytes) -split "`0" | Where-Object { $_ -ne '' })
        # Only a dotenv can be the sops exception, so only those are opened.
        $result.Leaks = @($hits | Where-Object { -not ($_ -like '*.env' -and (Test-SopsDotenv (Join-Path $root ($_ -replace '/', '\')))) })
        return $result
    }
    finally {
        if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# As nix-overlay-generate: one commit, no remote, autocrlf off (the distro reads the same files). An existing .git is
# left as is. All or nothing; only the checked list is staged; signing and hooks off.
function Initialize-OverlayRepository([string]$root) {
    if (Test-Path -LiteralPath (Join-Path $root '.git')) { return }
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Warn "no git on this Windows host - $root is not a git repository. 'git init' it later for history; 'flakelab update' checks drift once it has a remote."
        return
    }
    Do-Step "git init $root (one commit, no remote)" {
        $check = Get-OverlayGitLeaks $root
        if ($null -eq $check) { Warn "could not list what a first commit in $root would carry - the overlay is written, the repository is not"; return }
        if ($check.Leaks.Count -gt 0) {
            Warn "$root is NOT initialised as a repository: its .gitignore would let these into the first commit, and the template keeps them out of git"
            $check.Leaks | Select-Object -First 20 | ForEach-Object { Write-Host "      $_" -ForegroundColor Yellow }
            if ($check.Leaks.Count -gt 20) { Write-Host "      ... and $($check.Leaks.Count - 20) more" -ForegroundColor Yellow }
            Warn "bring $root\.gitignore up to $TemplateWin\.gitignore and rerun, or let 'flakelab update' initialise it afterwards"
            return
        }
        if ($check.Candidates.Length -eq 0) { Warn "nothing in $root to commit - the repository is not initialised"; return }
        $dotGit = Join-Path $root '.git'
        $list = [System.IO.Path]::GetTempFileName()
        $done = $false
        try {
            [System.IO.File]::WriteAllBytes($list, $check.Candidates)
            $steps = [ordered]@{
                init   = @('init', '-q', '--initial-branch=main')
                config = @('config', 'core.autocrlf', 'false')
                add    = @('--literal-pathspecs', 'add', "--pathspec-from-file=$list", '--pathspec-file-nul')
                commit = @('-c', 'user.name=flakelab', '-c', 'user.email=flakelab@localhost', '-c', 'commit.gpgsign=false',
                    'commit', '-q', '--no-verify', '-m', 'overlay generated by setup-wsl-nix.ps1')
            }
            foreach ($step in $steps.GetEnumerator()) {
                $r = Invoke-GitBytes (@('-C', $root) + $step.Value) $null
                if ($r.ExitCode -ne 0) {
                    Warn "git $($step.Key) failed in $root - the overlay is written, the repository is not: $(($r.Err -split "`n")[0])"
                    return
                }
            }
            $done = $true
        }
        finally {
            Remove-Item -LiteralPath $list -Force -ErrorAction SilentlyContinue
            if (-not $done -and (Test-Path -LiteralPath $dotGit)) { Remove-Item -LiteralPath $dotGit -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
}

# The `init` skeleton from templates/overlay (one copy of the layout); refuses to clobber without -Force.
function New-OverlaySkeleton([string]$root) {
    if ($root -eq $RepoWin) { throw "refusing to write the overlay over this repo - pass -FlakeRef <path to the overlay>" }
    if (-not (Test-Path (Join-Path $TemplateWin 'flake.nix'))) { throw "template not found at $TemplateWin" }
    # The key directory is made BESIDE the overlay (Get-PayloadRoot): the overlay
    # holds the flake and nothing a `nix` command must not copy into the store.
    $keyDir = Join-Path (Get-PayloadRoot $root) 'shared\ssh\keys'
    Do-Step "mkdir $root, $keyDir" {
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        New-Item -ItemType Directory -Force -Path $keyDir | Out-Null
    }
    foreach ($name in @('flake.nix', '.gitignore')) {
        $dst = Join-Path $root $name
        if ((Test-Path $dst) -and -not $Force) { Warn "keeping existing $name (use -Force to overwrite)"; continue }
        if ($name -eq 'flake.nix') {
            # Substitute the flakelab URL keyed on the `flakelab-url:` marker, not the URL; line-wise so a '$' is literal.
            # The marker must occur exactly once: an unsubstituted overlay is worse than none.
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
    Initialize-OverlayRepository $root
}

function Invoke-Init {
    Say "init overlay skeleton: $OverlayWin"
    New-OverlaySkeleton $OverlayWin
    Say 'Next:' 'Yellow'
    Write-Host ("  1. edit {0} - username, git identity, gitlabGroups, profiles, sessionVariables" -f $OverlayFlakeWin) -ForegroundColor DarkGray
    Write-Host  "     (or skip steps 1-3 entirely: 'provision -Config <user_data.yaml>' generates all of it)" -ForegroundColor DarkGray
    Write-Host ("  2. drop the private SSH key(s) named in sshKeys into {0}" -f $KeyDirWin) -ForegroundColor DarkGray
    Write-Host  "     (LF line endings only - OpenSSH rejects a CRLF private key)" -ForegroundColor DarkGray
    Write-Host ("  3. write {0} (from files\config\secrets.env.example), or let 'provision' harvest it from a config" -f $SecretsWin) -ForegroundColor DarkGray
    Write-Host ("  4. .\setup-wsl-nix.ps1 provision -FlakeRef {0}" -f $OverlayWin) -ForegroundColor DarkGray
}

function Assert-WslAvailable {
    $wslVer = @(Invoke-NativeQuiet 'wsl.exe' @('--version')) -replace "`0", ''
    if (-not $wslVer) { throw "WSL not available. Run once: wsl --install --no-distribution" }
}

# Shared by `bootstrap`, `provision` and `generate`: the overlay generator runs inside the distro.
function Import-BaseDistro {
    if (Test-Distro $DistroName) {
        Warn "distro '$DistroName' already exists - skipping import"
        return
    }
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

# The overlay flake is written by files/scripts/nix-overlay-generate, this checkout's copy,
# run inside the distro: one generator, under test-nix-overlay-generate, where a PowerShell
# twin used to drift from it. The base image has neither zsh nor git, so `nix shell` brings
# both, as it brings switch 1 its git. It runs as uid 1000 - the base image's `nixos`, the
# flakelab user once switch 1 ran - because root's files on /mnt/c keep uid 0 in the drvfs
# metadata (the hazard Invoke-NixosRebuild removes its flake.lock for). secrets.env stays
# Set-OverlaySecrets' to write, so the generator leaves no stub that would read as seeded.
function Invoke-OverlayGenerator {
    Say "overlay flake from config: $ConfigPath (files/scripts/nix-overlay-generate, in '$DistroName')"
    $asUser = '<uid-1000 user>'
    if (-not $DryRun) {
        $pw = @(Invoke-NativeQuiet 'wsl.exe' @('-d', $DistroName, '-u', 'root', '--', 'getent', 'passwd', '1000')) -replace "`0", ''
        $asUser = [string](@($pw -match '^[^:]+:') | Select-Object -First 1) -replace ':.*$', ''
        if (-not $asUser) { throw "no uid 1000 user in '$DistroName' to run the overlay generator as - as root it would leave root-owned files on the Windows mount" }
    }
    $argv = @('env', 'NIX_CONFIG=experimental-features = nix-command flakes',
        'nix', 'shell', 'nixpkgs#zsh', 'nixpkgs#git', '-c',
        'zsh', "$RepoWsl/files/scripts/nix-overlay-generate",
        '--out', $OverlayWsl, '--config', $ConfigWsl, '--no-secrets-stub')
    if ($GenWindowsUser) { $argv += @('--windows-username', $GenWindowsUser) }
    if ($Force) { $argv += '--force' }
    # Its closing Next: steps are for a standalone run; this run is about to take them.
    $next = $false
    Invoke-Wsl $DistroName $asUser $argv -AllowExit (1..255) | ForEach-Object {
        if ("$_" -match '^> Next:') { $next = $true }
        if (-not $next) { $_ }
    } | Out-Host
    if ($DryRun) { return }
    if ($LASTEXITCODE -ne 0) {
        throw "the overlay generator stopped (exit $LASTEXITCODE; its reason is printed above). Fix $ConfigPath and re-run: the import is skipped next time."
    }
    $script:User = Get-OverlayUser
    if (-not $User) { throw "the overlay generator left no flake.nix naming a username in $OverlayWin" }
}

function Invoke-Generate {
    if (-not $ConfigPath) { throw "nothing to generate from - pass -Config <path to a user_data.yaml> (see files\config\user_data.example.yaml)" }
    Confirm-ConfigBeforeImport $ConfigPath
    # The generator needs the distro, so the base image is imported first; `provision` finds it and skips that.
    Assert-WslAvailable
    Import-BaseDistro
    Invoke-OverlayGenerator
    Say ("Overlay written: {0}" -f $OverlayWin) 'Green'
    Say ("Check it before applying:  nix eval path:{0}#nixosConfigurations.default.config.system.build.toplevel.drvPath" -f (ConvertTo-PathUrl $OverlayWsl)) 'Yellow'
    Say ("Then apply with:  .\setup-wsl-nix.ps1 provision -FlakeRef {0}" -f $OverlayWin) 'Yellow'
}

function Invoke-Bootstrap {
    Say "Bootstrap '$DistroName' from overlay: $OverlayWin (user: $User)"
    Assert-WslAvailable
    # Baseline, so a wipe that was already there is not blamed on this run - and so
    # an operator who sees .exe failures mid-run knows which switch caused them.
    Show-InteropState 'before start' $true $true | Out-Null
    # Asked before the download, unless the flake whose sshKeys name the keys is yet to be generated.
    if (-not $FlakeFromConfig) { Resolve-SshPassphrase }
    Import-BaseDistro
    # `provision` generates the flake here, in the imported distro: switch 1 is what reads it.
    if ($InProvision -and $ConfigPath) {
        Invoke-OverlayGenerator
        Resolve-SshPassphrase
    }

    # TWO switches: SSH-dependent activation steps defer until the key exists, which needs the user switch 1 creates.
    # Degraded carries on: switch 1's user@1000 start can fail with EBUSY; the terminate restarts it.
    Invoke-NixosRebuild 'switch 1/2: create the user and the system generation'
    # Restart so the new user resolves; before the heal, since a terminate can wipe binfmt again.
    Do-Step "wsl --terminate $DistroName (apply new user)" { & wsl.exe --terminate $DistroName | Out-Null }
    # Read the restarted boot's verdict now: switch 2/2 resets failed units. Nothing is carried across a boot.
    Say "reading the restarted boot's activation and units (waits up to 180s for the boot)"
    $script:CarriedUnits = @()
    try {
        Get-SwitchResult @()
        Confirm-SwitchResult 'the restarted boot'
    }
    catch {
        try { Invoke-InteropHeal '' 'before stopping on the boot verdict' | Out-Null }
        catch { Warn "the interop heal could not be offered: $($_.Exception.Message)" }
        throw
    }
    if ((Invoke-InteropHeal ".\setup-wsl-nix.ps1 provision   # import is skipped, the run resumes from here") -eq 'declined') {
        if ($SwitchVerdict.verdict -eq 'degraded') { $script:ExitCode = 4 }
        $unitNote = if ($ExitCode -eq 4) { ', and units are not running (named above)' } else { '' }
        Say "Stopped after switch 1/2 - the distro exists, nothing is seeded yet$unitNote." 'Yellow'
        $script:BootstrapStopped = $true
        return
    }

    Copy-OverlayFilesIntoDistro
    $agentLoaded = Add-SshKeyToAgent

    if ($SkipSecondSwitch) {
        Warn "second switch skipped (-SkipSecondSwitch). If SSH steps are still deferred, run in the distro: flakelab update"
    }
    elseif ($DryRun -or $agentLoaded) {
        Invoke-NixosRebuild 'switch 2/2: complete the deferred SSH steps (Claude marketplaces + plugins, statusline)'
        if (-not $DryRun) {
            # switch 2 restarts home-manager only on a changed generation, so re-run the activation now the key is loaded.
            Do-Step "systemctl restart home-manager-$User.service (re-run the activation with the loaded key)" {
                Invoke-Wsl $DistroName 'root' @('systemctl', 'restart', "home-manager-$User.service")
            }
            $deferred = @(Invoke-Wsl $DistroName $User @('sh', '-c', 'cat ~/.local/state/flakelab/activation-deferred 2>/dev/null; true') | Where-Object { $_ -and "$_".Trim() })
            if ($deferred.Count -gt 0) {
                Warn "activation still defers $($deferred.Count) step(s):"
                $deferred | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
                Warn "Complete them in the distro, with a loaded agent key: flakelab update   (flakelab doctor lists them until then)"
            }
            else { Say 'activation completed every step - nothing deferred' 'Green' }
        }
    }
    else {
        Warn "ssh-agent holds no key - skipping the second switch (it would only defer again)."
        Warn "Log in interactively once ('wsl -d $DistroName') and run: flakelab update"
    }
    if (-not $InProvision) {
        Complete-SwitchResult
        Invoke-InteropHeal '' 'at end of run' | Out-Null
    }
    if ($InProvision) {
        if ($SwitchVerdict.verdict -eq 'degraded') { Say "Applied '$DistroName', with units not running (named above) - read again before the run closes." 'Yellow' }
        else { Say "Applied '$DistroName'." 'Green' }
    }
    elseif ($ExitCode -eq 0) { Say "Applied '$DistroName'." 'Green' }
    else { Say "Applied '$DistroName', but its closing verdict is not clean (exit $ExitCode, above)." 'Yellow' }
}

# flakelab-switch-result in the distro (contract in files/scripts/switch-result). Earlier named units are carried;
# `unanswered` is never clean.
function Get-SwitchResult([string[]]$argv) {
    $tool = '/run/current-system/sw/bin/flakelab-switch-result'
    $cmd = @($tool) + $argv
    foreach ($u in $CarriedUnits) { $cmd += @('--carry', $u) }
    $v = @{ code = 0; verdict = 'applied'; activation = ''; failed = @() }
    if ($DryRun) {
        Invoke-Wsl $DistroName 'root' $cmd
        $script:SwitchVerdict = $v
        return
    }
    Invoke-Wsl $DistroName 'root' @('test', '-x', $tool) -AllowExit @(1)
    if ($LASTEXITCODE -ne 0) {
        $v.verdict = 'missing'
        $script:SwitchVerdict = $v
        return
    }
    $lines = @(Invoke-Wsl $DistroName 'root' $cmd -AllowExit (1..255) | ForEach-Object { ("$_" -replace "`0", '').Trim() })
    $v.code = $LASTEXITCODE
    $v.verdict = 'unanswered'
    foreach ($l in $lines) {
        if ($l -match '^(verdict|activation)=(.*)$') { $v[$Matches[1]] = $Matches[2] }
        elseif ($l -match '^failed=(.*)$') { $v.failed = @($Matches[1] -split '\s+' | Where-Object { $_ }) }
    }
    if ($v.verdict -eq 'unanswered' -and $v.code -eq 0) { $v.code = 3 }
    $script:SwitchVerdict = $v
}

function Confirm-SwitchResult([string]$what, [int]$switchRc = 0) {
    $v = $SwitchVerdict
    switch ($v.verdict) {
        'applied' { $script:CarriedUnits = @() }
        'degraded' {
            $names = if ($v.failed.Count -gt 0) { $v.failed -join ', ' } else { 'none named still failed (the switch output above says what it could not do)' }
            Warn "${what}: activated, but units are not running: $names. Carrying on; the run reads them again before it closes."
            $script:CarriedUnits = @($v.failed)
        }
        'missing' {
            if ($switchRc -ne 0) { throw "${what} exited $switchRc, and the running system has no flakelab-switch-result to tell a unit failure from a failed activation" }
            Warn "${what}: the running system has no flakelab-switch-result, so its activation is not verified"
        }
        default { throw "${what}: $($v.verdict) (exit $($v.code)) - the reason is printed above" }
    }
}

# The close: the running distro's verdict once more, carrying what earlier verdicts
# named, into $ExitCode. It never throws, because the heal after it still has to be
# offered: a verdict that would have stopped the run closes it with its code instead.
function Complete-SwitchResult {
    Say "reading the distro's activation and units before closing"
    try { Get-SwitchResult @() }
    catch {
        Warn "the closing verdict could not be read: $($_.Exception.Message)"
        $script:ExitCode = 3
        return
    }
    $v = $SwitchVerdict
    switch ($v.verdict) {
        'applied' { $script:ExitCode = 0 }
        'missing' {
            Warn 'the running system has no flakelab-switch-result, so the close is not verified'
            $script:ExitCode = 0
        }
        'degraded' {
            $names = if ($v.failed.Count -gt 0) { $v.failed -join ', ' } else { 'none named' }
            Warn "units not running at the close: $names. Inspect in the distro:  systemctl status <unit>"
            $script:ExitCode = 4
        }
        default {
            Warn "closing verdict: $($v.verdict) (exit $($v.code)) - the reason is printed above"
            $script:ExitCode = $v.code
        }
    }
}

# Restores whatever `flakelab backup` has staged in the overlay (gitconfig, ssh
# config, shell history, and secrets.env if it was backed up rather than
# hand-written). Non-fatal: a fresh PC has no payload yet, which is not an error.
function Restore-Backup {
    Say 'flakelab backup --restore (gitconfig, ssh config, shell history, secrets)'
    # An unknown instance name would restore only shared categories and look like success: refuse (once a payload exists).
    $instRoot = Join-Path $PayloadWin 'instances'
    if ($RestoreInstance -and (Test-Path $instRoot) -and -not (Test-Path (Join-Path $instRoot $RestoreInstance))) {
        $have = @(Get-ChildItem -Path $instRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        $names = if ($have.Count -gt 0) { $have -join ', ' } else { '(none)' }
        $msg = ("no backup instance '{0}' under {1} - it holds: {2}. " -f $RestoreInstance, $instRoot, $names) +
               "Name the one to restore with  -RestoreInstance <name>  (the default is the distro name, $DistroName)."
        # A dry run reports and carries on, so later steps stay visible.
        if ($DryRun) { Warn $msg } else { throw $msg }
    }
    # Only when it differs from the default; -cne: the payload is on a case-sensitive filesystem.
    $inst = if ($RestoreInstance -and $RestoreInstance -cne $DistroName) { " --instance '$RestoreInstance'" } else { '' }
    if ($inst) { Say "  restoring backup instance '$RestoreInstance'" 'DarkGray' }
    $cmd = "flakelab backup --restore$inst"
    if ($DryRun) { Write-Host "  [dry-run] wsl -d $DistroName -u $User -- zsh -lc '$cmd'" -ForegroundColor DarkGray; return }
    & wsl.exe -d $DistroName -u $User -- zsh -lc $cmd
    if ($LASTEXITCODE -ne 0) { Warn "flakelab backup --restore (instance '$RestoreInstance') returned $LASTEXITCODE - nothing staged yet, or see its output above" }
}

# .zshenv sources the secrets for every zsh, the sops render or secrets.env, so nothing is sourced here.
# Exit 3 is the clone's own refusal for a missing GITLAB_TOKEN, which it has already explained.
function Invoke-CloneRepos {
    if ($SkipCloneRepos) { Warn 'flakelab clone skipped (-SkipCloneRepos)'; return }
    # WSL can stop the distro between two wsl.exe calls, and the ssh-agent holding the unlocked key with it.
    $keepAlive = $null
    try {
        # Inside the try, so a Ctrl+C during the start or the wait still reaches the finally.
        if ($DryRun) { Write-Host "  [dry-run] keep '$DistroName' running across the agent load and the clone" -ForegroundColor DarkGray }
        else {
            $keepAlive = Start-Process -FilePath 'wsl.exe' -ArgumentList @(
                '--distribution', $DistroName, '--user', $User, '--',
                '/run/current-system/sw/bin/sleep', '600') -WindowStyle Hidden -PassThru
            Start-Sleep -Milliseconds 750
        }
        # A stopped distro cold-boots on the keep-alive, and the agent socket needs the user manager that boot starts:
        # wait for the boot, bounded, with the command flakelab-switch-result runs before the bootstrap's agent load.
        # Degraded counts as booted; a timeout warns and the run carries on, as every failure in this step does.
        $bootWait = 180
        Do-Step "wait for '$DistroName' to finish booting, at most ${bootWait}s (systemctl is-system-running --wait)" {
            & wsl.exe -d $DistroName -u root -- timeout $bootWait systemctl is-system-running --wait | Out-Null
            if ($LASTEXITCODE -eq 124) { Warn "'$DistroName' is still booting after ${bootWait}s - loading the key and cloning anyway" }
        }
        if (@(Get-OverlayPrivateKeyName).Count -gt 0) {
            Say 'reloading the SSH key(s) into the agent the clone will use'
            if (-not (Add-SshKeyToAgent) -and -not $DryRun) {
                Warn "the key could not be loaded into the distro's ssh-agent - cloning anyway; a passphrase-protected key makes the clone refuse until it is loaded (ssh-add, then flakelab clone)"
            }
        }
        Say 'flakelab clone (GitLab group discovery)'
        $cmd = 'flakelab clone'
        if ($DryRun) { Write-Host "  [dry-run] wsl -d $DistroName -u $User -- zsh -lc '$cmd'" -ForegroundColor DarkGray; return }
        & wsl.exe -d $DistroName -u $User -- zsh -lc $cmd
        if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3) {
            Warn "flakelab clone returned $LASTEXITCODE - see its output above"
        }
    }
    finally {
        if ($keepAlive -and -not $keepAlive.HasExited) {
            Stop-Process -Id $keepAlive.Id -ErrorAction SilentlyContinue
            $keepAlive.WaitForExit(5000) | Out-Null
        }
    }
}

# Copies live tokens and the private key UNENCRYPTED to the Windows mount: consented (-CopyLiveCredentials or a prompt),
# listed by NAME only.
function Confirm-CredentialCopy([string]$udPath, [int]$tokenCount = 0) {
    if ($CopyLiveCredentials -or $DryRun) { return $true }
    Warn 'about to copy LIVE credentials into the overlay, unencrypted on the Windows mount:'
    Write-Host ("    from  {0}" -f $udPath) -ForegroundColor DarkGray
    Write-Host ("      ->  {0}   ({1} token(s))" -f $SecretsWin, $tokenCount) -ForegroundColor DarkGray
    if (-not [Environment]::UserInteractive -or [Console]::IsInputRedirected) {
        Warn 'no interactive console - skipping. Pass -CopyLiveCredentials to authorise it, or seed the two files yourself.'
        return $false
    }
    if ((Read-Host 'Copy them now? [y/N] (Enter = no)') -match '^[Yy]') { return $true }
    Warn 'skipped - nothing copied.'
    Show-ManualSeedInstructions 'credential copy declined.'
    return $false
}

function Set-OverlaySecrets([string]$udPath) {
    if ($udPath -and (Test-Path $udPath)) {
        $ud = Read-UserDataYaml $udPath
        $envVars = Get-UserDataValue $ud 'custom_env_vars'
        # A top-level token key is accepted too, rather than silently dropped.
        $present = @($SecretKeyNames | Where-Object {
                [string](Get-UserDataValue $envVars $_) -or [string](Get-UserDataValue $ud $_)
            })
        # Plus each custom_env_vars entry the flake withholds by shape, or its value would land in neither file.
        if ($envVars -is [Collections.IDictionary]) {
            $present += @($envVars.Keys | Where-Object {
                    (Test-SecretName $_) -and ($RetiredSecretKeyNames -notcontains $_) -and
                    ($present -notcontains $_) -and [string]$envVars[$_]
                })
        }
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

        # Non-secret endpoints belong in sessionVariables; remind only for a hand-written flake. NAMES ONLY.
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
        Write-Host "  no SSH key at $KeyWin (optional; the SSH-dependent steps defer)" -ForegroundColor DarkGray
    }
}

function Invoke-Provision {
    Say "PROVISION: config check -> seed prep -> import -> overlay flake from config -> switch 1 -> key/secrets + ssh-agent -> switch 2 -> restore -> clone" 'Green'
    $script:InProvision = $true
    if ($ConfigPath) {
        # One command: the flake is generated from the config once the distro is imported (Invoke-Bootstrap);
        # the credential copy is still consented, and asked before the download.
        Confirm-ConfigBeforeImport $ConfigPath
        Set-OverlaySecrets $ConfigPath
    }
    if ((-not (Test-Path $KeyWin)) -or (Test-SecretsSeedNeeded)) {
        $what = @(); if (-not (Test-Path $KeyWin)) { $what += 'SSH key' }; if (Test-SecretsSeedNeeded) { $what += 'secrets.env' }
        $why = if ($ConfigPath) { "no {0} in the overlay ({1} carries none)." -f ($what -join ' and '), (Split-Path $ConfigPath -Leaf) }
        else { "no {0} in the overlay - no config to harvest them from (no -Config, and no user_data.yaml beside it)." -f ($what -join ' and ') }
        Show-ManualSeedInstructions $why
    }
    Invoke-Bootstrap
    if ($BootstrapStopped) { return }
    Restore-Backup
    Invoke-CloneRepos
    Complete-SwitchResult
    Invoke-InteropHeal '' 'at end of run' | Out-Null
    $elapsed = "{0:mm}m{0:ss}s" -f ([datetime]0 + ((Get-Date) - $started))
    if ($ExitCode -eq 0) { Say "Provision done in $elapsed." 'Green' }
    else { Say "Provision done in $elapsed, but its closing verdict is not clean (exit $ExitCode, above)." 'Yellow' }
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
    $sopsSecretsWin = Get-SopsSecretsPath
    $secretsState = if (Test-Path $SecretsWin) { 'present' }
    elseif ($sopsSecretsWin -and (Test-Path $sopsSecretsWin)) { 'sops: {0}' -f $sopsSecretsWin }
    else { 'MISSING' }
    $payloadState = if (Test-Path (Join-Path $PayloadWin "instances\$DistroName")) { 'staged' } else { 'none' }
    $configState = if ($ConfigPath) { $ConfigPath } else { 'none (pass -Config to generate the flake)' }
    Write-Host ("  overlay       : {0} ({1})" -f $OverlayWin, $overlayState)
    Write-Host ("  payload root  : {0}" -f $PayloadWin)
    Write-Host ("  config        : {0}" -f $configState)
    Write-Host ("  linux user    : {0}" -f $User)
    Write-Host ("  declared keys : {0}" -f ((Get-DeclaredSshKeyName) -join ', '))
    Write-Host ("  distro '{0}' : {1}" -f $DistroName, $distroState)
    Write-Host ("  SSH key       : {0}" -f $keyState)
    Write-Host ("  secrets.env   : {0}" -f $secretsState)
    Write-Host ("  backup payload: {0}" -f $payloadState)
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
    default { Invoke-Status }
}
# The one non-throwing non-zero close: the closing verdict's code (Complete-SwitchResult).
if ($ExitCode -ne 0) { exit $ExitCode }
