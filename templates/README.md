# templates

## Overview
Reusable templates, checklists, and procedures for MEAM deployment, operations, and incident response.

## Purpose
This folder contains standardized templates that accelerate deployment, reduce errors, and ensure consistency across implementations.

## Available Templates

### MEAM-Deployment-Checklist.md
**Pre-deployment planning checklist**

Use this checklist before starting MEAM deployment to ensure all prerequisites are met:

**Contents:**
- [ ] Infrastructure readiness (Active Directory DFL, RSAT)
- [ ] Team roles assignment
- [ ] Communication plan
- [ ] Backup and recovery procedures
- [ ] Lab environment setup
- [ ] Configuration validation
- [ ] Stakeholder sign-off

**When to Use:**
- Before any production MEAM deployment
- When onboarding new infrastructure team members
- During quarterly compliance audits
- Before major AD changes

**Time Required:** 2-3 hours

### Break-Glass-Procedure.md
**Break-glass account creation and emergency access procedure**

Step-by-step procedure for:
- Creating break-glass accounts (one per tier)
- Securing credentials (HSM, vault, sealed envelope)
- Access procedures (4-eyes principle)
- Credential rotation schedules
- Disaster recovery scenarios

**When to Use:**
- During initial MEAM deployment
- When provisioning new break-glass accounts
- During quarterly break-glass account validation
- In security incident response

**Time Required:** 1-2 hours per tier

### Quarterly-Audit-Checklist.md
**Monthly/Quarterly MEAM compliance audit checklist**

Systematic verification of:
- Account placement correctness
- Group membership accuracy
- PSO application validation
- Auth Silo enforcement
- GPO link status
- Protected Users group accuracy
- Break-glass account validation
- Compliance report review

**When to Use:**
- Monthly compliance audits
- Quarterly security reviews
- Before audit season
- Post-incident validation

**Time Required:** 2-4 hours

### Service-Account-Migration.md
**Procedure for migrating service accounts to gMSA**

Step-by-step guide for:
- Prerequisites (service discovery, KDS root key)
- gMSA creation
- Service principal name (SPN) registration
- Application reconfiguration
- Testing and validation
- Rollback procedures

**When to Use:**
- During security hardening projects
- When deprecating legacy service accounts
- Before Kerberos hardening deployment

**Time Required:** 30 min - 2 hours per service

### Emergency-Procedures.md
**Emergency response playbooks for MEAM-related incidents**

Procedures for:
- Authentication outages (Kerberos failures)
- Break-glass account compromise
- Unauthorized tier elevation
- GPO corruption/deletion
- Auth Silo enforcement failure
- Password policy lock-out

**When to Use:**
- During security incidents
- During disaster recovery scenarios
- When training on-call teams

**Time Required:** Variable (5-60 min per incident type)

## Using Templates

### Step 1: Copy Template
```powershell
# In PowerShell
Copy-Item templates/MEAM-Deployment-Checklist.md `
  -Destination MEAM-Deployment-Checklist-2024-01-15.md
```

### Step 2: Customize
Edit the copied file to match your environment:
- Replace placeholder values (e.g., `corp.local` → `yourdomain.local`)
- Update team names and contact info
- Add environment-specific procedures
- Adjust timelines to your environment

### Step 3: Execute & Track
Use the checklist while executing procedures:
- Mark items as complete ([ ] → [x])
- Document timestamps and executed-by
- Note any deviations
- Archive completed checklist (for audit trail)

### Step 4: Archive
Save completed checklist:
```powershell
# Archive to audit folder
Move-Item MEAM-Deployment-Checklist-2024-01-15.md `
  -Destination archives/completed-checklists/
```

## Template Customization Guide

### Global Replace Values
When customizing templates, search for these placeholders:

| Placeholder | Example | Your Value |
|------------|---------|-----------|
| `{DOMAIN_FQDN}` | `corp.local` | ____________ |
| `{DOMAIN_NB}` | `CORP` | ____________ |
| `{TIER0_OU}` | `CN=Tier0,CN=Accounts` | ____________ |
| `{PAW_PREFIX}` | `PAW-T0` | ____________ |
| `{TEAM_LEAD}` | `Security Admin` | ____________ |
| `{TICKET_SYSTEM}` | `ServiceNow/Jira` | ____________ |
| `{CHANGE_CONTROL}` | `CAB_ID_12345` | ____________ |

### Creating New Templates

If you need templates not provided:

1. **Identify Gap:** What procedure needs standardization?
2. **Document Current State:** How is it done today?
3. **Create Template:** Follow existing format
4. **Get Peer Review:** Validate with team
5. **Add to Folder:** Submit PR for inclusion
6. **Document Usage:** Add to this README

## Integration with CI/CD

### GitHub Actions - Compliance Audit
```yaml
name: Monthly MEAM Audit
on:
  schedule:
    - cron: '0 2 1 * *'  # First day of month, 2 AM

jobs:
  audit:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v3
      - name: Run Quarterly Audit
        run: |
          # Use template as reference
          .\templates\Quarterly-Audit-Checklist.md
          # Execute compliance validation
          .\3-Monitoring\New-MEAM-Compliance-Report.ps1
```

### Azure DevOps - Pre-Deployment
```yaml
stages:
- stage: PreDeployment
  displayName: 'Pre-Deployment Checks'
  jobs:
  - job: ChecklistValidation
    steps:
    - script: |
        # Reference deployment checklist
        Write-Host "Reviewing $(System.DefaultWorkingDirectory)\templates\MEAM-Deployment-Checklist.md"
        # Run pre-flight checks
        .\4-Validation\Test-MEAM-Deployment.ps1
```

## Knowledge Base Articles

To create KB articles from templates:

1. **Copy template content** to KB system
2. **Add context:** Your environment specifics
3. **Document outcomes:** What happened when you followed it
4. **Link related articles:** Cross-reference other KB items
5. **Mark reviewed:** Verify and date

Example KB Structure:
```
Title: How to Deploy MEAM - [Your Environment]
Template Reference: MEAM-Deployment-Checklist.md
Prerequisites: [From checklist]
Steps: [From template, customized]
Troubleshooting: [Links to TROUBLESHOOTING.md]
Owner: [Team name]
Last Reviewed: [Date]
```

## Related Documentation

- **MEAM Deployment:** [1-Deployment/README.md](../1-Deployment/README.md)
- **Troubleshooting:** [TROUBLESHOOTING.md](../TROUBLESHOOTING.md)
- **Operations:** [OPERATIONS.md](../OPERATIONS.md)

---
**Last Updated:** 2024  
**Template Version:** 1.0
