# Tier-my-ADDS Documentation Guide

**Navigation Hub for All Documentation**

Welcome to Tier-my-ADDS! This guide helps you find the right documentation for your task.

---

## 🚀 Quick Navigation

### I'm New to This Project
👉 Start here: [README.md](./README.md) (5-10 min read)
- What this project does
- Quick start guide
- Key concepts

### I'm Deploying MEAM (Main Tier Model)
👉 Read: [DEPLOYMENT.md](./docs/DEPLOYMENT.md)
- Step-by-step deployment procedures
- Configuration guide
- Pre-flight validation
- Troubleshooting common issues

### I Need to Understand the Architecture
👉 Read: [ARCHITECTURE.md](./docs/ARCHITECTURE.md)
- Tier structure (T0/T1/T2)
- Zone definitions
- Enforcement layers
- Group naming conventions
- OU hierarchy

### I'm Operating an Existing MEAM Environment
👉 Read: [OPERATIONS.md](./docs/OPERATIONS.md)
- Admin onboarding
- Server/computer onboarding
- Break-glass procedures
- Quarterly reviews
- Monitoring & compliance

### Something is Broken or Not Working
👉 Read: [TROUBLESHOOTING.md](./docs/TROUBLESHOOTING.md)
- Common issues & solutions
- Kerberos auth failures
- PAW access problems
- Service account issues
- Emergency procedures

### I'm Implementing Kerberos Hardening (RFC 8062)
👉 Read: [5. Kerberos Hardening/README.md](./5.%20Kerberos%20Hardening/README.md)
- RFC 8062 overview
- Pre-flight validation
- Deployment phases
- Emergency rollback

Then: [5. Kerberos Hardening/RFC8062-Implementation-Guide.md](./5.%20Kerberos%20Hardening/RFC8062-Implementation-Guide.md)
- Detailed procedures
- Risk assessment
- Monitoring setup

### I Need to Configure Monitoring
👉 Read: [MONITORING.md](./docs/MONITORING.md)
- Auto-Tiering scanner setup
- Monthly compliance reports
- CI/CD pipeline configuration
- Webhook alerting

### I Need to Roll Out Tiering Safely in an Existing Domain
👉 Start with: [BOOTSTRAP-AND-MIGRATION.md](./docs/BOOTSTRAP-AND-MIGRATION.md)
- Bootstrap from existing privileged access
- Avoid Tier 0 chicken-and-egg failures
- Pilot-first migration sequence
- Tier 1 hybrid sync guidance

Then read the SOPs:
- [TIER-0-SOP.md](./docs/TIER-0-SOP.md)
- [TIER-1-SOP.md](./docs/TIER-1-SOP.md)
- [TIER-2-SOP.md](./docs/TIER-2-SOP.md)

Validation gate:
- [VALIDATION-CHECKLIST.md](./docs/VALIDATION-CHECKLIST.md)

### I Need References & Security Standards
👉 Read: [REFERENCES.md](./docs/REFERENCES.md)
- Academic papers
- Microsoft EAM model
- CIS benchmarks
- NIST compliance mappings
- External resources

---

## 📋 Complete Documentation Index

| Document | Purpose | Audience |
|----------|---------|----------|
| [README.md](./README.md) | Overview & quick start | Everyone (start here!) |
| [ARCHITECTURE.md](./docs/ARCHITECTURE.md) | Tier model design | Architects, security teams |
| [DEPLOYMENT.md](./docs/DEPLOYMENT.md) | Deployment procedures | Implementers, AD admins |
| [OPERATIONS.md](./docs/OPERATIONS.md) | Day-to-day operations | AD operators |
| [MONITORING.md](./docs/MONITORING.md) | Monitoring & reporting | DevOps, analysts |
| [TROUBLESHOOTING.md](./docs/TROUBLESHOOTING.md) | Issue resolution | Support teams |
| [REFERENCES.md](./docs/REFERENCES.md) | External resources | Researchers, auditors |
| [BOOTSTRAP-AND-MIGRATION.md](./docs/BOOTSTRAP-AND-MIGRATION.md) | Existing-domain rollout path | Architects, implementers |
| [TIER-0-SOP.md](./docs/TIER-0-SOP.md) | Tier 0 operating procedure | Tier 0 admins |
| [TIER-1-SOP.md](./docs/TIER-1-SOP.md) | Tier 1 operating procedure | Tier 1 admins |
| [TIER-2-SOP.md](./docs/TIER-2-SOP.md) | Tier 2 operating procedure | Tier 2 admins |
| [VALIDATION-CHECKLIST.md](./docs/VALIDATION-CHECKLIST.md) | Go/no-go validation gates | Operators, reviewers |

### Kerberos Hardening (RFC 8062)

| Document | Purpose |
|----------|---------|
| [5. Kerberos Hardening/README.md](./5.%20Kerberos%20Hardening/README.md) | Quick start for RFC 8062 |
| [5. Kerberos Hardening/RFC8062-Implementation-Guide.md](./5.%20Kerberos%20Hardening/RFC8062-Implementation-Guide.md) | Detailed RFC 8062 guide |
| [5. Kerberos Hardening/DEPLOYMENT-SUMMARY.md](./5.%20Kerberos%20Hardening/DEPLOYMENT-SUMMARY.md) | RFC 8062 implementation overview |

---

## 🗂️ Repository Structure

```
Tier-my-ADDS/
├── README.md                                    ← Start here
├── DOCUMENTATION.md                             ← You are here
├── docs/
│   ├── ARCHITECTURE.md                         [Core concepts]
│   ├── DEPLOYMENT.md                           [How to deploy]
│   ├── OPERATIONS.md                           [Day-to-day procedures]
│   ├── MONITORING.md                           [Compliance & reporting]
│   ├── TROUBLESHOOTING.md                      [When things break]
│   └── REFERENCES.md                           [External sources]
├── 1. Main/
│   ├── script_v2.ps1                           [Main deployment script]
│   └── script_v2.config.example.json           [Configuration]
├── 2. Role_segregation/
│   ├── DNS_seperate.ps1                        [DNS admin role script]
│   └── DNS_seperate.config.example.json        [Configuration]
├── 3. Monitoring/
│   ├── Auto-Tiering Computer account scanner.ps1
│   ├── MEAM-Tier-Report.ps1                    [Monthly compliance report]
│   └── *.config.example.json                   [Configurations]
├── 4. Validation/
│   └── Validate-MEAM-Deployment.ps1            [Post-deployment validator]
├── 5. Kerberos Hardening/
│   ├── RFC8062-PreFlight-Check.ps1             [Validation]
│   ├── RFC8062-Hardening-Deploy.ps1            [Deployment]
│   ├── RFC8062-DcRegistryRollback.ps1          [Emergency rollback]
│   ├── README.md                               [Quick start]
│   ├── RFC8062-Implementation-Guide.md         [Full guide]
│   └── DEPLOYMENT-SUMMARY.md                   [Overview]
└── [CI/CD pipelines]
    ├── azure-pipelines-monthly-report.yml
    └── .github/workflows/meam-monthly-report.yml
```

---

## 🎯 Common Workflows

### Scenario: I'm Deploying MEAM for the First Time

1. **Week 1:** Understanding
   - Read [README.md](./README.md) (5 min)
   - Review [ARCHITECTURE.md](./docs/ARCHITECTURE.md) (20 min)
   - Watch model diagrams in [flowchart TD.presentation.md](./flowchart%20TD.presentation.md)

2. **Week 2:** Planning
   - Read [DEPLOYMENT.md](./docs/DEPLOYMENT.md) (30 min)
   - Customize `1. Main/script_v2.config.example.json`
   - Run pre-flight validation

3. **Week 3-4:** Deployment
   - Follow step-by-step procedures in [DEPLOYMENT.md](./docs/DEPLOYMENT.md)
   - Validate using `4. Validation/Validate-MEAM-Deployment.ps1`

4. **Week 5:** Operations
   - Read [OPERATIONS.md](./docs/OPERATIONS.md)
   - Set up monitoring using `3. Monitoring/MEAM-Tier-Report.ps1`
   - Configure CI/CD pipelines

### Scenario: I'm Adding RFC 8062 Hardening

1. Read [5. Kerberos Hardening/README.md](./5.%20Kerberos%20Hardening/README.md)
2. Run pre-flight: `5. Kerberos Hardening/RFC8062-PreFlight-Check.ps1`
3. Follow [5. Kerberos Hardening/RFC8062-Implementation-Guide.md](./5.%20Kerberos%20Hardening/RFC8062-Implementation-Guide.md)
4. Deploy phases sequentially

### Scenario: Something is Broken

1. Read [TROUBLESHOOTING.md](./docs/TROUBLESHOOTING.md)
2. Find your issue in the table
3. Follow the solution steps
4. If still broken, follow emergency procedures

---

## 📖 Reading Recommendations by Role

### Security Architect
1. [ARCHITECTURE.md](./docs/ARCHITECTURE.md) - Design principles
2. [README.md](./README.md) - Model overview
3. [REFERENCES.md](./docs/REFERENCES.md) - Security standards

### AD Administrator
1. [README.md](./README.md) - Overview
2. [DEPLOYMENT.md](./docs/DEPLOYMENT.md) - How to deploy
3. [OPERATIONS.md](./docs/OPERATIONS.md) - Day-to-day tasks
4. [TROUBLESHOOTING.md](./docs/TROUBLESHOOTING.md) - Problem solving

### Security Operations (SOC)
1. [MONITORING.md](./docs/MONITORING.md) - Compliance reporting
2. [OPERATIONS.md](./docs/OPERATIONS.md) - Operational procedures
3. [TROUBLESHOOTING.md](./docs/TROUBLESHOOTING.md) - Issue resolution

### DevOps / CI/CD Engineer
1. [MONITORING.md](./docs/MONITORING.md) - Pipeline setup
2. [5. Kerberos Hardening/RFC8062-Implementation-Guide.md](./5.%20Kerberos%20Hardening/RFC8062-Implementation-Guide.md) - Kerberos hardening integration

### Help Desk / Support
1. [TROUBLESHOOTING.md](./docs/TROUBLESHOOTING.md) - Common issues
2. [OPERATIONS.md](./docs/OPERATIONS.md) - Procedures
3. Emergency contacts (TBD)

---

## 🔍 Finding Specific Topics

### Authentication & Kerberos
- Enforcement layers → [ARCHITECTURE.md](./docs/ARCHITECTURE.md#enforcement-layers)
- Kerberos hardening → [5. Kerberos Hardening/](./5.%20Kerberos%20Hardening/)
- Auth failures → [TROUBLESHOOTING.md](./docs/TROUBLESHOOTING.md#kerberos-authentication-failures)

### Administrative Procedures
- Adding new admin → [OPERATIONS.md](./docs/OPERATIONS.md#new-admin-onboarding)
- Adding new server → [OPERATIONS.md](./docs/OPERATIONS.md#new-servercomputer-onboarding)
- Break-glass access → [OPERATIONS.md](./docs/OPERATIONS.md#break-glass-usage)

### Monitoring & Compliance
- Setup monitoring → [MONITORING.md](./docs/MONITORING.md)
- Monthly reports → [MONITORING.md](./docs/MONITORING.md#monthly-compliance-reports)
- Quarterly reviews → [OPERATIONS.md](./docs/OPERATIONS.md#quarterly-review)

### Troubleshooting
- PAW access issues → [TROUBLESHOOTING.md](./docs/TROUBLESHOOTING.md#paw-access-problems)
- Authentication failures → [TROUBLESHOOTING.md](./docs/TROUBLESHOOTING.md#kerberos-authentication-failures)
- Service account issues → [TROUBLESHOOTING.md](./docs/TROUBLESHOOTING.md#service-account-problems)

---

## 💡 Tips for Using This Documentation

### Finding What You Need
1. Check the [Quick Navigation](#-quick-navigation) section above
2. Use the repository structure to find files
3. Use your IDE's search function (Ctrl+Shift+F) for keywords
4. Check the workflow examples for your scenario

### Understanding the Terminology
- **T0 / Tier 0:** Control plane (Domain Controllers, PKI, hypervisors)
- **T1 / Tier 1:** Management plane (servers, DNS, backup)
- **T2 / Tier 2:** Workload plane (workstations, user systems)
- **Zone:** Horizontal microsegmentation within a tier (e.g., Zone 1B = Server Management)
- **PAW:** Privileged Access Workstation (hardened admin machine)
- **Auth Silo:** Kerberos policy restricting who can authenticate where
- **Protected Users:** Security group with enhanced authentication restrictions

### Staying Current
- New versions are documented in the main [README.md](./README.md)
- Check [REFERENCES.md](./docs/REFERENCES.md) for external updates on EAM model
- Monitor the GitHub repository for updates

---

## ❓ FAQ

**Q: Where should I start?**  
A: [README.md](./README.md) - It's designed for first-time readers.

**Q: How long does it take to read all documentation?**  
A: ~3-4 hours for a complete read-through. Start with the sections relevant to your role.

**Q: Can I just look at diagrams instead of reading?**  
A: The Mermaid diagrams ([flowchart TD.presentation.md](./flowchart%20TD.presentation.md)) give a visual overview, but you'll need the full docs for procedures.

**Q: What if I find an error in the documentation?**  
A: Submit a GitHub issue or pull request with corrections.

---

## 📞 Support & Feedback

- 🐛 **Bug reports:** Submit GitHub issue
- 💡 **Feature requests:** GitHub discussions
- 📝 **Documentation improvements:** Pull requests welcome
- ❓ **General questions:** GitHub discussions

---

**Last Updated:** 2026-05-18  
**Version:** 2.0 (Reorganized)  
**Status:** Complete

Start reading: [README.md](./README.md) →
