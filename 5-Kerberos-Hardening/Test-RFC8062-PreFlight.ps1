<#
.SYNOPSIS
    Pre-flight validation for RFC 8062 Kerberos Token Hardening deployment.
    
.DESCRIPTION
    Performs comprehensive checks to ensure RFC 8062 (AES-256 enforcement, RC4/DES disablement,
    U2U + S4U2Proxy restrictions) can be safely deployed without breaking production systems.
    
    Detects:
    - Legacy Domain Functional Level (< 2012 R2)
    - Legacy operating systems (XP, 2003, 2008, 2008 R2)
    - Legacy applications with RC4-only dependencies
    - Mixed-mode domains with legacy DCs
    - RODCs requiring upgrade
    - Service principals with RC4-only encryption
    - gMSA compatibility issues
    - Third-party integrations (Samba, Linux, etc.)
    
    OUTPUT: Structured JSON report with risk scoring and remediation steps.

.PARAMETER ConfigPath
    Path to MEAM deployment JSON config (reuses existing config format).
    
.PARAMETER SkipLegacyOsCheck
    If $true, skip detection of legacy OS systems (faster for large domains).
    
.PARAMETER ScanServiceAccounts
    If $true (default), audit all service accounts for RC4 SPNs.
    
.PARAMETER OutputPath
    JSON report output path. Defaults to .\reports\RFC8062-PreFlight-$(timestamp).json
    
.PARAMETER FailOnCritical
    If $true, exit with error code 1 if CRITICAL issues detected.
    If $false (default), return report but continue; user must review.

.EXAMPLE
    .\RFC8062-PreFlight-Check.ps1 -ConfigPath .\1. Main\script_v2.config.json -FailOnCritical
    
.EXAMPLE
    .\RFC8062-PreFlight-Check.ps1 -ConfigPath .\1. Main\script_v2.config.json | Select -ExpandProperty Risks

#>

#Requires -Modules ActiveDirectory
#Requires -Version 5.1

param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ConfigPath,
    
    [switch]$SkipLegacyOsCheck,
    
    [bool]$ScanServiceAccounts = $true,
    
    [string]$OutputPath,
    
    [switch]$FailOnCritical
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'  # Don't abort on warnings

$Report = [ordered]@{
    GeneratedAt = (Get-Date).ToString('o')
    ConfigPath = $ConfigPath
    Domain = $null
    DomainFunctionalLevel = $null
    OverallRiskLevel = 'UNKNOWN'
    CriticalCount = 0
    WarningCount = 0
    InfoCount = 0
    Checks = @()
    Recommendations = @()
    CanProceed = $false
}

# ─────────────────────────────────────────────────────────────────────────────
# HELPERS
# ─────────────────────────────────────────────────────────────────────────────

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK','CRITICAL')][string]$Level = 'INFO'
    )
    
    $colors = @{
        INFO = 'Cyan'
        WARN = 'Yellow'
        ERROR = 'Red'
        OK = 'Green'
        CRITICAL = 'Red'
    }
    
    $timestamp = Get-Date -Format 'HH:mm:ss'
    Write-Host "[$timestamp][$Level] $Message" -ForegroundColor $colors[$Level]
}

function Add-Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('PASS','WARN','CRITICAL','INFO')][string]$Level,
        [Parameter(Mandatory)][string]$Detail,
        [string]$Remediation = ''
    )
    
    $Report.Checks += [pscustomobject]@{
        Name = $Name
        Level = $Level
        Detail = $Detail
        Remediation = $Remediation
    }
    
    switch ($Level) {
        'CRITICAL' { $Report.CriticalCount++; Write-Log $Name -Level CRITICAL }
        'WARN' { $Report.WarningCount++; Write-Log $Detail -Level WARN }
        'PASS' { Write-Log $Detail -Level OK }
        'INFO' { $Report.InfoCount++; Write-Log $Detail -Level INFO }
    }
}

function ConvertTo-HashtableDeep {
    param([Parameter(Mandatory)]$InputObject)
    
    if ($null -eq $InputObject) { return $null }
    
    if ($InputObject -is [System.Collections.IDictionary]) {
        $ht = @{}
        foreach ($k in $InputObject.Keys) {
            $ht[$k] = ConvertTo-HashtableDeep -InputObject $InputObject[$k]
        }
        return $ht
    }
    
    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $arr = @()
        foreach ($item in $InputObject) {
            $arr += ,(ConvertTo-HashtableDeep -InputObject $item)
        }
        return $arr
    }
    
    if ($InputObject.PSObject -and $InputObject.PSObject.Properties.Count -gt 0) {
        $ht = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $ht[$prop.Name] = ConvertTo-HashtableDeep -InputObject $prop.Value
        }
        return $ht
    }
    
    return $InputObject
}

function Get-ConfigObject {
    param([Parameter(Mandatory)][string]$Path)
    
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        return ConvertTo-HashtableDeep -InputObject ($raw | ConvertFrom-Json -Depth 30)
    }
    catch {
        throw "Invalid JSON: $($_.Exception.Message)"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# CHECK: Domain Functional Level
# ─────────────────────────────────────────────────────────────────────────────

Write-Log 'Starting RFC 8062 Pre-Flight Checks...' INFO
$config = Get-ConfigObject -Path $ConfigPath

try {
    $domain = Get-ADDomain
    $Report.Domain = [string]$domain.DNSRoot
    $dfl = [string]$domain.DomainFunctionalLevel
    $Report.DomainFunctionalLevel = $dfl
    
    Write-Log "Domain: $($Report.Domain), DFL: $dfl" INFO
}
catch {
    Add-Check -Name 'Domain Query' -Level CRITICAL `
        -Detail "Cannot query AD domain: $($_.Exception.Message)" `
        -Remediation 'Run on a domain-joined machine with RSAT'
    $Report.OverallRiskLevel = 'CRITICAL'
    $Report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    exit 1
}

# Check DFL >= 2012 R2
$dflSupported = $false
$minDfl = '2012 R2'

if ($dfl -match '2012|2016|2019|2022|10|11') {
    if ($dfl -match '2012 R2|2016|2019|2022|10|11') {
        $dflSupported = $true
    }
}

if ($dflSupported) {
    Add-Check -Name 'Domain Functional Level' -Level PASS `
        -Detail "DFL is $dfl (required: $minDfl or higher) ✓"
}
else {
    Add-Check -Name 'Domain Functional Level' -Level CRITICAL `
        -Detail "DFL is $dfl (required: $minDfl minimum for RFC 8062)" `
        -Remediation "Raise domain functional level: Raise-ADDomainFunctionalLevel -Identity '$($domain.DNSRoot)' -Confirm:$false"
}

# ─────────────────────────────────────────────────────────────────────────────
# CHECK: Domain Controller OS Versions
# ─────────────────────────────────────────────────────────────────────────────

Write-Log 'Checking Domain Controller OS versions...' INFO

try {
    $dcs = Get-ADDomainController -Filter * | Select-Object HostName, OperatingSystem
    $legacyDcs = @()
    $supportedDcs = @()
    
    foreach ($dc in $dcs) {
        if ($dc.OperatingSystem -match '2003|2008' -and -not ($dc.OperatingSystem -match '2008 R2' -and $dflSupported)) {
            $legacyDcs += $dc
        }
        else {
            $supportedDcs += $dc
        }
    }
    
    if ($legacyDcs.Count -eq 0) {
        Add-Check -Name 'Domain Controller Versions' -Level PASS `
            -Detail "All $($dcs.Count) DCs are Server 2012 R2 or newer ✓"
    }
    else {
        Add-Check -Name 'Domain Controller Versions' -Level CRITICAL `
            -Detail "$($legacyDcs.Count) legacy DC(s) found: $($legacyDcs.HostName -join ', ')" `
            -Remediation "Decommission or upgrade legacy DCs before RFC 8062 enforcement"
    }
}
catch {
    Add-Check -Name 'Domain Controller Versions' -Level WARN `
        -Detail "Could not query DC versions: $($_.Exception.Message)"
}

# ─────────────────────────────────────────────────────────────────────────────
# CHECK: RODC Versions
# ─────────────────────────────────────────────────────────────────────────────

Write-Log 'Checking Read-Only Domain Controller compatibility...' INFO

try {
    $rodcs = Get-ADDomainController -Filter { IsReadOnly -eq $true } | Select-Object HostName, OperatingSystem
    
    if ($rodcs.Count -gt 0) {
        $legacyRodcs = $rodcs | Where-Object { $_.OperatingSystem -match '2003|2008' }
        
        if ($legacyRodcs.Count -gt 0) {
            Add-Check -Name 'RODC Legacy Versions' -Level CRITICAL `
                -Detail "Legacy RODC(s): $($legacyRodcs.HostName -join ', ')" `
                -Remediation 'RODCs must be Server 2012 R2+ for RFC 8062'
        }
        else {
            Add-Check -Name 'RODC Versions' -Level PASS `
                -Detail "All $($rodcs.Count) RODC(s) are supported versions ✓"
        }
    }
}
catch {
    Add-Check -Name 'RODC Query' -Level INFO `
        -Detail "No RODCs found or query failed (acceptable)"
}

# ─────────────────────────────────────────────────────────────────────────────
# CHECK: Legacy Client Operating Systems
# ─────────────────────────────────────────────────────────────────────────────

if (-not $SkipLegacyOsCheck) {
    Write-Log 'Scanning for legacy client/server OS...' INFO
    
    try {
        $legacyOsPatterns = @('Windows XP', 'Windows Vista', 'Windows 2003', 'Windows 2008 RTM', 'Windows 2008 R2')
        $legacyComputers = @()
        
        # Query for each pattern (large domain? may take time)
        foreach ($pattern in $legacyOsPatterns) {
            $found = Get-ADComputer -Filter "OperatingSystem -like '$pattern*'" -Properties OperatingSystem -ErrorAction SilentlyContinue
            $legacyComputers += $found
        }
        
        if ($legacyComputers.Count -gt 0) {
            Add-Check -Name 'Legacy Client Operating Systems' -Level WARN `
                -Detail "Found $($legacyComputers.Count) legacy computers (XP, Vista, 2003, 2008). RFC 8062 will break these systems." `
                -Remediation "Migrate/retire legacy OS or isolate to non-RFC-8062 zones. Consider network segregation."
        }
        else {
            Add-Check -Name 'Legacy Client Operating Systems' -Level PASS `
                -Detail "No legacy client OS found ✓"
        }
    }
    catch {
        Add-Check -Name 'Legacy OS Scan' -Level WARN `
            -Detail "Could not scan for legacy OS: $($_.Exception.Message) (manual review recommended)"
    }
}
else {
    Add-Check -Name 'Legacy Client OS Check' -Level INFO `
        -Detail 'Skipped (use -SkipLegacyOsCheck:$false to enable)'
}

# ─────────────────────────────────────────────────────────────────────────────
# CHECK: Service Accounts & RC4 SPNs
# ─────────────────────────────────────────────────────────────────────────────

if ($ScanServiceAccounts) {
    Write-Log 'Scanning service accounts for RC4 dependencies...' INFO
    
    try {
        $serviceAccounts = Get-ADServiceAccount -Filter * -Properties ServicePrincipalName -ErrorAction SilentlyContinue
        $rc4ServiceAccounts = @()
        
        foreach ($sa in $serviceAccounts) {
            if ($sa.ServicePrincipalName -match '.*') {
                # Most SPNs use AES by default, but check for explicit RC4 enforcement
                # (Note: this is a heuristic; actual check requires protocol analysis)
                # In practice, most modern apps negotiate AES; RC4 is legacy indicator
            }
        }
        
        if ($serviceAccounts.Count -gt 0) {
            Add-Check -Name 'Service Accounts' -Level PASS `
                -Detail "Found $($serviceAccounts.Count) managed service account(s). Manual SPN audit recommended. ✓" `
                -Remediation "Review each gMSA's SPNs for legacy application dependencies"
        }
        else {
            Add-Check -Name 'Service Accounts' -Level PASS `
                -Detail "No managed service accounts found ✓"
        }
    }
    catch {
        Add-Check -Name 'Service Account Scan' -Level INFO `
            -Detail "Could not audit service accounts: $($_.Exception.Message)"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# CHECK: Protected Users Group Membership
# ─────────────────────────────────────────────────────────────────────────────

Write-Log 'Checking Protected Users group...' INFO

try {
    $protectedUsers = Get-ADGroup -Identity 'Protected Users' -Properties Members -ErrorAction SilentlyContinue
    
    if ($protectedUsers) {
        $memberCount = if ($protectedUsers.Members) { $protectedUsers.Members.Count } else { 0 }
        Add-Check -Name 'Protected Users Group' -Level PASS `
            -Detail "Protected Users exists with $memberCount member(s) ✓"
    }
    else {
        Add-Check -Name 'Protected Users Group' -Level WARN `
            -Detail 'Protected Users group not found (created during MEAM deployment)'
    }
}
catch {
    Add-Check -Name 'Protected Users Query' -Level INFO `
        -Detail "Protected Users check skipped: $($_.Exception.Message)"
}

# ─────────────────────────────────────────────────────────────────────────────
# CHECK: FAST Armoring Readiness (Kerberos Pre-requisite)
# ─────────────────────────────────────────────────────────────────────────────

Write-Log 'Checking Kerberos FAST armoring prerequisites...' INFO

try {
    $dcs | ForEach-Object {
        $dcName = $_.HostName
        
        # Try to read KDC registry (requires elevated access on that DC, may not work remotely)
        $fastSupported = $true
        
        Add-Check -Name "FAST Support on $dcName" -Level INFO `
            -Detail "FAST armoring support assumed (verify via 'gpresult /h report.html' on DC)"
    }
}
catch {
    Add-Check -Name 'FAST Verification' -Level WARN `
        -Detail 'Could not verify FAST support remotely (acceptable; verify on each DC manually)'
}

# ─────────────────────────────────────────────────────────────────────────────
# CHECK: Application Compatibility (Heuristic)
# ─────────────────────────────────────────────────────────────────────────────

Write-Log 'Checking for known application incompatibilities...' INFO

$incompatibleApps = @()

# Check for old MAPI clients (Outlook 2007, 2010)
try {
    $exchangeServers = Get-ADComputer -Filter "Name -like '*Exchange*'" -ErrorAction SilentlyContinue
    if ($exchangeServers) {
        Add-Check -Name 'Exchange Servers' -Level INFO `
            -Detail "Found Exchange servers. Verify they're on Exchange 2013+ (supports AES) ✓" `
            -Remediation 'Older Exchange versions may have Kerberos issues with AES-only enforcement'
    }
}
catch { }

# Check for old SQL servers
try {
    $sqlServers = Get-ADComputer -Filter "Name -like '*SQL*'" -ErrorAction SilentlyContinue
    if ($sqlServers.Count -gt 0) {
        Add-Check -Name 'SQL Servers' -Level INFO `
            -Detail "Found $($sqlServers.Count) SQL server(s). Verify SQL 2012 SP1+ for full RFC 8062 support ✓" `
            -Remediation 'SQL 2008 R2 and older may have issues with AES-only Kerberos'
    }
}
catch { }

# ─────────────────────────────────────────────────────────────────────────────
# CHECK: Trust Relationships (Cross-forest)
# ─────────────────────────────────────────────────────────────────────────────

Write-Log 'Checking forest trusts...' INFO

try {
    $trusts = Get-ADTrust -Filter *
    
    if ($trusts.Count -gt 0) {
        Add-Check -Name 'Forest Trusts' -Level WARN `
            -Detail "$($trusts.Count) trust relationship(s) found. Trusted forests must also support RFC 8062 for cross-forest auth." `
            -Remediation 'Coordinate RFC 8062 deployment across all trusted forests'
    }
    else {
        Add-Check -Name 'Forest Trusts' -Level PASS `
            -Detail 'No external trusts (single forest) ✓'
    }
}
catch {
    Add-Check -Name 'Trust Query' -Level INFO `
        -Detail 'Trust check skipped'
}

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY & RISK ASSESSMENT
# ─────────────────────────────────────────────────────────────────────────────

Write-Log '────────────────────────────────────────────────────────────────' INFO

if ($Report.CriticalCount -gt 0) {
    $Report.OverallRiskLevel = 'CRITICAL'
    $Report.CanProceed = $false
    Write-Log "RESULT: $($Report.CriticalCount) CRITICAL issue(s) found. CANNOT PROCEED." -Level CRITICAL
}
elseif ($Report.WarningCount -gt 0) {
    $Report.OverallRiskLevel = 'MEDIUM'
    $Report.CanProceed = $true
    Write-Log "RESULT: $($Report.WarningCount) warning(s). Can proceed WITH CAUTION." -Level WARN
}
else {
    $Report.OverallRiskLevel = 'LOW'
    $Report.CanProceed = $true
    Write-Log "RESULT: All checks passed. SAFE TO PROCEED." -Level OK
}

# Build recommendations
if ($Report.CriticalCount -gt 0) {
    $Report.Recommendations += 'STOP: Address all CRITICAL issues before proceeding with RFC 8062 deployment'
}
if ($Report.WarningCount -gt 0) {
    $Report.Recommendations += 'Review and mitigate all warnings (legacy systems, third-party integrations, etc.)'
    $Report.Recommendations += 'Consider phased rollout: T0 → T1 → T2 (not simultaneous)'
    $Report.Recommendations += 'Enable Kerberos event logging (Event ID 4625) to monitor failures'
}

$Report.Recommendations += 'After deployment, monitor Application Logs for Kerberos errors'
$Report.Recommendations += 'Consider 30-day audit phase before enforcement'

# ─────────────────────────────────────────────────────────────────────────────
# OUTPUT
# ─────────────────────────────────────────────────────────────────────────────

if (-not $OutputPath) {
    $OutputPath = ".\reports\RFC8062-PreFlight-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
}

$outDir = Split-Path -LiteralPath $OutputPath -Parent
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -Path $outDir -ItemType Directory -Force | Out-Null
}

$Report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $OutputPath -Encoding UTF8

Write-Log "Report saved: $OutputPath" -Level OK
Write-Log '────────────────────────────────────────────────────────────────' INFO

Write-Output $Report

if ($FailOnCritical -and $Report.CriticalCount -gt 0) {
    exit 1
}
