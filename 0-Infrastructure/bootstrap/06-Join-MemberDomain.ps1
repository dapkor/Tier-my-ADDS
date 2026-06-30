#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 6 (MEMBER01): Join contoso.local as a member server.
    Vagrant provision tag: join-domain  (reboot: true)

    Also installs RSAT toolset so MEAM scripts can be run locally on MEMBER01
    to validate deployment against DC01 without needing a separate admin workstation.

    Run AFTER dc01 is fully provisioned.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LogDir = 'C:\vagrant-bootstrap\logs'
$null   = New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction SilentlyContinue

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERROR')]$Level = 'INFO')
    $colour = @{ INFO='Cyan'; OK='Green'; WARN='Yellow'; ERROR='Red' }[$Level]
    $line   = "[$(Get-Date -f 'HH:mm:ss')][$Level] $Message"
    Write-Host $line -ForegroundColor $colour
    $line | Add-Content -Path "$LogDir\06-Join-Domain.log" -Encoding UTF8
}

Write-Log '=== Phase 6: Join MEMBER01 to contoso.local ==='

$cfg = Get-Content 'C:\vagrant-bootstrap\lab.json' -Raw | ConvertFrom-Json

# ── Idempotency ────────────────────────────────────────────────────────────────
$cs = Get-WmiObject Win32_ComputerSystem
if ($cs.PartOfDomain -and $cs.Domain -eq $cfg.DomainFQDN) {
    Write-Log "Already joined to $($cfg.DomainFQDN) — skipping domain join." OK
    # Still ensure RSAT is present
    $rsat = @('RSAT-AD-PowerShell','RSAT-AD-AdminCenter','RSAT-ADDS-Tools',
              'RSAT-DNS-Server','RSAT-GroupPolicy-Tools')
    foreach ($f in $rsat) {
        Install-WindowsFeature -Name $f -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Log 'RSAT verified.' OK
    exit 0
}

# ── Point DNS at DC01 ─────────────────────────────────────────────────────────
Write-Log 'Configuring DNS to point at DC01 (192.168.56.10)...'
Get-NetAdapter | Where-Object Status -eq 'Up' | ForEach-Object {
    try {
        $ips = (Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
        if ($ips -match '^192\.168\.56\.') {
            Set-DnsClientServerAddress -InterfaceIndex $_.ifIndex -ServerAddresses '192.168.56.10','192.168.56.11'
            Write-Log "  DNS set on adapter: $($_.Name)" OK
        }
    }
    catch { }
}

# ── Wait for DC01 ─────────────────────────────────────────────────────────────
Write-Log 'Waiting for DC01 to respond...'
$maxAttempt = 30
$attempt    = 0
while ($attempt -lt $maxAttempt) {
    if (Test-Connection -ComputerName '192.168.56.10' -Count 1 -Quiet) {
        Write-Log 'DC01 reachable.' OK
        break
    }
    $attempt++
    Write-Log "DC01 not reachable yet (attempt $attempt / $maxAttempt)..." WARN
    Start-Sleep -Seconds 10
}

# ── Install RSAT (before join so modules are ready post-reboot) ───────────────
Write-Log 'Installing RSAT features...'
$rsat = @(
    'RSAT-AD-PowerShell',
    'RSAT-AD-AdminCenter',
    'RSAT-ADDS-Tools',
    'RSAT-DNS-Server',
    'RSAT-GroupPolicy-Tools'
)
foreach ($f in $rsat) {
    $feat = Install-WindowsFeature -Name $f -ErrorAction SilentlyContinue
    Write-Log "  $f : installed=$($feat.Success)" OK
}

# ── Join the domain ───────────────────────────────────────────────────────────
Write-Log "Joining domain: $($cfg.DomainFQDN)..."
$cred = New-Object System.Management.Automation.PSCredential(
    "$($cfg.DomainNetBIOS)\Administrator",
    (ConvertTo-SecureString $cfg.AdminPassword -AsPlainText -Force)
)
Add-Computer -DomainName $cfg.DomainFQDN -Credential $cred -Force -ErrorAction Stop

Write-Log 'Domain join successful — Vagrant will reboot MEMBER01 now.' OK
Write-Log '=== Phase 6 complete ===' OK
