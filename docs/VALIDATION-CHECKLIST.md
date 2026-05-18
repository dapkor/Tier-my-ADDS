# Validation Checklist

## Purpose
Use this checklist before, during, and after introducing the tier model into an existing AD DS domain. It is designed to reduce the chance of lockout, service interruption, or hidden dependency failure.

## Validation Philosophy
Do not validate only the scripts. Validate the real workflows.

The key questions are:
- Can the right admin still reach the right system?
- Can the wrong admin no longer reach the wrong system?
- Can normal business services still function?
- Can you recover quickly if a change is too restrictive?

## Validation Phases
- Discovery validation
- Bootstrap validation
- Pilot validation
- Enforcement validation
- Operational validation
- Recurring health checks

## 1. Discovery Validation
Before any change, confirm the current state.

### Identity and Access
- Enumerate all privileged groups.
- Enumerate all admin accounts.
- Identify service accounts and gMSAs.
- Identify any accounts that are shared or poorly named.
- Identify admins who currently have cross-tier access.

### Infrastructure
- Confirm Domain Controller health.
- Confirm replication health.
- Confirm DNS health.
- Confirm time synchronization.
- Confirm backup coverage.

### Application Dependencies
- Identify applications that depend on NTLM.
- Identify applications that rely on legacy LDAP behavior.
- Identify servers that require constrained or unconstrained delegation.
- Identify admin tools that need RDP, WinRM, WMI, or remote registry.

Example commands:
```powershell
dcdiag /v
repadmin /replsummary
Get-ADGroupMember 'Domain Admins'
Get-ADUser -Filter * -SearchBase 'OU=Admins,DC=corp,DC=example,DC=com'
```

## 2. Bootstrap Validation
After the tier structure is created, confirm it is sane before enforcement.

### Tier 0 Checks
- Tier 0 OU exists.
- Tier 0 admin accounts exist.
- Tier 0 PAWs exist.
- Tier 0 accounts can log on to Tier 0 PAWs.
- Tier 0 accounts cannot be used on non-Tier 0 systems.
- Tier 0 accounts are not synced to Entra.

### Tier 1 Checks
- Tier 1 OU exists.
- Tier 1 admin accounts exist.
- Tier 1 admin accounts are in the sync scope if hybrid is required.
- Tier 1 accounts can manage Tier 1 servers.
- Tier 1 accounts cannot manage Tier 0 systems.

### Tier 2 Checks
- Tier 2 support groups exist.
- Tier 2 accounts can support workstations and users.
- Tier 2 accounts cannot manage servers or identity systems.

### Policy Checks
- Group Policy inheritance is correct.
- Required GPOs are linked to the right OUs.
- Blocked inheritance is used only where needed.
- No unintended GPO is leaking into the wrong tier.

Example commands:
```powershell
Get-GPInheritance -Target 'ou=Tier 0,dc=corp,dc=example,dc=com'
Get-GPInheritance -Target 'ou=Tier 1,dc=corp,dc=example,dc=com'
Get-GPInheritance -Target 'ou=Tier 2,dc=corp,dc=example,dc=com'
```

## 3. Pilot Validation
Pilot the controls with a small, real workload.

### Pilot Scope
- One Tier 0 admin
- One Tier 0 PAW
- One Tier 1 admin
- One Tier 1 server set
- One Tier 2 support user or workstation set

### Pilot Tasks
- Log on to the correct tiered workstation.
- Perform an allowed administrative task.
- Confirm a disallowed cross-tier logon fails.
- Confirm a routine management tool still works.
- Confirm change logging is complete.
- Confirm rollback is available and understood.

### Pilot Exit Criteria
Do not expand if any of these fail:
- Admin logon path fails
- GPO application breaks essential tools
- Authentication policy silos block expected access
- Entra sync for Tier 1 does not complete properly
- Break-glass access is not verified

## 4. Enforcement Validation
Only after the pilot succeeds should you turn on strong enforcement.

### Enforcement Checks
- Authentication Policy Silos are configured as intended.
- PAW restrictions are active.
- Cross-tier logon attempts fail as expected.
- Tier 0 and Tier 1 admin boundaries are respected.
- Tier 1 hybrid accounts sync correctly if enabled.
- No Tier 0 account appears in Entra sync scope.

### Validation Commands
```powershell
Get-ADAuthenticationPolicySilo -Filter *
Get-ADAuthenticationPolicySilo -Identity 'Tier0-Silo'
Get-ADAuthenticationPolicySilo -Identity 'Tier1-Silo'
```

## 5. Operational Validation
After go-live, prove the model still works in the real world.

### Daily Checks
- Domain Controllers are healthy.
- Replication is healthy.
- Tier 0 admin access still works from the PAW.
- Tier 1 server administration still works.
- Tier 2 support tasks still work.
- No unexpected cross-tier access exists.

### Weekly Checks
- Review admin logons.
- Review GPO changes.
- Review break-glass account status.
- Review sync status for Tier 1 hybrid accounts.
- Review high-risk authentication failures.

### Monthly Checks
- Confirm all privileged groups are still scoped correctly.
- Review service accounts for drift.
- Test a recovery path.
- Revalidate any exceptions.

## 6. Recurring Health Checks
Use a scheduled validation run to keep the model honest.

Minimum recurring checks:
- AD replication health
- DNS health
- Time sync health
- GPO link health
- Tier 0 PAW reachability
- Tier 1 admin account sync health
- Break-glass account readiness

## Tier 1 Hybrid Sync Checks
If Tier 1 accounts are synced to Entra, validate:
- The correct OU is in sync scope.
- The correct accounts are visible in Entra.
- Tier 0 accounts are not visible.
- Break-glass accounts are not visible.
- The sign-in path is still approved.
- The account is not granted unintended cloud privilege.

## Go / No-Go Decision Rules
Go forward only if:
- The target tier can administer its own scope.
- Cross-tier access is blocked or controlled.
- Rollback is documented and tested.
- Break-glass access works.
- Tier 1 sync works if required.

Stop or roll back if:
- Tier 0 access is lost.
- Admins cannot reach their normal systems.
- A core application breaks.
- A cross-tier boundary is unexpectedly open.
- The rollback path is unclear.

## Minimum Evidence to Keep
- Change request or approval record
- Validation output
- Replication and health results
- Break-glass test record
- Tier 1 sync verification if used
- Any exception approvals

## Short Version
If you cannot show that the right people can still do their jobs and the wrong people cannot cross tiers, the rollout is not ready.
