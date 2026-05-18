# 5-Kerberos-Hardening

## Overview
RFC 8062 Kerberos hardening implementation, pre-flight validation, and emergency recovery procedures.

## Purpose
This folder contains the complete 4-phase RFC 8062 Kerberos hardening deployment, pre-flight validation checks, and emergency rollback procedures for organizations implementing cryptographic strengthening of Kerberos authentication.

## Strategic Context

### Why Kerberos Hardening?
- **RC4 & DES Deprecation:** Legacy encryption algorithms are cryptographically weak
- **RFC 8062 Standard:** Microsoft enforces this in modern DFL environments
- **Defense Depth:** AES-256 enforcement + FAST armoring + Auth Silos
- **Compliance:** Required for many security frameworks (Zero Trust, SOC2, NIST)

### Risks Without Hardening
- RC4 key reuse vulnerabilities
- Pass-the-hash attacks
- Downgrade attacks to DES
- Credential compromise vectors

## Files

### Test-RFC8062-PreFlight.ps1
**Pre-deployment readiness validation (530 lines)**

**Purpose:** Non-invasive pre-flight checks to ensure environment readiness for RFC 8062 hardening without making any changes.

**Run as:** Domain Admin (read-only operations only)

**Requirements:**
- ActiveDirectory module (RSAT)
- PowerShell 5.1+
- Read access to forest configuration
- DC discovery access

**Usage:**
```powershell
# Full pre-flight assessment
.\Test-RFC8062-PreFlight.ps1 -ConfigPath .\Test-RFC8062-PreFlight.config.example.json

# Quick readiness check
.\Test-RFC8062-PreFlight.ps1 -ConfigPath .\Test-RFC8062-PreFlight.config.example.json -QuickCheck

# Generate JSON risk report
.\Test-RFC8062-PreFlight.ps1 -ConfigPath .\Test-RFC8062-PreFlight.config.example.json -OutputFormat JSON

# Inline config
$config = Get-Content .\Test-RFC8062-PreFlight.config.example.json -Raw
.\Test-RFC8062-PreFlight.ps1 -ConfigJson $config
```

**Pre-Flight Checks:**

| Check | Purpose | Risk Level |
|-------|---------|-----------|
| Domain Functional Level | Requires 2012 R2+ | CRITICAL |
| DC OS Versions | Windows Server 2012 R2+, 2016+, 2019+, 2022 | HIGH |
| Legacy OS Scan | Identifies XP, 7, 8 systems | HIGH |
| RODC Detection | Special handling needed | MEDIUM |
| Service Accounts | gMSA compatibility check | MEDIUM |
| FAST Support | Kerberos FAST Armoring | CRITICAL |
| Forest Trusts | Cross-forest implications | HIGH |

**Risk Assessment Levels:**
- 🟢 **LOW** - Environment ready to proceed
- 🟡 **MEDIUM** - Warnings but can proceed (document exceptions)
- 🔴 **CRITICAL** - Blocking issues, must resolve before proceeding

**Output Artifacts:**
- `.\reports\RFC8062-PreFlight-<timestamp>.json` - Detailed assessment
- `.\reports\RFC8062-RiskLevel.txt` - Overall risk level
- Exit code: 0 = ready, 1 = issues found

### New-RFC8062-Hardening.ps1
**4-phase deployment script (560 lines)**

**Purpose:** Implements RFC 8062 Kerberos hardening in 4 sequential phases with rollback capability.

**Run as:** Enterprise Admin (makes forest-wide changes)

**Requirements:**
- ActiveDirectory module (RSAT)
- GroupPolicy module (RSAT)
- Elevated privileges (Enterprise Admin)
- All DCs online and reachable
- PowerShell 5.1+
- Pre-flight validation completed ✓

**Usage:**
```powershell
# Phase 1 only: DC Registry hardening
.\New-RFC8062-Hardening.ps1 -ConfigPath .\config.json -Phase Registry

# Phase 2 only: Group Policy deployment
.\New-RFC8062-Hardening.ps1 -ConfigPath .\config.json -Phase GroupPolicy

# Phase 3 only: S4U2Proxy whitelist
.\New-RFC8062-Hardening.ps1 -ConfigPath .\config.json -Phase Whitelist

# Phase 4 only: Monitoring
.\New-RFC8062-Hardening.ps1 -ConfigPath .\config.json -Phase Monitoring

# All phases (sequential)
.\New-RFC8062-Hardening.ps1 -ConfigPath .\config.json -Phase All

# With rollback enabled
.\New-RFC8062-Hardening.ps1 -ConfigPath .\config.json -Phase All -RollbackOnFailure
```

**4-Phase Deployment:**

```
Phase 1: DC Registry Hardening
├─ Enable AES-256 on all DCs
├─ Disable RC4 (preserves DES for legacy)
├─ Require FAST armoring
└─ DC Restart Required ⚠️

↓

Phase 2: Group Policy Deployment
├─ Create RFC8062 GPO
├─ Link to all OUs
├─ Set kerberos policies
└─ GPO refresh (auto)

↓

Phase 3: S4U2Proxy Whitelisting
├─ Build service whitelist
├─ Configure per-service delegation
├─ Test constrained delegation
└─ Non-disruptive

↓

Phase 4: Monitoring & Compliance
├─ Enable Kerberos event logging
├─ Configure alerts
├─ Pre-auth failure tracking
└─ Ongoing compliance
```

**Key Features:**
- ✅ Phased execution (can run individually)
- ✅ Automatic rollback on phase failure (if enabled)
- ✅ DC restart orchestration
- ✅ Phase resumption capability
- ✅ Comprehensive logging

**Output Artifacts:**
- `.\reports\RFC8062-Deployment-<timestamp>.json` - Full execution log
- `.\reports\RFC8062-Registry-Changes.csv` - Registry modifications
- `.\reports\RFC8062-PhaseLog.csv` - Per-phase status

### Restore-RFC8062-Registry.ps1
**Emergency rollback script (380 lines)**

**Purpose:** Rapidly restores RC4/DES support on DCs in emergency situations (e.g., authentication failures post-hardening).

**Run as:** Enterprise Admin

**Requirements:**
- ActiveDirectory module (RSAT)
- Elevated privileges
- Emergency access to at least one DC
- PowerShell 5.1+

**Usage - Emergency Scenarios:**

```powershell
# Scenario 1: Sequential DC restart (safe, slower)
.\Restore-RFC8062-Registry.ps1 -ConfigPath .\config.json -DcRestartMode Sequential

# Scenario 2: Simultaneous restart (fast, requires careful planning)
.\Restore-RFC8062-Registry.ps1 -ConfigPath .\config.json -DcRestartMode Simultaneous

# Scenario 3: Single DC (for testing)
.\Restore-RFC8062-Registry.ps1 -ConfigPath .\config.json -RestoreOnlyDC DC1.corp.local

# Scenario 4: Restore specific encryption only
.\Restore-RFC8062-Registry.ps1 -ConfigPath .\config.json -RestoreRc4Only -DcRestartMode Sequential
```

**Rollback Procedure:**

1. **Assess Impact** (2 min)
   ```powershell
   # Are authentication failures widespread?
   Get-WinEvent -ComputerName DC1 -FilterHashtable @{LogName='Security'; ID=4768} -MaxEvents 100
   ```

2. **Execute Rollback** (5-15 min)
   ```powershell
   # Sequential restart = 5 min per DC
   .\Restore-RFC8062-Registry.ps1 -ConfigPath .\config.json -DcRestartMode Sequential
   ```

3. **Validate Recovery** (5 min)
   ```powershell
   # Test authentication
   klist purge
   kinit user@CORP.LOCAL
   ```

4. **Root Cause Analysis** (ongoing)
   - Review Phase 1 logs for incompatibilities
   - Check service account encryption requirements
   - Test Phase 1 in lab environment first

**Output Artifacts:**
- `.\reports\RFC8062-Rollback-<timestamp>.json` - Rollback log
- Console output during DC restarts

## Deployment Workflow

### Pre-Deployment (Week 1)
```powershell
# Step 1: Run pre-flight validation
.\Test-RFC8062-PreFlight.ps1 -ConfigPath .\prod-rfc8062.config.json

# Step 2: Review risk assessment
cat .\reports\RFC8062-RiskLevel.txt

# Step 3: Remediate any CRITICAL items
# (Fix legacy OS, upgrade DFL, etc.)
```

### Lab Validation (Week 2)
```powershell
# Step 1: Copy config to lab environment
# Step 2: Deploy Phase 1 in lab
.\New-RFC8062-Hardening.ps1 -ConfigPath .\lab-rfc8062.config.json -Phase Registry

# Step 3: Test authentication workflows
# Step 4: Validate service accounts (gMSA, regular accounts)
# Step 5: Test emergency rollback
.\Restore-RFC8062-Registry.ps1 -ConfigPath .\lab-rfc8062.config.json -DcRestartMode Sequential
```

### Production Deployment (Week 3-4)
```powershell
# Step 1: Plan maintenance window (2-3 hours)
# Step 2: Execute Phase 1 (1 hour + DC restart)
.\New-RFC8062-Hardening.ps1 -ConfigPath .\prod-rfc8062.config.json -Phase Registry

# Step 3: Monitor for 24 hours
# - Watch for authentication failures
# - Review event logs on DCs
# - Check application logs for issues

# Step 4: If successful, proceed to Phase 2
.\New-RFC8062-Hardening.ps1 -ConfigPath .\prod-rfc8062.config.json -Phase GroupPolicy

# Step 5: Proceed to Phases 3 & 4 (non-invasive)
.\New-RFC8062-Hardening.ps1 -ConfigPath .\prod-rfc8062.config.json -Phase All
```

## Troubleshooting

### Authentication Failures After Phase 1
```powershell
# 1. Check DC registry
Get-Item 'HKLM:\System\CurrentControlSet\Control\Lsa\Kerberos\Parameters' -ComputerName DC1

# 2. Check DC event logs for pre-auth failures
Get-WinEvent -ComputerName DC1 -FilterHashtable @{
  LogName='Security'
  ID=4768,4771,4772
} -MaxEvents 50

# 3. Emergency rollback to unblock authentication
.\Restore-RFC8062-Registry.ps1 -ConfigPath .\prod-rfc8062.config.json -DcRestartMode Sequential

# 4. Investigate root cause in lab before re-attempting
```

### Service Account Issues
```powershell
# Check if service uses legacy encryption
Get-ADServiceAccount -Identity MyServiceAccount | Select-Object KerberosEncryptionType

# If legacy encryption required, exclude from hardening
# Or convert to gMSA (recommended)
New-ADServiceAccount -Name MyServiceAccountGMSA -ComputerName ComputerName1, ComputerName2
```

### RODC Compatibility
RODCs require special handling:
- RODCs cannot create/modify passwords
- RODCs must be in Tier 1 minimum
- Ensure RODC account is in Protected Users (if Tier 0)
- Test Phase 1 with RODC in lab first

## Configuration

### Test-RFC8062-PreFlight.config.example.json
```json
{
  "SkipLegacyOsScan": false,
  "SkipRodcCheck": false,
  "OutputFormat": "JSON",
  "OutputDirectory": ".\\reports"
}
```

### New-RFC8062-Hardening.config.example.json
```json
{
  "DomainControllers": ["DC1.corp.local", "DC2.corp.local"],
  "DcRestartMode": "Sequential",
  "DcRestartDelaySeconds": 60,
  "RollbackOnFailure": true,
  "OutputDirectory": ".\\reports"
}
```

### Restore-RFC8062-Registry.config.example.json
```json
{
  "DomainControllers": ["DC1.corp.local", "DC2.corp.local"],
  "DcRestartMode": "Sequential",
  "DcRestartDelaySeconds": 60,
  "RestoreRc4": true,
  "RestoreDes": false,
  "OutputDirectory": ".\\reports"
}
```

## References

- **RFC 8062:** [Kerberos Encryption Types](https://tools.ietf.org/html/rfc8062)
- **Microsoft Guidance:** [Kerberos Security Best Practices](https://docs.microsoft.com/en-us/windows/security/threat-protection/security-policy-settings/kerberos-policy)
- **Deployment Guide:** [DEPLOYMENT.md](../DEPLOYMENT.md)
- **Architecture:** [ARCHITECTURE.md](../ARCHITECTURE.md)

## Related Documentation

- **MEAM Deployment:** [1-Deployment/README.md](../1-Deployment/README.md)
- **Validation:** [4-Validation/README.md](../4-Validation/README.md)
- **Troubleshooting:** [TROUBLESHOOTING.md](../TROUBLESHOOTING.md)

---
**Version:** 1.0  
**Last Updated:** 2024  
**Maintainer:** Security Architecture Team
