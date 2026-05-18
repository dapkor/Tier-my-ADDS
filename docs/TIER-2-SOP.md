# Tier 2 SOP

## Purpose
This SOP defines how Tier 2 administrators operate. Tier 2 is the user, endpoint, and help desk layer. It should be the least privileged operational tier.

## Tier 2 Scope
Tier 2 includes:
- Workstations
- User profiles and user support
- Endpoint support tools
- Standard operating system troubleshooting
- Help desk workflows
- Client-side application support

Tier 2 does not include:
- Domain Controllers
- PKI or identity services
- Server administration
- Tier 0 systems
- Tier 1 server management systems

## Tier 2 Operating Rules
- Use Tier 2 admin or support accounts only.
- Use approved Tier 2 support devices or jump paths.
- Do not use Tier 2 accounts for server or identity administration.
- Keep user support work separate from server work.
- Follow ticket-driven workflows.
- Escalate anything that affects servers, identity, or security boundaries.

## Tier 2 Daily Workflow

### Start of Day
1. Sign in to the Tier 2 support workstation or help desk console.
2. Review assigned tickets.
3. Confirm any active incidents or outages.
4. Confirm the tools you need are approved and up to date.

### During Administration
1. Work only the tickets assigned to Tier 2.
2. Use standard support tools and approved scripts.
3. Keep changes minimal and reversible.
4. Validate the user or workstation issue after each change.
5. Escalate to Tier 1 if a server or shared service is involved.

### End of Day
1. Update ticket status.
2. Save logs or screenshots if needed.
3. Sign out of the support workstation.
4. Confirm no remote sessions are left open.

## Allowed Activities
- Password resets and user support where authorized
- Workstation troubleshooting
- Client software troubleshooting
- Endpoint imaging or rebuilds
- Basic local account support where permitted
- Help desk activities under approved procedures

## Disallowed Activities
- Server administration
- Identity infrastructure changes
- Group Policy changes outside approved Tier 2 scope
- Domain Controller access
- Tier 0 access of any kind
- Using Tier 2 accounts as a shortcut to server work

## Tier 2 Change Procedure
1. Confirm the request is a Tier 2 issue.
2. Confirm the target is a workstation or user endpoint.
3. Confirm the action is within approved support scope.
4. Make the minimum change needed.
5. Validate the fix.
6. Document the outcome.
7. Close the ticket or escalate.

Example checks:
```powershell
gpresult /r
Get-ComputerInfo
```

## Tier 2 Onboarding Checklist
- Create or assign the Tier 2 support account.
- Limit group membership to help desk scope.
- Confirm the support workstation is approved.
- Confirm access is denied to Tier 1 and Tier 0 systems.
- Review the escalation path.

## Tier 2 Offboarding Checklist
- Disable the account.
- Remove unnecessary group membership.
- Revoke support device access if required.
- Confirm no active sessions remain.

## Tier 2 Success Criteria
Tier 2 is operating correctly when:
- Help desk actions stay inside the workstation and user support boundary.
- Server and identity work escalates instead of being worked around.
- The account cannot be used to manage higher tiers.
- Ticket records show what was done and why.

## Short Version
Tier 2 should stay simple. If a Tier 2 task starts to affect servers or identity, it is no longer a Tier 2 task.
