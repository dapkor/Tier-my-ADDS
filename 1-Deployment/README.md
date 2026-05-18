# 1-Deployment

## Overview
Full greenfield deployment of the **Monash Enterprise Access Model (MEAM)** alongside an existing Active Directory forest.

## Purpose
This folder contains the authoritative MEAM deployment script that implements:
- **Administrative Tiers** (T0, T1, T2) with Privileged Access Workstations (PAWs)
- **Microsegmentation Zones** (8 zones across tiers for horizontal isolation)
- **Service-Level Delegation Groups** (~18 per zone for fine-grained access control)
- **Authentication Policy Silos** (per-tier PAW + per-zone enforcement)
- **Protected Users Security** (all zoned accounts + gMSAs for services)
- **Smartcard (PIV) Enforcement** for administrative accounts
- **Deny-Logon User Rights** as additional authorization layer
- **Group Policy Hardening** (LAPS, Credential Guard, Audit Policy)
- **DNS Tier 1 Delegation** for management isolation
- **Full Compliance Validation** reporting

## Files

### New-MEAM-Deployment.ps1
**Main deployment script (1700+ lines)**

**Run as:** Enterprise Admin on PDC Emulator or T0 PAW with RSAT

**Requirements:**
- Domain Functional Level 2012 R2 or higher
- ActiveDirectory, GroupPolicy, DnsServer RSAT modules
- Elevated privileges (Administrator)
- PowerShell 5.1+

**Usage:**
```powershell
# Validate configuration before deployment
.\New-MEAM-Deployment.ps1 -ConfigPath .\New-MEAM-Deployment.config.example.json -ValidateOnly

# Full deployment (lab environment - test first!)
.\New-MEAM-Deployment.ps1 -ConfigPath .\New-MEAM-Deployment.config.example.json

# Continue on non-fatal errors
.\New-MEAM-Deployment.ps1 -ConfigPath .\New-MEAM-Deployment.config.example.json -ContinueOnPhaseError

# Inline JSON configuration
$config = Get-Content .\New-MEAM-Deployment.config.example.json -Raw
.\New-MEAM-Deployment.ps1 -ConfigJson $config
```

**Key Features:**
- ✅ Idempotent (skips existing objects)
- ✅ Phase-based execution with resumption capability
- ✅ Structured JSON-driven configuration
- ✅ Non-fatal error handling and reporting
- ✅ Export artifacts: RunReport (JSON), Phase Log (CSV)

**Output Artifacts:**
- `.\reports\MEAM-RunReport.json` - Complete execution report
- `.\reports\MEAM-RunReport-phases.csv` - Per-phase status
- `.\reports\MEAM-ComplianceReport.html` - Initial compliance baseline

### New-MEAM-Deployment.config.example.json
**Configuration template** (see file for detailed schema)

Copy this to a new name (e.g., `corp-prod.config.json`) and customize:
- Tier/Zone definitions
- OU structure
- Service definitions per zone
- Password Security Object (PSO) policies
- Group Policy settings
- Reporting paths

## Deployment Workflow

### Step 1: Preparation
```powershell
# Copy config template
Copy-Item .\New-MEAM-Deployment.config.example.json .\corp-prod.config.json

# Edit for your environment
code .\corp-prod.config.json
```

### Step 2: Validation (Lab Only)
```powershell
# Lint configuration (no AD changes)
.\New-MEAM-Deployment.ps1 -ConfigPath .\corp-prod.config.json -LintConfigOnly

# Validate deployment changes without applying
.\New-MEAM-Deployment.ps1 -ConfigPath .\corp-prod.config.json -ValidateOnly
```

### Step 3: Phased Deployment
The script executes in these phases:
1. **OU Creation** - Creates organizational unit hierarchy
2. **Group Management** - Creates delegation and administrative groups
3. **PSO Configuration** - Applies password policies per tier
4. **Auth Silo Enforcement** - Creates authentication policies
5. **GPO Deployment** - Links and configures group policies
6. **ACL Configuration** - Applies discretionary access controls
7. **Compliance Report** - Generates baseline compliance artifact

### Step 4: Post-Deployment Validation
```powershell
# Full compliance check (see 4-Validation folder)
.\Test-MEAM-Deployment.ps1 -ConfigPath .\corp-prod.config.json
```

## Troubleshooting

### Script Fails on Phase 1 (OU Creation)
- Verify you're running as Enterprise Admin
- Check Domain Functional Level: `Get-ADDomainController -Discover | Select-Object Forest, Forest Functional Level`
- Verify RSAT modules: `Get-Module -ListAvailable ActiveDirectory,GroupPolicy,DnsServer`

### Idempotency Issue
The script is designed to be idempotent and skip existing objects. If you need to re-run:
- It will not modify existing OUs/groups/policies
- To force overwrite, manually delete/modify existing objects in ADUC

### Phase Resumption
If a phase fails, check the error in the run report:
```powershell
cat .\reports\MEAM-RunReport.json | ConvertFrom-Json
```

Fix the issue, then re-run. The script resumes from where it left off (per phase logic).

## References

- **MEAM Documentation:** [Monash Enterprise Access Model GitHub](https://github.com/mon-csirt/active-directory-security/tree/main/MEAM)
- **Microsoft EAM:** [Enterprise Access Model (aka.ms/EAM)](https://aka.ms/EAM)
- **RFC 8062:** [Kerberos Hardening (see 5-Kerberos-Hardening folder)](../5-Kerberos-Hardening/README.md)
- **Deployment Guide:** [ARCHITECTURE.md](../ARCHITECTURE.md)

## Security Considerations

⚠️ **TEST IN LAB FIRST** - This script makes extensive Active Directory modifications

- Implement in isolated lab environment first
- Validate all compliance checks before production
- Document current baseline before running
- Have rollback procedures documented
- Consider phased rollout (T0 → T1 → T2)

## Support

For issues, refer to:
1. [TROUBLESHOOTING.md](../TROUBLESHOOTING.md) - Common issues and solutions
2. [OPERATIONS.md](../OPERATIONS.md) - Post-deployment operations
3. [DEPLOYMENT.md](../DEPLOYMENT.md) - Detailed deployment guide

---
**Version:** 1.0  
**Last Updated:** 2024  
**Maintainer:** MEAM Team
