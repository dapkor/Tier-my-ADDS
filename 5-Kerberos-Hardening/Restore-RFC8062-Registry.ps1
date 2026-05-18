<#
.SYNOPSIS
    Emergency rollback for RFC 8062 Phase 1 (DC Registry Hardening).
    
.DESCRIPTION
    Reverts KDC registry changes on Domain Controllers if Phase 1 deployment
    causes authentication outages. This is a LAST-RESORT script for emergency
    recovery only. Normal deployment should be validated thoroughly first.
    
    This script:
    1. Removes RFC 8062 KDC hardening from DC registry
    2. Returns to pre-deployment encryption defaults
    3. Restores legacy encryption type support (RC4, DES fallback)
    4. Triggers DC restart (for GPO cleanup)
    
.PARAMETER DcName
    Specific DC to rollback. If omitted, prompts for all DCs.
    
.PARAMETER DeploymentReportPath
    Path to RFC8062-Deployment-*.json report (contains registry backups).
    Optional; if omitted, uses hardcoded pre-deployment defaults.
    
.PARAMETER RollbackMode
    'Sequential' = Restart DCs one-by-one (safer)
    'Simultaneous' = Restart all DCs at once (faster, riskier)
    Default: Sequential
    
.PARAMETER RestartDelaySeconds
    Seconds to wait between DC restarts (Sequential mode only).
    Default: 120 (2 minutes)

.EXAMPLE
    # Rollback a single DC
    .\RFC8062-DcRegistryRollback.ps1 -DcName DC01
    
.EXAMPLE
    # Rollback all DCs sequentially (recommended)
    .\RFC8062-DcRegistryRollback.ps1 -RollbackMode Sequential

.NOTES
    ⚠️ WARNING: This is an EMERGENCY procedure. Use only if auth is broken.
    Normal rollback should follow documented procedures in RFC8062-Implementation-Guide.md
#>

#Requires -Modules ActiveDirectory
#Requires -Version 5.1
#Requires -RunAsAdministrator

param(
    [string]$DcName,
    
    [string]$DeploymentReportPath,
    
    [ValidateSet('Sequential','Simultaneous')]
    [string]$RollbackMode = 'Sequential',
    
    [int]$RestartDelaySeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RollbackReport = [ordered]@{
    GeneratedAt = (Get-Date).ToString('o')
    RollbackMode = $RollbackMode
    DeploymentReportUsed = $false
    DcsRolledBack = @()
    Errors = @()
    Status = 'InProgress'
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

function Request-Confirmation {
    param([Parameter(Mandatory)][string]$Message)
    
    Write-Log "⚠️ $Message" -Level CRITICAL
    $response = Read-Host 'Type YES to continue, or press Enter to abort'
    return $response -eq 'YES'
}

# ─────────────────────────────────────────────────────────────────────────────
# PRE-ROLLBACK VALIDATION
# ─────────────────────────────────────────────────────────────────────────────

Write-Log 'RFC 8062 Emergency Rollback' -Level CRITICAL
Write-Log '═══════════════════════════════════════════════════════════════' -Level CRITICAL

if (-not (Request-Confirmation 'This will REVERT Kerberos hardening on Domain Controllers. Domain auth may be disrupted during restart. Continue?')) {
    Write-Log 'Rollback cancelled by user' -Level WARN
    exit 0
}

# Get DCs to rollback
if ($DcName) {
    $targetDcs = @($DcName)
}
else {
    $allDcs = Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName
    Write-Log "Found $($allDcs.Count) Domain Controller(s)" -Level INFO
    
    foreach ($dc in $allDcs) {
        Write-Log "  - $dc" -Level INFO
    }
    
    if (-not (Request-Confirmation "Rollback ALL $($allDcs.Count) DCs?")) {
        Write-Log 'User selected specific DCs (not implemented in this script)' -Level WARN
        Write-Log 'Re-run with -DcName parameter for specific DC' -Level INFO
        exit 1
    }
    
    $targetDcs = $allDcs
}

# Load deployment report if provided (contains backup registry values)
if ($DeploymentReportPath -and (Test-Path $DeploymentReportPath)) {
    try {
        $deploymentReport = Get-Content $DeploymentReportPath -Raw | ConvertFrom-Json
        $RollbackReport.DeploymentReportUsed = $true
        Write-Log "Using registry backups from deployment report" -Level INFO
    }
    catch {
        Write-Log "Could not parse deployment report: $($_.Exception.Message)" -Level WARN
        Write-Log "Using hardcoded defaults instead" -Level WARN
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# ROLLBACK REGISTRY ON EACH DC
# ─────────────────────────────────────────────────────────────────────────────

Write-Log "─ Reverting Registry on $($targetDcs.Count) DC(s) ─" -Level INFO

foreach ($i = 0; $i -lt $targetDcs.Count; $i++) {
    $dcName = $targetDcs[$i]
    
    Write-Log "[$($i+1)/$($targetDcs.Count)] Processing $dcName..." -Level INFO
    
    try {
        # Remote registry revert
        $remoteResult = Invoke-Command -ComputerName $dcName -ErrorAction Stop -ScriptBlock {
            param($BackupInfo)
            
            $kdcPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Kdc'
            $lsaPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa'
            
            $reverted = @{}
            
            try {
                # Revert KDC values to pre-RFC8062 defaults
                
                # SCForceOptions: 0 = FAST optional (was: 1 = required)
                if ($BackupInfo -and $BackupInfo.BackupValues.SCForceOptions) {
                    Set-ItemProperty -Path $kdcPath -Name 'SCForceOptions' `
                        -Value $BackupInfo.BackupValues.SCForceOptions -Type DWORD -ErrorAction SilentlyContinue
                    $reverted['SCForceOptions'] = $BackupInfo.BackupValues.SCForceOptions
                }
                else {
                    Set-ItemProperty -Path $kdcPath -Name 'SCForceOptions' -Value 0 -Type DWORD
                    $reverted['SCForceOptions'] = 0
                }
                
                # EnforceUserLogonRestrictions: 0 = disabled (was: 1 = enabled)
                if ($BackupInfo -and $BackupInfo.BackupValues.EnforceUserLogonRestrictions) {
                    Set-ItemProperty -Path $kdcPath -Name 'EnforceUserLogonRestrictions' `
                        -Value $BackupInfo.BackupValues.EnforceUserLogonRestrictions -Type DWORD -ErrorAction SilentlyContinue
                    $reverted['EnforceUserLogonRestrictions'] = $BackupInfo.BackupValues.EnforceUserLogonRestrictions
                }
                else {
                    Set-ItemProperty -Path $kdcPath -Name 'EnforceUserLogonRestrictions' -Value 0 -Type DWORD
                    $reverted['EnforceUserLogonRestrictions'] = 0
                }
                
                # MinimumClientEncryptionType: 0xFFFFFFFF = all types (was: 0x18 = AES only)
                if ($BackupInfo -and $BackupInfo.BackupValues.MinimumClientEncryptionType) {
                    Set-ItemProperty -Path $kdcPath -Name 'MinimumClientEncryptionType' `
                        -Value $BackupInfo.BackupValues.MinimumClientEncryptionType -Type DWORD -ErrorAction SilentlyContinue
                    $reverted['MinimumClientEncryptionType'] = $BackupInfo.BackupValues.MinimumClientEncryptionType
                }
                else {
                    Set-ItemProperty -Path $kdcPath -Name 'MinimumClientEncryptionType' -Value 0xFFFFFFFF -Type DWORD
                    $reverted['MinimumClientEncryptionType'] = 0xFFFFFFFF
                }
                
                # MinimumServerEncryptionType: 0xFFFFFFFF = all types (was: 0x18 = AES only)
                if ($BackupInfo -and $BackupInfo.BackupValues.MinimumServerEncryptionType) {
                    Set-ItemProperty -Path $kdcPath -Name 'MinimumServerEncryptionType' `
                        -Value $BackupInfo.BackupValues.MinimumServerEncryptionType -Type DWORD -ErrorAction SilentlyContinue
                    $reverted['MinimumServerEncryptionType'] = $BackupInfo.BackupValues.MinimumServerEncryptionType
                }
                else {
                    Set-ItemProperty -Path $kdcPath -Name 'MinimumServerEncryptionType' -Value 0xFFFFFFFF -Type DWORD
                    $reverted['MinimumServerEncryptionType'] = 0xFFFFFFFF
                }
                
                # KdcSupportedEncryptionTypes: 0xFFFFFFFF = all types (was: 0x7FFFFFF = filtered)
                if ($BackupInfo -and $BackupInfo.BackupValues.KdcSupportedEncryptionTypes) {
                    Set-ItemProperty -Path $kdcPath -Name 'KdcSupportedEncryptionTypes' `
                        -Value $BackupInfo.BackupValues.KdcSupportedEncryptionTypes -Type DWORD -ErrorAction SilentlyContinue
                    $reverted['KdcSupportedEncryptionTypes'] = $BackupInfo.BackupValues.KdcSupportedEncryptionTypes
                }
                else {
                    Set-ItemProperty -Path $kdcPath -Name 'KdcSupportedEncryptionTypes' -Value 0xFFFFFFFF -Type DWORD
                    $reverted['KdcSupportedEncryptionTypes'] = 0xFFFFFFFF
                }
                
                # LmCompatibilityLevel: keep at 5 (NTLMv2 only - good practice)
                # Don't change as it's orthogonal to RFC8062
                
                return @{ Success = $true; Reverted = $reverted }
            }
            catch {
                return @{ Success = $false; Error = $_.Exception.Message }
            }
        } -ArgumentList @{ BackupValues = $deploymentReport.RegistryRollbacks.BackupValues | Where-Object { $_.ComputerName -eq $dcName } } -ErrorVariable remoteErr
        
        if ($remoteResult.Success) {
            Write-Log "  ✓ Registry reverted on $dcName" -Level OK
            Write-Log "    - SCForceOptions: $($remoteResult.Reverted.SCForceOptions)" -Level INFO
            Write-Log "    - MinimumClientEncryptionType: 0x$($remoteResult.Reverted.MinimumClientEncryptionType.ToString('X'))" -Level INFO
        }
        else {
            Write-Log "  ✗ Registry rollback failed on $dcName : $($remoteResult.Error)" -Level ERROR
            $RollbackReport.Errors += "$dcName : $($remoteResult.Error)"
            continue
        }
        
        $RollbackReport.DcsRolledBack += [pscustomobject]@{
            Name = $dcName
            Status = 'RegistryReverted'
            Timestamp = (Get-Date).ToString('o')
        }
    }
    catch {
        Write-Log "  ✗ Failed to connect to $dcName : $($_.Exception.Message)" -Level ERROR
        $RollbackReport.Errors += "$dcName : $($_.Exception.Message)"
        continue
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# RESTART DCs
# ─────────────────────────────────────────────────────────────────────────────

Write-Log "─ Restarting Domain Controllers ─" -Level INFO
Write-Log "Restart mode: $RollbackMode" -Level INFO

if ($RollbackMode -eq 'Sequential') {
    foreach ($i = 0; $i -lt $RollbackReport.DcsRolledBack.Count; $i++) {
        $dcName = $RollbackReport.DcsRolledBack[$i].Name
        
        Write-Log "[$($i+1)/$($RollbackReport.DcsRolledBack.Count)] Restarting $dcName..." -Level INFO
        
        try {
            Restart-Computer -ComputerName $dcName -Force -ErrorAction Stop
            Write-Log "  ✓ Restart initiated on $dcName" -Level OK
            
            if ($i -lt ($RollbackReport.DcsRolledBack.Count - 1)) {
                Write-Log "  ⏳ Waiting $RestartDelaySeconds seconds before next restart..." -Level INFO
                Start-Sleep -Seconds $RestartDelaySeconds
            }
        }
        catch {
            Write-Log "  ✗ Restart failed on $dcName : $($_.Exception.Message)" -Level ERROR
        }
    }
}
else {
    # Simultaneous restart (faster but riskier)
    Write-Log "⚠️ Simultaneous restart: ALL DCs will be offline temporarily" -Level CRITICAL
    
    foreach ($dcName in $RollbackReport.DcsRolledBack.Name) {
        try {
            Restart-Computer -ComputerName $dcName -Force -AsJob | Out-Null
            Write-Log "  ✓ Restart job queued for $dcName" -Level OK
        }
        catch {
            Write-Log "  ✗ Restart failed on $dcName : $($_.Exception.Message)" -Level ERROR
        }
    }
    
    Write-Log "All DC restarts queued" -Level OK
}

# ─────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ─────────────────────────────────────────────────────────────────────────────

Write-Log '═══════════════════════════════════════════════════════════════' -Level CRITICAL

$RollbackReport.Status = if ($RollbackReport.Errors.Count -eq 0) { 'Success' } else { 'PartialSuccess' }

Write-Log "Rollback Status: $($RollbackReport.Status)" -Level $(if ($RollbackReport.Status -eq 'Success') { 'OK' } else { 'WARN' })
Write-Log "DCs Reverted: $($RollbackReport.DcsRolledBack.Count)" -Level INFO

if ($RollbackReport.Errors.Count -gt 0) {
    Write-Log "Errors: $($RollbackReport.Errors.Count)" -Level ERROR
    $RollbackReport.Errors | ForEach-Object { Write-Log "  - $_" -Level ERROR }
}

Write-Log '─ POST-ROLLBACK ACTIONS ─' -Level INFO
Write-Log '1. Wait 10 minutes for all DCs to restart' -Level INFO
Write-Log '2. Verify Domain Controllers come online (Event Viewer → System log)' -Level INFO
Write-Log '3. Test AD authentication from workstation' -Level INFO
Write-Log '4. Check Event ID 4625 for Kerberos errors (should be minimal)' -Level INFO
Write-Log '5. If auth restored, investigate what broke and plan fix' -Level INFO

$reportPath = ".\reports\RFC8062-Rollback-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
$RollbackReport | ConvertTo-Json -Depth 10 | Out-File -LiteralPath $reportPath -Encoding UTF8 -Force

Write-Log "Rollback report: $reportPath" -Level OK

Write-Output $RollbackReport

if ($RollbackReport.Status -eq 'Success') {
    Write-Log 'Rollback completed successfully. RFC 8062 hardening has been reverted.' -Level OK
}
else {
    Write-Log 'Rollback completed with errors. Review report above.' -Level WARN
    exit 1
}
