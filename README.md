# MEAM – Active Directory Tier Architecture

> **Author:** [@dapkor](https://github.com/dapkor)  
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
14. [Monthly HTML Tier Reports](#monthly-html-tier-reports)
15. [CI/CD Pipeline Setup](#cicd-pipeline-setup)
16. [Platform Integrations](#platform-integrations)
17. [Operational Runbook](#operational-runbook)
18. [References](#references)

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
| `1. Main/script_v2.config.example.json` | Ready-to-run JSON config for `script_v2.ps1`. Copy, fill in your domain values, run. |
| `2.Role_segregation/DNS_seperate.ps1` | DNS role segregation helper (repository utility script). |
| `3. Monitoring/Auto-Tiering Computer account scanner.ps1` | Tier placement monitoring for computer objects — scoring engine, CSV output, optional webhook alert. |
| `3. Monitoring/MEAM-Tier-Report.ps1` | **Monthly HTML compliance report** — T0 & T1 accounts, groups, PSOs, Auth Silos, PAWs, break-glass. Designed for scheduled CI/CD pipeline runs. |
| `4. Validation/Validate-MEAM-Deployment.ps1` | Post-deployment acceptance validator for OU layout, PSOs, auth silos, GPOs, Protected Users, and break-glass accounts. |
| `3. Monitoring/MEAM-Tier-Report.config.example.json` | Example config for the HTML report script. |
| `flowchart TD.presentation.txt` | Stakeholder-friendly Mermaid diagram (presentation view) with simplified labels and clean control narratives. |
| `flowchart TD.executive.txt` | Executive one-slide Mermaid diagram focused on business outcomes, governance cadence, and risk reduction. |
| `.github/workflows/meam-monthly-report.yml` | GitHub Actions workflow — runs the HTML report on the 1st of each month. |
| `azure-pipelines-monthly-report.yml` | Azure DevOps pipeline — same monthly schedule, publishes artifact. |

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
- Break-glass secret is present and meets the minimum length requirement
- High-risk defaults are flagged as warnings (plaintext break-glass password in config, test account creation enabled)

### Secret handling

- Do not store break-glass passwords in JSON config files committed to source control.
- Prefer `BreakGlass.TempPasswordEnvVar` in the config and provide the value at runtime through an environment variable such as `MEAM_BREAKGLASS_TEMP_PASSWORD`.
- Keep `CreateTestAccounts` disabled outside lab environments. If you enable it, provide each lab password through the environment variables `MEAM_TEST_PASSWORD_ADM_T0_TEST01`, `MEAM_TEST_PASSWORD_ADM_T1_SRV01`, `MEAM_TEST_PASSWORD_ADM_T1_DNS01`, and `MEAM_TEST_PASSWORD_ADM_T2_HD01`.

### New execution/reporting behavior in `script_v2.ps1`

- Phase wrapper with timing and standardized start/complete/fail logs
- Idempotent ACL delegation (`Add-ADDelegationSafe`) to avoid duplicate ACEs on rerun
- Centralized OU DN construction helper for zone paths
- Deny-logon baseline helper applies all five deny rights consistently
- Compliance report now exports to JSON and CSV in addition to console output

### Query tuning

- `script_v2.config.example.json`, `DNS_seperate.config.example.json`, `MEAM-Tier-Report.config.example.json`, and `Auto-Tiering Computer account scanner.config.example.json` now expose optional retry tuning values.
- Use these to bound transient failures without changing script code:
   - `RetryCount` / `retryCount`
   - `RetryDelaySeconds` / `retryDelaySeconds`
   - `cimOperationTimeoutSeconds` and `eventQueryTimeoutSeconds` in the scanner config
- These settings are optional. If omitted, the scripts use conservative built-in defaults.

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
- Scoring engine with configurable weights per signal type (OU, name, group, SPN, OS, events, recent moves).
- Exports findings to CSV and can send a webhook alert when violations are found.
- Detects high-risk moves (e.g. Tier 0 → Tier 1 lateral movement) via Security event ID 5139.
- Webhook notifications must use `https://` endpoints and are validated during pre-flight.

### Parameters

- `-ConfigPath` / `-ConfigJson`: JSON config file or inline JSON (required)
- `-FailOnPhaseError`: abort on phase failure instead of continuing
- `-LintConfigOnly`: validate config schema without querying AD

### Configuration keys (required)

| Key | Description |
|---|---|
| `corpOU` | Top-level OU name (e.g. `"Corp"`) |
| `reportPath` | Output CSV path for findings |
| `runReportPath` | Output JSON path for run report |
| `zoneOUs` | OU path patterns per tier (`Tier 0`, `Tier 1`, `Tier 2`) |
| `tierSignals` | Name/group/description/SPN patterns per tier |
| `targetOUByTier` | Target OU DNs for remediation suggestions |
| `weights` | Scoring weights per signal type |
| `signals` | Feature flags (useRoleSignals, useEventSignals, etc.) |
| `alert` | Webhook alert config (`enabled`, `mode`, `webhookUrlEnvVar`, optional `authorizationEnvVar`, `headers`) |

Optional:

| Key | Description |
|---|---|
| `queryTuning` | Retry/timeout controls for AD, CIM, and event-log queries |

### Prerequisites

- PowerShell `ActiveDirectory` module (RSAT)
- Read-only domain account (Domain Users is sufficient)
- HTTPS connectivity to your webhook endpoint for alerting (optional)
- If `authorizationEnvVar` is configured but unset, the scanner logs a warning and sends the webhook without an `Authorization` header.

### Alerting notes

- Only `https://` webhook endpoints are accepted.
- Prefer `webhookUrlEnvVar` and `authorizationEnvVar` over inline secrets in JSON.
- `-LintConfigOnly` now validates the alert transport settings before any AD queries are made.

---

## Monthly HTML Tier Reports

Script: `3. Monitoring/MEAM-Tier-Report.ps1`

Generates a **fully self-contained HTML report** — no external dependencies, single file, open in any browser.  
Designed to run monthly via CI/CD pipeline and be published as a pipeline artifact or forwarded through a webhook notifier.

### What the report covers

| Section | Contents |
|---|---|
| **KPI summary cards** | T0/T1 account counts, stale accounts, failures, warnings, auth silos, PAW device count |
| **Compliance checks** | PASS / WARN / FAIL per check with detail — PSOs, Protected Users, smartcard, Domain Admins hygiene, silos, break-glass |
| **Tier 0 accounts** | Enabled/stale/smartcard/Protected-Users status per account, role groups, PAW devices, break-glass accounts, GPO links |
| **Tier 1 accounts** | Same as above for T1 — accounts, role groups, GPO links |
| **PSO cards** | All fine-grained password policies with every setting visible |
| **Authentication silos** | All silos and enforcement status |
| **Domain hygiene** | Direct user members in Domain Admins, Protected Users membership |

### Usage

```powershell
# Copy and edit the example config
Copy-Item "3. Monitoring\MEAM-Tier-Report.config.example.json" `
          "3. Monitoring\MEAM-Tier-Report.config.json"

# Run locally (opens in browser)
.\3. Monitoring\MEAM-Tier-Report.ps1 `
    -ConfigPath .\3. Monitoring\MEAM-Tier-Report.config.json `
    -OpenInBrowser

# Run without opening browser (for pipeline use)
.\3. Monitoring\MEAM-Tier-Report.ps1 `
    -ConfigPath .\3. Monitoring\MEAM-Tier-Report.config.json `
    -OutputPath .\reports\MEAM-$(Get-Date -f yyyyMM).html
```

### Runner / agent requirements

> ⚠️ These requirements apply both to manual runs and to CI/CD pipeline runners.

| Requirement | Detail |
|---|---|
| **Domain-joined machine** | The executing host must be domain-joined **or** have direct LDAP access (TCP 389 / 636) to a DC. The script uses Kerberos — a TGT is required. **Do NOT run on a Domain Controller.** Recommended host: Tier 1 member server (Zone 1B or 1C). |
| **RSAT — ActiveDirectory module** | Mandatory. `Install-WindowsFeature RSAT-AD-PowerShell` (Server) or `Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0` (Win 10/11) |
| **RSAT — GroupPolicy module** | Optional. Enables the GPO links table in the report. `Install-WindowsFeature GPMC` |
| **Service account** | **Domain Users only — no admin rights required.** All AD reads use default Domain Users permissions. Recommended: create a dedicated account `svc-meam-report` with no interactive logon rights and no tier-role group membership. |
| **Network** | Port 389/636 open to at least one DC from the runner host. |

### Stale account threshold

Pass `-StaleThresholdDays` (default: `90`) to control when an account is flagged as stale.  
Any enabled account with no logon in that many days is highlighted in the report with a warning badge.

Optional:

- `QueryTuning.RetryCount`
- `QueryTuning.RetryDelaySeconds`

These settings help the report tolerate transient AD or Group Policy query failures on busy or slow domain controllers.

---

## Post-Deployment Validation

Script: `4. Validation/Validate-MEAM-Deployment.ps1`

This validator runs after `1. Main/script_v2.ps1` and checks that the expected MEAM structure exists in AD. It is meant to be an acceptance test, not just a log review.

### What it checks

- Core OU hierarchy under `OU=<CorpOU>`
- Zone and service OUs derived from the deployment config
- Fine-grained password policies (PSOs)
- Core GPOs when the `GroupPolicy` module is available
- PAW silos and per-zone auth silos when `EnableAuthSilos=true`
- Protected Users role-group nesting
- Domain Admins direct-user hygiene
- Break-glass account presence and disabled state

### Usage

```powershell
.\4. Validation\Validate-MEAM-Deployment.ps1 `
   -ConfigPath .\1. Main\script_v2.config.json

.\4. Validation\Validate-MEAM-Deployment.ps1 `
   -ConfigPath .\1. Main\script_v2.config.json `
   -OutputPath .\reports\meam-validation.json
```

### Output

- Console summary with PASS/WARN/FAIL/SKIPPED counts
- JSON report with per-check details for pipeline or audit use

---

## CI/CD Pipeline Setup

Both pipeline files use the same self-hosted runner/agent with the requirements above.  
Neither pipeline requires secrets beyond the config JSON and optional webhook credentials.

### GitHub Actions — `.github/workflows/meam-monthly-report.yml`

| Setting | Value |
|---|---|
| **Schedule** | 1st of each month at 07:00 UTC |
| **Runner label** | `ad-access` (must match your self-hosted runner label) |
| **Config source** | Secret `MEAM_REPORT_CONFIG_JSON` **or** committed `3. Monitoring\MEAM-Tier-Report.config.json` |
| **Artifact retention** | 90 days |
| **Webhook** | Add a follow-up step that posts `generatedReportPath` or the artifact URL to your webhook endpoint using `Invoke-RestMethod` |

**Quick setup:**
```
1. Register a self-hosted Windows runner on a Tier 1 server
   → GitHub repo → Settings → Actions → Runners → New self-hosted runner
   → Use the label "ad-access"

2. Install RSAT on that server:
   Install-WindowsFeature RSAT-AD-PowerShell, GPMC

3. Configure the runner service to run as svc-meam-report

4. Add secret MEAM_REPORT_CONFIG_JSON (JSON content of your config)
   → GitHub repo → Settings → Secrets and variables → Actions → New repository secret
```

### Azure DevOps — `azure-pipelines-monthly-report.yml`

| Setting | Value |
|---|---|
| **Schedule** | 1st of each month at 07:00 UTC |
| **Agent pool** | `MEAM-Agents` (update `name:` field to match your pool) |
| **Config source** | Pipeline variable `MEAM_REPORT_CONFIG_JSON` (mark as secret) **or** committed config file |
| **Artifact** | Published as `MEAM-TierReport-<BuildId>` pipeline artifact |
| **Webhook** | Add a follow-up task that posts `generatedReportPath` or the artifact URL to your webhook endpoint using `Invoke-RestMethod` |

**Quick setup:**
```
1. Register a self-hosted Windows agent on a Tier 1 server
   → Azure DevOps → Project Settings → Agent pools → New agent

2. Install RSAT on that server:
   Install-WindowsFeature RSAT-AD-PowerShell, GPMC

3. Configure the agent service to run as svc-meam-report

4. Create a pipeline variable MEAM_REPORT_CONFIG_JSON (secret)
   → Pipeline → Edit → Variables → New variable → Mark as secret
```

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
