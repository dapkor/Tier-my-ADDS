#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 4 (DC01): Apply realistic brownfield security misconfigurations.
    Vagrant provision tag: brownfield-misconfig

    Every misconfiguration below is INTENTIONAL — they simulate the security
    debt that accumulates in real domains over years, and provide concrete
    MEAM remediation targets for Get-Tiering-Compliance-Report.ps1 and
    Test-MEAM-Deployment.ps1.

    Misconfigurations applied:
      1.  Service accounts (svc-sql, svc-vmware, svc-sccm) in Domain Admins
      2.  IT staff (john.smith, jane.doe) directly in Domain Admins
      3.  IT-Admins group nested into Domain Admins
      4.  Helpdesk users + IT-Admins group in Account Operators
      5.  bob.jones in Server Operators
      6.  svc-backup in Backup Operators
      7.  SPNs on svc-sql, svc-web, svc-exchange (Kerberoastable)
      8.  Unconstrained Kerberos delegation on SQL01 and APP01
      9.  DoNotRequirePreAuth on svc-monitoring (AS-REP Roasting)
     10.  PasswordNotRequired on test.account
     11.  AllowReversiblePasswordEncryption on svc-exchange
     12.  Weak default domain password policy (min 6, no complexity, no lockout)
     13.  old.sysadmin and temp.contractor1 accounts left enabled
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LogDir = 'C:\vagrant-bootstrap\logs'
$null   = New-Item -ItemType Directory -Path $LogDir -Force -ErrorAction SilentlyContinue

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERROR')]$Level = 'INFO')
    $colour = @{ INFO='Cyan'; OK='Green'; WARN='Yellow'; ERROR='Red' }[$Level]
    $line   = "[$(Get-Date -f 'HH:mm:ss')][$Level] $Message"
    Write-Host $line -ForegroundColor $colour
    $line | Add-Content -Path "$LogDir\04-Brownfield-Misconfig.log" -Encoding UTF8
}

function Add-MemberSafe {
    param([string]$Group, [string]$Member)
    try {
        $existing = Get-ADGroupMember -Identity $Group -Recursive -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty SamAccountName
        if ($existing -notcontains $Member) {
            Add-ADGroupMember -Identity $Group -Members $Member
            Write-Log "  [MISCONFIG] $Member -> $Group" WARN
        }
    }
    catch { Write-Log "  AddMember $Member -> $Group: $($_.Exception.Message)" ERROR }
}

Import-Module ActiveDirectory -Force

Write-Log '=== Phase 4: Applying brownfield misconfigurations ==='
Write-Log 'All findings below are INTENTIONAL lab misconfigurations.' WARN

# ── 1+2. Service accounts + IT staff directly in Domain Admins ─────────────────
Write-Log '--- [1+2] Domain Admins over-population ---'

@('svc-sql','svc-vmware','svc-sccm','john.smith','jane.doe') | ForEach-Object {
    Add-MemberSafe 'Domain Admins' $_
}

# ── 3. IT-Admins group nested into Domain Admins ──────────────────────────────
Write-Log '--- [3] IT-Admins nested into Domain Admins ---'
Add-MemberSafe 'Domain Admins' 'IT-Admins'

# ── 4. Account Operators — helpdesk + group ───────────────────────────────────
Write-Log '--- [4] Account Operators over-populated ---'
@('alice.anderson','svc-helpdesk','Helpdesk-Staff') | ForEach-Object {
    Add-MemberSafe 'Account Operators' $_
}

# ── 5. Server Operators ───────────────────────────────────────────────────────
Write-Log '--- [5] Server Operators over-populated ---'
Add-MemberSafe 'Server Operators' 'bob.jones'

# ── 6. Backup Operators ───────────────────────────────────────────────────────
Write-Log '--- [6] Backup Operators membership ---'
Add-MemberSafe 'Backup Operators' 'svc-backup'

# ── 7. SPNs on service accounts (Kerberoastable targets) ──────────────────────
Write-Log '--- [7] Setting Kerberoastable SPNs ---'
$domain = (Get-ADDomain).DNSRoot
$spnMap = @{
    'svc-sql'      = @("MSSQLSvc/SQL01.$domain`:1433", "MSSQLSvc/SQL01:1433")
    'svc-web'      = @("HTTP/web.$domain", "HTTP/www.$domain")
    'svc-exchange' = @("exchangeMDB/EXCHANGE01.$domain", "SMTP/$domain")
}
foreach ($sam in $spnMap.Keys) {
    try {
        Set-ADUser -Identity $sam -ServicePrincipalNames @{ Add = $spnMap[$sam] }
        Write-Log "  [MISCONFIG] SPN set on $sam: $($spnMap[$sam] -join ' | ')" WARN
    }
    catch { Write-Log "  SPN on $sam: $($_.Exception.Message)" ERROR }
}

# ── 8. Unconstrained Kerberos delegation on servers ───────────────────────────
Write-Log '--- [8] Unconstrained delegation on SQL01 and APP01 ---'
@('SQL01','APP01') | ForEach-Object {
    try {
        if (Get-ADComputer -Filter "Name -eq '$_'" -ErrorAction SilentlyContinue) {
            Set-ADComputer -Identity $_ -TrustedForDelegation $true
            Write-Log "  [MISCONFIG] Unconstrained delegation enabled: $_" WARN
        }
        else {
            Write-Log "  Computer $_ not found — skipped." WARN
        }
    }
    catch { Write-Log "  Delegation on $_ : $($_.Exception.Message)" ERROR }
}

# ── 9. AS-REP Roasting target ─────────────────────────────────────────────────
Write-Log '--- [9] DoNotRequirePreAuth on svc-monitoring ---'
try {
    Set-ADAccountControl -Identity 'svc-monitoring' -DoesNotRequirePreAuth $true
    Write-Log '  [MISCONFIG] svc-monitoring: DoNotRequirePreAuth = TRUE (AS-REP Roasting target)' WARN
}
catch { Write-Log "  DoNotRequirePreAuth: $($_.Exception.Message)" ERROR }

# ── 10. PasswordNotRequired on test account ───────────────────────────────────
Write-Log '--- [10] PasswordNotRequired on test.account ---'
try {
    Set-ADAccountControl -Identity 'test.account' -PasswordNotRequired $true
    Write-Log '  [MISCONFIG] test.account: PasswordNotRequired = TRUE' WARN
}
catch { Write-Log "  PasswordNotRequired: $($_.Exception.Message)" ERROR }

# ── 11. Reversible encryption on svc-exchange ────────────────────────────────
Write-Log '--- [11] Reversible password encryption on svc-exchange ---'
try {
    Set-ADAccountControl -Identity 'svc-exchange' -AllowReversiblePasswordEncryption $true
    Write-Log '  [MISCONFIG] svc-exchange: AllowReversiblePasswordEncryption = TRUE' WARN
}
catch { Write-Log "  Reversible encryption: $($_.Exception.Message)" ERROR }

# ── 12. Weak default domain password policy ───────────────────────────────────
Write-Log '--- [12] Weakening default domain password policy ---'
try {
    Set-ADDefaultDomainPasswordPolicy `
        -Identity            (Get-ADDomain).DistinguishedName `
        -MinPasswordLength   6 `
        -PasswordHistoryCount 3 `
        -MaxPasswordAge      ([System.TimeSpan]::FromDays(365)) `
        -MinPasswordAge      ([System.TimeSpan]::Zero) `
        -LockoutThreshold    0 `
        -ComplexityEnabled   $false
    Write-Log '  [MISCONFIG] Default domain policy: MinLen=6, NoComplexity, NoLockout, MaxAge=365d' WARN
}
catch { Write-Log "  Password policy: $($_.Exception.Message)" ERROR }

# ── 13. Stale accounts remain enabled (no lifecycle process) ──────────────────
Write-Log '--- [13] Stale accounts verified still enabled ---'
@('old.sysadmin','temp.contractor1') | ForEach-Object {
    $u = Get-ADUser -Filter "SamAccountName -eq '$_'" -ErrorAction SilentlyContinue
    if ($u) {
        if (-not $u.Enabled) { Enable-ADAccount -Identity $_ }
        Write-Log "  [MISCONFIG] $_ is ENABLED (stale account, should be disabled)" WARN
    }
}

Write-Log '=== Phase 4: Brownfield misconfigurations applied ===' OK
Write-Log '--- Summary of MEAM remediation targets: ---' INFO
Write-Log '  Run: .\4-Validation\Test-MEAM-Deployment.ps1    — to validate current state' INFO
Write-Log '  Run: .\1-Deployment\New-MEAM-Deployment.ps1     — to apply MEAM tiering' INFO
Write-Log '  Run: .\3-Monitoring\Get-Tiering-Compliance-Report.ps1 — to scan compliance' INFO
