# MEAM Operations Guide

**Day-to-day administrative procedures for managing MEAM infrastructure**

**Related SOPs:**
- [Bootstrap and Migration Guide](BOOTSTRAP-AND-MIGRATION.md)
- [Tier 0 SOP](TIER-0-SOP.md)
- [Tier 1 SOP](TIER-1-SOP.md)
- [Tier 2 SOP](TIER-2-SOP.md)
- [Validation Checklist](VALIDATION-CHECKLIST.md)

If you are introducing the tier model into an existing domain, start with the bootstrap guide first. If Tier 1 accounts are hybrid, follow the Tier 1 SOP for the Entra sync boundary and keep Tier 0 on-premises only.

---

## Table of Contents

1. [Admin Onboarding](#admin-onboarding)
2. [Server Onboarding](#server-onboarding)
3. [Break-Glass Procedures](#break-glass-procedures)
4. [Quarterly Reviews](#quarterly-reviews)
5. [Common Admin Tasks](#common-admin-tasks)
6. [Delegated Permissions](#delegated-permissions)
7. [Emergency Procedures](#emergency-procedures)

---

## Admin Onboarding

### Creating a Tier 0 Administrator

```powershell
# 1. Create admin user account
New-ADUser -Name "adm-t0-admin02" `
    -Path "OU=Accounts,OU=Zone 0A,OU=Tier 0,OU=Tiers,OU=Corp,DC=corp,DC=example,DC=com" `
    -SamAccountName "adm-t0-admin02" `
    -UserPrincipalName "adm-t0-admin02@corp.example.com" `
    -Enabled $false  # Disabled until first logon

# 2. Set temporary password (communicate out-of-band)
Set-ADAccountPassword -Identity "adm-t0-admin02" `
    -NewPassword (ConvertTo-SecureString "TempP@ss123!Change" -AsPlainText -Force) `
    -Reset

# 3. Add to T0 role group (auto-adds to Protected Users)
Add-ADGroupMember -Identity "T0-ROLE-AD-Admins" -Members "adm-t0-admin02"

# 4. Verify membership (transitive)
Get-ADUser -Identity "adm-t0-admin02" -Properties MemberOf | Select-Object MemberOf

# 5. Enable account
Enable-ADAccount -Identity "adm-t0-admin02"

# 6. Issue smartcard (PIV) to admin
# → Send to PKI team for certificate enrollment
```

### Creating a Tier 1 Administrator (Zone 1B - Servers)

```powershell
# 1. Create admin user
New-ADUser -Name "adm-t1-srv02" `
    -Path "OU=Accounts,OU=Zone 1B,OU=Tier 1,OU=Tiers,OU=Corp,DC=corp,DC=example,DC=com" `
    -SamAccountName "adm-t1-srv02" `
    -UserPrincipalName "adm-t1-srv02@corp.example.com" `
    -Enabled $false

# 2. Set temporary password
Set-ADAccountPassword -Identity "adm-t1-srv02" `
    -NewPassword (ConvertTo-SecureString "TempP@ss456!Change" -AsPlainText -Force) `
    -Reset

# 3. Add to Zone 1B Server Admin group
Add-ADGroupMember -Identity "T1-ROLE-Server-Admins" -Members "adm-t1-srv02"

# 4. Delegate specific zone permissions if needed
Add-ADGroupMember -Identity "Z1B-DLG-AppServers-Computers-Write" -Members "adm-t1-srv02"

# 5. Enable account
Enable-ADAccount -Identity "adm-t1-srv02"
```

### Assigning PAW Access

```powershell
# Grant admin access to PAW
Add-ADGroupMember -Identity "PAW-T0-Users" -Members "adm-t0-admin02"
Add-ADGroupMember -Identity "PAW-T1-Users" -Members "adm-t1-srv02"

# PAW computer auto-members (from silo):
# PAW-T0-Computers: Includes all PAW-T0 devices
# PAW-T1-Computers: Includes all PAW-T1 devices
```

---

## Server Onboarding

### Adding a New T0 Domain Controller

```powershell
# 1. Pre-promote: Place DC computer object in correct OU
New-ADComputer -Name "DC04" `
    -Path "OU=Computers,OU=Zone 0A,OU=Tier 0,OU=Tiers,OU=Corp,DC=corp,DC=example,DC=com" `
    -Enabled $true

# 2. Promote via Install-ADDSForest or Add-ADDSForest (standard promotion)

# 3. Verify placement
Get-ADComputer -Identity "DC04" | Select-Object DistinguishedName, ObjectGUID

# 4. Verify silo membership (auto-added by Auth Policy)
# DC04 should now be in Zone-Silo-0A (KDC check)

# 5. Verify KDC enforcement
klist  # On DC: shows silo membership
```

### Adding a New T1 Server (Zone 1B - Application Server)

```powershell
# 1. Pre-deploy: Create computer object
New-ADComputer -Name "APP-SVR-05" `
    -Path "OU=Computers,OU=Zone 1B,OU=Tier 1,OU=Tiers,OU=Corp,DC=corp,DC=example,DC=com" `
    -Enabled $true

# 2. Add computer to zone group
Add-ADGroupMember -Identity "Z1B-Zone-1B-Computers" -Members "APP-SVR-05"

# 3. Join domain (standard Windows Server domain join process)

# 4. Verify computer is in silo
# Computer should inherit Zone-Silo-1B via group membership

# 5. Apply LAPS deployment
# → Via SCCM, Intune, or LAPS GPO application
```

### Adding a New T2 Workstation

```powershell
# 1. Create computer object
New-ADComputer -Name "WORKST-084" `
    -Path "OU=Computers,OU=Zone 2A,OU=Tier 2,OU=Tiers,OU=Corp,DC=corp,DC=example,DC=com" `
    -Enabled $true

# 2. Add to zone group
Add-ADGroupMember -Identity "Z2A-Zone-2A-Computers" -Members "WORKST-084"

# 3. Join domain (standard Windows 10/11 domain join)

# 4. Apply LAPS & Intune policies
# → Via Group Policy or Intune enrollment
```

---

## Break-Glass Procedures

### Break-Glass Account Purpose

Break-glass accounts are **emergency access** accounts used when normal admin access is unavailable.

**When to use:**
- ❌ Password forgot (use AD password reset)
- ❌ Account locked (use account unlock)
- ✅ Authentication infrastructure compromised
- ✅ All admin accounts compromised or deleted
- ✅ Emergency disaster recovery

**When NOT to use:**
- Regular administrative tasks (use normal role accounts)
- Auditing/monitoring (creates logs from break-glass account)
- Testing (use dedicated test accounts)

### Activating Break-Glass (T0)

```powershell
# 1. Verify break-glass account exists and is disabled
$bg = Get-ADUser -Identity "adm-bg-breakglass" -Properties Enabled
$bg.Enabled  # Should be $false

# 2. Enable account
Enable-ADAccount -Identity "adm-bg-breakglass"

# 3. Set strong temporary password (coordinate with security team)
$tempPwd = ConvertTo-SecureString "EmergencyP@ss123!LongAndStrong" -AsPlainText -Force
Set-ADAccountPassword -Identity "adm-bg-breakglass" -NewPassword $tempPwd -Reset

# 4. Force password change on next logon
Set-ADUser -Identity "adm-bg-breakglass" -ChangePasswordAtLogon $true

# 5. Use ONLY from T0 PAW or isolated break-glass machine
# → Never from standard workstation

# 6. Log all actions (break-glass usage should trigger alerts)
# → Enable detailed audit logging

# 7. Disable account immediately after use
Disable-ADAccount -Identity "adm-bg-breakglass"

# 8. Rotate break-glass password and communicate new one to security team
```

### Break-Glass Account Rotation

```powershell
# Every 90 days: Change break-glass password

# 1. Generate new strong password
$newPwd = ConvertTo-SecureString "NewEmergencyP@ss456!LongAndStrong" -AsPlainText -Force

# 2. While account is disabled:
Set-ADAccountPassword -Identity "adm-bg-breakglass" -NewPassword $newPwd -Reset

# 3. Securely communicate new password to authorized personnel
# → Out-of-band (not email, not Teams)
# → Print and seal in envelope (physical security)

# 4. Document rotation in security log
# → Timestamp, who performed it, who received new password
```

---

## Quarterly Reviews

### Quarterly Audit Checklist

Run quarterly (every 3 months) to ensure compliance:

```powershell
# Check for stale admin accounts (not used in 90 days)
Get-ADUser -Filter {memberof -RecursiveMatch "T0-ROLE-AD-Admins" -or memberof -RecursiveMatch "T1-ROLE-*"} `
    -Properties LastLogonDate | Where-Object { $_.LastLogonDate -lt (Get-Date).AddDays(-90) } | Format-Table Name, LastLogonDate

# Check for accounts in wrong OUs
Get-ADUser -Filter * -SearchBase "OU=Zone 0A,OU=Tier 0,OU=Tiers,OU=Corp,DC=corp,DC=example,DC=com" | 
    Where-Object { $_.DistinguishedName -notmatch "Accounts|Service Accounts" }

# Verify PSO application
Get-ADFineGrainedPasswordPolicy -Filter * | ForEach-Object {
    $_.AppliesTo | ForEach-Object {
        Get-ADGroup -Identity $_ | Select-Object Name, @{L="PSO";E={$_.PSO}}
    }
}

# Check Protected Users membership
Get-ADGroupMember -Identity "Protected Users" | Measure-Object
# Expected: All T0/T1 role groups nested here

# Audit Auth Silo enforcement status
Get-ADAuthenticationPolicy -Filter * | Select-Object Name, Enforced

# Check GPO links to tier OUs
Get-ADOrganizationalUnit -Filter 'Name -like "*Tier*"' | ForEach-Object {
    Get-GPInheritance -Target $_.DistinguishedName
}
```

### Annual Audit (Comprehensive)

Run annually: Full compliance check

```powershell
# Run validation script
cd "..\4. Validation"
.\Validate-MEAM-Deployment.ps1 -ConfigPath ..\1. Main\script_v2.config.json -OutputPath .\annual-audit.json

# Generate HTML report
cd "..\3. Monitoring"
.\MEAM-Tier-Report.ps1 -ConfigPath .\MEAM-Tier-Report.config.json -OutputPath .\annual-report.html

# Share report with:
# - Security team
# - Infrastructure team
# - Compliance/audit team
```

---

## Common Admin Tasks

### Reset Admin Password (Without Break-Glass)

```powershell
# For accounts where admin lost their password

# 1. Verify identity (out-of-band confirmation)
# 2. Reset password
Set-ADAccountPassword -Identity "adm-t0-admin01" `
    -NewPassword (ConvertTo-SecureString "NewTempP@ss789!" -AsPlainText -Force) `
    -Reset

# 3. Force change on next logon
Set-ADUser -Identity "adm-t0-admin01" -ChangePasswordAtLogon $true

# 4. Communicate new password out-of-band to admin
```

### Unlock Locked-Out Admin Account

```powershell
# If account is locked (5 failed password attempts)

Unlock-ADAccount -Identity "adm-t1-dns01"

# Account unlock is automatic after 30 minutes
# Manual unlock is faster for emergency situations
```

### Add Delegated Permission to Admin

```powershell
# Grant Zone 1B Server admin permission to manage App Servers

$admin = Get-ADUser -Identity "adm-t1-srv03"
Add-ADGroupMember -Identity "Z1B-DLG-AppServers-Computers-Write" -Members $admin

# Now this admin can:
# ✓ Modify computer objects in Zone 1B
# ✓ Reset LAPS passwords for those computers
# ✓ Manage group memberships
```

### Remove Admin Access (Offboarding)

```powershell
# When admin leaves company

$admin = "adm-t0-admin01"

# 1. Remove from all role groups
Get-ADUser -Identity $admin -Properties MemberOf | ForEach-Object {
    $_.MemberOf | Where-Object { $_ -like "*T0-ROLE*" -or $_ -like "*Z*-DLG*" } | ForEach-Object {
        Remove-ADGroupMember -Identity $_ -Members $admin -Confirm:$false
    }
}

# 2. Disable account
Disable-ADAccount -Identity $admin

# 3. Move to disabled users OU (optional, for cleanup)
Move-ADObject -Identity (Get-ADUser $admin).DistinguishedName `
    -TargetPath "OU=Disabled Users,OU=Corp,DC=corp,DC=example,DC=com"

# 4. Revoke smartcard (if applicable)
# → Coordinate with PKI team
```

---

## Delegated Permissions

### Delegating Zone-Specific Tasks

Each zone has 18 delegation groups for granular permission assignment:

```
Z1B-DLG-AppServers-Computers-Create      [Create computer objects]
Z1B-DLG-AppServers-Computers-Read        [Query computer attributes]
Z1B-DLG-AppServers-Computers-Write       [Modify computer attributes]
Z1B-DLG-AppServers-Computers-Delete      [Delete computer objects]
Z1B-DLG-AppServers-Computers-LAPSRead    [Read LAPS password]
Z1B-DLG-AppServers-Computers-LAPSReset   [Reset LAPS password]
Z1B-DLG-AppServers-Users-Create          [Create user accounts]
Z1B-DLG-AppServers-Users-PasswordReset   [Reset user passwords]
Z1B-DLG-AppServers-Users-Enable          [Enable user accounts]
Z1B-DLG-AppServers-Users-Disable         [Disable user accounts]
```

### Example: Grant App Team Server Admin Rights

```powershell
# App team needs to manage APP-SRV-* computers in Zone 1B

$appTeamGroup = "Z1B-DLG-AppServers-Computers-Write"  # Write permission

Get-ADUser -Filter {Title -eq "App Server Admin"} | ForEach-Object {
    Add-ADGroupMember -Identity $appTeamGroup -Members $_
}
```

---

## Emergency Procedures

### Authentication Infrastructure Failure

```
Scenario: KDC service down on all DCs, Kerberos not working

1. Assess impact
   ✓ Check DC status: Get-ADDomainController -Filter * | Select HostName, IsEnabled
   ✓ Check replication: repadmin /replsum

2. Activate break-glass account (works with local auth)
   ✓ Enable adm-bg-breakglass account
   ✓ Log in using local SAM authentication (not Kerberos)

3. Restore KDC service
   ✓ Restart Kerberos service on DCs
   ✓ Or restore from backup if corrupted

4. Verify auth recovery
   ✓ Test Kerberos auth: kinit adm-t0-admin01@CORP.EXAMPLE.COM
   ✓ Disable break-glass account after recovery
```

### Complete Admin Account Compromise

```
Scenario: All T0 admin accounts compromised, attacker has credentials

1. Lockdown
   ✓ Disable all compromised accounts: Disable-ADAccount -Identity adm-t0-admin*
   ✓ Enable break-glass: Enable-ADAccount -Identity "adm-bg-breakglass"
   ✓ Force password change on break-glass next logon

2. Investigation
   ✓ Review logs: Event Viewer → Security → Check logon events
   ✓ Look for: 4624 (successful logon), 4625 (failed logon), 4672 (privilege use)
   ✓ Check for lateral movement: 5156 (network connection), 4688 (process creation)

3. Recovery
   ✓ Reset all T0 admin passwords
   ✓ Revoke and reissue smartcards
   ✓ Verify Protected Users membership (enforce FAST, AES-only)
   ✓ Consider full domain recovery if needed

4. Post-incident
   ✓ Enable break-glass monitoring alerts
   ✓ Review and strengthen access controls
   ✓ Conduct security training
   ✓ Document incident in compliance log
```

---

**Document Version:** 1.0  
**Last Updated:** 2026-05-18  
**Next Review:** 2027-05-18
