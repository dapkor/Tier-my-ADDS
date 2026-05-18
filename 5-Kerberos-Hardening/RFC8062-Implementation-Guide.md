# RFC 8062 Kerberos Token Hardening - Implementation Guide

> **Date:** 2026-05-18  
> **Version:** 1.0  
> **Scope:** MEAM Tier Model Enhancement  

## Overview

RFC 8062 hardening strengthens Kerberos authentication by:
- ✅ Enforcing AES-256 encryption (removes RC4/DES fallback)
- ✅ Requiring FAST (Flexible Authentication Secure Tunneling) armoring for all logons
- ✅ Preventing unconstrained Kerberos delegation via User-to-User (U2U) enforcement
- ✅ Restricting protocol transition (S4U2Proxy) to whitelisted services only

---

## Pre-Deployment Workflow

### Step 1: Run Pre-Flight Validation

```powershell
# Check if your environment is ready for RFC 8062
.\5. Kerberos Hardening\RFC8062-PreFlight-Check.ps1 `
    -ConfigPath .\1. Main\script_v2.config.json `
    -OutputPath .\reports\rfc8062-preflight.json `
    -FailOnCritical
```

**Output:** JSON report with risk assessment

### Step 2: Review Pre-Flight Results

```powershell
# View risk summary
$report = Get-Content .\reports\rfc8062-preflight.json | ConvertFrom-Json
$report | Select-Object OverallRiskLevel, CriticalCount, WarningCount, CanProceed
$report.Checks | Where-Object Level -eq 'CRITICAL' | Select-Object Name, Detail, Remediation
```

---

## What Pre-Flight Checks FOR

### ✅ PASS Scenarios (Safe to Deploy)

- ✓ Domain Functional Level is 2012 R2 or higher
- ✓ All Domain Controllers are Server 2012 R2 or newer
- ✓ No Windows XP, Vista, 2003, or 2008 RTM systems found
- ✓ No legacy RODCs
- ✓ No external forest trusts requiring coordination
- ✓ FAST armoring prerequisites met

**Action:** Proceed to deployment

### ⚠️ WARNING Scenarios (Review Before Proceeding)

| Warning | Risk | Mitigation |
|---------|------|-----------|
| Legacy printers/scanners found | Network printing may break | Isolate to legacy network segment |
| Old SQL servers (2008 R2) | Kerberos auth issues | Upgrade SQL or use service account workaround |
| Windows 2008 R2 servers | RC4 fallback may fail | Schedule VM upgrade/migration |
| Custom applications | Potential auth failures | Test in lab before production |
| Exchange servers | MAPI clients may fail | Verify Exchange 2013+ |

**Action:** Mitigate risks → Proceed with caution → Monitor closely

### ❌ CRITICAL Scenarios (MUST FIX Before Deployment)

| Critical Issue | Impact | Resolution Timeline |
|---|---|---|
| **DFL < 2012 R2** | Cannot enforce RFC 8062 at KDC level | Raise DFL (1-2 weeks planning) |
| **Legacy DC (2008 R2)** | KDC cannot validate modern auth policies | Decommission / upgrade DC (1-4 weeks) |
| **Mixed-mode domain** | Older DCs will reject modern ciphers | Eliminate all non-2012R2+ DCs |
| **Legacy RODC** | Cannot participate in modern Auth Policies | Replace or upgrade RODC |

**Action:** STOP. Do NOT proceed. Address CRITICAL issues first.

---

## Pre-Flight Report Reference

### Report Structure

```json
{
  "OverallRiskLevel": "LOW|MEDIUM|CRITICAL",
  "CriticalCount": 0,
  "WarningCount": 2,
  "CanProceed": true/false,
  "Checks": [
    {
      "Name": "Check Name",
      "Level": "PASS|WARN|CRITICAL|INFO",
      "Detail": "What was found",
      "Remediation": "How to fix it"
    }
  ],
  "Recommendations": [
    "Step 1...",
    "Step 2..."
  ]
}
```

### Example: Pre-Flight CRITICAL Result

```json
{
  "Name": "Domain Functional Level",
  "Level": "CRITICAL",
  "Detail": "DFL is 2008 R2 (required: 2012 R2 minimum for RFC 8062)",
  "Remediation": "Raise-ADDomainFunctionalLevel -Identity 'corp.example.com' -Confirm:$false"
}
```

**What to do:**
1. Open PowerShell as Enterprise Admin
2. Run the remediation command
3. Wait 30-60 minutes for AD to replicate
4. Re-run pre-flight check
5. Verify "OverallRiskLevel" changed to "LOW" or "MEDIUM"

---

## Deployment Workflow

### Step 1: Deploy RFC 8062 Hardening

```powershell
# Deploy all phases (will prompt for approval at breaking changes)
.\5. Kerberos Hardening\RFC8062-Hardening-Deploy.ps1 `
    -ConfigPath .\1. Main\script_v2.config.json `
    -PreFlightReportPath .\reports\rfc8062-preflight.json `
    -Phase All `
    -OutputPath .\reports\rfc8062-deployment.json
```

---

## Deployment Phases Explained

### Phase 1: DC Registry Hardening

**What it does:**
- Modifies KDC registry on ALL Domain Controllers
- Sets `SCForceOptions=1` (FAST armoring required)
- Sets `MinimumClientEncryptionType=0x18` (AES-256 + AES-128 only)
- Disables RC4/DES at KDC level
- Enables U2U enforcement

**Impact:**
- ⚠️ **REQUIRES DC RESTART** (no graceful fallback)
- KDC stops issuing TGTs to RC4-only clients
- All AD authentication will use AES

**If something breaks:**
- Old apps trying RC4 will get `KRB5KDC_ERR_ETYPE_NOSUPP` error
- System logon may fail for legacy computers
- Network printing (printers with domain auth) may fail

**Rollback:**
```powershell
# Check registry rollback info in deployment report
$report = Get-Content .\reports\rfc8062-deployment.json | ConvertFrom-Json
$report.RegistryRollbacks | Format-Table

# If needed, registry values can be manually reverted on each DC:
#   SCForceOptions = 0 (optional)
#   MinimumClientEncryptionType = 0xFFFFFFFF (allow all)
#   MinimumServerEncryptionType = 0xFFFFFFFF (allow all)
```

### Phase 2: Group Policy Deployment

**What it does:**
- Creates GPO: `MEAM-RFC8062-Kerberos-Hardening`
- Links to T0 and T1 OU hierarchy
- Enforces FAST on client-side

**Impact:**
- ✅ No system restart required
- Takes effect after `gpupdate /force` or 10-minute cycle
- Ensures clients send FAST-armored requests

### Phase 3: S4U2Proxy Whitelisting

**What it does:**
- Generates whitelist template: `S4U2Proxy-Whitelist-Template.json`
- Lists all service accounts requiring protocol transition
- Documents SPN registration steps

**Manual Action Required:**
```powershell
# For each service that needs S4U2Proxy:
$sa = Get-ADServiceAccount -Identity 'MyService-gMSA'
Set-ADServiceAccount -Identity $sa -Add @{
    'msDS-AllowedToDelegateTo' = @(
        'MSSQLSvc/sql-server.corp.example.com:1433',
        'HTTP/webapp.corp.example.com'
    )
}
```

### Phase 4: Monitoring & Audit

**What it does:**
- Enables Kerberos service ticket audit (Event ID 4625)
- Configures KDC to log failed auth attempts
- Creates monitoring baseline

**Recommended Monitoring:**
```powershell
# On each DC, check for Kerberos errors daily
Get-WinEvent -FilterHashtable @{
    LogName = 'Security'
    Id = 4625
    StartTime = (Get-Date).AddHours(-1)
} | Where-Object { $_.Message -like '*Kerberos*' } | Select-Object -First 20
```

---

## If Deployment Detects Issues

### Issue: "Legacy Client Operating Systems Found"

**Pre-flight Level:** WARNING (not blocking)

**What happens:**
- Deployment continues but flags risk
- Old computers cannot authenticate after Phase 1 DC restart

**Resolution:**

1. **Option A: Migrate/Retire**
   ```powershell
   # Find legacy computers
   Get-ADComputer -Filter "OperatingSystem -like '*XP*' -or OperatingSystem -like '*2003*'"
   
   # Plan hardware replacement or virtualization
   ```

2. **Option B: Network Segregation**
   ```powershell
   # Move legacy computers to separate OU with legacy Kerberos policy
   # Create separate non-RFC8062 Auth Silo for legacy systems
   ```

3. **Option C: Delayed Deployment**
   - Deploy RFC 8062 only to T0/T1 (admin tier)
   - Keep T2 (workstations) on standard Kerberos for 6-12 months
   - Gradually migrate workstations

### Issue: "Domain Functional Level < 2012 R2"

**Pre-flight Level:** CRITICAL (blocks deployment)

**What to do:**
1. **Prerequisites:**
   - All DCs must be Server 2012 R2 or newer
   - If you have Server 2008 R2 DCs, decommission them first

2. **Raise DFL:**
   ```powershell
   # Enterprise Admin required
   Raise-ADDomainFunctionalLevel -Identity 'corp.example.com' `
       -DomainFunctionalLevel '2012 R2' -Confirm:$false
   ```

3. **Wait for replication:**
   - AD replicates DFL change across all DCs (typically 15-30 min)
   - Check with: `(Get-ADDomain).DomainFunctionalLevel`

4. **Verify:** Re-run pre-flight check

### Issue: "Legacy RODC Found"

**Pre-flight Level:** CRITICAL

**What to do:**

1. **Option A: Upgrade RODC Host**
   ```powershell
   # Determine RODC OS version
   Get-ADDomainController -Filter { IsReadOnly -eq $true } | 
       Select-Object HostName, OperatingSystem
   
   # Plan OS upgrade (Server 2008 R2 → Server 2019+)
   ```

2. **Option B: Decommission RODC**
   ```powershell
   # Remove RODC metadata
   Get-ADDomainController -Identity 'RODC-Name' | Remove-ADObject -Recursive -Confirm:$false
   ```

### Issue: "Service Accounts with RC4 Dependencies"

**Pre-flight Level:** WARNING

**What to do:**

1. **Identify apps using RC4 SPNs:**
   ```powershell
   Get-ADServiceAccount -Filter * -Properties ServicePrincipalName |
       ForEach-Object {
           Get-ADServiceAccount -Identity $_.DistinguishedName -Properties ServicePrincipalName |
               Select-Object @{N='Service'; E={$_.SamAccountName}}, ServicePrincipalName
       }
   ```

2. **For each legacy app:**
   - **SQL Server 2008 R2:** Upgrade or configure service account for AES
   - **Tomcat < 8.0:** Upgrade Tomcat or use separate AD account
   - **Oracle 11g:** Apply patches for AES support

3. **Workaround - Service Account Configuration:**
   ```powershell
   # Create legacy service account (NOT in Protected Users)
   # This account can use RC4 fallback during transition period
   
   $newSa = New-ADServiceAccount -Name 'LegacyApp-SA' `
       -ServicePrincipalNames @('HTTP/legacyapp.corp.example.com') `
       -PassThru
   
   # DO NOT add to Protected Users
   # Manually approve RC4 only during transition (with expiration date)
   ```

### Issue: "Forest Trusts Detected - Coordination Required"

**Pre-flight Level:** WARNING

**What to do:**

1. **Identify trusted forests:**
   ```powershell
   Get-ADTrust -Filter * | Select-Object Name, Direction, TrustType
   ```

2. **Coordinate with trusted forest admins:**
   - RFC 8062 must be deployed to trusted forests for cross-forest auth to work
   - Schedule synchronized deployment or phased rollout

3. **Test cross-forest auth before production:**
   ```powershell
   # After Phase 1 on local forest, test with trusted forest account
   # Expected: AES TGT issued, no RC4 fallback
   ```

---

## Rollback Procedures

### If Phase 1 (DC Registry) Breaks Prod

**Emergency Rollback (same day):**

```powershell
# 1. On each DC, revert KDC registry
$dc = 'DC01'
Invoke-Command -ComputerName $dc -ScriptBlock {
    # Revert to pre-deployment defaults
    $kdcPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Kdc'
    Set-ItemProperty -Path $kdcPath -Name 'SCForceOptions' -Value 0
    Set-ItemProperty -Path $kdcPath -Name 'EnforceUserLogonRestrictions' -Value 0
    Set-ItemProperty -Path $kdcPath -Name 'MinimumClientEncryptionType' -Value 0xFFFFFFFF
    Set-ItemProperty -Path $kdcPath -Name 'MinimumServerEncryptionType' -Value 0xFFFFFFFF
}

# 2. Restart DC
Restart-Computer -ComputerName $dc -Force

# 3. Verify auth restored
# Wait 5 min for DC to fully restart
# Test: kixtart or kerberos test tool
```

### If Phase 2 (GPO) Breaks Auth

```powershell
# Delete/unlink RFC8062 GPO
Remove-GPLink -Name 'MEAM-RFC8062-Kerberos-Hardening' -Target 'OU=Tier 0,OU=Tiers,OU=Corp,DC=...' -Confirm:$false

# Run gpupdate /force on affected systems
# Auth should restore within 10 minutes
```

### If Phase 3 (S4U2Proxy) Breaks Service

```powershell
# If protocol transition breaks an app:
Get-ADServiceAccount -Identity 'AppName-gMSA' -Properties msDS-AllowedToDelegateTo
Set-ADServiceAccount -Identity 'AppName-gMSA' -Clear 'msDS-AllowedToDelegateTo'

# Service should restore after app restart
```

---

## Monitoring Post-Deployment

### Daily Checks

```powershell
# Check for Kerberos auth failures (Event 4625)
# On each DC:
Get-WinEvent -FilterHashtable @{
    LogName = 'Security'
    Id = 4625
    StartTime = (Get-Date).AddDays(-1)
} | Where-Object {
    $_.Message -like '*Kerberos*' -or
    $_.Message -like '*ETYPE_NOSUPP*'  # AES-only rejection
} | Select-Object TimeCreated, Id, Message | Format-Table

# Expected: Very few events
# If spike: legacy system trying RC4, requires remediation
```

### Weekly Verification

```powershell
# Verify Protected Users still working
Get-ADGroup -Identity 'Protected Users' -Properties Members |
    Select-Object @{N='Members'; E={$_.Members.Count}}

# Verify T0/T1 PAW auth working
Get-ADComputer -Filter "Name -like 'PAW*'" -Properties ipv4Address | 
    Measure-Object | Select-Object Count

# Check for authentication policy violations
Get-ADAuthenticationPolicy -Filter * | 
    Select-Object Name, Enforced
```

### Monthly Compliance Report

```powershell
# Run existing MEAM compliance report (includes Kerberos status)
.\3. Monitoring\MEAM-Tier-Report.ps1 `
    -ConfigPath .\3. Monitoring\MEAM-Tier-Report.config.json `
    -OutputPath .\reports\MEAM-Report-$(Get-Date -Format 'yyyyMM').html
```

---

## FAQ

**Q: Can I roll back RFC 8062 after deployment?**  
A: Yes, but requires DC restarts and GPO reset. Not recommended for production. Test thoroughly in lab first.

**Q: What if an old printer breaks after DC restart?**  
A: Most printers don't use Kerberos auth; if one does:
- Configure printer to use Basic auth over HTTPS
- Or add printer to separate network segment with legacy domain controller
- Or use print server (T1) with service account fallback

**Q: Do I need to restart all DCs at once?**  
A: No. Rolling restart is safer:
1. Restart DC1 (monitor for 24h)
2. Restart DC2 (monitor for 24h)
3. Continue for remaining DCs
Gradual deployment reduces risk of widespread outage.

**Q: How long does Phase 1 take?**  
A: ~5 min registry changes + DC restart time (typically 10-30 min per DC)

**Q: Can I skip Phase 3 (S4U2Proxy)?**  
A: Yes. It's optional and only needed if you have legacy protocol transition services. Most modern apps use constrained delegation.

---

## Support & Troubleshooting

### Enable Debug Logging

```powershell
# On DCs, enable verbose Kerberos logging
auditpol /set /category:"Account Logon" /success:enable /failure:enable
auditpol /set /category:"Logon/Logoff" /success:enable /failure:enable

# Check KDC logs
Get-WinEvent -LogName "System" -FilterXPath "*[System[(EventID=37)]]" | Select-Object -First 10
```

### Test Kerberos Authentication

```powershell
# From a T0 PAW, test Kerberos auth
kinit adm-t0-admin@CORP.EXAMPLE.COM
# Expected: TGT issued with AES-256 encryption

# Check ticket encryption
klist tgt
# Expected: Ticket Encryption Type: AES-256-CTS-HMAC-SHA1-96
```

---

## Compliance & Security

- ✅ RFC 8062 compliant
- ✅ NIST SP 800-63B compatible
- ✅ PCI-DSS 3.4 (strong cryptography)
- ✅ CIS Microsoft Windows Server Hardening
- ✅ CISA Top 25 Mitigations

---

**Document Version:** 1.0  
**Last Updated:** 2026-05-18  
**Next Review:** 2027-05-18
