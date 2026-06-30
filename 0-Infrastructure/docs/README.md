# 0-Infrastructure — Lab Setup Guide

Vagrant-based brownfield Active Directory lab for MEAM tiering development and testing.
Three VMs, one-button deployment. Total provision time: ~40 minutes.

---

## VM Inventory

| VM       | IP             | Role                           | RAM  | Provision time |
|----------|----------------|--------------------------------|------|----------------|
| dc01     | 192.168.56.10  | Primary DC / PDC Emulator      | 4 GB | ~20 min        |
| dc02     | 192.168.56.11  | Secondary DC                   | 2 GB | ~10 min        |
| member01 | 192.168.56.20  | Member server / test target    | 2 GB | ~8 min         |

---

## Prerequisites

| Tool | Minimum version | Notes |
|------|-----------------|-------|
| Vagrant | 2.3+ | https://developer.hashicorp.com/vagrant/downloads |
| VirtualBox | 7.0+ | Intel Mac / Windows / Linux |
| VMware Fusion 13 Free | | Apple Silicon Mac — recommended |
| vagrant-vmware-desktop | latest | `vagrant plugin install vagrant-vmware-desktop` |

---

## Quick Start

```powershell
# One-button full deploy (provisions all three VMs in parallel where possible)
vagrant up

# Preferred: sequential order for cleaner dependency management
vagrant up dc01          # ~20 min — MUST complete before dc02 / member01
vagrant up dc02          # ~10 min
vagrant up member01      # ~8  min
```

---

## Credentials

| Account | Password | Notes |
|---------|----------|-------|
| `CONTOSO\Administrator` | `P@ssw0rd!Contoso2024` | Domain admin (all VMs) |
| DSRM (both DCs) | `P@ssw0rd!DSRM2024` | Directory Services Restore Mode |
| `vagrant` | `vagrant` | WinRM / local admin |
| All brownfield users | `LabUser2024!` | e.g. john.smith, carol.white |
| All service accounts | `SvcP@ss2024!` | e.g. svc-sql, svc-backup |
| Break glass (post-MEAM) | `B!gBr3@kGl@ss!L@b2024!` | brk-glass-01 / brk-glass-02 |

---

## Domain: contoso.local (CONTOSO)

| Attribute | Value |
|-----------|-------|
| Forest root | contoso.local |
| NetBIOS name | CONTOSO |
| Domain Functional Level | Windows2016Domain |
| Forest Functional Level | Windows2016Forest |
| KDS Root Key | Created (gMSA-ready) |
| AD Recycle Bin | Enabled |
| DNS Forwarder | 8.8.8.8 / 1.1.1.1 |

---

## What the Brownfield Contains

### OU Structure (flat/messy — no tiering)

```
contoso.local
├─ IT/
│  ├─ IT-Users/          # IT staff accounts
│  ├─ IT-Servers/        # SQL01, APP01, APP02, FILE01, BACKUP01
│  └─ Workstations/      # IT-owned workstations
├─ Finance/              # Finance users
├─ HR/                   # HR users
├─ Operations/           # Operations users
├─ Sales/                # Sales users
├─ Service Accounts/     # All svc-* accounts (flat, no tier separation)
├─ Legacy/               # Stale / orphaned accounts
└─ CN=Computers          # WKS001-005, LAPTOP001-002 (never moved — brownfield)
```

### Users (25 accounts)

| SAM | Department | Issue |
|-----|-----------|-------|
| john.smith | IT | Directly in Domain Admins; same account for email and admin |
| jane.doe | IT | Directly in Domain Admins |
| bob.jones | IT | Server Operators member |
| alice.anderson | IT | Account Operators member (over-privileged helpdesk) |
| mike.wilson | IT | DnsAdmins member (lateral-movement path) |
| frank.brown | Finance | Infrequent logon — stale risk |
| old.sysadmin | Legacy | Left company 2022, account still ENABLED |
| temp.contractor1 | Legacy | Contract ended 2023, account still ENABLED |
| test.account | (Users CN) | Left in production; PasswordNotRequired |
| + 16 others | Finance/HR/Ops/Sales | Standard users |

### Service Accounts (8 accounts) — all non-gMSA anti-patterns

| SAM | Critical Issue |
|-----|----------------|
| svc-sql | Domain Admins member + Kerberoastable SPN |
| svc-vmware | Domain Admins member |
| svc-sccm | Domain Admins member |
| svc-backup | Backup Operators member; PasswordNeverExpires |
| svc-web | Kerberoastable SPN (HTTP/web.contoso.local) |
| svc-monitoring | DoNotRequirePreAuth = TRUE (AS-REP Roasting target) |
| svc-exchange | AllowReversiblePasswordEncryption = TRUE |
| svc-helpdesk | Account Operators member |

### Groups (legacy, no tiering)

`IT-Admins`, `Server-Admins`, `Helpdesk-Staff`, `Network-Admins`,
`Finance-Users`, `HR-Users`, `Sales-Team`, `Operations-Staff`,
`VPN-Access`, `Remote-Desktop-Users`, `Software-Deploy`, `All-Staff`

All in `CN=Users` container (classic brownfield placement).

### Computers

| Name | Location | Issue |
|------|----------|-------|
| SQL01, APP01 | IT-Servers OU | Unconstrained Kerberos delegation enabled |
| APP02, FILE01, BACKUP01 | IT-Servers OU | Untiered |
| WKS001–WKS005, LAPTOP001–002 | CN=Computers | Never moved from default container |

---

## Provisioning Sequence

Each `vagrant up dc01` run executes these scripts in order:

```
01-Promote-DomainController.ps1   ← Install ADDS/DNS + promote forest (reboot)
02-Initialize-Domain.ps1          ← DFL/FFL, KDS key, Recycle Bin, DNS fwdr (reboot)
03-New-BrownfieldObjects.ps1      ← OUs, users, groups, computers
04-Apply-BrownfieldMisconfig.ps1  ← Security anti-patterns (DA svc accounts, SPNs, etc.)
```

```
05-Promote-SecondaryDC.ps1        ← DC02 joins as additional DC (reboot)
06-Join-MemberDomain.ps1          ← MEMBER01 joins domain + installs RSAT (reboot)
```

---

## After Provisioning: Deploy MEAM Tiering

RDP to DC01 (`192.168.56.10`) as `CONTOSO\Administrator` and run:

```powershell
# Validate the config first
.\1-Deployment\New-MEAM-Deployment.ps1 -ConfigPath C:\vagrant-bootstrap\lab.json -ValidateOnly

# Deploy MEAM tiering on top of the brownfield
.\1-Deployment\New-MEAM-Deployment.ps1 -ConfigPath C:\vagrant-bootstrap\lab.json

# Validate the result
.\4-Validation\Test-MEAM-Deployment.ps1 -ConfigPath C:\vagrant-bootstrap\lab.json

# Run compliance scan
.\3-Monitoring\Get-Tiering-Compliance-Report.ps1 -ConfigPath C:\vagrant-bootstrap\Get-Tiering-Compliance-Report.config.example.json
```

Scripts and config are available on DC01 at `C:\vagrant-bootstrap\`.
Reports are written to `C:\vagrant-bootstrap\reports\`.

---

## Troubleshooting

**Vagrant can't connect via WinRM after reboot**
```bash
vagrant reload dc01    # force a clean reconnect
```

**DC02 or MEMBER01 can't find contoso.local**
- Ensure `vagrant up dc01` completed 100% before starting dc02/member01
- Check `192.168.56.10` is reachable: `vagrant ssh dc01 -- ping 192.168.56.10`

**Script fails "Module not found"**
- RSAT is installed on MEMBER01 automatically; on DCs it comes with ADDS
- Manual fallback: `Install-WindowsFeature RSAT-AD-PowerShell`

**Re-provision a single VM**
```bash
vagrant destroy dc01 --force && vagrant up dc01
```

**Re-run a single bootstrap phase (e.g. brownfield objects)**
```powershell
# On DC01 via RDP or WinRM
& 'C:\vagrant-bootstrap\03-New-BrownfieldObjects.ps1'
```
All scripts are idempotent — re-running skips already-existing objects.
