# MEAM Tier Architecture Reference

**Complete technical reference for the Monash Enterprise Access Model**

---

## Table of Contents

1. [Three Commandments](#three-commandments)
2. [Tier Structure](#tier-structure)
3. [Zone Definitions](#zone-definitions)
4. [Enforcement Layers](#enforcement-layers-5-defense-depth)
5. [Authentication Flow](#authentication-flow)
6. [Group Naming Convention](#group-naming-convention)
7. [OU Hierarchy](#ou-hierarchy-structure)
8. [GPO Matrix](#gpo-configuration-matrix)
9. [PSO Matrix](#password-settings-objects-pso)
10. [Protected Users Configuration](#protected-users-configuration)
11. [Clean Source Principle](#clean-source-principle)

---

## Three Commandments

The MEAM enforces three core security principles (from Microsoft Enterprise Access Model):

### 1. Credentials from Higher Tier MUST NOT Leak to Lower Tiers

**Commandment:** Tier 0 credentials must NEVER be exposed to Tier 1 or Tier 2 systems.

**Enforcement:**
- T0 admin accounts cannot interactively log in to T1/T2 computers
- T0 accounts denied logon to T1/T2 OUs via GPO User Rights Assignment
- Smartcard (PIV) required for all T0 logons (not cached on disk)
- Credential Guard + Virtualization-Based Security on T0 PAWs

**Example Violation:**
```
❌ T0 admin RDP to T1 server (credential exposed if T1 compromised)
❌ T0 credentials in plaintext on T2 workstation
✅ T0 admin uses isolated PAW, never touches T1/T2
```

### 2. Lower-Tier Credentials CAN Use Higher-Tier Services (One-Way Flow)

**Commandment:** T2 systems can authenticate to T1/T0 services, but not vice versa.

**What this allows:**
- T2 workstation applies Group Policy from T0 Domain Controller ✅
- T2 workstation Kerberos authenticates to T0 KDC ✅
- T1 server uses T0 PKI for certificates ✅
- T1 server replicates from T0 DC ✅

**What this prevents:**
- T0 service authenticating via T2 account ❌
- T1 admin account managing T0 infrastructure ❌
- T2 system trusting T1-signed certs ❌

### 3. Any System Managing a Higher Tier IS a Member of That Tier

**Commandment:** Hypervisors hosting T0 VMs are Tier 0 assets. Their admins are T0 admins.

**Real-world examples:**
- vCenter managing DC VMs → vCenter is T0 → vCenter admins are T0 admins
- Nutanix CVM hosting DC VMs → Nutanix is T0 → Nutanix admins are T0 admins
- Backup appliance with access to T0 database → Backup is T0 → Its admins are T0 admins
- Hypervisor ESXi managing T1 servers → ESXi is T1 → ESXi admins are T1 admins

**Impact:**
- These systems require same hardening/restrictions as the tier they manage
- Administrative access to these systems must be treated as T0/T1 level privilege
- Compromise of these systems = compromise of entire tier

---

## Tier Structure

### Hierarchical Three-Tier Model

```
┌─────────────────────────────────────────────────────────────────────┐
│  TIER 0 — Control Plane (Highest Trust)                             │
│                                                                      │
│  Assets:  Domain Controllers, PKI/ADCS, ADFS, Entra Connect         │
│           vCenter, Nutanix, ESXi (hosting T0 VMs)                   │
│                                                                      │
│  PAW:     PAW-T0                                                    │
│           - Smartcard (PIV) required ✓                              │
│           - Windows Defender Application Control (WDAC) ✓           │
│           - Credential Guard ✓                                      │
│           - No internet access ✓                                    │
│           - U-2 (physically isolated) ✓                             │
│           - Air-gapped for top secrets ✓                            │
│                                                                      │
│  Admins:  Enterprise Admins, Domain Admins (at this tier only)      │
│           Schema Admins, Audit Admins                               │
│                                                                      │
│  Auth:    Kerberos only (no NTLM fallback)                          │
│           4-hour TGT lifetime (via Protected Users)                 │
│           Must use AES-256 encryption minimum                       │
├─────────────────────────────────────────────────────────────────────┤
│  TIER 1 — Management Plane (High Trust)                             │
│                                                                      │
│  Assets:  App Servers, File Servers, DNS, SCCM/Intune Infrastructure│
│           Backup Servers, Exchange, SQL                             │
│           Enterprise firewall, load balancers                       │
│                                                                      │
│  PAW:     PAW-T1                                                    │
│           - Credential Guard ✓                                      │
│           - LAPS (30-day rotation) ✓                                │
│           - AppLocker (whitelisting) ✓                              │
│           - Limited internet (filtered outbound) ✓                  │
│                                                                      │
│  Admins:  Delegated admins per service/function                     │
│           No universal Domain Admins here                           │
│           Separated by zone (1A, 1B, 1C, 1D)                        │
│                                                                      │
│  Auth:    Kerberos preferred, NTLMv2 allowed if required            │
│           8-hour TGT lifetime (via Protected Users)                 │
│                                                                      │
│  Managed: By T0 infrastructure (DCs, PKI, GPO from T0)              │
├─────────────────────────────────────────────────────────────────────┤
│  TIER 2 — Workload Plane (Standard Trust)                           │
│                                                                      │
│  Assets:  End-user workstations, kiosks                             │
│           Business application servers (non-T1 managed)             │
│           Departmental file shares                                  │
│                                                                      │
│  PAW:     None (end-users, not admins)                              │
│                                                                      │
│  Admins:  T2 helpdesk (limited local admin on workstations)         │
│           Service desk (password reset, etc.)                       │
│           Supervised by T1 admins                                   │
│                                                                      │
│  Auth:    Kerberos preferred, NTLMv2 allowed                        │
│           16-hour TGT lifetime                                      │
│           Standard user encryption (AES accepted)                   │
│                                                                      │
│  Managed: By T1 infrastructure (GPO, SCCM/Intune from T1)           │
└─────────────────────────────────────────────────────────────────────┘
```

### Key Principles Per Tier

| Principle | T0 | T1 | T2 |
|-----------|----|----|-----|
| **Physical isolation** | ✅ Yes | ⚠️ Partial | ❌ Standard |
| **Smartcard required** | ✅ Mandatory | ❌ No | ❌ No |
| **Credential Guard** | ✅ Enforced | ✅ Enforced | ⚠️ Enabled |
| **LAPS rotation** | ❌ N/A (smartcard) | ✅ 30 days | ✅ 30 days |
| **Internet access** | ❌ None | ⚠️ Filtered | ✅ Full |
| **NTLM allowed** | ❌ No | ⚠️ Limited | ✅ Yes |
| **Local admin** | ✅ Required | ✅ Yes | ⚠️ Limited |
| **Managed by** | N/A (root) | T0 infrastructure | T1 infrastructure |

---

## Zone Definitions

Zones provide **horizontal microsegmentation within tiers** using separate Authentication Policy Silos. An account in one zone **cannot** authenticate to systems in another zone (unless bridged by higher tier).

### Zone Structure by Tier

#### Tier 0 Zones (2 zones)

| Zone | Name | Systems | Purpose | Auth Silo |
|------|------|---------|---------|-----------|
| **0A** | Domain Management | DCs, ADFS, ADCS, Entra Connect, Key Management Service | Core identity & PKI infrastructure | Zone-Silo-0A |
| **0B** | Hypervisor Management | vCenter, Nutanix CVM, ESXi hosts, storage fabric | Virtual infrastructure hosting T0 assets | Zone-Silo-0B |

**Why separate?**
- Zone 0A admin cannot access hypervisors (contain infra compromise)
- Zone 0B admin cannot modify AD (contain virtualization compromise)
- Both are T0, but compartmentalized

#### Tier 1 Zones (4 zones)

| Zone | Name | Systems | Purpose | Auth Silo |
|------|------|---------|---------|-----------|
| **1A** | Workstation Management | SCCM/Intune infrastructure, MDT servers, image deployment | Management of end-user devices | Zone-Silo-1A |
| **1B** | Server Management | App servers, file servers, mail servers, database servers | General production servers | Zone-Silo-1B |
| **1C** | DNS Management | Dedicated DNS servers (authoritative, resolvers) | Separated DNS infrastructure | Zone-Silo-1C |
| **1D** | Storage Management | NAS (NetApp, EMC), SAN fabric, backup appliances | Storage & backup infrastructure | Zone-Silo-1D |

**Why separated?**
- Zone 1B admin managing a compromised app server cannot access DNS (contain app compromise)
- Zone 1C admin cannot modify SCCM (contain DNS manipulation)
- Zone 1D backup admin cannot access app server repositories (contain data exfiltration)
- Reduces blast radius of each service compromise

#### Tier 2 Zones (2 zones)

| Zone | Name | Systems | Purpose | Auth Silo |
|------|------|---------|---------|-----------|
| **2A** | Workstations | End-user workstations, thin clients, kiosks | Standard user computing | Zone-Silo-2A |
| **2B** | Business Servers | Non-T1-managed application servers, departmental systems | Line-of-business applications | Zone-Silo-2B |

---

## Enforcement Layers (5 Defense-in-Depth)

### Layer 1: Kerberos Armoring (FAST) — PREREQUISITE

**Technology:** Flexible Authentication Secure Tunneling (FAST) per RFC 6113

**What it does:**
- Wraps Kerberos pre-authentication in encrypted & integrity-protected tunnel
- Prevents packet capture & replay attacks during logon
- Enables other advanced Kerberos protections

**How enforced:**
```
DC (KDC):  GPO → KDC support for FAST = Enabled
           Registry: HKLM\SYSTEM\CurrentControlSet\Services\Kdc
           - SCForceOptions = 1 (FAST required)

Client:    GPO → Kerberos client support for FAST = Enabled
           Sends FAST-armored pre-auth requests
```

**Impact if missing:**
- Advanced Auth Policies don't work
- Protection against AS-REP roasting fails
- PKINIT attacks possible

**Minimum requirements:**
- Domain Controllers: Windows Server 2012 R2+
- Clients: Windows 7 SP1+, macOS 10.7+, Linux (MIT Kerberos 1.13+)

### Layer 2: Authentication Policy Silos — KDC-Level Enforcement

**Technology:** Active Directory Authentication Policy Silos (Server 2012 R2+)

**What they do:**
- KDC (ticket-granting service) checks silo membership BEFORE issuing tickets
- Impossible to bypass with local admin (enforced at domain-wide KDC)
- Supports conditional logic (computer + user + time-based)

**Silos in MEAM:**

```
PAW Silos (vertical isolation):
├── PAW-Silo-T0   → Only PAW-T0 devices + T0 admin accounts
├── PAW-Silo-T1   → Only PAW-T1 devices + T1 admin accounts
└── PAW-Silo-T2   → Only PAW-T2 devices (if applicable)

Zone Silos (horizontal isolation):
├── Zone-Silo-0A  → Only Zone 0A users + Zone 0A computers
├── Zone-Silo-0B  → Only Zone 0B users + Zone 0B computers
├── Zone-Silo-1A  → Only Zone 1A users + Zone 1A computers
├── Zone-Silo-1B  → Only Zone 1B users + Zone 1B computers
├── Zone-Silo-1C  → Only Zone 1C users + Zone 1C computers
├── Zone-Silo-1D  → Only Zone 1D users + Zone 1D computers
├── Zone-Silo-2A  → Only Zone 2A users + Zone 2A computers
└── Zone-Silo-2B  → Only Zone 2B users + Zone 2B computers
```

**Enforcement example:**
```
Zone 1B admin tries to log into Zone 1C (DNS) server:

1. Computer: Zone-1C-Server
   Silo: Zone-Silo-1C
   Allowed: @(Zone 1C users + computers)

2. User: adm-1b-admin (Zone 1B admin)
   Silo: Zone-Silo-1B
   Allowed: @(Zone 1B users + computers)

3. KDC check: User@Zone1B cannot auth to Computer@Zone1C
   Result: TGT DENIED (KRB5KDC_ERR_POLICY)
   ❌ Authentication fails at KDC level
```

**TGT Lifetimes:**
- T0: 60 minutes (most sensitive)
- T1: 120 minutes (management)
- T2: 240 minutes (workload)

**All silos set to:** ENFORCE (not audit)

### Layer 3: GPO User Rights Assignment (5 Deny Logon Rights)

**Technology:** Group Policy + Local Security Policy

**What it does:**
- Prevents denied groups from logging in via 5 different logon types
- Windows enforcement (not KDC-level), adds defense-in-depth
- Catches bypasses of Kerberos or local exploits

**The 5 Deny Rights:**

| Right | Blocks | Used For |
|-------|--------|----------|
| **SeDenyInteractiveLogonRight** | Interactive logon (Ctrl+Alt+Del) | Local console access |
| **SeDenyRemoteInteractiveLogonRight** | Remote interactive (RDP, SSH) | Remote desktop/terminal |
| **SeDenyNetworkLogonRight** | Network logon (\\\\server) | UNC paths, file shares |
| **SeDenyBatchLogonRight** | Batch (scheduled tasks) | RUNAS / Task Scheduler |
| **SeDenyServiceLogonRight** | Service account logon | Windows Services |

**Applied per tier:**

```
T0 Domain Controllers (GPO-T0-DenyLowerTier-Logon):
├── SeDenyInteractiveLogonRight       ← T1+T2 groups
├── SeDenyRemoteInteractiveLogonRight ← T1+T2 groups
├── SeDenyNetworkLogonRight           ← T1+T2 groups
├── SeDenyBatchLogonRight             ← T1+T2 groups
└── SeDenyServiceLogonRight           ← T1+T2 groups
    Result: T1/T2 admins cannot log in to DCs in ANY way

T1 Servers (GPO-T1-DenyT2-Logon):
├── SeDenyInteractiveLogonRight       ← T2 groups
├── SeDenyRemoteInteractiveLogonRight ← T2 groups
├── SeDenyNetworkLogonRight           ← T2 groups
├── SeDenyBatchLogonRight             ← T2 groups
└── SeDenyServiceLogonRight           ← T2 groups
    Result: T2 users cannot log in to T1 servers in ANY way

T2 Workstations (GPO-T2-DenyT0T1-Logon):
├── SeDenyInteractiveLogonRight       ← T0+T1 groups
├── SeDenyRemoteInteractiveLogonRight ← T0+T1 groups
├── SeDenyNetworkLogonRight           ← T0+T1 groups
├── SeDenyBatchLogonRight             ← T0+T1 groups
└── SeDenyServiceLogonRight           ← T0+T1 groups
    Result: T0/T1 admins cannot log in to T2 workstations
```

**Why both SeDenyBatchLogonRight AND SeDenyServiceLogonRight?**
- **SeDenyBatchLogonRight:** Blocks scheduled tasks (which run as users)
- **SeDenyServiceLogonRight:** Blocks Windows service accounts

Both can expose credentials in memory! Critical for T0/T1.

### Layer 4: Protected Users Security Group

**Technology:** AD Security Group (Server 2008+) with special KDC treatment

**What it does:**
- Members automatically get stronger security settings enforced by KDC
- NTLM disabled (Kerberos only)
- RC4 & DES encryption disabled (AES required)
- Unconstrained Kerberos delegation disabled
- 4-hour TGT maximum lifetime (non-renewable)

**MEAM configuration:**
- All T0 role groups nested into Protected Users
- All T1 role groups nested into Protected Users
- T2 helpdesk groups: optional (add if sensitive functions)

**Nested structure example:**
```
Protected Users (AD group)
├── T0-ROLE-AD-Admins
│   ├── adm-t0-admin01
│   ├── adm-t0-admin02
│   └── PAW-T0-Users
├── T0-ROLE-Hyper-Admins
│   ├── adm-t0-hyper01
│   └── PAW-T0-Users
├── T1-ROLE-Server-Admins
│   ├── adm-t1-srv01
│   └── PAW-T1-Users
├── T1-ROLE-DNS-Admins
│   ├── adm-t1-dns01
│   └── PAW-T1-Users
└── [other T0/T1 role groups]
```

**Impact on authentication:**
```
Before Protected Users:
✓ NTLM auth allowed
✓ RC4 encryption allowed
✓ Unconstrained delegation allowed
✓ 10-hour TGT lifetime possible

After Protected Users:
✗ NTLM auth BLOCKED (Kerberos only)
✗ RC4 encryption BLOCKED (AES required)
✗ Unconstrained delegation BLOCKED
✗ 4-hour TGT max (non-renewable)
```

### Layer 5: NTLM Restriction (GPO)

**Technology:** Group Policy + Registry

**What it does:**
- Progressively restricts NTLM usage
- Audit → Warn → Block progression
- Registry: `HKLM\SYSTEM\CurrentControlSet\Control\Lsa → LmCompatibilityLevel`

**Progression:**

```
Phase 1 (Audit):
├── NTLMv1: Audit all attempts
└── NTLMv2: Audit all attempts
    Result: Applications using NTLM are logged, not blocked

Phase 2 (Restrict):
├── NTLMv1: BLOCKED everywhere
├── NTLMv2: Allowed only to specific whitelisted servers
└── Registry: HKLM\SYSTEM\CurrentControlSet\Control\Lsa
    Value: RestrictNTLMIncomingTraffic = 1 (Audit)
    Value: RestrictNTLMOutgoingTraffic = 1 (Audit)

Phase 3 (Enforce):
├── NTLMv1: BLOCKED everywhere
├── NTLMv2: BLOCKED unless whitelisted
└── Registry: LmCompatibilityLevel = 5 (NTLMv2 minimum)
    Value: RestrictNTLMIncomingTraffic = 3 (Deny all)
    Value: RestrictNTLMOutgoingTraffic = 3 (Deny all)
```

**MEAM default:** LmCompatibilityLevel = 5 (NTLMv2 minimum, no NTLMv1)

---

## Authentication Flow

### Successful T0 Admin Logon (Happy Path)

```
T0 Admin (adm-t0-admin01) logs on to PAW-T0

1. CLIENT SIDE:
   ├─ User inserts smartcard (PIV)
   ├─ Provides PIN
   ├─ PowerShell: kinit adm-t0-admin01@CORP.EXAMPLE.COM
   └─ Client builds FAST-armored AS-REQ

2. AS-REQ (Initial TGT request):
   ├─ Transport: FAST-armored tunnel (encrypted)
   ├─ Contents: User name, realm, timestamp, smartcard cert
   └─ Encryption: AES-256-CTS-HMAC-SHA1-96

3. KDC (Domain Controller):
   ├─ Validates FAST armor (✓ from PAW-T0 computer)
   ├─ Checks Authentication Policy:
   │  ├─ Is adm-t0-admin01 in PAW-Silo-T0? → YES
   │  ├─ Is PAW-T0 in PAW-Silo-T0? → YES
   │  └─ Encryption type: AES? → YES
   ├─ Checks Protected Users:
   │  ├─ Account in Protected Users? → YES
   │  ├─ NTLM allowed? → NO (blocked)
   │  ├─ RC4 allowed? → NO (blocked)
   │  └─ TGT lifetime: 60 minutes (T0 max)
   ├─ Issues TGT (Ticket Granting Ticket)
   └─ All encryption: AES-256

4. CLIENT RECEIVES:
   ├─ TGT issued (60 min lifetime)
   ├─ Session key: AES-256
   └─ klist tgt
      Principal: adm-t0-admin01@CORP.EXAMPLE.COM
      Ticket Encryption Type: AES-256-CTS-HMAC-SHA1-96
      Start Time: 2:15:32 PM
      End Time: 3:15:32 PM
      Renew Time: None (non-renewable)

5. ADMIN CAN NOW:
   ✓ Access DC (authenticated with AES-encrypted TGT)
   ✓ Run domain administration tools (ADAC, Active Directory Users & Computers)
   ✓ Delegate authentication to services (using Kerberos only)
   ✗ Cannot access T1/T2 systems (Auth Silos prevent cross-tier access)
```

### Failed T1 Admin Logon (Violation)

```
T1 Admin (adm-t1-srv01) tries to log on to T0 Domain Controller

1. CLIENT SIDE:
   ├─ User tries: net use \\DC01\c$
   └─ Client builds AS-REQ

2. AS-REQ sent to KDC

3. KDC (Domain Controller):
   ├─ Receives: adm-t1-srv01 trying to access DC01
   ├─ Checks Authentication Policy:
   │  ├─ Is adm-t1-srv01 in Zone-Silo-0A? → NO
   │  ├─ Allowed silos: Zone-Silo-0A, PAW-Silo-T0
   │  ├─ User's silos: Zone-Silo-1B, PAW-Silo-T1
   │  └─ Match? NO ❌
   └─ DENY authentication

4. KDC RESPONSE:
   ├─ Error: KRB5KDC_ERR_POLICY
   ├─ Message: "Authentication policy forbids"
   └─ Returned to client

5. CLIENT RESULT:
   ❌ Access denied
   ❌ No logon occurs (stopped at KDC level)
   ❌ Event logged on DC: Event ID 4823 (policy denied)
```

### Cross-Zone Lateral Movement Attempt (Blocked)

```
Zone 1B Server Admin (adm-1b-srv01) tries to RDP to Zone 1C (DNS) server

1. Logon attempt: mstsc /v:dns-server.corp.example.com

2. KDC:
   ├─ Checks: Computer "dns-server" in silo? → Zone-Silo-1C
   ├─ Checks: User "adm-1b-srv01" in silo? → Zone-Silo-1B
   ├─ Match? NO ❌
   └─ TGT denied (KRB5KDC_ERR_POLICY)

3. Windows (dns-server):
   ├─ Receives failed Kerberos auth
   ├─ Tries NTLM fallback? → NO (Protected Users blocks it)
   └─ Connection closed

4. Result:
   ❌ RDP fails (cannot even get to credential prompt)
   ❌ Lateral movement contained
   ✓ Blast radius of Zone 1B admin = Zone 1B only
```

---

## Group Naming Convention

Standardized naming allows quick identification of function, scope, and permission level.

### Format: `T[n]-ROLE-[Function]` or `Z[zone]-ROLE-[Function]`

#### Tier Role Groups (Vertical Isolation)

```
T0-ROLE-AD-Admins                   [Active Directory domain admins]
T0-ROLE-Hyper-Admins               [Hypervisor (vCenter/Nutanix) admins]
T1-ROLE-Server-Admins              [General production server admins]
T1-ROLE-DNS-Admins                 [DNS server admins]
T1-ROLE-Exchange-Admins            [Exchange service admins]
T1-ROLE-Backup-Admins              [Backup infrastructure admins]
T2-ROLE-HelpDesk                   [Tier 2 help desk (limited admin)]
T2-ROLE-LocalAdmin-Restricted      [Limited local admin on workstations]
```

#### Zone Role Groups (Horizontal Isolation)

```
Z0A-ROLE-Domain-Controllers        [Zone 0A (AD) admins]
Z0B-ROLE-Hypervisor-Admins         [Zone 0B (hypervisor) admins]
Z1A-ROLE-Workstation-Mgmt          [Zone 1A (SCCM/MDT) admins]
Z1B-ROLE-Server-Mgmt               [Zone 1B (app/file servers) admins]
Z1C-ROLE-DNS-Mgmt                  [Zone 1C (DNS) admins]
Z1D-ROLE-Storage-Mgmt              [Zone 1D (backup/storage) admins]
```

#### Delegation Groups (Per-Service Permission)

```
Z1B-DLG-AppServers-Computers-Create
Z1B-DLG-AppServers-Users-PasswordReset
Z1C-DLG-DNS-Records-Create
Z1D-DLG-Backup-Servers-BitLockerRead
```

**Pattern:** `Z[zone]-DLG-[Service]-[ObjectType]-[Permission]`

- **ObjectType:** Computers, Users, Groups, Services
- **Permission:** Create, Read, Write, Delete, PasswordReset, Enable, Disable, etc.

#### PAW Groups

```
PAW-T0-Users                        [T0 admin users allowed on PAW-T0]
PAW-T1-Users                        [T1 admin users allowed on PAW-T1]
PAW-T2-Users                        [T2 admin users allowed on PAW-T2]
```

#### ACL Access Groups

```
Z1B-ACL-LAPS-Read                   [Allowed to read LAPS passwords in Zone 1B]
Z1D-ACL-Backup-Vault-Access        [Allowed to access backup vault]
Z2A-ACL-GPO-Edit                    [Allowed to edit Zone 2A GPOs]
```

#### GPO Edit Groups

```
Z1C-GPO-DNS-Edit                    [Allowed to edit DNS GPOs]
Z1B-GPO-Servers-Edit                [Allowed to edit server GPOs]
Z2A-GPO-Workstations-Edit           [Allowed to edit workstation GPOs]
```

### 18 Per-Service Delegation Groups Per Zone

Each service in a zone has **18 delegation groups**:

#### For Computer Objects (9):
1. DomainJoin
2. Read
3. Write
4. Delete
5. MoveOU
6. BitLockerRead
7. LAPSRead
8. LAPSReset
9. GroupMembership

#### For User Objects (9):
1. Create
2. Delete
3. Read
4. Write
5. PasswordReset
6. Unlock
7. Enable
8. Disable
9. GroupMembership

**Example:**
```
Zone 1B Server Management service "AppServers":
├── Z1B-DLG-AppServers-Computers-DomainJoin     [Can join computers]
├── Z1B-DLG-AppServers-Computers-Read           [Can query computers]
├── Z1B-DLG-AppServers-Computers-Write          [Can modify computers]
├── Z1B-DLG-AppServers-Computers-LAPSRead       [Can read LAPS pwd]
├── Z1B-DLG-AppServers-Computers-BitLockerRead  [Can read BitLocker]
├── Z1B-DLG-AppServers-Users-Create             [Can create users]
├── Z1B-DLG-AppServers-Users-PasswordReset      [Can reset pwd]
├── Z1B-DLG-AppServers-Users-Enable             [Can enable accounts]
└── Z1B-DLG-AppServers-Users-Disable            [Can disable accounts]

Assigned to: Delegated admin for Zone 1B AppServers (e.g., app support team)
```

---

## OU Hierarchy Structure

The OU tree follows a clear logical structure for policy application and access control.

```
DC=corp,DC=example,DC=com
│
└── OU=Corp                                    [Main organizational unit]
    │
    ├── OU=Tiers                               [Container for all tier OUs]
    │   │
    │   ├── OU=Tier 0                          [Control plane]
    │   │   ├── OU=PAWs
    │   │   │   ├── OU=Computers
    │   │   │   ├── OU=Accounts
    │   │   │   └── OU=Groups
    │   │   │
    │   │   ├── OU=Zone 0A (Domain Mgmt)
    │   │   │   ├── OU=Computers
    │   │   │   ├── OU=Accounts
    │   │   │   ├── OU=Service Accounts
    │   │   │   ├── OU=Groups
    │   │   │   │   ├── OU=Roles
    │   │   │   │   └── OU=Delegation
    │   │   │   ├── OU=Services
    │   │   │   │   ├── OU=DomainControllers
    │   │   │   │   └── OU=PKI
    │   │   │   └── OU=GPO Edit Permissions
    │   │   │
    │   │   └── OU=Zone 0B (Hypervisor Mgmt)
    │   │       ├── OU=Computers
    │   │       ├── OU=Accounts
    │   │       └── OU=Groups
    │   │
    │   ├── OU=Tier 1                          [Management plane]
    │   │   ├── OU=PAWs
    │   │   │   ├── OU=Zone 1A PAWs
    │   │   │   ├── OU=Zone 1B PAWs
    │   │   │   ├── OU=Zone 1C PAWs
    │   │   │   └── OU=Zone 1D PAWs
    │   │   │
    │   │   ├── OU=Zone 1A (Workstation Mgmt)
    │   │   │   ├── OU=Computers
    │   │   │   ├── OU=Accounts
    │   │   │   ├── OU=Service Accounts
    │   │   │   ├── OU=Groups
    │   │   │   │   ├── OU=Roles
    │   │   │   │   └── OU=Delegation
    │   │   │   └── OU=Services (SCCM, MDT, etc.)
    │   │   │
    │   │   ├── OU=Zone 1B (Server Mgmt)
    │   │   ├── OU=Zone 1C (DNS Mgmt)
    │   │   └── OU=Zone 1D (Storage Mgmt)
    │   │       [Same structure as 1A for each]
    │   │
    │   └── OU=Tier 2                          [Workload plane]
    │       ├── OU=Zone 2A (Workstations)
    │       │   ├── OU=Computers
    │       │   ├── OU=Accounts
    │       │   └── OU=Groups
    │       │
    │       └── OU=Zone 2B (Business Servers)
    │           ├── OU=Computers
    │           ├── OU=Accounts
    │           └── OU=Groups
    │
    ├── OU=Users                               [Non-tier users]
    │   ├── OU=Standard
    │   ├── OU=VIP
    │   └── OU=External
    │
    ├── OU=Groups                              [Non-tier groups]
    │   ├── OU=Distribution
    │   └── OU=Security
    │
    └── OU=Service Accounts                    [Non-tier service accounts]
        ├── OU=Applications
        ├── OU=Infrastructure
        └── OU=Business Services
```

### Key ACL Breaks

Break inheritance on these OUs to prevent accidental privilege escalation:

```
✓ Break at:  OU=Tiers (and all tier OUs)
             OU=Corp (root organizational unit)
             OU=Zone * (each zone)

Result:  Only explicitly delegated admins can modify tier-specific objects
         Prevents domain-wide accidental deletions or modifications
```

---

## GPO Configuration Matrix

### GPO Naming Convention

`GPO-[Tier]-[Function]-[SubFunction]`

Examples:
- `GPO-T0-DenyLowerTier-Logon` (deny T1/T2 from T0 systems)
- `GPO-T1-Servers-Baseline` (secure baseline for T1 servers)
- `GPO-T2-Workstations-LAPS` (local admin password service for T2)

### Complete GPO Deployment Matrix

| GPO Name | Linked OU | Scope | Key Settings | Enforced |
|----------|-----------|-------|--------------|----------|
| **GPO-T0-DenyLowerTier-Logon** | OU=Tier 0 | Deny T1+T2 | 5 deny logon rights | Yes |
| **GPO-T0-PAW-Baseline** | OU=PAWs (Tier 0) | Hardening | WDAC, CG, smartcard | Yes |
| **GPO-T0-Kerberos-FAST** | OU=Tier 0 | Auth | KDC FAST, 60min TGT | Yes |
| **GPO-T0-AuditPolicy** | OU=Domain Controllers | Logging | 15 audit categories | Yes |
| **GPO-T0-NTLM-Restrict** | OU=Tier 0 | Auth | NTLMv1 block, v2 limit | Yes |
| **GPO-T1-DenyT2-Logon** | OU=Tier 1 | Deny T2 | 5 deny logon rights | Yes |
| **GPO-T1-PAW-Baseline** | OU=PAWs (Tier 1) | Hardening | CG, LAPS, AppLocker | Yes |
| **GPO-T1-Servers-Baseline** | OU=Tier 1 | Hardening | LSA protection, CG, security | Yes |
| **GPO-T1-Kerberos-Policy** | OU=Tier 1 | Auth | 120min TGT, AES required | Yes |
| **GPO-T1-LAPS** | OU=Tier 1 | Local Admin | 30-day rotation, 20-char | Yes |
| **GPO-T1-Firewall** | OU=Tier 1 | Network | Inbound/outbound rules | Yes |
| **GPO-T2-DenyT0T1-Logon** | OU=Tier 2 | Deny T0+T1 | 5 deny logon rights | Yes |
| **GPO-T2-Workstation-Baseline** | OU=Zone 2A | Hardening | CG, LSA, WDAC audit | Yes |
| **GPO-T2-LAPS** | OU=Tier 2 | Local Admin | 30-day rotation, 20-char | Yes |
| **GPO-T2-Kerberos-Policy** | OU=Tier 2 | Auth | 240min TGT | No (audit) |
| **GPO-T2-CredentialGuard** | OU=Zone 2A | Hardening | VBS + CG enforced | No (recommended) |

---

## Password Settings Objects (PSO)

Fine-grained password policies per group.

| PSO Name | Precedence | Min Length | Max Age | Lockout | Applied To |
|----------|-----------|------------|---------|---------|-----------|
| **PSO-Tier0** | 1 | 20 chars | 180 days | None (smartcard) | T0 role groups |
| **PSO-Tier1** | 2 | 14 chars | 180 days | 5 attempts/30min | T1 role groups |
| **PSO-Tier2** | 3 | 12 chars | 180 days | 5 attempts/30min | T2 role groups |
| **PSO-SvcAccts** | 4 | 30 chars | 365 days | None | Service account groups |

---

## Protected Users Configuration

### Auto-Enforced Features

When an account is member of Protected Users group, the KDC automatically enforces:

| Feature | Effect |
|---------|--------|
| **NTLM authentication** | Disabled (Kerberos only) |
| **RC4 encryption** | Disabled (AES required) |
| **DES encryption** | Disabled (AES required) |
| **Unconstrained delegation** | Disabled (cannot delegate further) |
| **TGT lifetime** | Maximum 4 hours (non-renewable) |
| **Pre-authentication required** | Yes (PA-DATA) |
| **Armor support required** | Yes (FAST) |

### Nesting Structure

```
Protected Users (well-known security group)
│
├── [All T0 role groups]
│   ├── T0-ROLE-AD-Admins
│   ├── T0-ROLE-Hyper-Admins
│   └── [other T0 roles]
│
├── [All T1 role groups]
│   ├── T1-ROLE-Server-Admins
│   ├── T1-ROLE-DNS-Admins
│   ├── T1-ROLE-Exchange-Admins
│   └── [other T1 roles]
│
└── [Optional T2 sensitive groups]
    └── T2-ROLE-SecurityAudit (if needed)
```

---

## Clean Source Principle

### Definition

**Every security dependency must be as trustworthy as the object being secured.**

In practice: Anything that **can manage** Tier 0 **must be** Tier 0.

### Examples

#### Example 1: Database Server Hosting T0 Data

```
Scenario: SQL Server contains AD restore database

Classification:
├─ System: SQL Server
├─ Data: AD database (T0 sensitive)
├─ Access: SQL Admins can restore/backup AD
├─ Inference: SQL admins can compromise AD
└─ Conclusion: SQL = T0 asset

Implication:
├─ SQL server must be in Zone 0A or 0B
├─ SQL admins must be T0-ROLE-* group members
├─ SQL must use smartcard authentication
└─ SQL must have same hardening as DC
```

#### Example 2: vCenter Managing DC VMs

```
Scenario: vCenter hosts all DC virtual machines

Classification:
├─ System: vCenter hypervisor
├─ Control: Hosts T0 DC VMs
├─ Access: vCenter admin can shut down/manipulate DCs
├─ Inference: vCenter admin can compromise AD
└─ Conclusion: vCenter = T0 asset

Implication:
├─ vCenter must be Zone 0B
├─ vCenter admins must be T0-ROLE-Hyper-Admins
├─ vCenter must use Kerberos + smartcard
├─ vCenter must have T0 network isolation
└─ vCenter must have T0 server hardening
```

#### Example 3: Backup Appliance with AD Access

```
Scenario: Backup appliance can restore AD database

Classification:
├─ System: Backup appliance
├─ Control: Can restore entire AD
├─ Access: Backup admins control restoration
├─ Inference: Backup admin can compromise AD
└─ Conclusion: Backup = T0 asset

Implication:
├─ Backup must be in Zone 0A or 0B
├─ Backup admins = T0 role members
├─ Backup access requires T0 PAW logon
└─ Backup credentials must use smartcard
```

#### Example 4: SCCM Managing T1 Servers

```
Scenario: SCCM deploys software to all T1 servers

Classification:
├─ System: SCCM infrastructure
├─ Control: Can push code to T1 systems
├─ Access: SCCM admin can manipulate all T1 servers
├─ Inference: SCCM compromise = T1 compromise
└─ Conclusion: SCCM = T1 asset

Implication:
├─ SCCM must be in Zone 1A
├─ SCCM admins must be T1-ROLE-* group members
├─ SCCM must use Protected Users
└─ SCCM must have T1 server hardening
```

### Application to Vendor Software

When evaluating any administrative tool:

```
Ask: "Can this tool/admin impact a higher tier?"

YES → Assign to that tier + same restrictions
  ├─ Backup software managing T0 → Tier 0
  ├─ Monitoring tool with T1 access → Tier 1
  ├─ Patch management tool for all tiers → Tier 0 (can push to DCs)
  └─ Vendor support access → Tier equal to what they can access

NO → Assign to current tier
  ├─ T2 workstation management tool → Tier 2
  ├─ Departmental file server admin tool → Tier 2
  └─ Local printer management → Tier 2
```

---

**Document Version:** 1.0  
**Last Updated:** 2026-05-18  
**Next Review:** 2027-05-18
