# examples

## Overview
Real-world configuration examples for different MEAM deployment scenarios.

## Purpose
This folder contains pre-configured examples that serve as starting points for specific deployment contexts, reducing configuration time and providing best-practice references.

## Available Examples

### Small-Domain-Config.json
**Example configuration for small domains (1-2 sites, single forest)**

**Characteristics:**
- 1 site with 2-3 Domain Controllers
- Single forest
- 100-500 user/computer accounts
- Minimal zone complexity

**Suitable for:**
- Branch office deployments
- Lab environments
- Small organizations

**Configuration Highlights:**
- 3 tiers (T0, T1, T2)
- 2-3 zones per tier
- Simplified PSO policies
- Standard group structure

**Usage:**
```powershell
# Copy and customize
Copy-Item examples/Small-Domain-Config.json -Destination .\small-domain-config.json

# Edit for your environment
code .\small-domain-config.json

# Deploy
.\1-Deployment\New-MEAM-Deployment.ps1 -ConfigPath .\small-domain-config.json
```

### Multi-Site-Config.json
**Example configuration for multi-site enterprises**

**Characteristics:**
- 3-5 sites across multiple locations
- 2-4 Domain Controllers per site
- Single or multiple forests
- 1,000-10,000 accounts

**Suitable for:**
- Enterprise deployments
- Multi-office organizations
- Hybrid cloud scenarios

**Configuration Highlights:**
- Site-aware OU structure
- Cross-site replication considerations
- Regional service accounts
- Multi-tier administrative model

**Usage:**
```powershell
# Copy and customize
Copy-Item examples/Multi-Site-Config.json -Destination .\prod-multi-site.json

# Validate before deployment
.\1-Deployment\New-MEAM-Deployment.ps1 -ConfigPath .\prod-multi-site.json -ValidateOnly

# Deploy with continuation on errors
.\1-Deployment\New-MEAM-Deployment.ps1 -ConfigPath .\prod-multi-site.json -ContinueOnPhaseError
```

### Multi-OU-Config.json
**Example configuration for complex OU structures**

**Characteristics:**
- Existing multi-level OU hierarchy
- Department-specific service accounts
- Custom delegation requirements
- 5,000+ accounts

**Suitable for:**
- Organizations with existing OU structures
- Complex IT governance models
- Departments with special permissions

**Configuration Highlights:**
- OU integration with existing hierarchy
- Custom service group definitions
- Delegation per department
- Custom PSO application

**Usage:**
```powershell
# Copy and adapt to your OU structure
Copy-Item examples/Multi-OU-Config.json -Destination .\complex-ou-config.json

# Verify OU mappings
.\4-Validation\Test-MEAM-Deployment.ps1 -ConfigPath .\complex-ou-config.json -ValidateOnly

# Deploy
.\1-Deployment\New-MEAM-Deployment.ps1 -ConfigPath .\complex-ou-config.json
```

### Kerberos-Hardening-Config.json
**Example configuration for RFC 8062 Kerberos hardening**

**Characteristics:**
- Modern forest (DFL 2012 R2+)
- All DCs Server 2016+
- No legacy systems
- gMSA-based services

**Suitable for:**
- Security-focused organizations
- New deployments
- Post-MEAM hardening

**Configuration Highlights:**
- AES-256 enforcement
- FAST armoring enabled
- Service whitelisting
- Monitoring enabled

**Usage:**
```powershell
# Copy and customize
Copy-Item examples/Kerberos-Hardening-Config.json `
  -Destination .\rfc8062-prod.json

# Pre-flight validation
.\5-Kerberos-Hardening\Test-RFC8062-PreFlight.ps1 `
  -ConfigPath .\rfc8062-prod.json

# Deploy phases incrementally
.\5-Kerberos-Hardening\New-RFC8062-Hardening.ps1 `
  -ConfigPath .\rfc8062-prod.json -Phase Registry

# Monitor phase 1 for 24 hours before proceeding
.\5-Kerberos-Hardening\New-RFC8062-Hardening.ps1 `
  -ConfigPath .\rfc8062-prod.json -Phase All
```

## Using Examples

### Step 1: Identify Your Scenario
Match your environment to one of the examples above. If none match exactly, use the closest fit.

### Step 2: Copy Template
```powershell
# Copy the matching example
Copy-Item examples/Small-Domain-Config.json -Destination my-deployment.json
```

### Step 3: Customize
Open the file and update:
- Domain FQDN
- Forest root DN
- Tier/zone definitions
- Service definitions
- PSO policies
- Group naming

Use global placeholders listed in [templates/README.md](../templates/README.md)

### Step 4: Validate
```powershell
# Lint configuration
.\1-Deployment\New-MEAM-Deployment.ps1 -ConfigPath my-deployment.json -LintConfigOnly

# Validate against current AD
.\1-Deployment\New-MEAM-Deployment.ps1 -ConfigPath my-deployment.json -ValidateOnly
```

### Step 5: Deploy
```powershell
# Execute deployment
.\1-Deployment\New-MEAM-Deployment.ps1 -ConfigPath my-deployment.json
```

## Example Structure

All examples follow the standard MEAM configuration schema with these main sections:

```json
{
  "RunReportJsonPath": "path",
  "ComplianceReportOutputDirectory": "path",
  "DnsTier1Group": "group name",
  "CorpOU": "OU name",
  "Zones": { /* zone definitions */ },
  "ZoneServices": { /* service definitions */ },
  "PSO": { /* password policies */ },
  "GroupNamingScheme": { /* naming conventions */ }
}
```

See full schema in [1-Deployment/New-MEAM-Deployment.config.example.json](../1-Deployment/New-MEAM-Deployment.config.example.json)

## Creating New Examples

To add a new example:

1. **Copy Existing:** Start with closest match
2. **Customize:** Adapt for new scenario
3. **Document:** Add description above
4. **Validate:** Run validation checks
5. **Submit:** Create PR with example

Format: `{scenario}-Config.json`

## Troubleshooting Examples

### Example Won't Deploy
```powershell
# 1. Validate example syntax
.\1-Deployment\New-MEAM-Deployment.ps1 `
  -ConfigPath examples/my-example.json `
  -LintConfigOnly

# 2. Check error messages
cat reports/MEAM-RunReport.json | ConvertFrom-Json | Select-Object Errors

# 3. Adjust for your environment
# - Update domain names
# - Verify OU paths exist
# - Check group naming doesn't conflict
```

## Related Documentation

- **Deployment:** [1-Deployment/README.md](../1-Deployment/README.md)
- **Templates:** [templates/README.md](../templates/README.md)
- **Configuration Schema:** [1-Deployment/New-MEAM-Deployment.config.example.json](../1-Deployment/New-MEAM-Deployment.config.example.json)
- **Architecture:** [ARCHITECTURE.md](../ARCHITECTURE.md)

---
**Last Updated:** 2024  
**Example Version:** 1.0
