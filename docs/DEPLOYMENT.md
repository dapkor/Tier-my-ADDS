# MEAM Deployment Guide

**Step-by-step procedures for deploying the Monash Enterprise Access Model**

---

## Table of Contents

1. [Pre-Deployment Checklist](#pre-deployment-checklist)
2. [Environment Requirements](#environment-requirements)
3. [Phase 1: Pre-Flight Validation](#phase-1-pre-flight-validation)
4. [Phase 2: Configuration](#phase-2-configuration)
5. [Phase 3: Deployment Execution](#phase-3-deployment-execution)
6. [Phase 4: Post-Deployment Validation](#phase-4-post-deployment-validation)
7. [Common Configuration Scenarios](#common-configuration-scenarios)
8. [Troubleshooting During Deployment](#troubleshooting-during-deployment)

---

## Pre-Deployment Checklist

- [ ] Domain Functional Level: 2012 R2 or higher
- [ ] All DCs: Server 2012 R2 or newer
- [ ] RSAT installed on admin workstation (ActiveDirectory, GroupPolicy, DnsServer modules)
- [ ] Admin account: Enterprise Admin rights
- [ ] Break-glass password: Generated and stored securely
- [ ] Config file: Created and filled in (`script_v2.config.json`)
- [ ] Backup: Recent AD backup completed
- [ ] Stakeholder approval: Received from leadership
- [ ] Maintenance window: Scheduled (optional, but recommended for first deployment)

---

## Environment Requirements

### Domain Requirements

```
✓ DFL: 2012 R2 minimum
✓ All DCs: Windows Server 2012 R2 or newer
✓ Forest Functional Level: 2012 R2 minimum
✓ Schema Version: 69+ (Windows 2016+) for advanced features
✓ Replication health: All DCs replicating successfully
✓ No pending schema extensions
```

### PowerShell Requirements

```powershell
# Check required modules
Get-Module ActiveDirectory -ListAvailable
Get-Module GroupPolicy -ListAvailable
Get-Module DnsServer -ListAvailable  # If DNS delegation enabled

# On Windows Server:
Add-WindowsFeature RSAT-AD-PowerShell, GPMC

# On Windows 10/11:
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0
```

### Network Requirements

- TCP 389 (LDAP) to at least one Domain Controller
- TCP 636 (LDAPS) optional but recommended
- Kerberos support (port 88) working correctly
- DNS resolution for domain working

---

## Phase 1: Pre-Flight Validation

### Step 1.1: Validate Domain Readiness

```powershell
# Get domain information
$domain = Get-ADDomain
$domain | Select DNSRoot, DomainFunctionalLevel, Forest, RootDomain

# Check Domain Functional Level
if ($domain.DomainFunctionalLevel -lt "2012R2") {
    Write-Warning "Domain Functional Level too old, must be 2012 R2+"
    exit 1
}

# Check DC versions
Get-ADDomainController -Filter * | Select-Object HostName, OperatingSystem | Format-Table
```

### Step 1.2: Run Pre-Flight Script

```powershell
cd "1. Main"

# Copy config
Copy-Item script_v2.config.example.json script_v2.config.json

# Edit config with your domain values (see Phase 2)

# Run pre-flight validation (no changes made)
.\script_v2.ps1 -ConfigPath .\script_v2.config.json -ValidateOnly

# Review output for errors/warnings
```

**Expected output:**
```
✓ Domain context available
✓ DFL meets requirements
✓ Config structure valid
✓ Required modules available
✗ Any issues block deployment
```

---

## Phase 2: Configuration

### Step 2.1: Create Configuration File

```powershell
Copy-Item "1. Main\script_v2.config.example.json" "1. Main\script_v2.config.json"
```

### Step 2.2: Edit Configuration

Open `script_v2.config.json` and fill in your values:

```json
{
  "CorpOU": "Corp",                          // Your OU name
  "DomainDN": "DC=corp,DC=example,DC=com",  // Your domain DN
  
  "Zones": {
    "T0": { "0A": "Domain Management", "0B": "Hypervisor Management" },
    "T1": { "1A": "Workstation Management", "1B": "Server Management", "1C": "DNS Management", "1D": "Storage Management" },
    "T2": { "2A": "Workstations", "2B": "Servers" }
  },
  
  "PSO": {
    "T0": { "Name": "PSO-Tier0", "MinLength": 20, "MaxAge": 180 },
    "T1": { "Name": "PSO-Tier1", "MinLength": 14, "MaxAge": 180 },
    "T2": { "Name": "PSO-Tier2", "MinLength": 12, "MaxAge": 180 }
  },
  
  "BreakGlass": {
    "SamAccountName": "adm-bg-breakglass",
    "TempPasswordEnvVar": "MEAM_BREAKGLASS_TEMP_PASSWORD"  // Don't store password in file!
  },
  
  "CreateTestAccounts": false,  // Set to true only in lab
  
  "Services": {
    "EnableDnsDelegation": false,  // Set to true if deploying DNS tier delegation
    "DeployRoleSegregation": false
  }
}
```

### Step 2.3: Set Break-Glass Password

```powershell
# In PowerShell, set environment variable (don't save in config file!)
$env:MEAM_BREAKGLASS_TEMP_PASSWORD = "P@ssw0rd123!ComplexRequired"

# Or set via Command Prompt:
# set MEAM_BREAKGLASS_TEMP_PASSWORD=P@ssw0rd123!ComplexRequired
```

### Step 2.4: Validate Configuration

```powershell
.\script_v2.ps1 -ConfigPath .\script_v2.config.json -ValidateOnly
```

---

## Phase 3: Deployment Execution

### Step 3.1: Final Pre-Flight Check

```powershell
# Run validation one more time
.\script_v2.ps1 -ConfigPath .\script_v2.config.json -ValidateOnly
```

### Step 3.2: Run Deployment

```powershell
# Option 1: Deploy everything (recommended first time)
.\script_v2.ps1 -ConfigPath .\script_v2.config.json

# Option 2: Continue on phase error (safer for problematic domains)
.\script_v2.ps1 -ConfigPath .\script_v2.config.json -ContinueOnPhaseError

# Monitor output carefully for warnings/errors
```

### Step 3.3: Deployment Phases

The script runs automatically through these phases:

```
Phase 1: Domain Preparation
├─ Create Corp OU
├─ Clean up existing OUs (if configured)
└─ Set ACL breaks on Tiers OU

Phase 2: OU Creation
├─ Create all tier OUs
├─ Create all zone OUs
└─ Create all service OUs

Phase 3: Group Creation
├─ Create role groups (T0/T1/T2)
├─ Create zone-specific groups
├─ Create delegation groups (18 per service)
└─ Create PAW groups

Phase 4: Service Account Configuration
├─ Create gMSA accounts
└─ Apply to delegation groups

Phase 5: Password Policy (PSO)
├─ Create PSO-Tier0, PSO-Tier1, PSO-Tier2
├─ Apply to respective role groups
└─ Create PSO-SvcAccts

Phase 6: Authentication Policies & Silos
├─ Create PAW silos (PAW-Silo-T0, T1, T2)
├─ Create zone silos (Zone-Silo-0A through 2B)
└─ Set all to ENFORCE (not audit)

Phase 7: Group Policy Deployment
├─ Create GPOs for each tier
├─ Link to tier OUs
├─ Apply deny logon rules
├─ Configure Kerberos hardening
└─ Link to domain

Phase 8: Break-Glass & Test Accounts
├─ Create break-glass accounts (disabled by default)
├─ Create test accounts (if enabled)
└─ Apply security group memberships

Phase 9: ACL Delegation
├─ Delegate per-zone permissions
├─ Grant delegation groups rights
└─ Validate delegation

Phase 10: Compliance Report
├─ Validate all created objects
├─ Check GPO links
├─ Generate validation report
└─ Export to JSON/CSV
```

---

## Phase 4: Post-Deployment Validation

### Step 4.1: Run Validator Script

```powershell
cd "4. Validation"

.\Validate-MEAM-Deployment.ps1 -ConfigPath ..\1. Main\script_v2.config.json -OutputPath .\meam-validation.json
```

### Step 4.2: Review Validation Report

```powershell
# View summary
$report = Get-Content .\meam-validation.json | ConvertFrom-Json
$report | Select-Object -Property Summary, Domain

# Check for FAIL items
$report.Checks | Where-Object Status -eq "FAIL" | Format-Table Name, Detail
```

### Step 4.3: Verify Key Components

```powershell
# Check OUs were created
Get-ADOrganizationalUnit -Filter 'Name -like "*Tier*"' | Select-Object Name, DistinguishedName

# Check role groups exist
Get-ADGroup -Filter 'Name -like "T0-ROLE-*" -or Name -like "T1-ROLE-*"' | Select-Object Name

# Check Authentication Policies/Silos
Get-ADAuthenticationPolicy -Filter * | Select-Object Name, Enforced

# Check GPOs created
Get-GPO -All | Where-Object DisplayName -like "*MEAM*" | Select-Object DisplayName, Owner
```

### Step 4.4: Test Admin Account Creation

```powershell
# Create a test T0 admin account
New-ADUser -Name "adm-t0-test01" `
    -Path "OU=Accounts,OU=Zone 0A,OU=Tier 0,OU=Tiers,OU=Corp,DC=corp,DC=example,DC=com" `
    -SamAccountName "adm-t0-test01" `
    -UserPrincipalName "adm-t0-test01@corp.example.com" `
    -AccountPassword (ConvertTo-SecureString "P@ssw0rd123!Temp" -AsPlainText -Force) `
    -Enabled $true

# Add to role group
Add-ADGroupMember -Identity "T0-ROLE-AD-Admins" -Members "adm-t0-test01"

# Verify in Protected Users
$admin = Get-ADUser -Identity "adm-t0-test01" -Properties MemberOf
$admin.MemberOf | Where-Object { $_ -like "*Protected Users*" }
# Expected: Should be member transitively through T0-ROLE-AD-Admins
```

---

## Common Configuration Scenarios

### Scenario 1: Simple Single-Domain

```json
{
  "CorpOU": "Corp",
  "DomainDN": "DC=company,DC=com",
  "Zones": {
    "T0": { "0A": "Domain Management", "0B": "Hypervisor Management" },
    "T1": { "1A": "Workstation Management", "1B": "Server Management", "1C": "DNS Management", "1D": "Storage Management" },
    "T2": { "2A": "Workstations", "2B": "Servers" }
  }
}
```

### Scenario 2: Multi-OU Structure (Departments)

```json
{
  "CorpOU": "Global",                    // Top-level OU
  "DomainDN": "DC=enterprise,DC=corp",
  "Zones": {
    "T0": { ... },
    "T1": { ... },
    "T2": { ... }
  },
  "OU": {
    "Regions": ["NA", "EU", "APAC"],
    "CreateRegionalOUs": true           // Adds region sub-OUs
  }
}
```

### Scenario 3: DNS Delegation Enabled

```json
{
  "Services": {
    "EnableDnsDelegation": true,
    "DnsTier1Group": "T1-ROLE-DNS-Admins",
    "CreateDnsOUs": true
  }
}
```

---

## Troubleshooting During Deployment

### Issue: "Domain Functional Level too old"

```
Error: Domain Functional Level must be 2012 R2 or higher

Solution:
1. Identify lowest DC OS version: Get-ADDomainController -Filter * | Select OperatingSystem
2. Upgrade/decommission older DCs
3. Raise DFL: Raise-ADDomainFunctionalLevel -Identity "domain.com" -DomainFunctionalLevel "2012R2"
4. Wait for replication
5. Re-run deployment
```

### Issue: "Required modules not found"

```
Error: The required module 'ActiveDirectory' is not available

Solution:
# Windows Server:
Add-WindowsFeature RSAT-AD-PowerShell, GPMC

# Windows 10/11:
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
```

### Issue: "Access denied" during group policy creation

```
Error: Access denied when creating Group Policy Objects

Solution:
1. Verify running as Enterprise Admin
2. Check Group Policy Creator Owners group membership
3. Verify GPO creation permissions in domain root
```

### Issue: "Break-glass account creation fails"

```
Error: Cannot create break-glass account

Solution:
1. Verify OU path exists
2. Verify break-glass password meets PSO requirements (20 chars minimum for T0)
3. Verify environment variable is set: echo %MEAM_BREAKGLASS_TEMP_PASSWORD%
4. Create account manually and retry
```

---

**Document Version:** 1.0  
**Last Updated:** 2026-05-18  
**Next Review:** 2027-05-18
