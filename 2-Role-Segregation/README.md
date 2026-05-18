# 2-Role-Segregation

## Overview
Role segregation and DNS architecture implementation for enterprise-grade Active Directory security.

## Purpose
This folder contains scripts that implement **separation of duties** and **role-based access control** by segregating DNS authority functions across infrastructure tiers.

## Files

### New-DNS-Segregation.ps1
**DNS role separation script (200+ lines)**

**Purpose:** Implements DNS separation so AD authority stays on Domain Controllers while recursive queries are handled by a dedicated resolver/forwarder.

**Run as:** Domain Admin or Enterprise Admin

**Requirements:**
- DNS Server administrative access
- Domain Admin credentials (for DC configuration)
- ActiveDirectory module (RSAT)
- PowerShell 5.1+

**Usage:**
```powershell
# Validate DNS configuration
.\New-DNS-Segregation.ps1 -ConfigPath .\New-DNS-Segregation.config.example.json -LintConfigOnly

# Dry-run (WhatIf)
.\New-DNS-Segregation.ps1 -ConfigPath .\New-DNS-Segregation.config.example.json -WhatIf

# Full deployment
.\New-DNS-Segregation.ps1 -ConfigPath .\New-DNS-Segregation.config.example.json -Force

# Inline config
$config = Get-Content .\New-DNS-Segregation.config.example.json -Raw
.\New-DNS-Segregation.ps1 -ConfigJson $config
```

**Key Features:**
- ✅ Preserves AD authority on DCs
- ✅ Delegates recursive resolution to dedicated resolver
- ✅ Configures DHCP scope DNS settings
- ✅ Phase-based with run reporting
- ✅ JSON-driven configuration

**Output Artifacts:**
- `.\reports\DNS-Baseline.json` - Current DNS configuration snapshot
- `.\reports\DNS-RunReport.json` - Execution report
- `.\reports\DNS-RunReport-phases.csv` - Per-phase status

### New-DNS-Segregation.config.example.json
**Configuration template**

Customize the following:
```json
{
  "DomainControllers": ["DC1.corp.local", "DC2.corp.local"],
  "DomainFqdn": "corp.local",
  "ResolverIp": "10.0.1.100",
  "UpstreamResolvers": ["8.8.8.8", "8.8.4.4"],
  "DHCPServers": ["10.0.1.50"],
  "DHCPScope": "10.0.0.0",
  "RunReportOutputDirectory": ".\\reports"
}
```

## DNS Architecture

### Before Segregation
```
Client → DC (Authority + Recursion)
         ↓
         All DNS queries handled by DC
         + SPOF risk
         + Performance impact
```

### After Segregation
```
Internal Queries  → DC (Authority for corp.local)
                     ↓
                     Returns authoritative records
                     
External Queries  → Dedicated Resolver (10.0.1.100)
                     ↓
                     Forwards to upstream (8.8.8.8)
                     ↓
                     Returns recursive results
```

## Deployment Workflow

### Step 1: Prepare Configuration
```powershell
# Copy and customize
Copy-Item .\New-DNS-Segregation.config.example.json .\prod-dns.config.json
code .\prod-dns.config.json
```

### Step 2: Validate
```powershell
# Lint configuration
.\New-DNS-Segregation.ps1 -ConfigPath .\prod-dns.config.json -LintConfigOnly

# Verify DNS settings
nslookup corp.local DC1.corp.local
nslookup google.com 10.0.1.100
```

### Step 3: Deploy
```powershell
# Backup current DNS config (see tools/Backup-DNSConfiguration.ps1)
.\New-DNS-Segregation.ps1 -ConfigPath .\prod-dns.config.json -Force
```

### Step 4: Verify
```powershell
# Test internal resolution
nslookup corp.local DC1.corp.local

# Test external resolution (should go to resolver)
nslookup google.com DC1.corp.local

# Check DHCP scope settings
Get-DhcpServerv4Scope -ScopeId 10.0.0.0 | Select-Object -ExpandProperty DnsServers
```

## Troubleshooting

### DNS Resolution Fails After Deployment
```powershell
# Check DC DNS configuration
Get-DnsServerSetting -ComputerName DC1

# Check DHCP scope
Get-DhcpServerv4Scope -ScopeId 10.0.0.0

# Check resolver accessibility
Test-Connection 10.0.1.100

# Query with verbose output
nslookup -d corp.local DC1.corp.local
```

### Resolver Not Responding
```powershell
# Test resolver health
Test-NetConnection 10.0.1.100 -Port 53 -InformationLevel Detailed

# Check resolver DNS service
Get-Service -ComputerName 10.0.1.100 -Name DNS | Select-Object Status
```

## Related Documentation

- **MEAM Deployment:** [1-Deployment/README.md](../1-Deployment/README.md)
- **Monitoring:** [3-Monitoring/README.md](../3-Monitoring/README.md)
- **Operations Guide:** [OPERATIONS.md](../OPERATIONS.md)

---
**Version:** 1.0  
**Last Updated:** 2024  
**Maintainer:** Infrastructure Team
