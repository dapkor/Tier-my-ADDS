#Requires -Modules ActiveDirectory
#Requires -Version 5.1
<#
.SYNOPSIS
    MEAM Monthly Tier Report — self-contained HTML compliance report for T0 and T1.
.DESCRIPTION
    Queries Active Directory for Tier 0 and Tier 1 security posture: user accounts,
    role groups, PSOs, Auth Silos, PAW computers, break-glass accounts and GPO links.
    Outputs a richly styled, fully self-contained HTML file with summary KPI cards,
    collapsible sections and PASS/FAIL/WARN compliance checks.

    Designed to run on a scheduled GitHub Actions or Azure DevOps pipeline using a
    domain-joined self-hosted runner with RSAT ActiveDirectory installed.

.PARAMETER ConfigPath
    Path to the MEAM JSON config file (same schema as script_v2.ps1).

.PARAMETER ConfigJson
    Inline JSON config string (for pipeline inline injection).

.PARAMETER OutputPath
    Override the HTML output path.
    Default: .\MEAM-TierReport-<yyyyMMdd>.html

.PARAMETER StaleThresholdDays
    Days without logon before an account is flagged stale. Default: 90.

.PARAMETER OpenInBrowser
    If set, opens the generated HTML in the default browser after writing.

.EXAMPLE
    .\MEAM-Tier-Report.ps1 -ConfigPath .\MEAM-Tier-Report.config.json
    .\MEAM-Tier-Report.ps1 -ConfigPath .\MEAM-Tier-Report.config.json -StaleThresholdDays 60 -OpenInBrowser

.NOTES
    Author   : @dapkor
    Version  : 1.0

    ── RUNNER / AGENT REQUIREMENTS ─────────────────────────────────────────────
    This script queries Active Directory via the Microsoft ActiveDirectory module
    (RSAT). It does NOT require elevated privileges. A standard domain read-only
    account is sufficient for all queries.

    The machine executing this script must meet ALL of the following:

      1. DOMAIN-JOINED (or have direct LDAP network access to a DC on port 389/636)
         The script uses Kerberos; the executing machine must be able to obtain a
         TGT against your domain.

      2. RSAT — ActiveDirectory PowerShell module installed
         Windows Server:
           Install-WindowsFeature RSAT-AD-PowerShell
         Windows 10/11:
           Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0

      3. RSAT — GroupPolicy module (OPTIONAL — needed for GPO link tables)
         Windows Server:
           Install-WindowsFeature GPMC
         Windows 10/11:
           Add-WindowsCapability -Online -Name Rsat.GroupPolicy.Management.Tools~~~~0.0.1.0

      4. SERVICE ACCOUNT PERMISSIONS — READ-ONLY IS ENOUGH
         The account running this script needs only these built-in rights:
           • Member of "Domain Users" (default for any domain account)
           • Read access on all OU/object types (granted to Domain Users by default)
         No admin rights, no tier-0/tier-1 role group membership required.
         Recommended: create a dedicated low-privilege service account, e.g.
           svc-meam-report   (Domain Users only, no interactive logon rights)

      5. PIPELINE RUNNERS (GitHub Actions / Azure DevOps)
         The self-hosted runner or agent MUST satisfy requirements 1-4 above.
         It is strongly recommended to run on a Tier 1 server (Zone 1B or 1C)
         using the dedicated svc-meam-report account.
         DO NOT run on a Tier 0 / Domain Controller.
    ─────────────────────────────────────────────────────────────────────────────
#>
[CmdletBinding(DefaultParameterSetName = 'ConfigFile')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ConfigFile')]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath,

    [Parameter(Mandatory, ParameterSetName = 'ConfigInline')]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigJson,

    [string]$OutputPath,
    [int]$StaleThresholdDays = 90,
    [switch]$OpenInBrowser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:QueryTuning = [ordered]@{
    RetryCount = 2
    RetryDelaySeconds = 2
}

function New-DirectoryForFilePath {
    param([Parameter(Mandatory)][string]$FilePath)

    $dir = Split-Path -LiteralPath $FilePath -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
}

function Set-TextFileContent {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [AllowEmptyString()][Parameter(Mandatory)]$Value
    )

    New-DirectoryForFilePath -FilePath $FilePath
    Set-Content -LiteralPath $FilePath -Value $Value -Encoding UTF8
}

function Get-OptionalIntValue {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$PropertyName,
        [Parameter(Mandatory)][int]$DefaultValue
    )

    if ($null -eq $Object -or -not $Object.PSObject.Properties.Name.Contains($PropertyName)) {
        return $DefaultValue
    }

    $parsed = 0
    if ([int]::TryParse([string]$Object.$PropertyName, [ref]$parsed) -and $parsed -ge 0) {
        return $parsed
    }

    return $DefaultValue
}

function Initialize-QueryTuning {
    param($Config)

    $settings = $null
    if ($Config.PSObject.Properties.Name.Contains('QueryTuning')) {
        $settings = $Config.QueryTuning
    }

    $script:QueryTuning = [ordered]@{
        RetryCount = Get-OptionalIntValue -Object $settings -PropertyName 'RetryCount' -DefaultValue 2
        RetryDelaySeconds = Get-OptionalIntValue -Object $settings -PropertyName 'RetryDelaySeconds' -DefaultValue 2
    }
}

function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [Parameter(Mandatory)][string]$Operation
    )

    $attempt = 0
    while ($true) {
        try {
            return & $ScriptBlock
        }
        catch {
            if ($attempt -ge [int]$script:QueryTuning.RetryCount) {
                throw
            }

            $attempt++
            Write-Warning ("{0} failed on attempt {1}. Retrying in {2} second(s): {3}" -f $Operation, $attempt, $script:QueryTuning.RetryDelaySeconds, $_.Exception.Message)
            Start-Sleep -Seconds ([int]$script:QueryTuning.RetryDelaySeconds)
        }
    }
}

# ─── Config load ──────────────────────────────────────────────────────────────
if ($PSBoundParameters.ContainsKey('ConfigPath')) {
    if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) { throw "Config file not found: $ConfigPath" }
    $rawJson = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
} else {
    $rawJson = $ConfigJson
}
try { $Cfg = $rawJson | ConvertFrom-Json -Depth 20 } catch { throw "Invalid JSON: $($_.Exception.Message)" }
Initialize-QueryTuning -Config $Cfg

# ─── Domain detection ────────────────────────────────────────────────────────
Write-Host '[INFO] Connecting to Active Directory...' -ForegroundColor Cyan
$adDomain   = Invoke-WithRetry -Operation 'Get-ADDomain' -ScriptBlock { Get-ADDomain }
$DomainFQDN = $adDomain.DNSRoot
$DomainDN   = $adDomain.DistinguishedName
$CorpOU     = if ($Cfg.PSObject.Properties.Name -contains 'CorpOU') { [string]$Cfg.CorpOU } else { 'Corp' }
$CorpDN     = "OU=$CorpOU,$DomainDN"
$TiersDN    = "OU=Tiers,$CorpDN"

$staleDate  = (Get-Date).AddDays(-$StaleThresholdDays)

if (-not $PSBoundParameters.ContainsKey('OutputPath') -or [string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = ".\MEAM-TierReport-$(Get-Date -Format 'yyyyMMdd').html"
}
$OutputDir = Split-Path -Parent $OutputPath
if ($OutputDir -and -not (Test-Path -LiteralPath $OutputDir)) { New-Item -Path $OutputDir -ItemType Directory -Force | Out-Null }

# ─── Helpers ─────────────────────────────────────────────────────────────────
function Esc([string]$s) {
    if ([string]::IsNullOrEmpty($s)) { return '' }
    $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}

function Get-PsoKey([string]$key) {
    try { return $Cfg.PSO.$key } catch { return $null }
}

# ─────────────────────────────────────────────────────────────────────────────
# RUNNER REQUIREMENTS (summary — full detail in .NOTES above)
#   Machine   : Domain-joined Windows host (NOT a Domain Controller)
#   Module    : RSAT ActiveDirectory  (mandatory)
#               RSAT GroupPolicy      (optional — enables GPO link table)
#   Account   : Domain Users (read-only). No admin rights required.
#               Recommended service account: svc-meam-report
#   Network   : Port 389/636 to a DC must be reachable from the runner
# ─────────────────────────────────────────────────────────────────────────────

# ─── Data collection ─────────────────────────────────────────────────────────
Write-Host "[INFO] Querying AD objects in $DomainFQDN..." -ForegroundColor Cyan

$userProps = @('SamAccountName','DisplayName','Enabled','PasswordLastSet','LastLogonDate',
               'SmartcardLogonRequired','Description','DistinguishedName','MemberOf')

$collect = @{
    T0Users       = @()
    T1Users       = @()
    T0Groups      = @()
    T1Groups      = @()
    ProtectedUsers = @()
    DomainAdmins  = @()
    PSOs          = @()
    Silos         = @()
    PAWComputers  = @()
    BreakGlass    = @()
    T0GPOLinks    = @()
    T1GPOLinks    = @()
}

# Users per tier
foreach ($tier in @('T0','T1')) {
    $ouLabel = if ($tier -eq 'T0') { 'Tier 0' } else { 'Tier 1' }
    $base = "OU=$ouLabel,$TiersDN"
    try {
        if (Invoke-WithRetry -Operation "Get-ADOrganizationalUnit $base" -ScriptBlock { Get-ADOrganizationalUnit -Identity $base -ErrorAction SilentlyContinue }) {
            $userKey = '{0}Users' -f $tier
            $collect[$userKey] = @(Invoke-WithRetry -Operation "Get-ADUser tier $tier" -ScriptBlock { Get-ADUser -Filter * -SearchBase $base -SearchScope Subtree -Properties $userProps -ErrorAction Stop })
            Write-Host ("  [OK] {0} {1} user(s)" -f $collect[$userKey].Count, $tier)
        } else {
            Write-Warning "OU not found: $base"
        }
    } catch { Write-Warning ("T{0} users: {1}" -f $tier, $_.Exception.Message) }
}

# Role groups
foreach ($tier in @('T0','T1')) {
    $prefix = $tier
    try {
        $groupKey = '{0}Groups' -f $tier
        $collect[$groupKey] = @(Invoke-WithRetry -Operation "Get-ADGroup prefix $prefix" -ScriptBlock { Get-ADGroup -Filter "Name -like '$prefix-*'" -Properties Members,Description -ErrorAction Stop | Sort-Object Name })
        Write-Host ("  [OK] {0} {1} group(s)" -f $collect[$groupKey].Count, $tier)
    } catch { Write-Warning ("{0} groups: {1}" -f $tier, $_.Exception.Message) }
}

# Protected Users
try {
    $collect.ProtectedUsers = @(Invoke-WithRetry -Operation 'Get-ADGroupMember Protected Users' -ScriptBlock { Get-ADGroupMember 'Protected Users' -Recursive -ErrorAction Stop } |
        Where-Object { $_.objectClass -eq 'user' } | Select-Object -ExpandProperty SamAccountName)
    Write-Host "  [OK] Protected Users: $($collect.ProtectedUsers.Count) member(s)"
} catch { Write-Warning ("Protected Users: {0}" -f $_.Exception.Message) }

# Domain Admins
try {
    $collect.DomainAdmins = @(Invoke-WithRetry -Operation 'Get-ADGroupMember Domain Admins' -ScriptBlock { Get-ADGroupMember 'Domain Admins' -ErrorAction Stop } |
        Where-Object { $_.objectClass -eq 'user' })
    Write-Host "  [OK] Domain Admins: $($collect.DomainAdmins.Count) direct user(s)"
} catch { Write-Warning ("Domain Admins: {0}" -f $_.Exception.Message) }

# PSOs
try {
    $collect.PSOs = @(Invoke-WithRetry -Operation 'Get-ADFineGrainedPasswordPolicy' -ScriptBlock { Get-ADFineGrainedPasswordPolicy -Filter * -Properties AppliesTo -ErrorAction Stop | Sort-Object Precedence })
    Write-Host "  [OK] PSOs: $($collect.PSOs.Count) found"
} catch { Write-Warning ("PSOs: {0}" -f $_.Exception.Message) }

# Auth Silos
try {
    $collect.Silos = @(Invoke-WithRetry -Operation 'Get-ADAuthenticationPolicySilo' -ScriptBlock { Get-ADAuthenticationPolicySilo -Filter * -ErrorAction Stop | Sort-Object Name })
    Write-Host "  [OK] Auth Silos: $($collect.Silos.Count) found"
} catch { Write-Warning ("Auth Silos (requires DFL 2012R2+): {0}" -f $_.Exception.Message) }

# PAW computers (Tier 0 PAWs)
try {
    $pawBase = "OU=PAWs,OU=Tier 0,$TiersDN"
    if (Invoke-WithRetry -Operation "Get-ADOrganizationalUnit $pawBase" -ScriptBlock { Get-ADOrganizationalUnit -Identity $pawBase -ErrorAction SilentlyContinue }) {
        $collect.PAWComputers = @(Invoke-WithRetry -Operation 'Get-ADComputer PAW inventory' -ScriptBlock { Get-ADComputer -Filter * -SearchBase $pawBase -Properties Description,LastLogonDate,OperatingSystem -ErrorAction Stop | Sort-Object Name })
        Write-Host "  [OK] PAW computers: $($collect.PAWComputers.Count)"
    }
} catch { Write-Warning ("PAW computers: {0}" -f $_.Exception.Message) }

# Break-glass accounts
$bgSam1 = try { [string]$Cfg.BreakGlass.Account1 } catch { 'brk-glass-01' }
$bgSam2 = try { [string]$Cfg.BreakGlass.Account2 } catch { 'brk-glass-02' }
foreach ($bgSam in @($bgSam1, $bgSam2)) {
    if ([string]::IsNullOrWhiteSpace($bgSam)) { continue }
    try {
        $u = Invoke-WithRetry -Operation "Get-ADUser break-glass $bgSam" -ScriptBlock {
            Get-ADUser -Filter "SamAccountName -eq '$bgSam'" `
                -Properties PasswordLastSet, LastLogonDate, Enabled, PasswordNeverExpires, SmartcardLogonRequired -ErrorAction SilentlyContinue
        }
        if ($u) { $collect.BreakGlass += $u }
    } catch { Write-Warning ("Break-glass {0}: {1}" -f $bgSam, $_.Exception.Message) }
}

# GPO links to tier OUs
try {
    Import-Module GroupPolicy -ErrorAction SilentlyContinue
    $t0Inh = Invoke-WithRetry -Operation 'Get-GPInheritance Tier 0' -ScriptBlock { Get-GPInheritance -Target "OU=Tier 0,$TiersDN" -ErrorAction SilentlyContinue }
    if ($t0Inh) { $collect.T0GPOLinks = @($t0Inh.GpoLinks) }
    $t1Inh = Invoke-WithRetry -Operation 'Get-GPInheritance Tier 1' -ScriptBlock { Get-GPInheritance -Target "OU=Tier 1,$TiersDN" -ErrorAction SilentlyContinue }
    if ($t1Inh) { $collect.T1GPOLinks = @($t1Inh.GpoLinks) }
    Write-Host "  [OK] GPO links: T0=$($collect.T0GPOLinks.Count) T1=$($collect.T1GPOLinks.Count)"
} catch { Write-Warning ("GPO links: {0}" -f $_.Exception.Message) }

# ─── Compliance checks ────────────────────────────────────────────────────────
Write-Host '[INFO] Running compliance checks...' -ForegroundColor Cyan
$checks = [System.Collections.Generic.List[hashtable]]::new()
function Add-Check([string]$Name, [string]$Status, [string]$Detail = '') {
    $checks.Add([ordered]@{ Name = $Name; Status = $Status; Detail = $Detail })
}

# Domain Admins: no direct users
Add-Check 'Domain Admins — no direct user members' `
    $(if ($collect.DomainAdmins.Count -eq 0) { 'PASS' } else { 'FAIL' }) `
    $(if ($collect.DomainAdmins.Count -gt 0) { "Direct members: $($collect.DomainAdmins.SamAccountName -join ', ')" } else { 'No direct user members' })

# PSO checks
foreach ($key in @('T0','T1','T2','SA')) {
    $psoName  = try { [string](Get-PsoKey $key).Name } catch { '' }
    if ([string]::IsNullOrEmpty($psoName)) { $psoName = "PSO-$key" }
    $found = $collect.PSOs | Where-Object { $_.Name -eq $psoName }
    Add-Check "PSO present: $psoName" `
        $(if ($found) { 'PASS' } else { 'FAIL' }) `
        $(if ($found) { "Precedence $($found.Precedence), MinLength=$($found.MinPasswordLength)" } else { 'NOT FOUND in AD' })
}

# T0 users all in Protected Users
$t0Sams      = @($collect.T0Users | Select-Object -ExpandProperty SamAccountName)
$t0NotInPU   = @($t0Sams | Where-Object { $_ -notin $collect.ProtectedUsers })
Add-Check 'All T0 users in Protected Users group' `
    $(if ($t0NotInPU.Count -eq 0) { 'PASS' } elseif ($collect.T0Users.Count -eq 0) { 'WARN' } else { 'FAIL' }) `
    $(if ($t0NotInPU.Count -gt 0) { "Missing: $($t0NotInPU -join ', ')" } else { "All $($t0Sams.Count) T0 account(s) covered" })

# T0 smartcard enforcement
$t0NoSC = @($collect.T0Users | Where-Object { $_.Enabled -and -not $_.SmartcardLogonRequired })
Add-Check 'T0 SmartcardLogonRequired on all active accounts' `
    $(if ($t0NoSC.Count -eq 0) { 'PASS' } else { 'FAIL' }) `
    $(if ($t0NoSC.Count -gt 0) { "Not enforced on: $($t0NoSC.SamAccountName -join ', ')" } else { "All $($collect.T0Users.Count) T0 account(s) enforced" })

# T0 stale accounts
$t0Stale = @($collect.T0Users | Where-Object { $_.Enabled -and ($null -eq $_.LastLogonDate -or $_.LastLogonDate -lt $staleDate) })
Add-Check "T0 stale active accounts (>${StaleThresholdDays} days)" `
    $(if ($t0Stale.Count -eq 0) { 'PASS' } else { 'WARN' }) `
    $(if ($t0Stale.Count -gt 0) { "$($t0Stale.Count) stale account(s): $($t0Stale.SamAccountName -join ', ')" } else { 'None' })

# T1 stale accounts
$t1Stale = @($collect.T1Users | Where-Object { $_.Enabled -and ($null -eq $_.LastLogonDate -or $_.LastLogonDate -lt $staleDate) })
Add-Check "T1 stale active accounts (>${StaleThresholdDays} days)" `
    $(if ($t1Stale.Count -eq 0) { 'PASS' } else { 'WARN' }) `
    $(if ($t1Stale.Count -gt 0) { "$($t1Stale.Count) stale account(s)" } else { 'None' })

# Auth silos
Add-Check 'Authentication Policy Silos configured' `
    $(if ($collect.Silos.Count -ge 2) { 'PASS' } elseif ($collect.Silos.Count -gt 0) { 'WARN' } else { 'FAIL' }) `
    "$($collect.Silos.Count) silo(s) found: $($collect.Silos.Name -join ', ')"

# Break-glass exists
Add-Check 'Break-glass accounts present' `
    $(if ($collect.BreakGlass.Count -ge 2) { 'PASS' } elseif ($collect.BreakGlass.Count -gt 0) { 'WARN' } else { 'FAIL' }) `
    $(if ($collect.BreakGlass.Count -gt 0) { "$($collect.BreakGlass.Count) account(s): $($collect.BreakGlass.SamAccountName -join ', ')" } else { 'No break-glass accounts found' })

# Break-glass: no recent logon (should never be used)
$bgRecentLogon = @($collect.BreakGlass | Where-Object { $null -ne $_.LastLogonDate -and $_.LastLogonDate -gt (Get-Date).AddDays(-30) })
Add-Check 'Break-glass not used in past 30 days' `
    $(if ($bgRecentLogon.Count -eq 0) { 'PASS' } else { 'WARN' }) `
    $(if ($bgRecentLogon.Count -gt 0) { "Recent logon detected: $($bgRecentLogon.SamAccountName -join ', ')" } else { 'No recent logon activity' })

# ─── Summary stats ────────────────────────────────────────────────────────────
$totalFails = ($checks | Where-Object { $_.Status -eq 'FAIL' }).Count
$totalWarns = ($checks | Where-Object { $_.Status -eq 'WARN' }).Count
$allUsers   = @($collect.T0Users) + @($collect.T1Users)
$totalStale = (@($allUsers) | Where-Object { $_.Enabled -and ($null -eq $_.LastLogonDate -or $_.LastLogonDate -lt $staleDate) }).Count

$overallBadge = if ($totalFails -gt 0) { 'FAIL' } elseif ($totalWarns -gt 0) { 'WARN' } else { 'PASS' }

# ─── HTML templates ───────────────────────────────────────────────────────────
$css = @'
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:'Segoe UI',Arial,sans-serif;background:#f0f2f5;color:#1a1a2e;font-size:14px}
  a{color:#2980b9;text-decoration:none}
  /* ── Header */
  .report-header{background:linear-gradient(135deg,#0f3460 0%,#16213e 100%);color:#fff;padding:28px 40px;display:flex;justify-content:space-between;align-items:flex-end}
  .report-header h1{font-size:22px;font-weight:700;letter-spacing:.3px}
  .report-header .meta{font-size:12px;opacity:.75;margin-top:6px;line-height:1.8}
  .overall-badge{font-size:13px;font-weight:700;padding:6px 18px;border-radius:20px;letter-spacing:.5px}
  .overall-pass{background:#27ae60;color:#fff}
  .overall-warn{background:#e67e22;color:#fff}
  .overall-fail{background:#e74c3c;color:#fff}
  /* ── Container */
  .wrap{max-width:1380px;margin:0 auto;padding:28px 32px}
  /* ── KPI cards */
  .kpi-row{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:16px;margin-bottom:28px}
  .kpi{background:#fff;border-radius:10px;padding:20px 16px;text-align:center;box-shadow:0 2px 8px rgba(0,0,0,.07)}
  .kpi .num{font-size:38px;font-weight:800;line-height:1}
  .kpi .label{font-size:11px;text-transform:uppercase;letter-spacing:.6px;color:#888;margin-top:6px}
  .c-blue .num{color:#2980b9}.c-purple .num{color:#8e44ad}.c-green .num{color:#27ae60}
  .c-orange .num{color:#e67e22}.c-red .num{color:#e74c3c}.c-teal .num{color:#16a085}
  /* ── Sections */
  details{background:#fff;border-radius:10px;margin-bottom:18px;box-shadow:0 2px 8px rgba(0,0,0,.07);overflow:hidden}
  details summary{padding:15px 22px;cursor:pointer;font-size:15px;font-weight:700;background:#f8f9fa;border-bottom:1px solid #eee;list-style:none;display:flex;align-items:center;gap:10px;user-select:none}
  details summary::-webkit-details-marker{display:none}
  details summary::before{content:'▶';font-size:10px;color:#999;transition:transform .2s}
  details[open] summary::before{transform:rotate(90deg)}
  .section-body{padding:20px 24px}
  /* ── Sub-sections */
  .sub{margin-top:22px}
  .sub:first-child{margin-top:0}
  .sub-title{font-size:13px;font-weight:700;color:#0f3460;text-transform:uppercase;letter-spacing:.4px;margin-bottom:10px;padding-bottom:4px;border-bottom:2px solid #e8eaf0}
  /* ── Tables */
  table{width:100%;border-collapse:collapse;font-size:13px}
  th{background:#f0f2f5;text-align:left;padding:9px 12px;font-weight:700;font-size:12px;text-transform:uppercase;letter-spacing:.3px;white-space:nowrap;border-bottom:2px solid #dde1e7}
  td{padding:8px 12px;border-bottom:1px solid #f2f3f5;vertical-align:middle}
  tr:last-child td{border-bottom:none}
  tr:hover td{background:#f8f9fb}
  /* ── Badges */
  .b{display:inline-block;padding:2px 9px;border-radius:12px;font-size:11px;font-weight:700;white-space:nowrap}
  .b-pass{background:#d4edda;color:#155724}.b-fail{background:#f8d7da;color:#721c24}
  .b-warn{background:#fff3cd;color:#7d5a00}.b-info{background:#d1ecf1;color:#0c5460}
  .b-t0{background:#fde8e8;color:#922b21}.b-t1{background:#fef9e7;color:#7d6608}
  .b-t2{background:#eafaf1;color:#1e8449}.b-na{background:#f0f2f5;color:#6c757d}
  /* ── Value colors */
  .ok{color:#27ae60;font-weight:600}.bad{color:#e74c3c;font-weight:600}.warn-c{color:#e67e22;font-weight:600}
  /* ── PSO table */
  .pso-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(260px,1fr));gap:16px}
  .pso-card{border:1px solid #e8eaf0;border-radius:8px;padding:16px;background:#fafbfc}
  .pso-card h4{font-size:13px;margin-bottom:10px;color:#0f3460}
  .pso-card dl{display:grid;grid-template-columns:auto 1fr;gap:3px 12px;font-size:12px}
  .pso-card dt{color:#888;white-space:nowrap}.pso-card dd{font-weight:600}
  /* ── Empty state */
  .empty{color:#aaa;font-style:italic;padding:12px 0;font-size:13px}
  /* ── Compliance table */
  .comp-pass td:first-child{border-left:3px solid #27ae60}
  .comp-fail td:first-child{border-left:3px solid #e74c3c}
  .comp-warn td:first-child{border-left:3px solid #e67e22}
  /* ── Footer */
  .footer{text-align:center;color:#bbb;font-size:12px;padding:28px 0 40px}
</style>
'@

function Get-StatusBadge([string]$s) {
    $cls = switch ($s) { 'PASS' {'b-pass'} 'FAIL' {'b-fail'} 'WARN' {'b-warn'} default {'b-info'} }
    "<span class='b $cls'>$s</span>"
}
function Get-TierBadge([string]$t) {
    $cls = switch ($t) { 'T0' {'b-t0'} 'T1' {'b-t1'} 'T2' {'b-t2'} default {'b-na'} }
    "<span class='b $cls'>$t</span>"
}
function Format-DisplayDate($d, [switch]$FlagOld) {
    if ($null -eq $d) { return "<span class='bad'>Never</span>" }
    $s = $d.ToString('yyyy-MM-dd')
    if ($FlagOld -and $d -lt $staleDate) { return "<span class='bad'>$s &#9888;</span>" }
    return $s
}
function Format-DisplayBool($v, [switch]$InvertBad) {
    if ($v) { return $(if (-not $InvertBad) { "<span class='ok'>Yes</span>" } else { "<span class='bad'>Yes &#9888;</span>" }) }
    return   $(if (-not $InvertBad) { "<span class='bad'>No &#9888;</span>" } else { "<span class='ok'>No</span>" })
}

function Build-UserTable([array]$Users) {
    if ($null -eq $Users -or $Users.Count -eq 0) { return "<p class='empty'>No accounts found in this tier.</p>" }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<table><tr><th>SAM Account</th><th>Display Name</th><th>Enabled</th><th>Last Logon</th><th>Pwd Last Set</th><th>Smartcard</th><th>Protected Users</th><th>OU</th></tr>")
    foreach ($u in ($Users | Sort-Object SamAccountName)) {
        $inPU  = $u.SamAccountName -in $collect.ProtectedUsers
        $ouPart= ($u.DistinguishedName -split ',' | Where-Object { $_ -like 'OU=*' } | Select-Object -First 1) -replace 'OU=',''
        $rowClass = if ($u.Enabled -and (($null -eq $u.LastLogonDate) -or $u.LastLogonDate -lt $staleDate)) { " class='comp-warn'" } else { '' }
        [void]$sb.Append("<tr$rowClass>")
        [void]$sb.Append("<td>$(Esc $u.SamAccountName)</td>")
        [void]$sb.Append("<td>$(Esc ([string]$u.DisplayName))</td>")
        [void]$sb.Append("<td>$(Format-DisplayBool $u.Enabled)</td>")
        [void]$sb.Append("<td>$(Format-DisplayDate $u.LastLogonDate -FlagOld)</td>")
        [void]$sb.Append("<td>$(Format-DisplayDate $u.PasswordLastSet)</td>")
        [void]$sb.Append("<td>$(Format-DisplayBool $u.SmartcardLogonRequired)</td>")
        [void]$sb.Append("<td>$(Format-DisplayBool $inPU)</td>")
        [void]$sb.Append("<td>$(Esc $ouPart)</td></tr>")
    }
    [void]$sb.Append("</table>")
    return $sb.ToString()
}

function Build-GroupTable([array]$Groups) {
    if ($null -eq $Groups -or $Groups.Count -eq 0) { return "<p class='empty'>No groups found.</p>" }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<table><tr><th>Group Name</th><th>Scope</th><th>Member Count</th><th>Description</th></tr>")
    foreach ($g in $Groups) {
        $cnt  = @($g.Members).Count
        $cntClass = if ($cnt -eq 0) { " class='warn-c'" } else { '' }
        [void]$sb.Append("<tr>")
        [void]$sb.Append("<td>$(Esc $g.Name)</td>")
        [void]$sb.Append("<td><span class='b b-info'>$($g.GroupScope)</span></td>")
        [void]$sb.Append("<td$cntClass>$cnt</td>")
        [void]$sb.Append("<td>$(Esc ([string]$g.Description))</td></tr>")
    }
    [void]$sb.Append("</table>")
    return $sb.ToString()
}

function Build-PSOCards([array]$PSOs) {
    if ($null -eq $PSOs -or $PSOs.Count -eq 0) { return "<p class='empty'>No Fine-Grained Password Policies found.</p>" }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<div class='pso-grid'>")
    foreach ($p in $PSOs) {
        $tier = if ($p.Name -match 'Tier0') {'T0'} elseif ($p.Name -match 'Tier1') {'T1'} elseif ($p.Name -match 'Tier2') {'T2'} else {'SA'}
        [void]$sb.Append("<div class='pso-card'><h4>$(Esc $p.Name) $(Get-TierBadge $tier)</h4><dl>")
        [void]$sb.Append("<dt>Precedence</dt><dd>$($p.Precedence)</dd>")
        [void]$sb.Append("<dt>Min Length</dt><dd>$($p.MinPasswordLength)</dd>")
        [void]$sb.Append("<dt>Max Age</dt><dd>$(if ($p.MaxPasswordAge.TotalDays -gt 36000) {'No max'} else {"$([int]$p.MaxPasswordAge.TotalDays) days"})</dd>")
        [void]$sb.Append("<dt>Min Age</dt><dd>$([int]$p.MinPasswordAge.TotalDays) day(s)</dd>")
        [void]$sb.Append("<dt>History</dt><dd>$($p.PasswordHistoryCount)</dd>")
        [void]$sb.Append("<dt>Lockout Threshold</dt><dd>$(if ($p.LockoutThreshold -eq 0) {'<span class=ok>Disabled</span>'} else {$p.LockoutThreshold})</dd>")
        [void]$sb.Append("<dt>Lockout Duration</dt><dd>$(if ($p.LockoutDuration.TotalMinutes -gt 35000) {'Permanent'} else {"$([int]$p.LockoutDuration.TotalMinutes) min"})</dd>")
        $appliesToCount = 0
        try { $appliesToCount = @($p.AppliesTo).Count } catch {}
        [void]$sb.Append("<dt>Applied to</dt><dd>$appliesToCount object(s)</dd>")
        [void]$sb.Append("</dl></div>")
    }
    [void]$sb.Append("</div>")
    return $sb.ToString()
}

function Build-ComplianceTable([System.Collections.Generic.List[hashtable]]$Checks) {
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<table><tr><th>Check</th><th>Status</th><th>Detail</th></tr>")
    foreach ($c in $Checks) {
        $rowCls = switch ($c.Status) { 'PASS' {'comp-pass'} 'FAIL' {'comp-fail'} default {'comp-warn'} }
        [void]$sb.Append("<tr class='$rowCls'>")
        [void]$sb.Append("<td>$(Esc $c.Name)</td>")
        [void]$sb.Append("<td>$(Get-StatusBadge $c.Status)</td>")
        [void]$sb.Append("<td>$(Esc $c.Detail)</td></tr>")
    }
    [void]$sb.Append("</table>")
    return $sb.ToString()
}

function Build-GPOTable([array]$Links) {
    if ($null -eq $Links -or $Links.Count -eq 0) { return "<p class='empty'>No GPO links found (GroupPolicy module may not be available).</p>" }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<table><tr><th>GPO Name</th><th>Enabled</th><th>Enforced</th><th>Order</th></tr>")
    foreach ($lnk in ($Links | Sort-Object Order)) {
        [void]$sb.Append("<tr>")
        [void]$sb.Append("<td>$(Esc $lnk.DisplayName)</td>")
        [void]$sb.Append("<td>$(Format-DisplayBool $lnk.Enabled)</td>")
        [void]$sb.Append("<td>$(Format-DisplayBool $lnk.Enforced -InvertBad)</td>")
        [void]$sb.Append("<td>$($lnk.Order)</td></tr>")
    }
    [void]$sb.Append("</table>")
    return $sb.ToString()
}

function Build-SiloTable([array]$Silos) {
    if ($null -eq $Silos -or $Silos.Count -eq 0) { return "<p class='empty'>No Authentication Policy Silos found (requires DFL 2012R2+).</p>" }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<table><tr><th>Silo Name</th><th>Enforced</th></tr>")
    foreach ($silo in $Silos) {
        [void]$sb.Append("<tr><td>$(Esc $silo.Name)</td>")
        [void]$sb.Append("<td>$(Format-DisplayBool $silo.Enforce)</td></tr>")
    }
    [void]$sb.Append("</table>")
    return $sb.ToString()
}

function Build-PAWTable([array]$PAWs) {
    if ($null -eq $PAWs -or $PAWs.Count -eq 0) { return "<p class='empty'>No PAW computer objects found in OU=PAWs,OU=Tier 0.</p>" }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<table><tr><th>Name</th><th>OS</th><th>Last Logon</th><th>Description</th></tr>")
    foreach ($c in $PAWs) {
        [void]$sb.Append("<tr>")
        [void]$sb.Append("<td>$(Esc $c.Name)</td>")
        [void]$sb.Append("<td>$(Esc ([string]$c.OperatingSystem))</td>")
        [void]$sb.Append("<td>$(Format-DisplayDate $c.LastLogonDate -FlagOld)</td>")
        [void]$sb.Append("<td>$(Esc ([string]$c.Description))</td></tr>")
    }
    [void]$sb.Append("</table>")
    return $sb.ToString()
}

function Build-BreakGlassTable([array]$Accounts) {
    if ($null -eq $Accounts -or $Accounts.Count -eq 0) { return "<p class='empty'>No break-glass accounts found.</p>" }
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append("<table><tr><th>SAM Account</th><th>Enabled</th><th>Last Logon</th><th>Pwd Last Set</th><th>Pwd Never Expires</th><th>Smartcard Required</th></tr>")
    foreach ($u in $Accounts) {
        # Break-glass should NOT have recent logon - flag it if logged in within 30 days
        $recentLogon = $null -ne $u.LastLogonDate -and $u.LastLogonDate -gt (Get-Date).AddDays(-30)
        [void]$sb.Append("<tr>")
        [void]$sb.Append("<td>$(Esc $u.SamAccountName)</td>")
        [void]$sb.Append("<td>$(Format-DisplayBool $u.Enabled)</td>")
        $logonClass = if ($recentLogon) { " class='bad'" } else { '' }
        [void]$sb.Append("<td$logonClass>$(Format-DisplayDate $u.LastLogonDate)$(if ($recentLogon) {' &#9888; USED RECENTLY'} else {''})</td>")
        [void]$sb.Append("<td>$(Format-DisplayDate $u.PasswordLastSet)</td>")
        [void]$sb.Append("<td>$(Format-DisplayBool $u.PasswordNeverExpires -InvertBad)</td>")
        # Break-glass should NOT require smartcard (can't use smartcard in recovery scenario)
        [void]$sb.Append("<td>$(if (-not $u.SmartcardLogonRequired) { "<span class='ok'>No (correct)</span>" } else { "<span class='warn-c'>Yes &#9888;</span>" })</td>")
        [void]$sb.Append("</tr>")
    }
    [void]$sb.Append("</table>")
    return $sb.ToString()
}

# ─── Overall badge class ─────────────────────────────────────────────────────
$overallClass = switch ($overallBadge) { 'PASS' {'overall-pass'} 'FAIL' {'overall-fail'} default {'overall-warn'} }
$overallLabel = switch ($overallBadge) { 'PASS' {'COMPLIANT'} 'FAIL' {"$totalFails FAILURE(S)"} default {"$totalWarns WARNING(S)"} }
$reportDate   = Get-Date -Format 'dddd dd MMMM yyyy — HH:mm UTC'
$domainLabel  = Esc $DomainFQDN

# ─── Assemble HTML ────────────────────────────────────────────────────────────
$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>MEAM Tier Report — $domainLabel — $(Get-Date -Format 'yyyy-MM-dd')</title>
  $css
</head>
<body>

<div class="report-header">
  <div>
    <h1>&#x1F6E1; MEAM Tier Compliance Report</h1>
    <div class="meta">
      Domain: <strong>$domainLabel</strong> &nbsp;|&nbsp;
      Generated: <strong>$reportDate</strong> &nbsp;|&nbsp;
      Stale threshold: <strong>${StaleThresholdDays} days</strong>
    </div>
  </div>
  <span class="overall-badge $overallClass">$overallLabel</span>
</div>

<div class="wrap">

  <!-- KPI Row -->
  <div class="kpi-row">
    <div class="kpi c-blue"><div class="num">$($collect.T0Users.Count)</div><div class="label">T0 Accounts</div></div>
    <div class="kpi c-purple"><div class="num">$($collect.T1Users.Count)</div><div class="label">T1 Accounts</div></div>
    <div class="kpi c-teal"><div class="num">$($collect.T0Groups.Count + $collect.T1Groups.Count)</div><div class="label">Role Groups</div></div>
    <div class="kpi c-orange"><div class="num">$totalStale</div><div class="label">Stale Accounts</div></div>
    <div class="kpi $(if ($totalFails -gt 0) {'c-red'} else {'c-green'})"><div class="num">$totalFails</div><div class="label">Failures</div></div>
    <div class="kpi $(if ($totalWarns -gt 0) {'c-orange'} else {'c-green'})"><div class="num">$totalWarns</div><div class="label">Warnings</div></div>
    <div class="kpi c-teal"><div class="num">$($collect.Silos.Count)</div><div class="label">Auth Silos</div></div>
    <div class="kpi c-blue"><div class="num">$($collect.PAWComputers.Count)</div><div class="label">PAW Devices</div></div>
  </div>

  <!-- Compliance Summary -->
  <details open>
    <summary>&#x2714; Compliance Checks ($($checks.Count) total)</summary>
    <div class="section-body">
      $(Build-ComplianceTable $checks)
    </div>
  </details>

  <!-- Tier 0 -->
  <details open>
    <summary><span class="b b-t0">T0</span> Tier 0 — Domain &amp; Hypervisor Management</summary>
    <div class="section-body">

      <div class="sub">
        <div class="sub-title">User Accounts ($($collect.T0Users.Count))</div>
        $(Build-UserTable $collect.T0Users)
      </div>

      <div class="sub">
        <div class="sub-title">Role Groups ($($collect.T0Groups.Count))</div>
        $(Build-GroupTable $collect.T0Groups)
      </div>

      <div class="sub">
        <div class="sub-title">PAW Devices — OU=PAWs,OU=Tier 0 ($($collect.PAWComputers.Count))</div>
        $(Build-PAWTable $collect.PAWComputers)
      </div>

      <div class="sub">
        <div class="sub-title">Break-Glass Accounts</div>
        $(Build-BreakGlassTable $collect.BreakGlass)
      </div>

      <div class="sub">
        <div class="sub-title">GPO Links on OU=Tier 0</div>
        $(Build-GPOTable $collect.T0GPOLinks)
      </div>

    </div>
  </details>

  <!-- Tier 1 -->
  <details open>
    <summary><span class="b b-t1">T1</span> Tier 1 — Server &amp; Infrastructure Management</summary>
    <div class="section-body">

      <div class="sub">
        <div class="sub-title">User Accounts ($($collect.T1Users.Count))</div>
        $(Build-UserTable $collect.T1Users)
      </div>

      <div class="sub">
        <div class="sub-title">Role Groups ($($collect.T1Groups.Count))</div>
        $(Build-GroupTable $collect.T1Groups)
      </div>

      <div class="sub">
        <div class="sub-title">GPO Links on OU=Tier 1</div>
        $(Build-GPOTable $collect.T1GPOLinks)
      </div>

    </div>
  </details>

  <!-- Password Policies -->
  <details>
    <summary>&#x1F512; Fine-Grained Password Policies ($($collect.PSOs.Count))</summary>
    <div class="section-body">
      $(Build-PSOCards $collect.PSOs)
    </div>
  </details>

  <!-- Authentication Silos -->
  <details>
    <summary>&#x1F510; Authentication Policy Silos ($($collect.Silos.Count))</summary>
    <div class="section-body">
      $(Build-SiloTable $collect.Silos)
    </div>
  </details>

  <!-- Domain Hygiene -->
  <details>
    <summary>&#x1F9F9; Domain Hygiene</summary>
    <div class="section-body">

      <div class="sub">
        <div class="sub-title">Domain Admins — Direct User Members (should be empty)</div>
        $(
            if ($collect.DomainAdmins.Count -eq 0) {
                "<p><span class='ok'>&#x2714; No direct user members in Domain Admins.</span></p>"
            } else {
                $sb2 = [System.Text.StringBuilder]::new()
                [void]$sb2.Append("<table><tr><th>SAM Account</th><th>Display Name</th></tr>")
                foreach ($u in $collect.DomainAdmins) {
                    [void]$sb2.Append("<tr><td class='bad'>$(Esc $u.SamAccountName)</td><td>$(Esc ([string]$u.Name))</td></tr>")
                }
                [void]$sb2.Append("</table>")
                $sb2.ToString()
            }
        )
      </div>

      <div class="sub">
        <div class="sub-title">Protected Users Group ($($collect.ProtectedUsers.Count) member(s))</div>
        $(
            if ($collect.ProtectedUsers.Count -eq 0) {
                "<p class='empty'>No members in Protected Users group.</p>"
            } else {
                $sb3 = [System.Text.StringBuilder]::new()
                [void]$sb3.Append("<table><tr><th>SAM Account</th><th>T0 Account?</th></tr>")
                foreach ($sam in ($collect.ProtectedUsers | Sort-Object)) {
                    $isT0 = $sam -in $t0Sams
                    [void]$sb3.Append("<tr><td>$(Esc $sam)</td><td>$(if ($isT0) { "<span class='b b-t0'>T0</span>" } else { '—' })</td></tr>")
                }
                [void]$sb3.Append("</table>")
                $sb3.ToString()
            }
        )
      </div>

    </div>
  </details>

  <div class="footer">
    Generated by MEAM-Tier-Report.ps1 &nbsp;|&nbsp; Domain: $domainLabel &nbsp;|&nbsp; $(Get-Date -Format 'yyyy-MM-dd HH:mm') UTC
  </div>

</div>
</body>
</html>
"@

# ─── Write report ─────────────────────────────────────────────────────────────
$html | Set-TextFileContent -FilePath $OutputPath
$absPath = (Resolve-Path $OutputPath).Path
Write-Host ''
Write-Host "[OK] Report written: $absPath" -ForegroundColor Green
Write-Host "     T0 accounts : $($collect.T0Users.Count)"
Write-Host "     T1 accounts : $($collect.T1Users.Count)"
Write-Host "     Failures    : $totalFails"
Write-Host "     Warnings    : $totalWarns"
Write-Host "     Stale total : $totalStale"
Write-Host ''

if ($OpenInBrowser) {
    Start-Process -FilePath $absPath
}

# ─── Return structured result for pipeline use ────────────────────────────────
[pscustomobject]@{
    ReportPath   = $absPath
    Domain       = $DomainFQDN
    GeneratedAt  = (Get-Date).ToString('o')
    T0UserCount  = $collect.T0Users.Count
    T1UserCount  = $collect.T1Users.Count
    Failures     = $totalFails
    Warnings     = $totalWarns
    StaleTotal   = $totalStale
    OverallStatus = $overallBadge
}
