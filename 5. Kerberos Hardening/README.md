# RFC 8062 Kerberos Token Hardening for MEAM

## 🔐 What This Does

Hardens Kerberos authentication in your MEAM tier model by:

1. **Enforcing AES-256 encryption** - Disables RC4/DES at KDC level
2. **Requiring FAST armoring** - All logons must be Kerberos-armored
3. **Blocking unconstrained delegation** - User-to-User (U2U) enforcement
4. **Restricting protocol transition** - S4U2Proxy whitelisting only

---

## ⚡ Quick Start

### 1. Validate Your Domain (REQUIRED - Run First)

```powershell
.\RFC8062-PreFlight-Check.ps1 `
    -ConfigPath ..\1. Main\script_v2.config.json `
    -FailOnCritical
```

**Review the report:**
- ✅ **OverallRiskLevel: LOW** → Safe to deploy
- ⚠️ **OverallRiskLevel: MEDIUM** → Review warnings, proceed with caution
- ❌ **OverallRiskLevel: CRITICAL** → STOP, fix issues first

### 2. Deploy RFC 8062 (After Pre-Flight Passes)

```powershell
.\RFC8062-Hardening-Deploy.ps1 `
    -ConfigPath ..\1. Main\script_v2.config.json `
    -PreFlightReportPath .\rfc8062-preflight.json `
    -Phase All
```

### 3. Post-Deployment Monitoring

```powershell
# Check for Kerberos auth failures
Get-WinEvent -FilterHashtable @{
    LogName = 'Security'
    Id = 4625
    StartTime = (Get-Date).AddDays(-1)
} | Where-Object Message -like '*Kerberos*'
```

---

## 📋 Files in This Folder

| File | Purpose |
|------|---------|
| **RFC8062-PreFlight-Check.ps1** | Validates domain readiness (MUST RUN FIRST) |
| **RFC8062-Hardening-Deploy.ps1** | Deploys hardening across 4 phases |
| **RFC8062-Implementation-Guide.md** | Comprehensive deployment guide with troubleshooting |
| **RFC8062.config.example.json** | Optional hardening configuration settings |
| **RFC8062-DcRegistryRollback.ps1** | Emergency rollback script (if Phase 1 breaks prod) |

---

## ⚠️ What Could Break

### Likely to Break ❌

- Windows XP, Vista, 2003, 2008 RTM machines
- Legacy printers using domain Kerberos auth
- Old SQL servers (2008 R2) without patches
- Legacy line-of-business apps with RC4-only dependencies

### Unlikely to Break ✅

- Windows 7 SP1+ machines
- Windows Server 2012 R2+ servers
- Modern applications (Exchange 2013+, SQL 2012+)
- Properly configured gMSA service accounts

---

## 🚨 If Something Breaks Post-Deployment

### Quick Rollback (Immediate)

```powershell
# Emergency: Revert DC registry if Phase 1 breaks auth
# This stops RFC 8062 enforcement immediately
$rollbackScript = Get-Content .\rfc8062-preflight.json | ConvertFrom-Json
# See RFC8062-DcRegistryRollback.ps1 for automation
```

### Phased Rollback (Safer)

1. Disable RFC8062 GPO (no restart needed)
   ```powershell
   Remove-GPLink -Name 'MEAM-RFC8062-Kerberos-Hardening' -Target 'OU=Tier 0,OU=Tiers,...' -Confirm:$false
   ```

2. Monitor Event ID 4625 for failures
3. If auth restored, proceed with DC registry rollback

---

## 🔍 Pre-Flight Check: What It Detects

### CRITICAL Issues (Blocks Deployment)
- ❌ DFL < 2012 R2
- ❌ Legacy Domain Controllers (2008 R2, 2008)
- ❌ Mixed-mode domain (older DCs still online)
- ❌ Legacy RODCs

### WARNINGS (Blocks Proceed without Approval)
- ⚠️ Legacy client OS (XP, Vista, 2003)
- ⚠️ Old SQL servers (2008 R2)
- ⚠️ Legacy Exchange
- ⚠️ Cross-forest trusts requiring coordination

### INFO (Noted But Not Blocking)
- ℹ️ Service account configurations
- ℹ️ FAST prerequisite status
- ℹ️ Kerberos event logging readiness

---

## 📊 Deployment Phases

| Phase | What | Duration | Risk | DC Restart? |
|-------|------|----------|------|-------------|
| **1: DC Registry** | KDC hardening | 5 min + restart | HIGH | ✅ YES |
| **2: GPO** | Client enforcement | 5 min | LOW | ❌ NO |
| **3: S4U2Proxy** | Whitelist SPNs | Manual (per-svc) | LOW | ❌ NO |
| **4: Monitoring** | Audit logging | 10 min | NONE | ❌ NO |

---

## ✅ Pre-Flight Check: What to Look For

### Good Sign ✅
```
OverallRiskLevel: LOW
CriticalCount: 0
WarningCount: 0
CanProceed: true
```

### Needs Review ⚠️
```
OverallRiskLevel: MEDIUM
CriticalCount: 0
WarningCount: 3
CanProceed: true
```

Review warnings in report → Apply mitigations → Proceed

### Stop Here ❌
```
OverallRiskLevel: CRITICAL
CriticalCount: 2
CanProceed: false
```

Fix CRITICAL issues → Re-run pre-flight → Try again

---

## 🎯 Success Criteria

After deployment, verify:

✅ All Domain Controllers restarted successfully  
✅ Protected Users accounts still authenticate  
✅ PAW (T0/T1) accounts still work  
✅ Break-glass accounts still functional  
✅ Event ID 4625 shows no spike (no RC4 auth attempts)  
✅ MEAM compliance report shows all checks passing  

---

## 📖 For Complete Documentation

👉 See **RFC8062-Implementation-Guide.md** for:
- Detailed phase explanations
- Troubleshooting each phase
- Remediation steps for common issues
- Monitoring & alerting setup
- Rollback procedures
- FAQ

---

## 🆘 Troubleshooting Quick Links

| Issue | Solution |
|-------|----------|
| Pre-flight fails with CRITICAL | See Implementation Guide → "CRITICAL Scenarios" |
| After Phase 1, old computer can't log in | See "If Something Breaks" → Phased Rollback |
| S4U2Proxy breaks app | Remove app's SPN from whitelist (Phase 3 → Manual Revert) |
| Still seeing RC4 auth attempts | Check if computer is in Protected Users (should not be) |

---

## ⏱️ Recommended Timeline

- **Week 1:** Run pre-flight, fix CRITICAL issues
- **Week 2:** Lab test (Phase 1 on test DCs)
- **Week 3:** Schedule maintenance window, Phase 1 DC restarts
- **Week 4:** Monitor for failures, Phase 2 GPO deployment
- **Week 5:** Phase 3 S4U2Proxy configuration (manual)
- **Week 6+:** Phase 4 monitoring, quarterly compliance reviews

---

**Need Help?** Review RFC8062-Implementation-Guide.md or contact your AD team.

**Last Updated:** 2026-05-18
