<#
.SYNOPSIS
    Connect to a remote host over SSH through a zrok private share, in one command.

.DESCRIPTION
    The Windows 11 SSH-only equivalent of `rat ssh`: opens a zrok private access
    tunnel bound to a local port, waits for it to come up, then runs ssh to that
    local port. When the SSH session ends, the tunnel this script started is torn
    down.

    If the local port is already bound (for example by a tunnel from an earlier
    session), that existing tunnel is reused and left running on exit.

    Password auth is handled by OpenSSH's own interactive prompt (there is no
    sshpass on Windows); for key auth pass -IdentityFile.

.PARAMETER ShareName
    zrok share name (token) of the remote host. Required.

.PARAMETER SshUser
    SSH user. Default: ubuntu.

.PARAMETER SshPort
    Local port to bind the zrok tunnel to. Default: 2222.

.PARAMETER IdentityFile
    Path to an SSH private key. If omitted, SSH prompts for a password.

.PARAMETER TimeoutSeconds
    How long to wait for the tunnel to bind. Default: 15.

.PARAMETER Command
    Optional remote command (and its arguments) to run instead of an
    interactive shell. Everything after the named parameters is passed to ssh.

.EXAMPLE
    .\rat-ssh.ps1 -ShareName jumphostssh

.EXAMPLE
    .\rat-ssh.ps1 -ShareName jumphostssh -SshUser admin -IdentityFile ~\.ssh\mykey

.EXAMPLE
    .\rat-ssh.ps1 -ShareName jumphostssh hostname
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ShareName,
    [string]$SshUser = "ubuntu",
    [int]$SshPort = 2222,
    [string]$IdentityFile = "",
    [int]$TimeoutSeconds = 15,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Command
)

$ErrorActionPreference = "Stop"

function Write-Info($msg) { Write-Host $msg -ForegroundColor Cyan }
function Write-Err2($msg)  { Write-Host $msg -ForegroundColor Red }

function Test-PortListening($port) {
    return [bool](Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
}

if (-not (Get-Command zrok -ErrorAction SilentlyContinue)) {
    Write-Err2 "zrok not found on PATH. Run setup-zrok-client-windows.ps1 first."
    exit 1
}
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Write-Err2 "OpenSSH client not found on PATH. Run setup-zrok-client-windows.ps1 first."
    exit 1
}

$tunnel = $null
$ownTunnel = $false

try {
    if (Test-PortListening $SshPort) {
        Write-Info "Reusing existing tunnel on 127.0.0.1:$SshPort"
    } else {
        Write-Info "Starting zrok access for $ShareName on 127.0.0.1:$SshPort..."
        $tunnel = Start-Process -FilePath "zrok" `
            -ArgumentList @("access", "private", "--headless", "--bind", "127.0.0.1:$SshPort", $ShareName) `
            -PassThru -WindowStyle Hidden
        $ownTunnel = $true

        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while (-not (Test-PortListening $SshPort)) {
            if ($tunnel.HasExited) {
                Write-Err2 "zrok access exited (code $($tunnel.ExitCode)) before binding the port."
                exit 1
            }
            if ((Get-Date) -ge $deadline) {
                Write-Err2 "Tunnel did not bind 127.0.0.1:$SshPort within ${TimeoutSeconds}s."
                exit 1
            }
            Start-Sleep -Milliseconds 500
        }
        Write-Info "Tunnel up."
    }

    # Build ssh args: flags before the connection target, remote command after.
    $sshArgs = @("-o", "StrictHostKeyChecking=no", "-p", "$SshPort")
    if ($IdentityFile) {
        $sshArgs += @("-i", $IdentityFile)
    }
    $sshArgs += "$SshUser@localhost"
    if ($Command) {
        $sshArgs += $Command
    }

    & ssh @sshArgs
    $exitCode = $LASTEXITCODE
} finally {
    if ($ownTunnel -and $tunnel -and -not $tunnel.HasExited) {
        Write-Info "Stopping zrok access..."
        Stop-Process -Id $tunnel.Id -Force -ErrorAction SilentlyContinue
    }
}

exit $exitCode
