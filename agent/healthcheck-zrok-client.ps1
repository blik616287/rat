<#
.SYNOPSIS
    Health-check the zrok SSH client path on Windows 11.

.DESCRIPTION
    Verifies, end to end, that this client can reach a remote host's SSH server
    through a zrok private share. Each check prints PASS or FAIL; the script
    exits 0 only if every check passes, so it is safe to use in scripts or CI.

    Checks, in order:
      1. zrok binary is on PATH
      2. zrok environment is enabled
      3. OpenSSH client is on PATH
      4. a zrok private access tunnel to the share comes up and binds the port
      5. the local bound port accepts TCP connections
      6. the remote SSH server answers with an SSH banner through the tunnel

    Check 6 reads the SSH protocol banner only; it does not authenticate, so no
    credentials are needed and nothing is changed on the remote host. The
    temporary tunnel this script opens is always torn down before it exits.

.PARAMETER ShareName
    zrok share name (token) of the remote host. Required.

.PARAMETER SshPort
    Local port to bind the zrok tunnel to for the test. Default: 2222.
    If this port is already bound by another tunnel, pass a free one.

.PARAMETER TimeoutSeconds
    How long to wait for the tunnel to bind and for the SSH banner. Default: 15.

.EXAMPLE
    .\healthcheck-zrok-client.ps1 -ShareName jumphostssh
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ShareName,
    [int]$SshPort = 2222,
    [int]$TimeoutSeconds = 15
)

$ErrorActionPreference = "Stop"
$failures = 0

function Test-Check($name, [scriptblock]$body) {
    Write-Host -NoNewline ("  {0,-40} " -f $name)
    try {
        $detail = & $body
        Write-Host "PASS" -ForegroundColor Green -NoNewline
        if ($detail) { Write-Host " ($detail)" -ForegroundColor DarkGray } else { Write-Host "" }
    } catch {
        Write-Host "FAIL" -ForegroundColor Red -NoNewline
        Write-Host " ($($_.Exception.Message))" -ForegroundColor DarkGray
        $script:failures++
    }
}

# Try to read an SSH banner from a TCP endpoint within a timeout.
function Get-SshBanner($hostName, $port, $timeoutMs) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $client.BeginConnect($hostName, $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($timeoutMs)) { throw "connect timed out" }
        $client.EndConnect($iar)
        $stream = $client.GetStream()
        $stream.ReadTimeout = $timeoutMs
        $buffer = New-Object byte[] 255
        $read = $stream.Read($buffer, 0, $buffer.Length)
        return [System.Text.Encoding]::ASCII.GetString($buffer, 0, $read).Trim()
    } finally {
        $client.Close()
    }
}

Write-Host "=== Zrok SSH Client Health Check: $ShareName ===" -ForegroundColor White
Write-Host ""

Test-Check "zrok installed" {
    $c = Get-Command zrok -ErrorAction SilentlyContinue
    if (-not $c) { throw "zrok not on PATH" }
    (zrok version 2>&1 | Select-Object -First 1)
}

Test-Check "zrok environment enabled" {
    $status = (zrok status 2>&1) -join "`n"
    if ($status -notmatch "Account Token.*<<SET>>") { throw "run: zrok enable <token>" }
    "enabled"
}

Test-Check "OpenSSH client installed" {
    $c = Get-Command ssh -ErrorAction SilentlyContinue
    if (-not $c) { throw "ssh not on PATH" }
    "ssh present"
}

# Open a temporary private access tunnel for the connectivity checks.
$tunnel = $null
try {
    Test-Check "zrok tunnel binds 127.0.0.1:$SshPort" {
        $script:tunnel = Start-Process -FilePath "zrok" `
            -ArgumentList @("access", "private", "--headless", "--bind", "127.0.0.1:$SshPort", $ShareName) `
            -PassThru -WindowStyle Hidden
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while ((Get-Date) -lt $deadline) {
            if ($script:tunnel.HasExited) { throw "zrok access exited (code $($script:tunnel.ExitCode))" }
            if (Get-NetTCPConnection -State Listen -LocalPort $SshPort -ErrorAction SilentlyContinue) {
                return "bound"
            }
            Start-Sleep -Milliseconds 500
        }
        throw "port not listening after ${TimeoutSeconds}s"
    }

    Test-Check "local port accepts TCP" {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $iar = $client.BeginConnect("127.0.0.1", $SshPort, $null, $null)
            if (-not $iar.AsyncWaitHandle.WaitOne($TimeoutSeconds * 1000)) { throw "connect timed out" }
            $client.EndConnect($iar)
        } finally { $client.Close() }
        "connected"
    }

    Test-Check "remote SSH server answers" {
        $banner = Get-SshBanner "127.0.0.1" $SshPort ($TimeoutSeconds * 1000)
        if ($banner -notmatch "^SSH-") { throw "no SSH banner (got: '$banner')" }
        $banner
    }
} finally {
    if ($tunnel -and -not $tunnel.HasExited) {
        Stop-Process -Id $tunnel.Id -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
if ($failures -eq 0) {
    Write-Host "All checks passed." -ForegroundColor Green
    exit 0
} else {
    Write-Host "$failures check(s) failed." -ForegroundColor Red
    exit 1
}
