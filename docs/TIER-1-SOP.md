# Tier 1 SOP

## Purpose
This SOP defines how Tier 1 administrators operate after the tier model is introduced. Tier 1 covers servers and management systems that are not part of the identity control plane.

## Tier 1 Scope
Tier 1 includes:
- Member servers
- Server management tools
- Application servers
- File services
- Backup and infrastructure support systems that are not Tier 0
- Server-side admin workstations if they are dedicated to Tier 1

Tier 1 does not include:
- Domain Controllers
- PKI or identity infrastructure
- Tier 0 PAWs
- Workstation help desk tasks
- Tier 2 user support tasks

## Tier 1 Operating Rules
- Use Tier 1 admin accounts only.
- Use Tier 1 admin workstations or approved jump hosts only.
- Do not use Tier 1 accounts for Tier 0 systems.
- Do not use Tier 1 accounts for Tier 2 support.
- Keep server administration separated from identity administration.
- Use change control for server changes.
- Validate the effect of each change before moving on.

## Tier 1 Account Model
Tier 1 is often the first tier that needs hybrid identity.

Recommended model:
- Create Tier 1 admin accounts in a dedicated on-premises AD OU.
- Sync only the approved Tier 1 admin accounts to Microsoft Entra.
- Keep Tier 0 accounts out of sync.
- Keep break-glass accounts out of sync.
- Use separate cloud-only accounts if you need privileged Entra roles that should not be tied to on-prem server administration.

The source of authority for Tier 1 remains on-premises AD DS. Entra is a synchronized consumer of the account, not the owner of it.

## Tier 1 Hybrid Sync Procedure

### 1. Create the On-Premises Account
Create the Tier 1 account in the Tier 1 admin OU.

```powershell
New-ADUser -Name 'adm-t1-srv01' `
  -SamAccountName 'adm-t1-srv01' `
  -UserPrincipalName 'adm-t1-srv01@corp.example.com' `
  -Path 'OU=Tier1-Admins,OU=Accounts,DC=corp,DC=example,DC=com' `
  -Enabled $true
```

### 2. Add the Correct Tier 1 Group Memberships
```powershell
Add-ADGroupMember -Identity 'T1-ROLE-Server-Admins' -Members 'adm-t1-srv01'
```

### 3. Confirm the OU Is in Sync Scope
Use OU filtering or an equivalent inclusion rule in Microsoft Entra Connect.
- Include the Tier 1 admin OU.
- Exclude Tier 0 admin OUs.
- Exclude break-glass OUs.

### 4. Wait for Synchronization
Confirm the account appears in Entra.
- Verify the object exists.
- Verify the user principal name is correct.
- Verify any required attributes are present.
- Verify the account is not given unnecessary cloud roles.

### 5. Validate Sign-In Paths
Confirm the user can sign in only from approved Tier 1 access paths.
- Tier 1 admin workstation
- Approved jump host
- Approved remote administration path

### 6. Retire the Account Properly
When the account is no longer required:
- Disable it on-premises.
- Remove it from the Tier 1 admin group.
- Confirm the sync removal flows to Entra.
- Archive the change evidence.

## Tier 1 Daily Workflow

### Start of Day
1. Sign in to the Tier 1 admin workstation.
2. Confirm patch and security status.
3. Review changes and maintenance windows.
4. Confirm the target server set is correct.
5. Confirm you are not touching Tier 0 assets.

### During Administration
1. Connect only to approved Tier 1 targets.
2. Apply one change at a time where practical.
3. Validate services after each change.
4. Record the exact server, action, and outcome.
5. Escalate Tier 0-affecting issues instead of working around them.

### End of Day
1. Save change evidence.
2. Verify no lingering remote sessions remain.
3. Sign out of the Tier 1 admin workstation.
4. Close or update tickets.

## Allowed Activities
- Server builds and patching
- Server configuration changes
- Application server administration
- Backup and restore operations for Tier 1 systems
- Monitoring and service health work for Tier 1
- Server-side group membership changes where authorized

## Disallowed Activities
- Managing Domain Controllers
- Managing PKI or identity infrastructure
- Tier 0 changes of any kind
- User help desk work
- General workstation administration unless explicitly part of Tier 1 scope
- Using Tier 1 accounts from Tier 2 devices for convenience

## Tier 1 Change Procedure
1. Confirm approval.
2. Confirm target system is Tier 1.
3. Confirm you are using a Tier 1 account from a Tier 1 system.
4. Perform the change.
5. Validate application and system health.
6. Record evidence.
7. Close the ticket.

Example checks:
```powershell
Get-Service -ComputerName 'srv01'
Get-GPInheritance -Target 'ou=Servers,dc=corp,dc=example,dc=com'
```

## Tier 1 and Microsoft Entra
If Tier 1 accounts are synchronized to Entra, keep the cloud footprint disciplined.
- Do not grant broad cloud admin roles to the same account used for server administration.
- Use separate privileged Entra roles if cloud administration is needed.
- Keep conditional access and MFA policies aligned with your admin access path.
- Make sure the account lifecycle is controlled on-premises.
- Ensure sign-in logs are reviewed for unexpected cloud access.

## Tier 1 Onboarding Checklist
- Create the account in the Tier 1 admin OU.
- Add only the required Tier 1 groups.
- Confirm Entra sync scope if the account is hybrid.
- Validate the workstation or jump host access path.
- Confirm the account cannot log on to Tier 0.
- Confirm the account cannot be used for help desk work.

## Tier 1 Offboarding Checklist
- Disable the account.
- Remove it from Tier 1 groups.
- Confirm synchronization removal.
- Review recent activity for anomalies.
- Revoke any associated access tokens or sessions if your process uses them.

## Tier 1 Success Criteria
Tier 1 is operating correctly when:
- Server administration is separated from identity administration.
- Hybrid Tier 1 accounts are synced only where required.
- Tier 0 remains isolated.
- Server changes are auditable and reversible.
- Help desk and user support workflows stay out of Tier 1.

## Short Version
Tier 1 is allowed to be hybrid, but only in a controlled way. Sync the accounts that need it, keep authority on-premises, and never let Tier 1 become a back door into Tier 0.
