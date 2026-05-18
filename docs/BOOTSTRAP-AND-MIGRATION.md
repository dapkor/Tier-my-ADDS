# Bootstrap and Migration Guide

## Purpose
This guide explains how to introduce the tier model into an existing AD DS domain without needing a pre-existing Tier 0 operating model. It is written for customers who already have a production forest and need a safe way to create the new structure while minimizing risk.

## Core Principle
You do not avoid the chicken-and-egg problem. You control it.

Use the current privileged access only as a temporary bootstrap method to build the new model, then retire that broad privilege from daily use. The goal is to move from "standing privilege" to "controlled privilege" as quickly as possible.

## Recommended Bootstrap Model
- Use your existing Enterprise Admin or Domain Admin access only for the initial build window.
- Create the tier structure, admin accounts, PAWs, groups, break-glass accounts, and validation controls.
- Move yourself and other operators onto the new Tier 0 path after the build.
- Keep the original broad privilege only for emergency recovery and documented break-glass use.

## What to Prepare Before You Start
- A tested backup of Active Directory and SYSVOL.
- A verified path back into the environment if a tier control blocks access.
- A small pilot OU or lab domain.
- A maintenance window with clear rollback authority.
- A list of existing privileged users, service accounts, applications, and admin tools.
- A decision on Tier 1 hybrid sync scope in Microsoft Entra.

## Minimum Safe Migration Sequence

### 1. Discovery and Freeze
Inventory the current environment before making changes.
- Privileged groups
- Admin accounts
- Service accounts
- Delegated admin groups
- Domain Controllers and management servers
- Remote admin paths such as RDP, WinRM, WMI, RSAT, and MMC
- Legacy operating systems and legacy authentication
- Applications that depend on AD, LDAP, Kerberos, or NTLM

Stop unrelated changes while you build the tier model.

### 2. Health Check the Forest
Before you create the new model, confirm the domain is healthy.
- `dcdiag /v`
- `repadmin /replsummary`
- Confirm time synchronization is correct on all DCs
- Confirm DNS resolution is stable for all DCs and admin systems
- Check for unresolved replication failures
- Review SYSVOL and NETLOGON consistency

### 3. Create the Tier Structure
Using the current privileged account, create the base OUs and groups for:
- Tier 0 identities, PAWs, and infrastructure
- Tier 1 server administration
- Tier 2 workstation and help desk administration
- Break-glass users and accounts
- Administrative groups for each tier

Keep Tier 0 very small. Do not widen it to include general infrastructure work.

### 4. Create Break-Glass Access
Before any enforcement, create and test break-glass access.
- Use separate accounts from daily admin identities.
- Store credentials in a secure offline process.
- Exclude these accounts from normal tiering workflows where appropriate.
- Test each account before you rely on it.
- Document when it may be used and who may authorize it.

### 5. Create Tier 0 Admin Accounts
Create the Tier 0 human admin accounts that will replace your broad privilege.
- Place them in the Tier 0 admin OU.
- Use separate accounts from your normal user account.
- Do not sync Tier 0 admin accounts to Microsoft Entra.
- Restrict logon to Tier 0 PAWs only.
- Keep the group membership minimal.

### 6. Build Tier 0 PAWs
Build one or more dedicated Tier 0 admin workstations.
- Join them to the correct OU.
- Apply only Tier 0-approved settings.
- Remove email, browser, and general-purpose applications where possible.
- Allow only the administrative tools required for identity infrastructure.
- Validate that Tier 0 admin accounts can log on and perform their tasks.

### 7. Create Tier 1 Hybrid Admin Accounts
If Tier 1 admins must also use Microsoft Entra services, create Tier 1 accounts with a controlled sync scope.
- Keep the source of authority on-premises AD DS.
- Sync only the Tier 1 admin OU or filtered security group to Entra.
- Do not sync Tier 0 accounts.
- Do not sync break-glass accounts.
- Do not assign Tier 1 accounts privileged Tier 0 rights.
- If cloud admin roles are needed, use separate cloud-only or PIM-controlled identities.

### 8. Pilot the Model
Pilot in a small scope before broad enforcement.
- One Tier 0 admin
- One Tier 0 PAW
- One Tier 1 admin group
- One server OU
- One workstation OU

Confirm real work still functions:
- Directory administration
- GPO edits
- Server administration
- Account lifecycle changes
- Reporting and monitoring

### 9. Enforce the Boundaries
Only after the pilot works should you enforce the tier boundaries.
- Block cross-tier logon where required.
- Link the correct GPOs to the correct OUs.
- Apply Authentication Policy Silos only when the accounts and devices are ready.
- Use inheritance blocking carefully and only where needed.
- Keep exception handling explicit and temporary.

### 10. Retire the Bootstrap Path
Once Tier 0 is working:
- Remove daily use of the old broad admin accounts.
- Keep the old privilege only for documented recovery.
- Review the access model after each cutover.
- Move all future admin onboarding to the new process.

## How the Chicken-and-Egg Problem Is Handled
The bootstrap is handled by time-limited legacy privilege.

That means:
- You use the existing privileged account to create the new model.
- You do not keep using that account as your daily operating identity.
- You transfer operational control to the new Tier 0 accounts as soon as they exist.
- You keep a tested emergency path in case the new controls are too restrictive.

This is safer than trying to pre-create a Tier 0 model without any privileged starting point.

## Tier 1 Hybrid Sync Model
Tier 1 is the most likely place where a customer needs hybrid identity.

Recommended approach:
- Keep Tier 1 admin accounts in a dedicated on-premises OU.
- Use OU filtering or group-based filtering to sync only Tier 1 accounts to Microsoft Entra.
- Keep the accounts separate from Tier 0.
- Use the synced identity only for the access that genuinely needs Entra connectivity.
- If cloud privileged roles are required, use separate cloud-only admin identities or just-in-time access.

Operational rule:
- Tier 1 may be hybrid.
- Tier 0 should remain on-premises only.
- Break-glass should remain separate from both.

## Recommended Pilot Exit Criteria
Do not expand the rollout until all of these work:
- Tier 0 admin logon from the PAW
- Tier 0 administrative tools work as expected
- Tier 1 admin can manage servers without cross-tier access
- Tier 1 account sync to Entra completes successfully if used
- Tier 2 support flow works without server or identity access
- Break-glass account access is proven
- Monitoring and validation scripts report expected results

## Rollback Mindset
Every major control needs a rollback plan.
- GPO inheritance changes
- Authentication Policy Silo enforcement
- DC registry hardening
- PAW lock-down steps
- Entra sync scope changes

If a control breaks access, the rollback path must be simpler than the forward path.

## Bottom Line
For an existing AD DS environment, bootstrap with your current privileged access, but use it only long enough to create the new operating model. Then move to dedicated Tier 0, Tier 1, and Tier 2 identities, with Tier 1 synced to Entra only when required and Tier 0 kept isolated.
