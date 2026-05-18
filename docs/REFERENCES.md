# MEAM References & Resources

**External documentation, standards, and compliance mappings**

---

## Table of Contents

1. [Microsoft Documentation](#microsoft-documentation)
2. [Security Standards & Frameworks](#security-standards--frameworks)
3. [Compliance Mappings](#compliance-mappings)
4. [RFCs & Technical Specifications](#rfcs--technical-specifications)
5. [Academic Papers & Research](#academic-papers--research)
6. [Tools & Utilities](#tools--utilities)
7. [Community Resources](#community-resources)

---

## Microsoft Documentation

### Enterprise Access Model (EAM)

- **Main Page:** https://aka.ms/EAM
- **Enterprise Access Model (EAM):** Foundational architecture for tier model
- **Rapid Modernization Plan (RaMP):** Implementation guidance
- **MEAM Extended Model:** Monash CSIRT GitHub implementation

### Active Directory Architecture

- **Active Directory Security Best Practices:** https://docs.microsoft.com/windows-server/identity/ad-ds/plan/security-best-practices
- **AD Administrative Tier Model:** https://docs.microsoft.com/windows-server/identity/ad-ds/plan/security-best-practices/active-directory-administrative-tier-model
- **Authentication Policies and Policy Silos:** https://docs.microsoft.com/windows-server/security/credentials-protection-and-management/authentication-policies-and-policy-silos
- **Protected Users Security Group:** https://docs.microsoft.com/windows-server/security/credentials-protection-and-management/protected-users-security-group

### Kerberos & Authentication

- **Kerberos Authentication Overview:** https://docs.microsoft.com/windows-server/security/kerberos/kerberos-authentication-overview
- **FAST (Flexible Authentication Secure Tunneling):** https://docs.microsoft.com/windows-server/security/kerberos/kerberos-constrained-delegation-overview
- **Kerberos Delegation Types:** https://docs.microsoft.com/windows-server/security/kerberos/kerberos-constrained-delegation-overview
- **Group Policy for Kerberos:** https://docs.microsoft.com/previous-versions/windows/it-pro/windows-server-2012-R2-and-2012/dn452416(v=ws.11)

### Group Policy

- **Group Policy Object (GPO) Fundamentals:** https://docs.microsoft.com/windows-server/identity/ad-ds/manage/group-policy/group-policy-overview
- **Group Policy Editor Reference:** https://docs.microsoft.com/windows-server/administration/windows-commands/gpedit-msc
- **User Rights Assignment:** https://docs.microsoft.com/windows-server/security/user-rights-assignment

### Local Administrator Password Solution (LAPS)

- **LAPS Overview:** https://docs.microsoft.com/windows-server/identity/laps/laps-overview
- **LAPS Deployment Guide:** https://docs.microsoft.com/windows-server/identity/laps/laps-deployment-guide
- **Azure AD-integrated LAPS:** https://docs.microsoft.com/windows-server/identity/laps/laps-scenarios-azure-active-directory

---

## Security Standards & Frameworks

### CIS Benchmarks

- **CIS Microsoft Windows Server 2022 Benchmark:** https://www.cisecurity.org/benchmark/microsoft_windows_server_2022
- **CIS Microsoft Windows 10 Benchmark:** https://www.cisecurity.org/benchmark/microsoft_windows_desktop
- **CIS Active Directory Benchmark:** https://www.cisecurity.org/benchmark/active_directory_v3.1.1

Key controls mapped to MEAM:
```
CIS 1.1.1  - Account Policies
CIS 1.2.x  - Password Policies
CIS 2.3.x  - User Rights Assignment (denial rights)
CIS 4.1    - Kerberos Policy
CIS 17.x   - Group Policy
```

### NIST Guidance

- **NIST SP 800-53 Rev. 5:** Security and Privacy Controls
  - AC-2: Account Management
  - AC-3: Access Control
  - AC-6: Least Privilege
  - SC-7: Boundary Protection

- **NIST SP 800-63B:** Authentication and Lifecycle Management
  - 4.2: Authentication and Lifecycle Management
  - 5.1: Cryptographic Algorithms

### SANS & Security Recommendations

- **SANS: Privileged User Access:** https://www.sans.org/reading-room/whitepapers/
- **NSA: Cybersecurity Technical Guidance:** https://www.nsa.gov/resources/everyone/cybersecurity-advisories/

---

## Compliance Mappings

### SOC 2 Type II

**MEAM Controls → SOC 2 Criteria:**

| SOC 2 Criteria | MEAM Control | Status |
|---|---|---|
| CC6.1: Logical access rights | Auth Policy Silos, GPO Deny Rights | ✅ Covered |
| CC6.2: Unauthorized access | Zone isolation, tier segregation | ✅ Covered |
| CC7.2: System monitoring | Event log auditing, scanner | ✅ Covered |
| A1.1: Risk assessment | MEAM architecture, zones | ✅ Covered |

### PCI-DSS v3.2.1

**PCI-DSS Requirement → MEAM Control:**

| PCI Req | Requirement | MEAM Compliance |
|---|---|---|
| 2.1 | Admin access hardening | T0 tier, smartcard, protected users |
| 3.2.1 | Password policy | PSO tiers (T0: 20 chars, T1/T2: 14/12) |
| 7.1 | Least privilege | Zone/tier segregation, delegation groups |
| 8.1 | User account access | Role groups, silo enforcement |
| 8.2.3 | Password strength | Protected Users + PSO |
| 10.2.7 | Admin user monitoring | Audit policy, event logging |

### GDPR Data Protection

**GDPR Article → MEAM Relevance:**

| Article | MEAM Mitigation |
|---|---|
| Art. 32 | Technical measures | Kerberos encryption (AES-256), authentication policies |
| Art. 33-34 | Breach notification | Event logging enables breach detection |
| Art. 5 | Data protection principles | Tier separation, access control logging |

### HIPAA Security Rule

**HIPAA Technical Safeguard → MEAM Control:**

| Safeguard | Implementation |
|---|---|
| Access Control | Auth policies, zone isolation |
| Audit & Accountability | Event logging (4625, 4823, etc.) |
| Integrity | Kerberos message authentication |
| Transmission Security | TLS for LDAPS, Kerberos encryption |

---

## RFCs & Technical Specifications

### Kerberos (RFC Standards)

- **RFC 1510:** The Kerberos Network Authentication V5 Protocol (obsolete, reference only)
- **RFC 4120:** The Kerberos Network Authentication V5 Protocol (current standard)
- **RFC 3961:** Encryption and Checksum Specifications for Kerberos 5
- **RFC 3962:** Advanced Encryption Standard (AES) CTS Mode Operations With Kerberos 5
- **RFC 4402:** A Pseudo-Random Function (PRF) for Kerberos 5
- **RFC 6113:** Flexible Authentication Secure Tunneling (FAST) for Kerberos V5
- **RFC 8062:** Kerberos Generic Pre-Authentication Data

#### RFC 8062 Summary

**Title:** Kerberos Generic Pre-Authentication Data  
**Relevance:** Core technology for MEAM Kerberos hardening  
**Key points:**
- Defines generic pre-authentication for Kerberos
- Enables FAST armoring of pre-authentication
- Supports conditional pre-authentication requirements
- Required for RFC 8212 compliance

**Section 3:** FAST Pre-Authentication
```
FAST provides an encrypted tunnel for pre-authentication exchanges
allowing safe transport of sensitive information and strong
pre-authentication mechanisms.
```

### Active Directory RFC & Standards

- **RFC 4876:** LDAP URL Syntax Specifications
- **RFC 2307:** LDAP as a Network Information Service (NIS)
- **RFC 3271:** Lightweight Directory Access Protocol (LDAP): Requirements
- **X.520:** The Directory: Selected Attribute Types

---

## Academic Papers & Research

### Access Control Models

- **Lampson, B.C. (1971):** "Protection" - ACM Computing Surveys
  - Foundational access control theory
  - Referenced in tiered access models

- **Bell & LaPadula (1973):** "Secure Computer Systems: Mathematical Model"
  - Multi-level security model
  - Theoretical basis for tier isolation

### Credential Management

- **Morris & Thompson (1979):** "Password Security: A Case History"
  - Historical password security analysis
  - Informs PSO policy design

- **"The GUI Principle for Computer Security" (2010)**
  - Recommendations for admin interface security
  - Relevant to PAW design

### Active Directory Security

- **Metcalf & Spence: "Mimikatz" Analysis**
  - Credential extraction attacks
  - Informs Protected Users requirements
  - Drives Credential Guard adoption

---

## Tools & Utilities

### Microsoft Tools

| Tool | Purpose | Link |
|------|---------|------|
| **RSAT** | Remote Server Administration Tools | aka.ms/RSAT |
| **ADUC** | Active Directory Users & Computers | Built-in |
| **GPMC** | Group Policy Management Console | Built-in |
| **Event Viewer** | Windows Event log inspection | Built-in |
| **klist** | Kerberos ticket viewer | Built-in |
| **setspn** | SPN management | Built-in |
| **LAPSUtil** | LAPS password viewer | aka.ms/LAPS |
| **Netdom** | Domain management tool | Built-in |
| **NLTEST** | Netlogon testing | Built-in |

### Third-Party Tools

| Tool | Purpose | Link |
|------|---------|------|
| **Kerberoast** | SPN auditing | GitHub: EmptyDream |
| **BloodHound** | AD visual analysis | bloodhoundad.github.io |
| **Ping Castle** | AD auditing | pingcastle.com |
| **ADRecon** | AD data exporter | GitHub: sense-of-security |
| **PetriBot** | AD testing framework | petri.com/tools |

### Monitoring Tools

| Tool | Purpose |
|------|---------|
| **Splunk** | SIEM for event log analysis |
| **Elastic Stack** | Open-source SIEM |
| **Azure Monitor** | Azure native monitoring |
| **Grafana** | Metrics visualization |

---

## Community Resources

### GitHub Repositories

- **Monash CSIRT MEAM:** https://github.com/mon-csirt/active-directory-security
  - Original MEAM implementation
  - Reference architecture

- **Microsoft EAM Examples:** https://github.com/microsoft/EnterpriseAccessModel
  - Microsoft's official implementations
  - Best practices examples

- **Tier-my-ADDS:** https://github.com/dapkor/Tier-my-ADDS
  - This repository
  - Extended MEAM implementation

### Online Communities

- **Microsoft Tech Community - Active Directory:** https://techcommunity.microsoft.com/t5/active-directory/ct-p/ActiveDirectory
- **Reddit: r/sysadmin** - Practical advice
- **LinkedIn: Active Directory/Identity & Access Management groups**
- **SANS Cyber Academy:** https://www.sans.org/cyber-academy/

### Security Conferences & Events

- **Microsoft Ignite:** https://microsoft.com/ignite
  - Annual security updates and guidance

- **InfoSec Community (SANS, ISSA, etc.)**
  - Local chapter meetings
  - Webinars on identity & access

- **Black Hat / DEFCON:**
  - Advanced attack research
  - Defense techniques

---

## Glossary of Terms

| Term | Definition |
|------|-----------|
| **Tier** | Horizontal security layer (T0/T1/T2) |
| **Zone** | Vertical compartment within a tier |
| **PAW** | Privileged Access Workstation for admins |
| **Auth Policy** | Kerberos policy applied per user/computer group |
| **Auth Silo** | Boundary enforced by KDC ticket issuance |
| **Protected Users** | AD group with auto-enforced security features |
| **PSO** | Password Settings Object (fine-grained password policy) |
| **LAPS** | Local Administrator Password Solution |
| **FAST** | Flexible Authentication Secure Tunneling (RFC 6113) |
| **S4U2Proxy** | Service for User to Proxy delegation |
| **Clean Source** | Principle: any system managing higher tier IS that tier |
| **OU** | Organizational Unit for hierarchical admin delegation |
| **GPO** | Group Policy Object for centralized settings |
| **SPN** | Service Principal Name for Kerberos delegation |
| **TGT** | Ticket Granting Ticket from KDC |
| **DFL** | Domain Functional Level |

---

## Document References

### Within This Repository

- [README.md](../README.md) - Quick start guide
- [DOCUMENTATION.md](../DOCUMENTATION.md) - Navigation hub
- [docs/ARCHITECTURE.md](./ARCHITECTURE.md) - Detailed design
- [docs/DEPLOYMENT.md](./DEPLOYMENT.md) - Implementation guide
- [docs/OPERATIONS.md](./OPERATIONS.md) - Operational procedures
- [docs/MONITORING.md](./MONITORING.md) - Monitoring setup
- [docs/TROUBLESHOOTING.md](./TROUBLESHOOTING.md) - Problem solving

### Related Standards Documents

See [docs/](.) directory for:
- RFC 8062 implementation guide
- Deployment summary
- Configuration examples

---

## Revision History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-05-18 | Initial version: compiled references, mappings, glossary |

---

**Document Version:** 1.0  
**Last Updated:** 2026-05-18  
**Next Review:** 2027-05-18

**Last Updated by:** GitHub Copilot  
**Maintained in:** This Repository  
**For updates:** See [GitHub Issues](https://github.com/dapkor/Tier-my-ADDS/issues)
