# Tier 0 SOP

## Purpose
This SOP defines how Tier 0 administrators operate after the tier model is introduced. Tier 0 is the identity and control plane of the environment. If Tier 0 is compromised, the rest of the domain can usually be recovered only with difficulty.

## Tier 0 Scope
Tier 0 includes:
- Domain Controllers
- Identity infrastructure
- PKI and certificate services
- Federation and identity trust components
- Authentication Policy Silos and related enforcement objects
- Emergency recovery and break-glass processes
- PAWs used to manage Tier 0 systems

Tier 0 does not include general server administration, workstation administration, help desk work, or daily productivity tasks.

## Tier 0 Operating Rules
- Use Tier 0 admin accounts only.
- Log on only from Tier 0 PAWs.
- Do not browse the internet or use email from Tier 0 systems.
- Do not use Tier 0 accounts for general administration of Tier 1 or Tier 2 systems.
- Keep membership in Tier 0 groups minimal and reviewed.
- Treat every Tier 0 action as change-controlled.
- Assume every Tier 0 session is sensitive and should be logged.

## Tier 0 Daily Workflow

### Start of Day
1. Sign in to the Tier 0 PAW.
2. Confirm the workstation is healthy and patched.
3. Verify the correct time source and network path.
4. Check outstanding change requests and maintenance windows.
5. Confirm break-glass procedures are available and understood.

### During Administration
1. Use approved Tier 0 tools only.
2. Make one change at a time where possible.
3. Document the purpose of each change.
4. Validate the result before moving to the next task.
5. Avoid mixing identity changes with unrelated infrastructure changes in the same session.

### End of Day
1. Record what was changed.
2. Confirm replication or service health where relevant.
3. Sign out of the PAW.
4. Store notes and change evidence in the approved repository.

## Allowed Activities
- Managing Domain Controllers
- Managing AD DS identities and privileged groups
- Managing PKI and identity trust infrastructure
- Managing Authentication Policy Silos for Tier 0
- Managing GPOs that affect Tier 0 identity security
- Responding to Tier 0 incidents
- Using break-glass access under approved conditions

## Disallowed Activities
- Web browsing, email, chat, or general office work
- Tier 1 or Tier 2 administration
- Using a Tier 0 account on a Tier 1 or Tier 2 system
- Using a Tier 0 PAW for help desk tasks
- Installing unapproved software
- Sharing Tier 0 credentials

## Tier 0 Change Procedure
1. Confirm the change request is approved.
2. Confirm you are on the correct Tier 0 PAW.
3. Confirm the target is actually Tier 0.
4. Run the change script or procedure.
5. Validate the result.
6. Capture evidence.
7. Close the request.

Example validation commands:
```powershell
Get-ADDomainController -Filter *
repadmin /replsummary
Get-GPInheritance -Target 'dc=corp,dc=example,dc=com'
```

## Authentication Policy Silos
If using silos, Tier 0 accounts and Tier 0 PAWs should be paired deliberately.
- Create the silo first in audit or non-enforced mode if possible.
- Add only the intended Tier 0 accounts and Tier 0 PAWs.
- Test logon and management tasks.
- Enforce only after verification.

Example commands:
```powershell
New-ADAuthenticationPolicySilo -Name Tier0-Silo -Enforce
Get-ADAuthenticationPolicySilo -Identity Tier0-Silo
```

## Break-Glass Procedure for Tier 0
Break-glass is for emergency recovery only.

### When to Use
- Loss of normal Tier 0 access
- Lockout caused by a control change
- Authentication failure caused by an enforcement mistake
- Incident response requiring immediate domain recovery

### Steps
1. Obtain authorization from the designated approver.
2. Use the break-glass account from the documented recovery path.
3. Record the exact reason for use.
4. Make the minimum recovery change needed.
5. Return the environment to the normal operating model.
6. Rotate or revalidate the account after use.

### What Not to Do
- Do not use break-glass for routine admin work.
- Do not leave break-glass logged in.
- Do not use break-glass as a daily backup account.

## Tier 0 Logging and Evidence
Every Tier 0 change should have:
- Who changed it
- What was changed
- Why it was changed
- When it was changed
- How it was validated
- Whether rollback was required

## Tier 0 Onboarding Checklist
- Create account in the Tier 0 admin OU.
- Assign only necessary Tier 0 groups.
- Enroll or provision the Tier 0 PAW access path.
- Test authentication from the PAW.
- Verify the account cannot be used on Tier 1 or Tier 2 systems.
- Confirm the account is not synced to Entra.

## Tier 0 Offboarding Checklist
- Disable the account.
- Remove from all Tier 0 groups.
- Rotate any associated secrets.
- Confirm no active sessions remain.
- Review logs for recent use.

## Tier 0 Success Criteria
Tier 0 is operating correctly when:
- Only Tier 0 accounts can manage Tier 0 systems.
- Tier 0 accounts work only from Tier 0 PAWs.
- Tier 0 systems are not used for general productivity.
- Emergency access is tested and documented.
- Change evidence is complete and auditable.

## Short Version
Tier 0 is small, strict, and boring on purpose. If it becomes convenient for general admin work, it is no longer Tier 0.
