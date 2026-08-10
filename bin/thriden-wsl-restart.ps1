# thriden-wsl-restart.ps1 — the Windows half of enabling systemd in WSL.
#
# Run this in a WINDOWS POWERSHELL terminal, between the two passes of
# bin/thriden-wsl-systemd.sh (which runs inside Ubuntu). It exists because
# `wsl --shutdown` cannot be run from inside the distro it is shutting down.
#
#   1. Ubuntu:      bin/thriden-wsl-systemd.sh      <- configures systemd
#   2. PowerShell:  .\bin\thriden-wsl-restart.ps1   <- THIS (restarts WSL)
#   3. Ubuntu:      bin/thriden-wsl-systemd.sh      <- installs the dispatcher
#
# Safe to re-run. It only checks a version and restarts WSL.

$ErrorActionPreference = 'Stop'

Write-Host ''
Write-Host '>> Checking your WSL version' -ForegroundColor Cyan

# systemd support needs the Store build of WSL (>= 0.67.6). The old inbox
# component has no `--version` at all, which is itself the tell.
$versionText = ''
try { $versionText = (wsl.exe --version 2>&1 | Out-String) } catch { $versionText = '' }

if ([string]::IsNullOrWhiteSpace($versionText) -or $versionText -match 'Invalid command line') {
    Write-Host ''
    Write-Host 'Your WSL is too old to support systemd (no --version).' -ForegroundColor Yellow
    Write-Host 'Update it first, then run this script again:'
    Write-Host ''
    Write-Host '    wsl --update' -ForegroundColor White
    Write-Host ''
    exit 1
}

$firstLine = ($versionText -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
Write-Host "   $firstLine"

if ($firstLine -match '(\d+)\.(\d+)\.(\d+)') {
    $v = [version]("{0}.{1}.{2}" -f $Matches[1], $Matches[2], $Matches[3])
    if ($v -lt [version]'0.67.6') {
        Write-Host ''
        Write-Host "WSL $v is below 0.67.6, which is where systemd support starts." -ForegroundColor Yellow
        Write-Host 'Run `wsl --update`, then run this script again.'
        exit 1
    }
}

Write-Host ''
Write-Host '>> Restarting WSL' -ForegroundColor Cyan
Write-Host '   This stops every distro. Docker Desktop restarts its backend and'
Write-Host '   your containers come back on their own (they are unless-stopped),'
Write-Host '   so give it a minute before expecting your Scion to answer.'
Write-Host ''

wsl.exe --shutdown

Write-Host 'Done.' -ForegroundColor Green
Write-Host ''
Write-Host 'Now reopen Ubuntu and finish the install:'
Write-Host ''
Write-Host '    cd ~/thriden && bin/thriden-wsl-systemd.sh' -ForegroundColor White
Write-Host ''
