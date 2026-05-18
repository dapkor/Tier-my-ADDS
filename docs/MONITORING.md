# MEAM Monitoring & Reporting Guide

**Setting up compliance monitoring and automated reporting for MEAM**

---

## Table of Contents

1. [Overview](#overview)
2. [Auto-Tiering Scanner](#auto-tiering-scanner)
3. [Monthly HTML Reports](#monthly-html-reports)
4. [CI/CD Pipeline Setup](#cicd-pipeline-setup)
5. [Webhook Alerting](#webhook-alerting)
6. [Event Log Monitoring](#event-log-monitoring)
7. [Dashboard Setup](#dashboard-setup)

---

## Overview

MEAM monitoring has three components:

```
┌─────────────────────────────────────────┐
│ Auto-Tiering Scanner                    │ ← Real-time: Detect misplaced computers
├─────────────────────────────────────────┤
│ Compliance HTML Reports                 │ ← Monthly: Policy adherence dashboard
├─────────────────────────────────────────┤
│ Event Log Monitoring & Dashboards       │ ← Continuous: KDC failures, auth violations
└─────────────────────────────────────────┘
```

---

## Auto-Tiering Scanner

### Purpose

Detects computers placed in **wrong tier OUs** that should be in different tiers.

**Example violations detected:**
- T1 admin computer in T2 zone OU
- T0 Domain Controller in T1 zone OU
- Non-admin workstation in admin OU

### Configuration

```powershell
cd "3. Monitoring"
Copy-Item "Auto-Tiering Computer account scanner.config.example.json" "Auto-Tiering Computer account scanner.config.json"
```

Edit config:

```json
{
  "DomainDN": "DC=corp,DC=example,DC=com",
  "CorpOU": "Corp",
  
  "ComputerRulesApplied": [
    {
      "Description": "Domain Controllers must be in Zone 0A",
      "Filter": "operatingSystem -like '*Server*' -and dNSHostName -like '*dc*'",
      "AllowedOU": "OU=Computers,OU=Zone 0A,OU=Tier 0,OU=Tiers,OU=Corp",
      "Severity": "CRITICAL"
    },
    {
      "Description": "PAW devices must be in PAWs OU",
      "Filter": "name -like 'PAW-*'",
      "AllowedOU": "OU=PAWs,OU=Tier",
      "Severity": "HIGH"
    }
  ],
  
  "ScanInterval": "Weekly",
  "EventQueryTimeoutSeconds": 30,
  "OutputPath": "./tiering-report.csv"
}
```

### Running Scanner

```powershell
.\
'Auto-Tiering Computer account scanner.ps1' -ConfigPath "Auto-Tiering Computer account scanner.config.json"
```

Output:

```
Computer                    Rule                          Tier    Zone    Score   Verdict
────────────────────────────────────────────────────────────────────────────────────────
DC01                        DC must be in Zone 0A         ✓ OK    T0      0A      100%
WORKST-042                  Computer in correct tier      ✓ OK    T2      2A      100%
APP-SRV-15                  In T1B but named as T0        ✗ FAIL  T1      1B      20%
                            recommendation: Move to appropriate OU
```

### Webhook Alert

Send misplacement alerts to Slack or Teams:

```powershell
# Add to scanner config:
"WebhookAlert": {
  "Enabled": true,
  "Url": "https://hooks.slack.com/services/YOUR/WEBHOOK/URL",
  "TriggerThreshold": "CRITICAL"  # Alert only on CRITICAL violations
}

# Runs automatically if computer placed in wrong OU
```

---

## Monthly HTML Reports

### Purpose

Generate compliance dashboard showing:
- T0/T1 admin accounts (count, last logon)
- Role groups and members
- PSO applied groups
- Auth silos and enforcement status
- PAW readiness (computers, users)
- Break-glass account status
- Compliance scoring (% compliant)

### Configuration

```powershell
cd "3. Monitoring"
Copy-Item "MEAM-Tier-Report.config.example.json" "MEAM-Tier-Report.config.json"
```

Edit config:

```json
{
  "DomainDN": "DC=corp,DC=example,DC=com",
  "CorpOU": "Corp",
  
  "ReportOptions": {
    "IncludeT0Accounts": true,
    "IncludeT1Accounts": true,
    "IncludeGroupPolicy": true,
    "IncludeAuthPolicies": true,
    "IncludePAWStatus": true,
    "IncludeBreakGlassStatus": true,
    "IncludeComplianceScore": true
  },
  
  "OutputFormat": "HTML",
  "OutputPath": "./meam-compliance-report.html",
  "Title": "MEAM Compliance Report - Month/Year"
}
```

### Running Report

```powershell
.\MEAM-Tier-Report.ps1 -ConfigPath "MEAM-Tier-Report.config.json"
```

Output: `meam-compliance-report.html`

**Report sections:**

```
├─ Executive Summary
│  └─ Compliance Score: 98%
├─ Tier 0 Status
│  ├─ Domain Controllers: 3 (all healthy)
│  ├─ Admin Accounts: 5 (all in Protected Users)
│  ├─ PAW Devices: 2 (both online)
│  └─ Break-Glass: 1 (enabled, last changed 60 days ago)
├─ Tier 1 Status
│  ├─ Admin Accounts: 12 (11 in Protected Users, 1 MISSING)
│  ├─ Servers: 28 (26 compliant LAPS, 2 legacy)
│  ├─ Zone Breakdown: 1A: 3 admins, 1B: 5 admins, 1C: 2 admins, 1D: 2 admins
│  └─ Issues: 1 admin account not in Protected Users
├─ Policy & Silos
│  ├─ Auth Silos: 11 total (all ENFORCED)
│  ├─ GPOs: 15 linked (all ENABLED)
│  └─ PSOs: 4 applied (coverage 100%)
└─ Recommendations
   ├─ Add adm-t1-srv04 to Protected Users
   └─ Upgrade 2 legacy T1 servers
```

---

## CI/CD Pipeline Setup

### GitHub Actions (Monthly Report)

Create `.github/workflows/meam-monthly-report.yml`:

```yaml
name: MEAM Monthly Compliance Report

on:
  schedule:
    - cron: '0 9 1 * *'  # 9 AM on 1st of every month
  workflow_dispatch:     # Manual trigger

jobs:
  report:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      
      - name: Generate MEAM Compliance Report
        shell: pwsh
        run: |
          # Download config
          $config = Get-Content "3. Monitoring\MEAM-Tier-Report.config.json" | ConvertFrom-Json
          
          # Run report script
          & ".\3. Monitoring\MEAM-Tier-Report.ps1" -ConfigPath "3. Monitoring\MEAM-Tier-Report.config.json"
      
      - name: Publish Report as Artifact
        uses: actions/upload-artifact@v3
        with:
          name: meam-compliance-report
          path: ./3. Monitoring/meam-compliance-report.html
      
      - name: Send Report via Email
        if: always()
        run: |
          # Email report to compliance@company.com
          # (Requires secrets: EMAIL_FROM, EMAIL_TO, EMAIL_PASSWORD)
```

### Azure DevOps Pipeline (Monthly Report)

Create `azure-pipelines-monthly-report.yml`:

```yaml
trigger:
  - none  # Disabled - use scheduled trigger

schedules:
  - cron: "0 9 1 * *"
    displayName: Monthly MEAM Report
    branches:
      include:
        - main
    always: true

pool:
  vmImage: 'windows-latest'

steps:
  - task: PowerShell@2
    displayName: Generate MEAM Compliance Report
    inputs:
      targetType: 'filePath'
      filePath: '$(System.DefaultWorkingDirectory)/3. Monitoring/MEAM-Tier-Report.ps1'
      arguments: '-ConfigPath "$(System.DefaultWorkingDirectory)/3. Monitoring/MEAM-Tier-Report.config.json"'

  - task: PublishBuildArtifacts@1
    displayName: Publish Report Artifact
    inputs:
      PathtoPublish: '$(System.DefaultWorkingDirectory)/3. Monitoring/meam-compliance-report.html'
      ArtifactName: 'MEAM-Reports'
      publishLocation: 'Container'

  - task: PowerShell@2
    displayName: Email Report
    inputs:
      targetType: 'inline'
      script: |
        $reportPath = "$(System.DefaultWorkingDirectory)/3. Monitoring/meam-compliance-report.html"
        # Send email logic here
```

---

## Webhook Alerting

### Slack Integration

Setup Slack incoming webhook:

```
1. Go to https://api.slack.com/apps
2. Create new app
3. Enable Incoming Webhooks
4. Add Webhook to Slack workspace
5. Copy webhook URL: https://hooks.slack.com/services/T.../B.../X...
```

Add to Auto-Tiering Scanner config:

```json
"WebhookAlert": {
  "Enabled": true,
  "Url": "https://hooks.slack.com/services/YOUR/WEBHOOK/URL",
  "Channel": "#security-alerts",
  "TriggerThreshold": "CRITICAL",
  "Message": "MEAM Tier Violation Detected: {violation}"
}
```

**Slack message example:**

```
🚨 MEAM Tier Violation Detected
  Computer: APP-SRV-15
  Expected OU: OU=Computers,OU=Zone 1B,...
  Actual OU: OU=Computers,OU=Zone 1A,...
  Severity: HIGH
  Time: 2026-05-18 14:22:00
```

### Teams Integration

Similar setup for Microsoft Teams:

1. Create Teams app → Incoming Webhook
2. Configure webhook URL
3. Add to monitoring script config

---

## Event Log Monitoring

### Key Kerberos Events to Monitor

```
Event ID  | Meaning                      | Action If Seen
──────────┼──────────────────────────────┼─────────────────────────
4625      | Logon failure (auth denied)  | Check Auth Silo rules
4634      | Logon session ended          | Normal (informational)
4672      | Special privileges assigned  | Review for T0 elevation
4768      | AS ticket requested          | Normal (informational)
4769      | Service ticket requested     | Normal (informational)
4771      | Pre-auth failed              | Check smartcard/FAST armor
4777      | NTLM auth attempt            | NTLM might not be blocked
4823      | Policy denied                | Auth Silo enforcing (good)
5058      | Encryption changed           | Check RFC 8062 enforcement
```

### Setup Event Log Collection

**On Domain Controller:**

```powershell
# Enable Kerberos audit policy
auditpol /set /subcategory:"Kerberos Authentication Service" /success:enable /failure:enable
auditpol /set /subcategory:"Kerberos Service Ticket Operations" /success:enable /failure:enable

# Increase event log size (default 20 MB)
wevtutil.exe sl Security /ms:104857600  # 100 MB
```

**On Windows Event Collector (optional):**

```powershell
# Forward security events to central collector
# Use Event Forwarding for centralized logging
```

### Query Events

```powershell
# Failed Kerberos auth attempts (last 24 hours)
Get-WinEvent -FilterHashtable @{
    LogName = 'Security'
    ID = 4625
    StartTime = (Get-Date).AddHours(-24)
} | Format-Table TimeCreated, TargetUserName, ComputerName -AutoSize

# Auth Silo enforcement
Get-WinEvent -FilterHashtable @{
    LogName = 'Security'
    ID = 4823
    StartTime = (Get-Date).AddDays(-7)
} | Format-Table TimeCreated, Message -AutoSize
```

---

## Dashboard Setup

### Option 1: Azure Monitor + Workbooks

```powershell
# Create workbook for MEAM monitoring
# → Azure Monitor → Workbooks → Add
```

**Workbook queries (KQL):**

```kusto
// Failed Kerberos authentications by computer
Event
| where EventID == 4625
| where TimeGenerated > ago(7d)
| summarize FailureCount = count() by Computer
| sort by FailureCount desc
```

### Option 2: Splunk Dashboard

```
Splunk query:
source="Security" EventCode=4625 OR EventCode=4823 OR EventCode=4768
| stats count by EventCode
```

### Option 3: Grafana

Integration with custom metrics export from PowerShell scripts.

---

**Document Version:** 1.0  
**Last Updated:** 2026-05-18  
**Next Review:** 2027-05-18
