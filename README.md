# MEAM – Active Directory Tier Architecture

> **Monash Enterprise Access Model (MEAM)** extended with Microsoft Enterprise Access Model (EAM),  
> Kerberos Authentication Policies, Clean Source Principle, VMware vCenter & Nutanix RBAC integration.

---

## Table of Contents
1. [Model Overview](#model-overview)
2. [Scripts In This Repository](#scripts-in-this-repository)
3. [Pre-Flight and Safe Execution](#pre-flight-and-safe-execution)
4. [Three Commandments](#three-commandments)
5. [Tier Structure](#tier-structure)
6. [Zone Definitions](#zone-definitions)
7. [Enforcement Layers](#enforcement-layers)
8. [Authentication Flow](#authentication-flow)
9. [Group Naming Convention](#group-naming-convention)
10. [OU Hierarchy](#ou-hierarchy)
11. [GPO Matrix](#gpo-matrix)
12. [PSO Matrix](#pso-matrix)
13. [Monitoring: Auto-Tiering Scanner](#monitoring-auto-tiering-scanner)
14. [Platform Integrations](#platform-integrations)
15. [Operational Runbook](#operational-runbook)
16. [References](#references)

---

## Model Overview

The MEAM implements the **Clean Source Principle**: every security dependency must be as trustworthy  
as the object being secured. The model enforces this through two independent, complementary layers:

| Layer | Mechanism | Scope |
|---|---|---|
| **AuthN** | Kerberos Authentication Policy Silos | Domain-wide, enforced by KDC |
| **AuthZ** | GPO User Rights Assignment (5 deny settings) | Windows domain-joined systems only |

> ⚠️ Both layers are required. GPO alone can be bypassed by local admins. Silos alone do not cover  
> all logon types. Together they provide defense-in-depth.

---

## Scripts In This Repository

| Script | Purpose |
|---|---|
| `1. Main/script_v2.ps1` | Full greenfield MEAM deployment (OUs, groups, PSOs, Auth Policies/Silos, GPOs, ACL delegation, break-glass/test accounts, DNS delegation, compliance report). |
| `2.Role_segregation/DNS_seperate.ps1` | DNS role segregation helper (repository utility script). |
| `3. Monitoring/Auto-Tiering Computer account scanner.ps1` | Tier placement monitoring for computer objects, with CSV output and optional alerting. |

---

## Pre-Flight and Safe Execution

`script_v2.ps1` supports a pre-flight mode so you can validate prerequisites before making AD changes.

### Validate only

```powershell
.\script_v2.ps1 -ValidateOnly
```

### What pre-flight validates

- Required modules are available (`ActiveDirectory`, `GroupPolicy`, and `DnsServer` when DNS deploy is enabled)
- AD domain context can be queried (`Get-ADDomain`)
- Domain functional level is high enough for Authentication Policy Silos (`Windows2012R2Domain+`)
- Config structure and values are consistent (zones, services, required fields)
- High-risk defaults are flagged as warnings (placeholder break-glass password, test account creation enabled)

### New execution/reporting behavior in `script_v2.ps1`

- Phase wrapper with timing and standardized start/complete/fail logs
- Idempotent ACL delegation (`Add-ADDelegationSafe`) to avoid duplicate ACEs on rerun
- Centralized OU DN construction helper for zone paths
- Deny-logon baseline helper applies all five deny rights consistently
- Compliance report now exports to JSON and CSV in addition to console output

---

## Three Commandments

*(Microsoft Enterprise Access Model — enforced by this script)*

1. **Credentials from a higher tier MUST NOT be exposed to lower-tier systems.**  
   A T0 admin account must NEVER log on interactively or via RDP/network to a T1 or T2 system.

2. **Lower-tier credentials CAN use services provided by higher tiers, but not the other way around.**  
   A T2 workstation can still apply Group Policy from DCs. A T1 server can still authenticate via Kerberos to DCs.

3. **Any system or user account that can MANAGE a higher tier is also a member of that tier.**  
   The vCenter/Nutanix hypervisor hosting DC VMs is Tier 0. Its admins are Tier 0 admins.

---

## Tier Structure

```
┌─────────────────────────────────────────────────────────────────────┐
│  TIER 0 — Control Plane                                             │
│  Domain Controllers, PKI/ADCS, ADFS, Entra Connect, Hypervisors     │
│  (vCenter/Nutanix hosting T0 VMs = T0 asset by Commandment 3)       │
│  PAW-T0: Smartcard enforced, WDAC, Credential Guard, No internet    │
├─────────────────────────────────────────────────────────────────────┤
│  TIER 1 — Management Plane                                          │
│  App Servers, File Servers, DNS, SCCM/Intune Infra, Backup Servers  │
│  PAW-T1: Credential Guard, LAPS, AppLocker                          │
├─────────────────────────────────────────────────────────────────────┤
│  TIER 2 — Workload Plane                                            │
│  Workstations, Kiosks, Business Application Servers                 │
│  Managed by T1 admins via Jump/PAW; T2 helpdesk for user support    │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Zone Definitions

Zones provide **horizontal microsegmentation within tiers** via dedicated Authentication Silos.  
An account in Zone 1B (Server Mgmt) cannot authenticate to Zone 1C (DNS Mgmt) systems.

| Zone | Tier | Label | Systems | Auth Silo |
|------|------|-------|---------|-----------|
| 0A | 0 | Domain Management | DCs, PKI, ADFS, Entra Connect | Zone-Silo-0A |
| 0B | 0 | Hypervisor Management | vCenter, Nutanix CVM, ESXi hosts | Zone-Silo-0B |
| 1A | 1 | Workstation Management | SCCM/Intune infra, MDT | Zone-Silo-1A |
| 1B | 1 | Server Management | App servers, file servers | Zone-Silo-1B |
| 1C | 1 | DNS Management | Dedicated DNS servers | Zone-Silo-1C |
| 1D | 1 | Storage Management | NAS, SAN, backup servers | Zone-Silo-1D |
| 2A | 2 | Workstations | End-user workstations, kiosks | Zone-Silo-2A |
| 2B | 2 | Business Servers | Business app servers (non-T1 managed) | Zone-Silo-2B |

---

## Enforcement Layers

### Layer 1 – Kerberos Armoring (FAST) [PREREQUISITE]
Must be enabled BEFORE deploying Authentication Policies.
- GPO: Computer Config → Admin Templates → System → KDC → "KDC support for claims, compound authentication, and Kerberos armoring" = **Enabled**
- GPO: Computer Config → Admin Templates → System → Kerberos → "Kerberos client support for claims, compound authentication" = **Enabled**

### Layer 2 – Authentication Policy Silos
- Per-zone silos enforced by KDC (not bypassable by local admins)
- PAW Silos: PAW-Silo-T0/T1/T2 — only PAW machines per tier
- Zone Silos: Zone-Silo-0A through Zone-Silo-2B
- TGT lifetimes: T0=60min, T1=120min, T2=240min
- All silos set to **ENFORCE** (not audit)

### Layer 3 – GPO User Rights Assignment (5 deny logon rights)
Applied to tier-scoped computer OUs:

| Right | T0 GPO | T1 GPO | T2 GPO |
|-------|--------|--------|--------|
| SeDenyInteractiveLogonRight | T1+T2 groups | T2 groups | T0+T1 groups |
| SeDenyRemoteInteractiveLogonRight | T1+T2 groups | T2 groups | T0+T1 groups |
| SeDenyNetworkLogonRight | T1+T2 groups | T2 groups | T0+T1 groups |
| SeDenyBatchLogonRight | T1+T2 groups | T2 groups | T0+T1 groups |
| SeDenyServiceLogonRight | T1+T2 groups | T2 groups | T0+T1 groups |

> Note: SeDenyBatchLogonRight and SeDenyServiceLogonRight are critical — RUNAS and  
> scheduled tasks are interactive logons that expose credentials!

### Layer 4 – Protected Users Security Group
All T0 and T1 role groups are nested into Protected Users:
- Disables NTLM authentication
- Disables RC4 and DES encryption
- Disables unconstrained Kerberos delegation
- Forces 4-hour TGT expiry

### Layer 5 – NTLM Restriction (GPO)
- Audit NTLMv1 → block NTLMv1
- Audit NTLMv2 → progressively restrict to named servers only
- HKLM\SYSTEM\CurrentControlSet\Control\Lsa → LmCompatibilityLevel = 5

---

## Authentication Flow

```
T0 Admin logs on to PAW-T0:
  1. Computer (PAW-T0) authenticates to DC → receives armored TGT
  2. User (T0-Admin) sends armored AS-REQ
  3. KDC checks Authentication Policy: is PAW-T0 in Zone-Silo-0A?
  4a. YES → TGT issued (Kerberos only, 60min lifetime)
  4b. NO  → KRB5KDC_ERR_POLICY returned; access denied

T1 Admin tries to log on to DC (cross-tier violation):
  1. Computer (T1 Server) → T1 armored TGT
  2. User (T1-Admin) sends armored AS-REQ
  3. KDC checks T0-Auth-Policy: is T1 Server in Zone-Silo-0A? → NO
  4. KRB5KDC_ERR_POLICY → access denied at KDC level (not at target!)
```

---

## Group Naming Convention

| Type | Format | Example |
|------|--------|---------|
| Tier role | `T[n]-ROLE-[Function]` | `T0-ROLE-AD-Admins` |
| Zone role | `Z[zone]-ROLE-[Function]` | `Z1B-ROLE-Server-Admins` |
| Delegation | `Z[zone]-DLG-[Svc]-[Obj]-[Perm]` | `Z1B-DLG-AppServers-Users-PasswordReset` |
| GPO edit | `Z[zone]-GPO-[Svc]-Edit` | `Z1C-GPO-DNS-Edit` |
| LAPS read | `Z[zone]-ACL-LAPS-Read` | `Z2A-ACL-LAPS-Read` |
| PAW access | `PAW-T[n]-Users` | `PAW-T0-Users` |

**18 delegation groups per service** (pattern: 9 computer + 9 user permission groups):
`DomainJoin, Read, Write, Delete, MoveOU, BitLockerRead, LAPSRead, LAPSReset, GroupMembership` (computers)  
`Create, Delete, Read, Write, PasswordReset, Unlock, Enable, Disable, GroupMembership` (users)

---

## OU Hierarchy

```
DC=corp,DC=example,DC=com
└── OU=Corp
    ├── OU=Tiers
    │   ├── OU=Tier 0
    │   │   ├── OU=PAWs
    │   │   ├── OU=Zone 0A (Domain Management)
    │   │   │   ├── OU=Computers
    │   │   │   ├── OU=Accounts
    │   │   │   ├── OU=Service Accounts
    │   │   │   ├── OU=Groups
    │   │   │   │   ├── OU=Roles
    │   │   │   │   └── OU=Delegation
    │   │   │   └── OU=Services
    │   │   │       ├── OU=DomainControllers
    │   │   │       └── OU=PKI
    │   │   └── OU=Zone 0B (Hypervisor Management)
    │   ├── OU=Tier 1
    │   │   ├── OU=PAWs
    │   │   ├── OU=Zone 1A (Workstation Management)
    │   │   ├── OU=Zone 1B (Server Management)
    │   │   ├── OU=Zone 1C (DNS Management)
    │   │   └── OU=Zone 1D (Storage Management)
    │   └── OU=Tier 2
    │       ├── OU=Zone 2A (Workstations)
    │       └── OU=Zone 2B (Business Servers)
    ├── OU=Users
    │   ├── OU=Standard
    │   ├── OU=VIP
    │   └── OU=External
    ├── OU=Groups
    └── OU=Service Accounts
```

> ⚠️ **Clean Source Principle**: Break ACL inheritance on `OU=Tiers` and `OU=Corp`.  
> Review root domain ACLs BEFORE creating Corp OU. Remove any IDM/application accounts  
> with GenericAll/WriteDACL at domain root level.

---

## GPO Matrix

| GPO Name | Linked OU | Key Settings |
|----------|-----------|-------------|
| GPO-T0-DenyLowerTier-Logon | OU=Domain Controllers | Deny T1+T2 (5 rights) |
| GPO-T0-PAW-Baseline | OU=PAWs Tier 0 | WDAC, no internet, CG, smartcard |
| GPO-T0-AuditPolicy | OU=Domain Controllers | 15 advanced audit subcategories |
| GPO-T1-DenyTier2-Logon | OU=Tier 1 | Deny T2 (5 rights) |
| GPO-T1-Server-Baseline | OU=Tier 1 | LSA protection, CG, secure baseline |
| GPO-T1-LAPS | OU=Tier 1 | LAPS 30-day rotation, 20-char |
| GPO-T2-DenyT0T1-Logon | OU=Tier 2 | Deny T0+T1 (5 rights) |
| GPO-T2-Workstation-Baseline | OU=Tier 2 | CG, LSA, WDAC audit mode |
| GPO-T2-LAPS | OU=Tier 2 | LAPS 30-day rotation, 20-char |
| GPO-T2-CredentialGuard | OU=Zone 2A | VBS + CG enforced |

---

## PSO Matrix

| PSO | Precedence | Min Length | Max Age | Lockout | Applied To |
|-----|-----------|-----------|---------|---------|-----------|
| PSO-Tier0 | 1 | 20 chars | 180 days | None (smartcard) | T0 role groups |
| PSO-Tier1 | 2 | 14 chars | 180 days | 5 attempts/30min | T1 role groups |
| PSO-Tier2 | 3 | 12 chars | 180 days | 5 attempts/30min | T2 role groups |
| PSO-SvcAccts | 4 | 30 chars | 365 days | None | Service account groups |

---

## Monitoring: Auto-Tiering Scanner

Script: `3. Monitoring/Auto-Tiering Computer account scanner.ps1`

### Purpose

- Scans AD computer objects and detects likely tier-placement mismatches based on naming patterns and OU path patterns.
- Exports findings to CSV and can send an email alert when violations are found.

### Parameters

- `DomainDN`: defaults to `(Get-ADDomain).DistinguishedName`
- `ReportPath`: defaults to `C:\MEAM\TierScan-YYYYMMDD.csv`
- `AlertTo`: email recipient for alert message

### Current behavior and scope

- Scans computer objects only (users/service accounts are not yet included)
- Uses regex-based tier inference from computer names
- Produces remediation suggestions (`Move-ADObject` example)
- Auto-fix logic is intentionally commented out by default

### Prerequisites

- PowerShell `ActiveDirectory` module
- SMTP connectivity for alerting (`Send-MailMessage` currently used)

### Recommended hardening follow-ups

- Replace `Send-MailMessage` with a modern mail/API approach
- Add explicit `-WhatIf`/`-Confirm` support before enabling any auto-move logic
- Expand scanner coverage to user/service accounts and zone-specific rules

---

## Platform Integrations

### VMware vCenter (Tier 0B / Tier 1B)

vCenter hosting Tier 0 VMs (DCs) → **Tier 0** asset.  
vCenter managing only Tier 1 VMs → **Tier 1** asset (Zone 1B).

| vCenter Role | Maps to AD Group | Tier |
|---|---|---|
| Administrator | T0-ROLE-Hyper-Admins | 0 |
| Read-only (DC VMs) | T0-ACL-Computers-Read | 0 |
| VM Power User (T1 VMs) | T1-ROLE-Server-Admins | 1 |
| Network Admin | T1-ROLE-Infra-Admins | 1 |

Configure via: `Set-VIPermission` using AD group SIDs mapped to vCenter built-in roles.  
Restrict SSO login to PAW machines using vCenter Identity Sources + ADFS/Auth Policies.

### Nutanix Prism (Tier 0B / Tier 1B)

Nutanix CVMs and AHV hosting DC VMs → **Tier 0** asset (Zone 0B).

| Prism Role | Maps to AD Group | Tier |
|---|---|---|
| Prism Admin (CVM/AHV) | T0-ROLE-Hyper-Admins | 0 |
| Prism Admin (T1 VMs) | T1-ROLE-Server-Admins | 1 |
| Prism Viewer | T1-ACL-Computers-Read | 1 |
| Self-Service Admin | T2-ROLE-HelpDesk | 2 |

Configure via: Prism Central → Directory Services → Add AD groups per role.  
Use Prism Central RBAC to restrict T1 admins to non-T0 clusters.

---

## Operational Runbook

### New Admin Onboarding
1. Create admin account in correct zone OU (`OU=Accounts,OU=Zone Xn,OU=Tier X,OU=Tiers,OU=Corp`)
2. Add to role group (`T[n]-ROLE-*`) — PSO applied automatically
3. Add to Protected Users via role group nesting
4. Add to PAW-T[n]-Users group
5. Grant Auth Silo access: `Grant-ADAuthenticationPolicySiloAccess -Identity Zone-Silo-Xn -Account <sam>`
6. Assign PAW device: `Set-ADComputer -Identity <PAW> -AuthenticationPolicySilo PAW-Silo-T[n]`
7. Issue PIV/Yubikey smartcard (T0/T1 mandatory)

### New Server/Computer Onboarding
1. Place computer object in correct zone OU
2. Assign to zone silo: `Set-ADComputer -Identity <computer> -AuthenticationPolicySilo Zone-Silo-Xn`
3. Add computer to LAPS delegation group for that zone
4. Verify GPO application: `gpresult /r /scope computer`

### Break-Glass Usage
1. Enable designated break-glass account (created disabled by deployment script)
2. Log usage in security ticket system (mandatory)
3. Re-disable account immediately after use
4. Rotate credentials; return to offline vault (sealed envelope)
5. Review AD audit logs for all actions taken

### Quarterly Review
- Run BloodHound/PingCastle: verify no T1→T0 attack paths
- Review Domain Admins / Schema Admins: must only contain role groups
- Review Protected Users membership
- Review Auth Silo assignments (new computers, new admins)
- Validate LAPS is rotating on all T1/T2 computers
- Review gMSA health: `Get-ADServiceAccount -Filter * -Properties PasswordLastSet`

---

## References

| Resource | URL |
|---|---|
| MEAM (Monash CSIRT) | https://github.com/mon-csirt/active-directory-security/tree/main/MEAM |
| Microsoft Enterprise Access Model | https://aka.ms/EAM |
| Protecting Tier 0 the Modern Way | https://techcommunity.microsoft.com/blog/coreinfrastructureandsecurityblog/protecting-tier-0-the-modern-way/4052851 |
| Quest: Implementing Tiered Admin | https://blog.quest.com/implementing-a-tiered-administration-model-in-active-directory/ |
| Kili69 T0 Automation Script | https://github.com/Kili69/Tier0-User-Isolation |
| AdminDroid Tiering Guide | https://blog.admindroid.com/active-directory-tiering-model/ |
| Truesec AD Tiering | https://www.truesec.com/security/active-directory-tiering |
| Authentication Policy How-To | https://learn.microsoft.com/en-us/windows-server/identity/ad-ds/manage/how-to-configure-protected-accounts |
