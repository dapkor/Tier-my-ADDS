# 3-Monitoring

## Overview
Real-time compliance monitoring and monthly reporting for MEAM-deployed Active Directory environments.

## Purpose
This folder contains scripts that provide continuous visibility into MEAM tier placement, compliance posture, and security health through both real-time alerts and monthly HTML reports.

## Files

### Get-Tiering-Compliance-Report.ps1
**Real-time compliance scanner (500+ lines)**

**Purpose:** Performs continuous monitoring of computer account tier placement, detects misplacements, and evaluates compliance scoring.

**Run as:** Domain Admin or domain-joined service account with read permissions

**Requirements:**
- ActiveDirectory module (RSAT)
- PowerShell 5.1+
- Read access to all OUs
- HTTPS webhook endpoint for alerting (optional)
- Sufficient time for full domain scan (varies with environment size)

**Usage:**
```powershell
# Run full compliance scan
.\Get-Tiering-Compliance-Report.ps1 -ConfigPath .\Get-Tiering-Compliance-Report.config.example.json

# Validate configuration only
.\Get-Tiering-Compliance-Report.ps1 -ConfigPath .\Get-Tiering-Compliance-Report.config.example.json -LintConfigOnly

# Fail on phase errors (default continues)
.\Get-Tiering-Compliance-Report.ps1 -ConfigPath .\Get-Tiering-Compliance-Report.config.example.json -FailOnPhaseError

# Inline configuration
$config = Get-Content .\Get-Tiering-Compliance-Report.config.example.json -Raw
.\Get-Tiering-Compliance-Report.ps1 -ConfigJson $config
```

**Key Features:**
- ✅ Real-time compliance scoring engine
- ✅ Automatic detection of account misplacements
- ✅ CSV and webhook reporting
- ✅ Environment variable support
- ✅ HTTPS webhook alerting on high-risk moves
- ✅ Detailed scoring rubric (adjustable)

**Output Artifacts:**
- `.\reports\Tiering-Compliance-<timestamp>.csv` - Detailed scan results
- `.\reports\Tiering-RunReport.json` - Execution summary
- Webhook POST: High-risk tier violations (if configured)

**Scoring Rules:**
The script applies a risk-weighted scoring model:
- **Tier Mismatch:** Base penalty
- **Zone Mismatch:** Additional penalty
- **Service Mismatch:** Additional penalty
- **Age of Misplacement:** Time-decay multiplier
- **Account Type:** User vs. computer weighting

### New-MEAM-Compliance-Report.ps1
**Monthly compliance report generator (500+ lines)**

**Purpose:** Generates richly formatted, self-contained HTML reports for executive and operational audiences with KPI summaries and compliance scoring.

**Run as:** Service account with read-only AD access (ideal for scheduled runs)

**Requirements:**
- ActiveDirectory module (RSAT)
- PowerShell 5.1+
- Read access to all OUs
- Runs on domain-joined machine or with domain access

**Usage:**
```powershell
# Generate default report
.\New-MEAM-Compliance-Report.ps1 -ConfigPath .\New-MEAM-Compliance-Report.config.example.json

# Generate with custom stale threshold
.\New-MEAM-Compliance-Report.ps1 -ConfigPath .\New-MEAM-Compliance-Report.config.example.json -StaleThresholdDays 60

# Override output path
.\New-MEAM-Compliance-Report.ps1 -ConfigPath .\New-MEAM-Compliance-Report.config.example.json -OutputPath C:\reports\custom-report.html

# Open in browser after generation
.\New-MEAM-Compliance-Report.ps1 -ConfigPath .\New-MEAM-Compliance-Report.config.example.json -OpenInBrowser

# Inline config
$config = Get-Content .\New-MEAM-Compliance-Report.config.example.json -Raw
.\New-MEAM-Compliance-Report.ps1 -ConfigJson $config
```

**Key Features:**
- ✅ Self-contained HTML (no external CSS/JS dependencies)
- ✅ Collapsible sections for easy navigation
- ✅ KPI cards showing compliance metrics
- ✅ Role-based account status (T0/T1 breakdowns)
- ✅ Break-glass account verification
- ✅ PAW readiness scoring
- ✅ GPO link validation
- ✅ Print-friendly formatting

**Output Artifacts:**
- `.\MEAM-TierReport-<yyyyMMdd>.html` - Main compliance report

### Configuration Files

#### Get-Tiering-Compliance-Report.config.example.json
```json
{
  "ScoringRules": {
    "TierMismatchPenalty": 50,
    "ZoneMismatchPenalty": 30,
    "ServiceMismatchPenalty": 20,
    "AgeFactor": 1.1
  },
  "ReportPath": ".\\reports\\Tiering-Compliance.csv",
  "WebhookUrl": "https://alerts.example.com/webhook",
  "EventQueryTimeoutSeconds": 20
}
```

#### New-MEAM-Compliance-Report.config.example.json
```json
{
  "TierScoping": {
    "Tiers": ["T0", "T1"],
    "IncludeStaleAccounts": true
  },
  "StaleThresholdDays": 90,
  "OutputPath": ".\\MEAM-TierReport.html",
  "ReportTitle": "MEAM Monthly Compliance Report"
}
```

## Monitoring Workflow

### Continuous Monitoring (Real-Time)
```powershell
# Run on schedule (e.g., every 4 hours)
# PowerShell Scheduled Task or Azure Automation Runbook

$schedule = New-JobTrigger -Daily -At 2:00 AM
Register-ScheduledJob -Name "MEAM-Compliance-Scan" `
  -ScriptBlock { .\Get-Tiering-Compliance-Report.ps1 -ConfigPath .\prod-config.json } `
  -Trigger $schedule
```

### Monthly Reporting
```powershell
# Run on first day of month for executive reporting
$trigger = New-JobTrigger -Daily -At 1:00 AM -DaysOfWeek Monday
Register-ScheduledJob -Name "MEAM-Monthly-Report" `
  -ScriptBlock { .\New-MEAM-Compliance-Report.ps1 -ConfigPath .\prod-config.json -OpenInBrowser } `
  -Trigger $trigger
```

### Alert Handling
If the webhook is configured and high-risk tier violations are detected:
1. System POSTs JSON alert to webhook URL
2. Alert handler (e.g., Azure Logic App) triggers response
3. Incident ticket created in ITSM
4. On-call team notified

## Troubleshooting

### Report Generation is Slow
- Check domain size: `(Get-ADComputer -Filter *).Count`
- Increase timeout: Update `EventQueryTimeoutSeconds` in config
- Run during off-peak hours
- Consider running reports in stages (per OU)

### No Data in Report
```powershell
# Verify AD connectivity
Get-ADDomain

# Check account counts
Get-ADComputer -Filter "OperatingSystem -like '*Server*'" | Measure-Object
Get-ADUser -Filter "Enabled -eq `$true" | Measure-Object

# Check filtering logic
Get-ADComputer -SearchBase "CN=Tier0,CN=Accounts,..." -Filter * | Select-Object Name, Description
```

### Webhook Not Firing
```powershell
# Test webhook endpoint manually
$body = @{ test = "alert" } | ConvertTo-Json
Invoke-WebRequest -Uri "https://alerts.example.com/webhook" `
  -Method POST -ContentType "application/json" -Body $body

# Check webhook URL in config
$config = Get-Content config.json | ConvertFrom-Json
$config.WebhookUrl
```

## Integration

### Azure DevOps Pipeline
```yaml
- task: PowerShell@2
  inputs:
    scriptPath: '3-Monitoring/New-MEAM-Compliance-Report.ps1'
    arguments: '-ConfigPath prod-config.json'
    pwsh: true
```

### GitHub Actions
```yaml
- name: Generate MEAM Report
  run: |
    .\3-Monitoring\New-MEAM-Compliance-Report.ps1 -ConfigPath prod-config.json
```

## Related Documentation

- **MEAM Deployment:** [1-Deployment/README.md](../1-Deployment/README.md)
- **Operations:** [OPERATIONS.md](../OPERATIONS.md)
- **Troubleshooting:** [TROUBLESHOOTING.md](../TROUBLESHOOTING.md)

---
**Version:** 1.0  
**Last Updated:** 2024  
**Maintainer:** Security Operations
