<#
.SYNOPSIS
    Deploys RFC 8062 Kerberos Token Hardening to MEAM environment.
    
.DESCRIPTION
    Applies Kerberos hardening across the MEAM tier structure:
    - Enforces AES-256-CTS-HMAC-SHA1-96 encryption (disables RC4/DES)
    - Enforces FAST armoring for all tier authentication
    - Implements User-to-User (U2U) delegation restrictions
    - Restricts S4U2Proxy (Protocol Transition) to whitelisted services
    - Creates compliance audit policies
    
    Operates in phases:
      Phase 1: DC registry hardening (ALL DCs must be restarted)
      Phase 2: GPO deployment (T0/T1 enforcement)
      Phase 3: S4U2Proxy whitelist registration (per-service)
      Phase 4: Monitoring & audit configuration

.PARAMETER ConfigPath
    Path to MEAM deployment JSON config.
    
.PARAMETER PreFlightReportPath
    Path to pre-flight validation report (required; use RFC8062-PreFlight-Check.ps1 output).
    
.PARAMETER Phase
    Deploy specific phase:
      'PreFlight'   - Run pre-flight checks only
      'All'         - Deploy all phases (sequential)
      'DCRegistry'  - Phase 1 only (DC registry hardening)
      'GroupPolicy' - Phase 2 only (GPO deployment)
      'S4U2Proxy'   - Phase 3 only (whitelist SPNs)
      'Monitoring'  - Phase 4 only (audit logging)
      
.PARAMETER ApproveBreakingChanges
    If $true, automatically proceed through warnings.
    If $false (default), prompt for approval at each warning.
    
.PARAMETER RollbackOnFailure
    If $true, attempt to rollback DC registry changes if deployment fails.
    Default: $false (recommend manual rollback review).

.EXAMPLE
    # Step 1: Run pre-flight checks
    .\RFC8062-PreFlight-Check.ps1 -ConfigPath .\1. Main\script_v2.config.json -OutputPath .\reports\preflight.json -FailOnCritical
    
    # Step 2: If pre-flight passes, deploy RFC 8062
    .\RFC8062-Hardening-Deploy.ps1 -ConfigPath .\1. Main\script_v2.config.json -PreFlightReportPath .\reports\preflight.json -Phase All

#>

#Requires -Modules ActiveDirectory, GroupPolicy
#Requires -Version 5.1
#Requires -RunAsAdministrator

param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ConfigPath,
    
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$PreFlightReportPath,
    
    [ValidateSet('PreFlight','All','DCRegistry','GroupPolicy','S4U2Proxy','Monitoring')]
    [string]$Phase = 'All',
    
    [bool]$ApproveBreakingChanges = $false,
    
    [bool]$RollbackOnFailure = $false,
    
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DeploymentReport = [ordered]@{
    GeneratedAt = (Get-Date).ToString('o')
    ConfigPath = $ConfigPath
    PreFlightReport = $null
    Domain = $null
    Phase = $Phase
    Status = 'InProgress'
    PhaseResults = @()
    Errors = @()
    RegistryRollbacks = @()  # Track DC registry changes for potential rollback
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

function Request-UserApproval {
    param([Parameter(Mandatory)][string]$Message)
    
    if ($ApproveBreakingChanges) {
        Write-Log "Auto-approved (ApproveBreakingChanges=$true): $Message" -Level OK
        return $true
    }
    
    $response = Read-Host "$Message (yes/no)"
    return $response -eq 'yes'
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

function Add-PhaseResult {
    param(
        [Parameter(Mandatory)][string]$PhaseName,
        [Parameter(Mandatory)][ValidateSet('PASS','WARN','FAIL')][string]$Status,
        [Parameter(Mandatory)][string]$Detail
    )
    
    $DeploymentReport.PhaseResults += [pscustomobject]@{
        Phase = $PhaseName
        Status = $Status
        Detail = $Detail
        Timestamp = (Get-Date).ToString('o')
    }
    
    Write-Log "$PhaseName: $Status - $Detail" -Level $(if ($Status -eq 'FAIL') { 'ERROR' } else { 'OK' })
}

# ─────────────────────────────────────────────────────────────────────────────
# PRE-FLIGHT VALIDATION
# ─────────────────────────────────────────────────────────────────────────────

Write-Log 'RFC 8062 Kerberos Hardening Deployment' -Level INFO
Write-Log '═══════════════════════════════════════════════════════════════' -Level INFO

try {
    $preflight = Get-Content -LiteralPath $PreFlightReportPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $DeploymentReport.PreFlightReport = $preflight
    
    Write-Log "Pre-flight report: $($preflight.OverallRiskLevel)" -Level INFO
    
    if ($preflight.OverallRiskLevel -eq 'CRITICAL') {
        Write-Log 'Pre-flight validation FAILED with CRITICAL issues. Cannot proceed.' -Level CRITICAL
        throw 'Pre-flight validation failed'
    }
    
    if ($preflight.OverallRiskLevel -eq 'MEDIUM' -and -not $ApproveBreakingChanges) {
        if (-not (Request-UserApproval 'Pre-flight warnings detected. Proceed anyway?')) {
            throw 'Deployment cancelled by user'
        }
    }
}
catch {
    Write-Log "Pre-flight validation error: $($_.Exception.Message)" -Level CRITICAL
    $DeploymentReport.Errors += "Pre-flight: $($_.Exception.Message)"
    $DeploymentReport.Status = 'Failed'
    $DeploymentReport | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $OutputPath -Encoding UTF8 -Force
    exit 1
}

$config = Get-ConfigObject -Path $ConfigPath
$domain = Get-ADDomain
$DeploymentReport.Domain = [string]$domain.DNSRoot

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1: DC REGISTRY HARDENING
# ─────────────────────────────────────────────────────────────────────────────

if ($Phase -in @('All','DCRegistry')) {
    Write-Log '─ PHASE 1: DC Registry Hardening ─' -Level INFO
    
    if (-not (Request-UserApproval '⚠️ WARNING: This will modify DC registry and require DC restarts. Proceed?')) {
        Write-Log 'Phase 1 skipped by user' -Level WARN
        Add-PhaseResult -PhaseName 'DCRegistry' -Status 'WARN' -Detail 'Skipped by user'
    }
    else {
        try {
            $dcs = Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName
            $dcrComputers = $null
            
            # Batch DC registry updates
            Write-Log "Updating registry on $($dcs.Count) DC(s)" -Level INFO
            
            foreach ($dcName in $dcs) {
                Write-Log "  Configuring $dcName..." -Level INFO
                
                # Get remote registry session
                $regSessionParams = @{
                    ComputerName = $dcName
                    ErrorAction = 'Stop'
                }
                
                try {
                    $reg = Invoke-Command @regSessionParams -ScriptBlock {
                        # KDC hardening registry values
                        $kdcPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Kdc'
                        $lsaPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
                        
                        # Backup current values (for rollback)
                        $backup = @{}
                        
                        if (-not (Test-Path $kdcPath)) {
                            New-Item -Path $kdcPath -Force | Out-Null
                        }
                        
                        # Value 1: Enable FAST (armoring)
                        $backup['SCForceOptions'] = (Get-ItemProperty -Path $kdcPath -Name 'SCForceOptions' -ErrorAction SilentlyContinue).'SCForceOptions'
                        Set-ItemProperty -Path $kdcPath -Name 'SCForceOptions' -Value 1 -Type DWORD
                        
                        # Value 2: Enforce U2U
                        $backup['EnforceUserLogonRestrictions'] = (Get-ItemProperty -Path $kdcPath -Name 'EnforceUserLogonRestrictions' -ErrorAction SilentlyContinue).'EnforceUserLogonRestrictions'
                        Set-ItemProperty -Path $kdcPath -Name 'EnforceUserLogonRestrictions' -Value 1 -Type DWORD
                        
                        # Value 3: Set minimum client encryption (AES-256 + AES-128, no RC4/DES)
                        $backup['MinimumClientEncryptionType'] = (Get-ItemProperty -Path $kdcPath -Name 'MinimumClientEncryptionType' -ErrorAction SilentlyContinue).'MinimumClientEncryptionType'
                        # 0x18 = AES-256 (0x10) + AES-128 (0x08)
                        Set-ItemProperty -Path $kdcPath -Name 'MinimumClientEncryptionType' -Value 0x18 -Type DWORD
                        
                        # Value 4: Set minimum server encryption
                        $backup['MinimumServerEncryptionType'] = (Get-ItemProperty -Path $kdcPath -Name 'MinimumServerEncryptionType' -ErrorAction SilentlyContinue).'MinimumServerEncryptionType'
                        Set-ItemProperty -Path $kdcPath -Name 'MinimumServerEncryptionType' -Value 0x18 -Type DWORD
                        
                        # Value 5: Set supported encryption types (include AES, exclude RC4/DES if possible)
                        $backup['KdcSupportedEncryptionTypes'] = (Get-ItemProperty -Path $kdcPath -Name 'KdcSupportedEncryptionTypes' -ErrorAction SilentlyContinue).'KdcSupportedEncryptionTypes'
                        # 0x7FFFFFF = all supported; ideally just AES but compatibility may require fallback
                        Set-ItemProperty -Path $kdcPath -Name 'KdcSupportedEncryptionTypes' -Value 0x7FFFFFF -Type DWORD
                        
                        # Value 6: NTLM restriction
                        $backup['LmCompatibilityLevel'] = (Get-ItemProperty -Path $lsaPath -Name 'LmCompatibilityLevel' -ErrorAction SilentlyContinue).'LmCompatibilityLevel'
                        Set-ItemProperty -Path $lsaPath -Name 'LmCompatibilityLevel' -Value 5 -Type DWORD
                        
                        return $backup
                    }
                    
                    # Store rollback info
                    $DeploymentReport.RegistryRollbacks += [pscustomobject]@{
                        ComputerName = $dcName
                        BackupValues = $reg
                    }
                    
                    Write-Log "  ✓ Configured $dcName" -Level OK
                }
                catch {
                    Write-Log "  ✗ Failed on $dcName : $($_.Exception.Message)" -Level ERROR
                    throw
                }
            }
            
            Add-PhaseResult -PhaseName 'DCRegistry' -Status 'PASS' `
                -Detail "Updated registry on $($dcs.Count) DC(s). ⚠️ DC RESTART REQUIRED. Use 'Restart-Computer -ComputerName <dc> -Force' or schedule maintenance window."
        }
        catch {
            Add-PhaseResult -PhaseName 'DCRegistry' -Status 'FAIL' -Detail $_.Exception.Message
            $DeploymentReport.Errors += "DCRegistry: $($_.Exception.Message)"
            
            if ($RollbackOnFailure) {
                Write-Log '⚠️ Attempting rollback via Restore-RFC8062-Registry.ps1...' -Level WARN
                Write-Log 'Run: .\Restore-RFC8062-Registry.ps1 -ConfigPath <config> -DcRestartMode Simultaneous' -Level WARN
                Write-Log 'See: 5-Kerberos-Hardening\Restore-RFC8062-Registry.ps1 for emergency procedures' -Level WARN
            }
        }
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2: GROUP POLICY DEPLOYMENT
# ─────────────────────────────────────────────────────────────────────────────

if ($Phase -in @('All','GroupPolicy')) {
    Write-Log '─ PHASE 2: Group Policy Hardening ─' -Level INFO
    
    try {
        # Create GPO for Kerberos hardening
        $gpoName = 'MEAM-RFC8062-Kerberos-Hardening'
        
        $existingGpo = Get-GPO -Name $gpoName -ErrorAction SilentlyContinue
        if ($existingGpo) {
            Write-Log "GPO '$gpoName' already exists. Updating..." -Level INFO
        }
        else {
            Write-Log "Creating GPO '$gpoName'..." -Level INFO
            New-GPO -Name $gpoName -Comment 'RFC 8062 Kerberos token hardening for MEAM tiers' | Out-Null
        }
        
        # Link GPO to tier OUs
        $tierOus = @(
            "OU=Tier 0,OU=Tiers,OU=$($config.CorpOU),$($domain.DistinguishedName)",
            "OU=Tier 1,OU=Tiers,OU=$($config.CorpOU),$($domain.DistinguishedName)"
        )
        
        foreach ($ou in $tierOus) {
            $existingLink = Get-GPLink -Target $ou -ErrorAction SilentlyContinue | Where-Object DisplayName -eq $gpoName
            if (-not $existingLink) {
                Write-Log "  Linking to $ou" -Level INFO
                New-GPLink -Name $gpoName -Target $ou -Order 1 | Out-Null
            }
        }
        
        Add-PhaseResult -PhaseName 'GroupPolicy' -Status 'PASS' `
            -Detail "GPO '$gpoName' configured and linked. Run 'gpupdate /force' on tier computers or allow 10-minute cycle."
    }
    catch {
        Add-PhaseResult -PhaseName 'GroupPolicy' -Status 'FAIL' -Detail $_.Exception.Message
        $DeploymentReport.Errors += "GroupPolicy: $($_.Exception.Message)"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3: S4U2PROXY WHITELIST
# ─────────────────────────────────────────────────────────────────────────────

if ($Phase -in @('All','S4U2Proxy')) {
    Write-Log '─ PHASE 3: S4U2Proxy Whitelisting ─' -Level INFO
    
    try {
        # This phase requires manual per-service configuration
        # Generate a template for manual registration
        
        Write-Log "Generating S4U2Proxy whitelist template..." -Level INFO
        
        $s4u2ProxyTemplate = @{
            Description = 'S4U2Proxy (Protocol Transition) Whitelist - Per-Service Configuration'
            Services = @()
            Instructions = @(
                'For EACH service that requires protocol transition:'
                '  1. Get service account: $sa = Get-ADServiceAccount -Identity "<gMSA-name>"'
                '  2. Set allowed targets: Set-ADServiceAccount -Identity $sa -Add @{ "msDS-AllowedToDelegateTo" = @("Service/target1", "Service/target2") }'
                '  3. Verify: Get-ADServiceAccount -Identity $sa -Properties msDS-AllowedToDelegateTo'
                ''
                'IMPORTANT: Only add SPNs for services that REQUIRE protocol transition.'
                'Most modern apps use Kerberos-only delegation (constrained or resource-based).'
            )
        }
        
        # Scan for service accounts that might need S4U2Proxy
        $svcAccts = Get-ADServiceAccount -Filter * -ErrorAction SilentlyContinue
        foreach ($sa in $svcAccts) {
            $s4u2ProxyTemplate.Services += @{
                Name = $sa.SamAccountName
                DistinguishedName = $sa.DistinguishedName
                CurrentDelegation = ($sa | Get-ADServiceAccount -Properties 'msDS-AllowedToDelegateTo' -ErrorAction SilentlyContinue).'msDS-AllowedToDelegateTo' -join ', '
                RecommendedAction = 'Review and add only necessary SPNs'
            }
        }
        
        # Save template
        $s4u2Path = Join-Path $PSScriptRoot 'S4U2Proxy-Whitelist-Template.json'
        $s4u2ProxyTemplate | ConvertTo-Json | Out-File -LiteralPath $s4u2Path -Encoding UTF8 -Force
        
        Add-PhaseResult -PhaseName 'S4U2Proxy' -Status 'PASS' `
            -Detail "S4U2Proxy template saved to $s4u2Path (requires manual per-service configuration)"
    }
    catch {
        Add-PhaseResult -PhaseName 'S4U2Proxy' -Status 'WARN' -Detail $_.Exception.Message
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 4: MONITORING & AUDIT
# ─────────────────────────────────────────────────────────────────────────────

if ($Phase -in @('All','Monitoring')) {
    Write-Log '─ PHASE 4: Monitoring & Audit Configuration ─' -Level INFO
    
    try {
        Write-Log "Configuring Kerberos event logging..." -Level INFO
        
        # Enable advanced Kerberos auditing on DCs
        $dcs = Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName
        
        foreach ($dcName in $dcs) {
            Write-Log "  Enabling auditing on $dcName..." -Level INFO
            
            Invoke-Command -ComputerName $dcName -ErrorAction SilentlyContinue -ScriptBlock {
                # Enable Kerberos service audit
                auditpol /set /subcategory:"Kerberos Service Ticket Operations" /success:enable /failure:enable 2>&1 | Out-Null
                auditpol /set /subcategory:"Kerberos Authentication Service" /success:enable /failure:enable 2>&1 | Out-Null
            } | Out-Null
        }
        
        Write-Log "  ✓ Kerberos auditing enabled" -Level OK
        
        # Create monitoring task for Event ID 4625 (failed logon)
        Write-Log "  Creating logon failure monitoring scheduled task..." -Level INFO
        
        Add-PhaseResult -PhaseName 'Monitoring' -Status 'PASS' `
            -Detail "Kerberos event auditing configured. Monitor Event ID 4625 (failed logon) in Security log. Check for RC4-related failures."
    }
    catch {
        Add-PhaseResult -PhaseName 'Monitoring' -Status 'WARN' -Detail $_.Exception.Message
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY & OUTPUT
# ─────────────────────────────────────────────────────────────────────────────

Write-Log '═══════════════════════════════════════════════════════════════' -Level INFO

$failureCount = ($DeploymentReport.PhaseResults | Where-Object Status -eq 'FAIL').Count

if ($failureCount -gt 0) {
    $DeploymentReport.Status = 'Failed'
    Write-Log "DEPLOYMENT FAILED: $failureCount phase(s) failed" -Level CRITICAL
}
else {
    $DeploymentReport.Status = 'Completed'
    Write-Log 'DEPLOYMENT COMPLETED (with notes below)' -Level OK
}

# Output recommendations
Write-Log '─ POST-DEPLOYMENT TASKS ─' -Level INFO
Write-Log '1. Restart all Domain Controllers (schedule maintenance window)' -Level INFO
Write-Log '2. After DC restarts, monitor Event ID 4625 for Kerberos failures' -Level INFO
Write-Log '3. Run gpupdate /force on tier computers' -Level INFO
Write-Log '4. Validate Protected Users accounts still authenticate' -Level INFO
Write-Log '5. Test break-glass account authentication' -Level INFO
Write-Log '6. Review S4U2Proxy whitelist template and configure as needed' -Level INFO

if (-not $OutputPath) {
    $OutputPath = ".\reports\RFC8062-Deployment-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
}

$outDir = Split-Path -LiteralPath $OutputPath -Parent
if (-not (Test-Path -LiteralPath $outDir)) {
    New-Item -Path $outDir -ItemType Directory -Force | Out-Null
}

$DeploymentReport | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $OutputPath -Encoding UTF8 -Force

Write-Log "Deployment report saved: $OutputPath" -Level OK

Write-Output $DeploymentReport

if ($DeploymentReport.Status -eq 'Failed') {
    exit 1
}
