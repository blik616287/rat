<#
.SYNOPSIS
    Set up a Windows 11 machine as a zrok SSH client.

.DESCRIPTION
    Installs the client-side prerequisites needed to reach a remote host over
    SSH through a zrok private share:
      - the OpenSSH client (built into Windows 11, installed on demand)
      - the zrok binary (on PATH for the current user)
    and optionally enables the zrok environment with an account enable token.

    This is the SSH-only client counterpart to agent/setup-zrok-jumphost.sh,
    which bootstraps the remote host. VNC is intentionally not covered here.

    The `rat` CLI itself is Linux-only (it shells out to sshpass/remmina), so on
    Windows you connect with the two commands printed at the end: open the zrok
    private access tunnel, then ssh to the local bound port.

.PARAMETER EnableToken
    zrok account enable token. If supplied, the script runs `zrok enable` for the
    current user. Get it from https://api-v1.zrok.io after registering. If the
    environment is already enabled, this is skipped.

.PARAMETER InstallDir
    Directory to install the zrok binary into. Default: $env:LOCALAPPDATA\zrok.

.PARAMETER ShareName
    Share name to show in the printed connect instructions. Default: jumphostssh.

.PARAMETER SshUser
    SSH user to show in the printed connect instructions. Default: ubuntu.

.PARAMETER SshPort
    Local port the zrok tunnel binds to. Default: 2222.

.EXAMPLE
    .\setup-zrok-client-windows.ps1 -EnableToken YOUR_TOKEN -ShareName jumphostssh
#>
[CmdletBinding()]
param(
    [string]$EnableToken = "",
    [string]$InstallDir = "$env:LOCALAPPDATA\zrok",
    [string]$ShareName = "jumphostssh",
    [string]$SshUser = "ubuntu",
    [int]$SshPort = 2222
)

$ErrorActionPreference = "Stop"

function Write-Step($n, $msg) { Write-Host "[$n] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)       { Write-Host "  $msg" -ForegroundColor Green }
function Write-Warn2($msg)    { Write-Host "  WARNING: $msg" -ForegroundColor Yellow }

Write-Host "=== Zrok Windows 11 SSH Client Setup ===" -ForegroundColor White
Write-Host ""

# Step 1: OpenSSH client
Write-Step "1/3" "Checking OpenSSH client..."
if (Get-Command ssh -ErrorAction SilentlyContinue) {
    Write-Ok "OpenSSH client already present: $((ssh -V 2>&1) -join ' ')"
} else {
    $cap = Get-WindowsCapability -Online -Name "OpenSSH.Client*" -ErrorAction SilentlyContinue
    if ($cap -and $cap.State -ne "Installed") {
        Write-Ok "Installing OpenSSH client (requires administrator)..."
        try {
            Add-WindowsCapability -Online -Name $cap.Name | Out-Null
            Write-Ok "OpenSSH client installed"
        } catch {
            Write-Warn2 "Could not install OpenSSH client automatically. Run as administrator, or install it from Settings > Apps > Optional Features."
        }
    } else {
        Write-Warn2 "OpenSSH client not found and not available as a Windows capability. Install it from Settings > Apps > Optional Features."
    }
}

# Step 2: zrok binary
Write-Step "2/3" "Installing zrok..."
if (Get-Command zrok -ErrorAction SilentlyContinue) {
    Write-Ok "zrok already installed: $((zrok version 2>&1 | Select-Object -First 1))"
} else {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null

    # Resolve the latest Windows amd64 asset from GitHub releases.
    Write-Ok "Resolving latest zrok release..."
    $headers = @{ "User-Agent" = "rat-setup"; "Accept" = "application/vnd.github+json" }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/openziti/zrok/releases/latest" -Headers $headers
    $asset = $release.assets |
        Where-Object { $_.name -match "windows" -and $_.name -match "amd64" -and $_.name -match "\.(zip|tar\.gz)$" } |
        Select-Object -First 1
    if (-not $asset) { throw "No Windows amd64 asset found in zrok release $($release.tag_name)" }

    $archive = Join-Path $env:TEMP $asset.name
    Write-Ok "Downloading $($asset.name)..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $archive -Headers $headers

    Write-Ok "Extracting to $InstallDir..."
    if ($asset.name -match "\.zip$") {
        Expand-Archive -Path $archive -DestinationPath $InstallDir -Force
    } else {
        # tar (bsdtar) ships with Windows 11.
        tar -xzf $archive -C $InstallDir
    }
    Remove-Item $archive -Force -ErrorAction SilentlyContinue

    $zrokExe = Get-ChildItem -Path $InstallDir -Recurse -Filter "zrok.exe" | Select-Object -First 1
    if (-not $zrokExe) { throw "zrok.exe not found after extraction" }
    $zrokDir = $zrokExe.DirectoryName

    # Add to the user PATH so future shells find it, and this session too.
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    if ($userPath -notlike "*$zrokDir*") {
        [Environment]::SetEnvironmentVariable("Path", "$userPath;$zrokDir", "User")
        Write-Ok "Added $zrokDir to user PATH (restart shells to pick it up)"
    }
    $env:Path = "$env:Path;$zrokDir"
    Write-Ok "zrok installed: $((zrok version 2>&1 | Select-Object -First 1))"
}

# Step 3: enable zrok environment
Write-Step "3/3" "Enabling zrok environment..."
$status = (zrok status 2>&1) -join "`n"
if ($status -match "Account Token.*<<SET>>") {
    Write-Ok "zrok already enabled"
} elseif ($EnableToken) {
    zrok enable $EnableToken
    Write-Ok "zrok enabled"
} else {
    Write-Warn2 "zrok not enabled. Re-run with -EnableToken <token>, or run: zrok enable <token>"
}

Write-Host ""
Write-Host "=== Setup Complete ===" -ForegroundColor White
Write-Host ""
Write-Host "To connect to '$ShareName' over SSH (opens the tunnel and ssh in one command):" -ForegroundColor White
Write-Host "  .\rat-ssh.ps1 -ShareName $ShareName -SshUser $SshUser -SshPort $SshPort"
Write-Host ""
Write-Host "Or do it manually in two terminals:" -ForegroundColor White
Write-Host "  zrok access private --bind 127.0.0.1:$SshPort $ShareName"
Write-Host "  ssh -o StrictHostKeyChecking=no -p $SshPort $SshUser@localhost"
Write-Host ""
Write-Host "To verify the whole path end to end:" -ForegroundColor White
Write-Host "  .\healthcheck-zrok-client.ps1 -ShareName $ShareName -SshPort $SshPort"
Write-Host ""
