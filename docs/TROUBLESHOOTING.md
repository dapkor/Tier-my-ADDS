# MEAM Troubleshooting Guide

**Common issues and solutions for MEAM deployments**

---

## Table of Contents

1. [Pre-Deployment Issues](#pre-deployment-issues)
2. [Deployment Issues](#deployment-issues)
3. [Kerberos Authentication Failures](#kerberos-authentication-failures)
4. [PAW Access Problems](#paw-access-problems)
5. [Service Account Issues](#service-account-issues)
6. [Authentication Policy Violations](#authentication-policy-violations)
7. [Post-Deployment Validation Failures](#post-deployment-validation-failures)
8. [Getting Help](#getting-help)

---

## Pre-Deployment Issues

### Issue: "Domain Functional Level too old"

**Error:**
```
Error: Domain Functional Level must be 2012 R2 or higher. Current: 2008 R2
```

**Root cause:** Domain is too old to support Authentication Policy Silos

**Solution:**
1. Identify all Domain Controllers:
   ```powershell
   Get-ADDomainController -Filter * | Select-Object HostName, OperatingSystem
   ```

2. Upgrade DCs to Windows Server 2012 R2 or newer:
   - Decommission old DCs
   - Or upgrade in-place (test in lab first!)

3. After all DCs upgraded, raise Domain Functional Level:
   ```powershell
   Raise-ADDomainFunctionalLevel -Identity "corp.example.com" -DomainFunctionalLevel "2012R2"
   ```

4. Wait for replication across all DCs (10-15 minutes)

5. Verify:
   ```powershell
   (Get-ADDomain).DomainFunctionalLevel  # Should be Windows2012R2Domain
   ```

---

### Issue: "Required modules not found"

**Error:**
```
Import-Module : The specified module 'ActiveDirectory' has not been loaded
```

**Root cause:** RSAT tools not installed

**Solution:**

**Windows Server:**
```powershell
Add-WindowsFeature RSAT-AD-PowerShell, GPMC, RSAT-DNS-Server
```

**Windows 10/11:**
```powershell
Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0
Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0
```

**Linux (optional - for remote management):**
```bash
# Use krb5-workstation and ldap-utils for basic functionality
sudo apt install krb5-workstation ldap-utils
```

---

### Issue: "Config validation failed"

**Error:**
```
Validation failed: Zone name "1E" not recognized in DFL schema
```

**Root cause:** Invalid configuration values

**Solution:**
1. Review config file for typos:
   ```json
   "Zones": {
     "T1": { "1A": "...", "1B": "...", "1C": "...", "1D": "..." }
     // NOT "1E" - only 1A-1D are valid for T1
   }
   ```

2. Check [docs/ARCHITECTURE.md](./docs/ARCHITECTURE.md) for valid zone names

3. Re-validate:
   ```powershell
   .\script_v2.ps1 -ValidateOnly
   ```

---

## Deployment Issues

### Issue: "Access denied" during OU creation

**Error:**
```
New-ADOrganizationalUnit : Access Denied
```

**Root cause:** Running as non-Enterprise Admin

**Solution:**
1. Verify account is Enterprise Admin:
   ```powershell
   (whoami /groups) | Select-String "Enterprise Admins"
   ```

2. If not, add current user to Enterprise Admins:
   ```powershell
   # From Domain Admin console:
   Add-ADGroupMember -Identity "Enterprise Admins" -Members (whoami /upn)
   ```

3. Log out and log back in

4. Retry deployment

---

### Issue: "GPO creation fails"

**Error:**
```
New-GPO : Access denied. You do not have permissions to create a new Group Policy Object
```

**Root cause:** Not a member of Group Policy Creator Owners

**Solution:**
1. Add to Group Policy Creator Owners:
   ```powershell
   Add-ADGroupMember -Identity "Group Policy Creator Owners" -Members (whoami /upn)
   ```

2. Log out and log back in

3. Retry deployment

---

### Issue: "Break-glass account creation fails"

**Error:**
```
New-ADUser : The password does not meet the length, complexity, or history requirement
```

**Root cause:** Password doesn't meet PSO requirements

**Solution:**
1. Check current PSO requirements:
   ```powershell
   Get-ADFineGrainedPasswordPolicy -Filter * | Select-Object Name, MinPasswordLength
   ```

2. Create password meeting requirements (min 20 chars for T0):
   ```powershell
   $pwd = ConvertTo-SecureString "P@ssw0rd123!SuperComplexLongPassword" -AsPlainText -Force
   ```

3. Set environment variable:
   ```powershell
   $env:MEAM_BREAKGLASS_TEMP_PASSWORD = "P@ssw0rd123!SuperComplexLongPassword"
   ```

4. Retry deployment

---

## Kerberos Authentication Failures

### Issue: User cannot log in (Auth Silo violation)

**Symptom:**
```
Logon failed: The user has not been granted the requested logon type at this computer
```

**Root cause:** User not authorized by Authentication Policy for this computer

**Diagnosis:**
```powershell
# Check user's silo
$user = Get-ADUser -Identity "adm-t1-srv01"
$user.MemberOf | Get-ADGroup -Properties AuthenticationPolicySilo

# Check computer's silo
$computer = Get-ADComputer -Identity "APP-SRV-05"
$computer.AuthenticationPolicySilo

# If different silos → access denied
```

**Solution:**
1. Verify user should have access to this computer
2. Add user/computer to same silo:
   ```powershell
   # If user should access Zone 1B:
   Add-ADComputerGroupMembership -Identity "APP-SRV-05" -GroupIdentity "Z1B-Zone-1B-Computers"
   Add-ADUserGroupMembership -Identity "adm-t1-srv01" -GroupIdentity "Z1B-Zone-1B-Users"
   ```

3. Wait for AD replication (5-15 minutes)
4. User tries logon again

---

### Issue: "NTLM authentication blocked" error

**Symptom:**
```
The DC is not configured to allow NTLM authentication
```

**Root cause:** Protected Users group blocking NTLM

**Diagnosis:**
```powershell
# Check if account is in Protected Users
$user = Get-ADUser -Identity "adm-t0-admin01" -Properties MemberOf
$user.MemberOf | Where-Object { $_ -like "*Protected Users*" }
```

**Solution:**

**If NTLM is NOT needed:**
1. Ensure client supports Kerberos:
   ```powershell
   kinit user@CORP.EXAMPLE.COM  # Should succeed
   klist  # View TGT
   ```

2. Use Kerberos auth method (e.g., `Invoke-Command -ComputerName dc01 -Authentication Kerberos`)

**If NTLM IS needed (legacy app):**
1. Remove account from Protected Users:
   ```powershell
   Remove-ADGroupMember -Identity "Protected Users" -Members "app-svc-account"
   ```
   ⚠️ Only for legacy service accounts that MUST use NTLM

2. Or create separate legacy account not in Protected Users

---

### Issue: "AES encryption not available"

**Symptom:**
```
Error: Server does not support encryption type AES-256-CTS-HMAC-SHA1-96
```

**Root cause:** Client or server doesn't support AES encryption

**Diagnosis:**
```powershell
# On server:
reg query "HKLM\SYSTEM\CurrentControlSet\Services\Kdc" /v MaxTokenSize
```

**Solution:**
1. Update client/server to support AES:
   - Windows 7 SP1+ (built-in)
   - Windows Server 2008 R2 SP1+ (built-in)
   - Linux: `apt install krb5-user`

2. Enable AES in registry (if not auto-enabled):
   ```powershell
   reg add "HKLM\SYSTEM\CurrentControlSet\Services\Kdc" /v SupportedEncryptionTypes /t REG_DWORD /d 28 /f
   # 28 = AES-256 + AES-128 + RC4 + 3DES (for migration)
   ```

3. Restart Kerberos service:
   ```powershell
   Restart-Service -Name KDC
   ```

---

## PAW Access Problems

### Issue: Admin cannot log in to PAW

**Symptom:**
```
Access is denied. You do not have permission to access this computer
```

**Root cause:** Admin not member of PAW-T0-Users (or T1/T2)

**Diagnosis:**
```powershell
# Check PAW computer's silo
$paw = Get-ADComputer -Identity "PAW-T0"
$paw.AuthenticationPolicySilo  # Should be PAW-Silo-T0

# Check admin's group membership
$admin = Get-ADUser -Identity "adm-t0-admin01" -Properties MemberOf
$admin.MemberOf | Where-Object { $_ -like "*PAW*" }
```

**Solution:**
1. Add admin to PAW group:
   ```powershell
   Add-ADGroupMember -Identity "PAW-T0-Users" -Members "adm-t0-admin01"
   ```

2. Wait for AD replication (5-15 minutes)

3. Admin tries logon to PAW again

---

### Issue: PAW computer unable to access domain

**Symptom:**
```
The system cannot log you on now because the computer you are logging in to is not handling logons for your account
```

**Root cause:** PAW computer not in correct silo

**Diagnosis:**
```powershell
# On PAW:
nltest /dsgetdc:corp.example.com

# If DC is unreachable, might be network isolation issue
```

**Solution:**
1. Verify network connectivity:
   ```powershell
   # On PAW:
   ping dc01.corp.example.com
   Test-NetConnection -ComputerName dc01.corp.example.com -Port 88
   ```

2. Verify PAW is domain-joined:
   ```powershell
   Get-ADComputer -Identity "PAW-T0" | Select-Object Name, Enabled
   ```

3. If not domain-joined:
   ```powershell
   # From PAW machine:
   Add-Computer -DomainName corp.example.com -Credential (Get-Credential)
   # Restart-Computer
   ```

---

## Service Account Issues

### Issue: Service fails to start (auth failure)

**Symptom:**
```
The service failed to start. Error: Account name or password is incorrect
```

**Root cause:** Service account in Protected Users group, but needs password auth

**Diagnosis:**
```powershell
$svc = Get-ADUser -Identity "svc-app01" -Properties MemberOf
$svc.MemberOf  # Check if includes Protected Users
```

**Solution:**

**Option 1: Remove from Protected Users (if old/legacy service)**
```powershell
Remove-ADGroupMember -Identity "Protected Users" -Members "svc-app01"
```

**Option 2: Use Kerberos instead of password**
```powershell
# Configure service to use Kerberos (SPN required)
setspn -a svc-app01/appserver.corp.example.com svc-app01
```

**Option 3: Use gMSA (Group Managed Service Account)**
```powershell
# More complex, but eliminates password management
# See Microsoft docs on gMSA setup
```

---

## Authentication Policy Violations

### Issue: Zone admin can access wrong zone

**Symptom:** Zone 1B admin successfully RDP to Zone 1C DNS server (should fail)

**Root cause:** Auth Silo not properly enforced, or system clock skew

**Diagnosis:**
```powershell
# Check auth silo settings
Get-ADAuthenticationPolicy -Identity "Zone-Silo-1C" | Select-Object Name, Enforced, UserAllowedToAuthenticateTo

# Check computer's silo
Get-ADComputer -Identity "DNS-SRV-01" | Select-Object AuthenticationPolicySilo
```

**Solution:**
1. Verify silo is set to ENFORCE (not audit):
   ```powershell
   Set-ADAuthenticationPolicy -Identity "Zone-Silo-1C" -Enforce $true
   ```

2. Check system clocks (time skew causes auth failures):
   ```powershell
   # On DC:
   w32tm /query /status
   
   # On client:
   w32tm /query /status
   
   # If skew > 5 minutes, resync:
   w32tm /resync /force
   ```

3. Force KDC cache refresh:
   ```powershell
   # On DC:
   Restart-Service -Name KDC
   ```

---

## Post-Deployment Validation Failures

### Issue: "Validation: FAIL - Protected Users group incomplete"

**Error:**
```
Check: Protected Users Membership
Status: FAIL
Details: Not all T0 role groups nested in Protected Users
```

**Solution:**
1. Identify missing group:
   ```powershell
   $allT0Roles = Get-ADGroup -Filter "Name -like 'T0-ROLE-*'"
   $protected = Get-ADGroupMember -Identity "Protected Users" -Recursive
   
   $allT0Roles | Where-Object { $protected.Name -notcontains $_.Name }
   ```

2. Add missing group:
   ```powershell
   Add-ADGroupMember -Identity "Protected Users" -Members "T0-ROLE-Hyper-Admins"
   ```

3. Re-run validator

---

### Issue: "Validation: FAIL - Auth Silo not ENFORCED"

**Error:**
```
Check: Authentication Silo Enforcement
Status: FAIL
Details: Zone-Silo-1B is in Audit mode, should be Enforced
```

**Solution:**
```powershell
# Change from audit to enforce
Set-ADAuthenticationPolicy -Identity "Zone-Silo-1B" -Enforce $true
```

---

### Issue: "Validation: FAIL - GPO link missing"

**Error:**
```
Check: Group Policy Links
Status: FAIL
Details: GPO-T0-DenyLowerTier-Logon not linked to OU=Tier 0,...
```

**Solution:**
```powershell
# Link missing GPO
New-GPLink -Name "GPO-T0-DenyLowerTier-Logon" -Target "OU=Tier 0,OU=Tiers,OU=Corp,DC=corp,DC=example,DC=com" -LinkEnabled Yes -Enforced Yes
```

---

## Getting Help

### Collect Diagnostic Information

Before asking for help, gather:

```powershell
# Export current MEAM state
$output = @{}

# 1. Domain info
$output.Domain = Get-ADDomain | Select DNSRoot, DomainFunctionalLevel

# 2. Tier structure
$output.TierOUs = Get-ADOrganizationalUnit -Filter 'DistinguishedName -like "*Tier*"'

# 3. Role groups
$output.RoleGroups = Get-ADGroup -Filter 'Name -like "T0-ROLE-*" -or Name -like "T1-ROLE-*"' | Measure-Object

# 4. Auth Silos
$output.AuthPolicies = Get-ADAuthenticationPolicy -Filter * | Select Name, Enforced

# 5. Error logs
$output.RecentErrors = Get-EventLog -LogName System -Newest 20 | Where-Object { $_.EntryType -eq 'Error' }

# Export
$output | ConvertTo-Json | Out-File diagnostic-report.json
```

Share this file when asking for help.

### Common Support Resources

- **Microsoft Docs:** [aka.ms/EAM](https://aka.ms/EAM)
- **Kerberos RFC 8062:** [tools.ietf.org/html/rfc8062](https://tools.ietf.org/html/rfc8062)
- **GitHub Issues:** [This project](https://github.com/dapkor/Tier-my-ADDS/issues)
- **Domain Admins:** Ask your infrastructure team

---

**Document Version:** 1.0  
**Last Updated:** 2026-05-18  
**Next Review:** 2027-05-18
