#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 1 (DC01): Install ADDS + DNS and promote as contoso.local forest root.
    Vagrant provision tag: promote-dc  (reboot: true — Vagrant reboots after this script exits)
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
    $line | Add-Content -Path "$LogDir\01-Promote-DC.log" -Encoding UTF8
}

Write-Log '=== Phase 1: Promote DC01 as forest root ==='

# Read lab config
$cfg = Get-Content 'C:\vagrant-bootstrap\lab.json' -Raw | ConvertFrom-Json

# Idempotency guard — skip if already a DC
$domainRole = (Get-WmiObject Win32_ComputerSystem).DomainRole
if ($domainRole -ge 4) {
    Write-Log "Already a Domain Controller (DomainRole=$domainRole) — skipping promotion." OK
    exit 0
}

# Install Windows features
Write-Log 'Installing AD-Domain-Services and DNS-Server features...'
$feat = Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools
Write-Log "Feature install result: Success=$($feat.Success)  RestartNeeded=$($feat.RestartNeeded)" OK

Import-Module ADDSDeployment -Force

$dsrmSecure = ConvertTo-SecureString $cfg.DSRMPassword -AsPlainText -Force

Write-Log "Promoting to forest root: $($cfg.DomainFQDN)  NetBIOS: $($cfg.DomainNetBIOS)"
$result = Install-ADDSForest `
    -DomainName                    $cfg.DomainFQDN `
    -DomainNetbiosName             $cfg.DomainNetBIOS `
    -SafeModeAdministratorPassword $dsrmSecure `
    -InstallDns `
    -CreateDnsDelegation:$false `
    -DatabasePath                  'C:\Windows\NTDS' `
    -SysvolPath                    'C:\Windows\SYSVOL' `
    -LogPath                       'C:\Windows\NTDS' `
    -NoRebootOnCompletion `
    -Force

Write-Log "Promotion result: Status=$($result.Status)  Message=$($result.Message)" OK
Write-Log 'Phase 1 complete — Vagrant will reboot the VM now.' OK
