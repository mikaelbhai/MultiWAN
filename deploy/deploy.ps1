# deploy.ps1 — push the MultiWAN config and admin app to the router over SSH.
#
# Usage from E:\Coding\MultiWAN:
#     .\deploy\deploy.ps1 -Router 192.168.20.1
#     .\deploy\deploy.ps1 -Router 192.168.1.1 -ConfigOnly
#     .\deploy\deploy.ps1 -Router 192.168.20.1 -AppOnly
#
# Requires the OpenSSH client (built into Windows 10/11).

param(
    [string]$Router = "192.168.20.1",
    [string]$User   = "root",
    [switch]$ConfigOnly,
    [switch]$AppOnly
)

$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent $PSScriptRoot

function Say  { param($m) Write-Host "==> $m" -ForegroundColor Cyan }
function Warn { param($m) Write-Host "[!] $m" -ForegroundColor Yellow }
function Die  { param($m) Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

$Target = "$User@$Router"

# --- Preflight ---------------------------------------------------------------
if (-not (Get-Command ssh -ErrorAction SilentlyContinue)) {
    Die "The OpenSSH client is not available. Install it via Settings > Optional Features."
}

Say "Checking connectivity to $Router"
if (-not (Test-Connection -ComputerName $Router -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
    Die "$Router is not reachable. Check the cable, your IP address, and that the router is up."
}

Say "Verifying this is the expected device"
$board = ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new $Target `
    "cat /tmp/sysinfo/board_name 2>/dev/null"
if ($LASTEXITCODE -ne 0) { Die "SSH to $Target failed. Check the root password and that SSH is enabled." }

Write-Host "    board: $board"
if ($board -ne "tplink,archer-c6-v3") {
    Warn "Expected 'tplink,archer-c6-v3' but found '$board'."
    $ans = Read-Host "Continue anyway? [y/N]"
    if ($ans -notmatch '^[yY]') { Die "Aborted." }
}

# --- Config scripts ----------------------------------------------------------
if (-not $AppOnly) {
    Say "Checking that mwan.env has been filled in"
    $env_file = Join-Path $Repo "config\mwan.env"
    if ((Get-Content $env_file -Raw) -match '203\.0\.113\.') {
        Die @"
config\mwan.env still contains the placeholder WAN1 address (203.0.113.x).
Edit it and set your real static IP, netmask, gateway, and DNS before deploying.
"@
    }
    if ((Get-Content $env_file -Raw) -match 'CHANGEME') {
        Warn "mwan.env still contains a CHANGEME placeholder (likely a Wi-Fi password)."
    }

    Say "Copying config scripts to /root/multiwan/config"
    ssh $Target "mkdir -p /root/multiwan/config"
    scp -q (Join-Path $Repo "config\*") "${Target}:/root/multiwan/config/"
    ssh $Target "chmod +x /root/multiwan/config/*.sh; sed -i 's/\r`$//' /root/multiwan/config/*"
    Write-Host "    Run it on the router with:" -ForegroundColor Green
    Write-Host "      ssh $Target 'cd /root/multiwan/config && sh install.sh'"
}

# --- Admin app ---------------------------------------------------------------
if (-not $ConfigOnly) {
    Say "Deploying the admin application"

    ssh $Target "mkdir -p /www/mwadmin/cgi-bin /usr/lib/mwadmin /etc/hotplug.d/iface"

    scp -q -r (Join-Path $Repo "package\www\*")     "${Target}:/www/mwadmin/"
    scp -q    (Join-Path $Repo "package\cgi-bin\mwadmin") "${Target}:/www/mwadmin/cgi-bin/"
    scp -q    (Join-Path $Repo "package\lib\*.sh")  "${Target}:/usr/lib/mwadmin/"
    scp -q    (Join-Path $Repo "package\hotplug\95-mwadmin-portdetect") "${Target}:/etc/hotplug.d/iface/"
    scp -q    (Join-Path $Repo "package\init.d\mwadmin") "${Target}:/etc/init.d/"

    Say "Normalising line endings and setting permissions"
    # Windows CRLF in a shell script produces the classic and very confusing
    # "/bin/sh^M: bad interpreter" failure, so strip them on arrival.
    ssh $Target @"
set -e
for f in /www/mwadmin/cgi-bin/mwadmin /usr/lib/mwadmin/*.sh /etc/hotplug.d/iface/95-mwadmin-portdetect /etc/init.d/mwadmin; do
    [ -f "`$f" ] && sed -i 's/\r`$//' "`$f"
done
chmod 755 /www/mwadmin/cgi-bin/mwadmin /etc/init.d/mwadmin /etc/hotplug.d/iface/95-mwadmin-portdetect
chmod 644 /usr/lib/mwadmin/*.sh
chmod 644 /www/mwadmin/*.html /www/mwadmin/*.css /www/mwadmin/*.js
/etc/init.d/mwadmin enable
/etc/init.d/mwadmin restart
"@

    Say "Verifying the service responds"
    $port = (Select-String -Path (Join-Path $Repo "config\mwan.env") -Pattern '^ADMIN_PORT="(\d+)"').Matches.Groups[1].Value
    if (-not $port) { $port = "8080" }
    $probe = ssh $Target "wget -qO- http://127.0.0.1:$port/cgi-bin/mwadmin/ping 2>/dev/null"
    if ($probe -match '"ok":true') {
        Write-Host "    API responded correctly." -ForegroundColor Green
    } else {
        Warn "The API did not respond as expected. Check: ssh $Target 'logread | grep mwadmin'"
    }

    Write-Host ""
    Write-Host "Admin UI: http://${Router}:$port" -ForegroundColor Green
    Write-Host "Sign in with the router's root password." -ForegroundColor Green
}

Say "Done."
