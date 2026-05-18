# 4-Validation

## Overview
Post-deployment validation and compliance checking for MEAM and Active Directory security posture.

## Purpose
This folder contains scripts that comprehensively validate MEAM deployment, verify security controls are in place, and ensure the environment meets compliance requirements.

## Files

### Test-MEAM-Deployment.ps1
**Post-deployment validation script (800+ lines)**

**Purpose:** Executes 50+ compliance checks to verify MEAM deployment completeness and correctness.

**Run as:** Enterprise Admin or domain-joined account with read access

**Requirements:**
- ActiveDirectory module (RSAT)
- GroupPolicy module (RSAT)
- PowerShell 5.1+
- Read access to Active Directory
- Access to Domain Controllers (for GPO verification)

**Usage:**
```powershell
# Full compliance validation
.\Test-MEAM-Deployment.ps1 -ConfigPath .\prod-meam.config.json

# Validation with strict mode (stop on first failure)
.\Test-MEAM-Deployment.ps1 -ConfigPath .\prod-meam.config.json -FailOnPhaseError

# Skip certain checks (e.g., skip networking checks)
.\Test-MEAM-Deployment.ps1 -ConfigPath .\prod-meam.config.json -ExcludePhase Networking

# Generate JSON report
.\Test-MEAM-Deployment.ps1 -ConfigPath .\prod-meam.config.json -ReportFormat JSON

# Inline config
$config = Get-Content .\prod-meam.config.json -Raw
.\Test-MEAM-Deployment.ps1 -ConfigJson $config
```

**Validation Checks (50+):**

| Category | Check | Severity |
|----------|-------|----------|
| **OU Structure** | OU hierarchy created | CRITICAL |
| | OU naming compliance | HIGH |
| | OU delegation set | MEDIUM |
| **Group Management** | Delegation groups exist | CRITICAL |
| | Role groups configured | HIGH |
| | Service groups present | MEDIUM |
| **PSO Configuration** | PSOs created per tier | CRITICAL |
| | PSO policies applied | HIGH |
| | Scoped users correct | MEDIUM |
| **Auth Silos** | PAW silos created | CRITICAL |
| | Zone silos created | HIGH |
| | Silo policies enforced | MEDIUM |
| **GPO Deployment** | GPOs linked | CRITICAL |
| | Settings applied | HIGH |
| | Audit policy enabled | MEDIUM |
| **Protected Users** | Accounts protected | CRITICAL |
| | No legacy protocols | HIGH |
| **Break-Glass** | Break-glass accounts present | CRITICAL |
| | Break-glass validated | HIGH |
| | Credentials secure | MEDIUM |

**Output Artifacts:**
- `.\reports\MEAM-Validation-<timestamp>.json` - Detailed check results
- `.\reports\MEAM-Validation-<timestamp>.csv` - Summary CSV
- Exit code: 0 = all pass, 1 = failures detected

**Check Status Levels:**
- ✅ **PASS** - Check succeeded
- ⚠️ **WARN** - Check passed with warnings
- ❌ **FAIL** - Check failed (investigate)
- ⊘ **SKIP** - Check skipped (by filter)

## Validation Workflow

### Step 1: Post-Deployment
Run validation immediately after MEAM deployment:
```powershell
.\Test-MEAM-Deployment.ps1 -ConfigPath .\prod-meam.config.json
```

### Step 2: Review Results
```powershell
# View JSON report
$report = Get-Content .\reports\MEAM-Validation-*.json | ConvertFrom-Json
$report.Checks | Where-Object Status -eq 'FAIL' | Format-Table CheckName, Status, Detail

# View summary
$report | Select-Object -Property 'TotalChecks', 'PassCount', 'FailCount', 'SkipCount'
```

### Step 3: Remediate Failures
For each FAIL:
1. Read the `Detail` field for specific issue
2. Reference [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) for common fixes
3. Apply fix (e.g., link missing GPO)
4. Re-run validation for affected check

### Step 4: Continuous Monitoring
```powershell
# Schedule weekly validation
$trigger = New-JobTrigger -Weekly -DaysOfWeek Monday -At 3:00 AM
Register-ScheduledJob -Name "MEAM-Weekly-Validation" `
  -ScriptBlock { .\Test-MEAM-Deployment.ps1 -ConfigPath .\prod-meam.config.json } `
  -Trigger $trigger
```

## Troubleshooting Validation Failures

### Example: OU Structure Check Failed
```powershell
# Check what OUs exist
Get-ADOrganizationalUnit -Filter * -SearchBase "CN=Tier0,CN=Accounts,DC=corp,DC=local"

# Create missing OU
New-ADOrganizationalUnit -Name "0A-DomainControllers" -Path "CN=Tier0,CN=Accounts,DC=corp,DC=local"

# Re-run validation
.\Test-MEAM-Deployment.ps1 -ConfigPath .\prod-meam.config.json
```

### Example: Group Policy Check Failed
```powershell
# List linked GPOs
Get-GPInheritance -Target "CN=Tier0,CN=Accounts,DC=corp,DC=local"

# Link missing GPO
New-GPLink -Name "MEAM-T0-SecurityBaseline" -Target "CN=Tier0,CN=Accounts,DC=corp,DC=local"

# Force Group Policy update
Invoke-GPUpdate -Computer * -Force
```

### Example: PSO Check Failed
```powershell
# List existing PSOs
Get-ADFineGrainedPasswordPolicy -Filter *

# List applied PSOs
Get-ADFineGrainedPasswordPolicy -Identity "PSO-Tier0" | Get-ADFineGrainedPasswordPolicySubject

# Add missing users to PSO
Add-ADFineGrainedPasswordPolicySubject -Identity "PSO-Tier0" -Subjects (Get-ADUser -Filter "Name -like 'T0*'")
```

## Pre-Validation Checklist

Before running test-meam-deployment.ps1:
- [ ] MEAM deployment completed without errors
- [ ] Domain Functional Level is 2012 R2+
- [ ] You are running as Enterprise Admin
- [ ] ActiveDirectory and GroupPolicy modules installed
- [ ] All DCs are online and reachable
- [ ] AD replication is healthy
- [ ] No DC is in DSRM

## Integration with CI/CD

### Azure Pipeline
```yaml
- task: PowerShell@2
  inputs:
    scriptPath: '4-Validation/Test-MEAM-Deployment.ps1'
    arguments: '-ConfigPath $(Build.SourcesDirectory)/prod-meam.config.json -FailOnPhaseError'
    pwsh: true
  continueOnError: false
```

### GitHub Actions
```yaml
- name: Validate MEAM Deployment
  run: |
    .\4-Validation\Test-MEAM-Deployment.ps1 -ConfigPath prod-meam.config.json
    if ($LASTEXITCODE -ne 0) { exit 1 }
```

## Related Documentation

- **MEAM Deployment:** [1-Deployment/README.md](../1-Deployment/README.md)
- **Troubleshooting:** [TROUBLESHOOTING.md](../TROUBLESHOOTING.md)
- **Architecture:** [ARCHITECTURE.md](../ARCHITECTURE.md)

---
**Version:** 1.0  
**Last Updated:** 2024  
**Maintainer:** Infrastructure Team
