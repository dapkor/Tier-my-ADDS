#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 5 (DC02): Promote as additional domain controller in contoso.local.
    Vagrant provision tag: promote-secondary-dc  (reboot: true)

    Run AFTER dc01 is fully provisioned and all brownfield objects are in place.
    Uses credentials from C:\vagrant-bootstrap\lab.json.
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
    $line | Add-Content -Path "$LogDir\05-SecondaryDC.log" -Encoding UTF8
}

Write-Log '=== Phase 5: Promote DC02 as additional domain controller ==='

$cfg = Get-Content 'C:\vagrant-bootstrap\lab.json' -Raw | ConvertFrom-Json

# Idempotency — skip if already promoted
if ((Get-WmiObject Win32_ComputerSystem).DomainRole -ge 4) {
    Write-Log 'Already a Domain Controller — skipping promotion.' OK
    exit 0
}

# ── Point DNS at DC01 so we can locate the domain ─────────────────────────────
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

# ── Wait for DC01 to be reachable ────────────────────────────────────────────
Write-Log 'Waiting for DC01 to respond...'
$maxAttempt = 30   # 5 min ceiling
$attempt    = 0
while ($attempt -lt $maxAttempt) {
    if (Test-Connection -ComputerName '192.168.56.10' -Count 1 -Quiet) {
        Write-Log 'DC01 reachable.' OK
        break
    }
    $attempt++
    Write-Log "DC01 not reachable yet (attempt $attempt / $maxAttempt) — sleeping 10 s..." WARN
    Start-Sleep -Seconds 10
}

# ── Install Windows features ──────────────────────────────────────────────────
Write-Log 'Installing AD-Domain-Services and DNS-Server features...'
Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools | Out-Null
Write-Log 'Features installed.' OK

Import-Module ADDSDeployment -Force

$domainCred = New-Object System.Management.Automation.PSCredential(
    "$($cfg.DomainNetBIOS)\Administrator",
    (ConvertTo-SecureString $cfg.AdminPassword -AsPlainText -Force)
)
$dsrmSecure = ConvertTo-SecureString $cfg.DSRMPassword -AsPlainText -Force

# ── Promote ───────────────────────────────────────────────────────────────────
Write-Log "Promoting DC02 into domain: $($cfg.DomainFQDN)..."
$result = Install-ADDSDomainController `
    -DomainName                    $cfg.DomainFQDN `
    -Credential                    $domainCred `
    -SafeModeAdministratorPassword $dsrmSecure `
    -InstallDns `
    -CreateDnsDelegation:$false `
    -DatabasePath                  'C:\Windows\NTDS' `
    -SysvolPath                    'C:\Windows\SYSVOL' `
    -LogPath                       'C:\Windows\NTDS' `
    -NoRebootOnCompletion `
    -Force

Write-Log "Promotion result: Status=$($result.Status)  Message=$($result.Message)" OK
Write-Log 'Phase 5 complete — Vagrant will reboot DC02 now.' OK
