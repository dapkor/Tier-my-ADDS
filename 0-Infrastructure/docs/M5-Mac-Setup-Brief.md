# M5 Mac Setup Brief — Tier-my-ADDS Lab

> Hand this file to Claude (or a colleague) to set up the brownfield AD lab
> on an Apple Silicon Mac. Follow the steps in order — each section must
> complete before the next begins.

---

## Context

This repo (`Tier-my-ADDS`) implements the Monash Enterprise Access Model (MEAM)
for Active Directory tiering. The `0-Infrastructure/` folder contains a
**Vagrant lab** that spins up a realistic brownfield Windows Server 2022 AD
environment (`contoso.local`) so the MEAM deployment scripts can be tested.

**VMs created:**

| VM | IP | RAM | Role |
|----|----|-----|------|
| dc01 | 192.168.56.10 | 4 GB | Primary DC / PDC Emulator |
| dc02 | 192.168.56.11 | 2 GB | Secondary DC |
| member01 | 192.168.56.20 | 2 GB | Member server / test target |

**Total RAM needed: 8 GB** — M5 Macs (16 GB+) are well within spec.

VirtualBox does **not** run on Apple Silicon. This setup uses **VMware Fusion**
which is free for personal/educational use since Broadcom's May 2024 licensing change.

---

## Step 1 — Install VMware Fusion Pro (free)

1. Create a free Broadcom account at https://profile.broadcom.com/web/registration
2. Go to: https://support.broadcom.com/group/ecx/productdownloads?subfamily=VMware+Fusion
3. Download **VMware Fusion Pro 13.x** (choose the latest `.dmg` for macOS)
4. Open the `.dmg` and drag VMware Fusion to `/Applications`
5. Launch it once, accept the licence, choose **Free for Personal Use**

Verify:
```bash
/Applications/VMware\ Fusion.app/Contents/Library/vmware-vmx --version
```

---

## Step 2 — Install Vagrant

```bash
# Install Homebrew if not already present
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install Vagrant
brew install vagrant

# Confirm
vagrant --version   # should print 2.3.x or higher
```

---

## Step 3 — Install VMware Utility daemon + Vagrant plugin

The `vagrant-vmware-desktop` plugin needs a small system daemon that Vagrant
ships separately. Both must be installed.

```bash
# 1. Download the VMware Utility installer
#    Go to: https://developer.hashicorp.com/vagrant/install/vmware
#    Download "VMware Utility" for macOS (.dmg) and run the installer

# 2. Install the Vagrant plugin
vagrant plugin install vagrant-vmware-desktop

# Confirm
vagrant plugin list   # should include vagrant-vmware-desktop
```

---

## Step 4 — Set default provider

Add to your shell profile (`~/.zshrc` or `~/.bash_profile`):

```bash
echo 'export VAGRANT_DEFAULT_PROVIDER=vmware_desktop' >> ~/.zshrc
source ~/.zshrc
```

---

## Step 5 — Clone / open the repo

```bash
# If you have the repo already, just navigate to it
cd /path/to/Tier-my-ADDS/0-Infrastructure

# If you need to clone
git clone <repo-url>
cd Tier-my-ADDS/0-Infrastructure
```

---

## Step 6 — Deploy the lab

**Provision in order** — dc01 must be fully up before the others.

```bash
# Primary DC (takes ~20 min — promotes forest, creates brownfield objects)
vagrant up dc01

# Secondary DC (takes ~10 min — wait for dc01 to finish 100%)
vagrant up dc02

# Member server (takes ~8 min)
vagrant up member01
```

Or one-liner (Vagrant provisions sequentially when listed):
```bash
vagrant up dc01 && vagrant up dc02 && vagrant up member01
```

### What happens during `vagrant up dc01`

| Phase | Script | Action |
|-------|--------|--------|
| 1 | `01-Promote-DomainController.ps1` | Install ADDS + DNS, promote contoso.local forest, **reboot** |
| 2 | `02-Initialize-Domain.ps1` | Raise DFL/FFL to 2016, KDS root key, AD Recycle Bin, DNS forwarders, **reboot** |
| 3 | `03-New-BrownfieldObjects.ps1` | Create 25 users, 8 service accounts, 12 computers, legacy groups |
| 4 | `04-Apply-BrownfieldMisconfig.ps1` | Apply 13 intentional security misconfigurations (DA svc accounts, Kerberoastable SPNs, etc.) |

---

## Step 7 — Verify the lab

```bash
# Check all VMs are running
vagrant status

# RDP to DC01
open "rdp://192.168.56.10"
# User: CONTOSO\Administrator   Password: P@ssw0rd!Contoso2024
```

From inside DC01 (PowerShell):
```powershell
# Confirm domain is up
Get-ADDomain

# Confirm brownfield users exist
Get-ADUser -Filter * | Where-Object DistinguishedName -notmatch 'CN=Users' | Select-Object SamAccountName, Description

# Confirm misconfigs are present (DA should contain svc-sql etc.)
Get-ADGroupMember 'Domain Admins' | Select-Object SamAccountName
```

---

## Step 8 — Deploy MEAM tiering (the actual purpose)

Once the brownfield lab is up, deploy MEAM on top of it:

```powershell
# Run on DC01 (RDP or WinRM)
Set-Location C:\vagrant-bootstrap

# Validate config first (dry run)
..\1-Deployment\New-MEAM-Deployment.ps1 `
    -ConfigPath C:\vagrant-bootstrap\lab.json `
    -ValidateOnly

# Deploy
..\1-Deployment\New-MEAM-Deployment.ps1 `
    -ConfigPath C:\vagrant-bootstrap\lab.json

# Validate result
..\4-Validation\Test-MEAM-Deployment.ps1 `
    -ConfigPath C:\vagrant-bootstrap\lab.json

# Compliance scan
..\3-Monitoring\Get-Tiering-Compliance-Report.ps1
```

Reports are written to `C:\vagrant-bootstrap\reports\`.

---

## Troubleshooting

**`vagrant up` says "Provider 'vmware_desktop' not found"**
```bash
vagrant plugin install vagrant-vmware-desktop
# Also ensure VMware Utility daemon is installed (Step 3)
```

**WinRM timeout during provisioning**
```bash
vagrant reload dc01   # reconnects after reboot
vagrant provision dc01 --provision-with init-domain   # re-runs specific phase
```

**dc02 or member01 can't find contoso.local**
- dc01 must be 100% provisioned first
- Check dc01 is running: `vagrant status dc01`

**Re-provision a single phase**
```bash
vagrant provision dc01 --provision-with brownfield-objects
```

**Full teardown and rebuild**
```bash
vagrant destroy --force
vagrant up dc01 && vagrant up dc02 && vagrant up member01
```

---

## Credentials Reference

| Account | Password |
|---------|----------|
| `CONTOSO\Administrator` | `P@ssw0rd!Contoso2024` |
| DSRM (DC01 + DC02) | `P@ssw0rd!DSRM2024` |
| `vagrant` (local) | `vagrant` |
| All brownfield users (e.g. john.smith) | `LabUser2024!` |
| All service accounts (e.g. svc-sql) | `SvcP@ss2024!` |
| Break glass (post-MEAM deploy) | `B!gBr3@kGl@ss!L@b2024!` |
