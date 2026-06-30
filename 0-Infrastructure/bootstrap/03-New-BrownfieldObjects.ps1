#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 3 (DC01): Populate a realistic brownfield Active Directory environment.
    Vagrant provision tag: brownfield-objects

    Creates the messy, organically-grown AD state that MEAM tiering is designed
    to remediate:
      - Flat department OU structure (no tiering, no zones)
      - 25+ domain users across Finance / HR / IT / Operations / Sales
      - 8 service accounts (non-gMSA, plain user objects with passwords)
      - 10+ computer accounts in the wrong OUs
      - Legacy security groups with mixed privilege levels
      - A handful of stale/orphaned accounts still enabled

    Idempotent — skips objects that already exist.
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
    $line | Add-Content -Path "$LogDir\03-Brownfield-Objects.log" -Encoding UTF8
}

Import-Module ActiveDirectory -Force

# ── Helpers ───────────────────────────────────────────────────────────────────

function New-OUIfAbsent {
    param([string]$Name, [string]$Path, [string]$Description = '')
    $dn = "OU=$Name,$Path"
    if (-not (Get-ADOrganizationalUnit -Identity $dn -ErrorAction SilentlyContinue)) {
        $p = @{ Name=$Name; Path=$Path; ProtectedFromAccidentalDeletion=$false }
        if ($Description) { $p.Description = $Description }
        New-ADOrganizationalUnit @p | Out-Null
        Write-Log "  OU: $dn" OK
    }
    return $dn
}

function New-UserIfAbsent {
    param(
        [string]$Sam, [string]$GivenName, [string]$Surname,
        [string]$Path, [string]$Password,
        [string]$Title = '', [string]$Department = '', [string]$Description = '',
        [bool]$PwdNeverExpires = $false
    )
    if (Get-ADUser -Filter "SamAccountName -eq '$Sam'" -ErrorAction SilentlyContinue) { return }
    $domain = (Get-ADDomain).DNSRoot
    $p = @{
        SamAccountName       = $Sam
        Name                 = "$GivenName $Surname"
        GivenName            = $GivenName
        Surname              = $Surname
        UserPrincipalName    = "$Sam@$domain"
        Path                 = $Path
        AccountPassword      = (ConvertTo-SecureString $Password -AsPlainText -Force)
        Enabled              = $true
        PasswordNeverExpires = $PwdNeverExpires
        ChangePasswordAtLogon = $false
    }
    if ($Title)       { $p.Title       = $Title       }
    if ($Department)  { $p.Department  = $Department  }
    if ($Description) { $p.Description = $Description }
    New-ADUser @p | Out-Null
    Write-Log "  User: $Sam  ($GivenName $Surname)" OK
}

function New-GroupIfAbsent {
    param(
        [string]$Name, [string]$Path, [string]$Description = '',
        [ValidateSet('DomainLocal','Global','Universal')]$Scope = 'Global',
        [ValidateSet('Security','Distribution')]$Category = 'Security'
    )
    if (Get-ADGroup -Filter "Name -eq '$Name'" -ErrorAction SilentlyContinue) { return }
    New-ADGroup -Name $Name -SamAccountName $Name `
        -GroupScope $Scope -GroupCategory $Category `
        -Path $Path -Description $Description | Out-Null
    Write-Log "  Group: $Name ($Scope $Category)" OK
}

function Add-MemberSafe {
    param([string]$Group, [string]$Member)
    try {
        $existing = Get-ADGroupMember -Identity $Group -ErrorAction SilentlyContinue |
                    Select-Object -ExpandProperty SamAccountName
        if ($existing -notcontains $Member) {
            Add-ADGroupMember -Identity $Group -Members $Member
        }
    }
    catch { Write-Log "  AddMember $Member -> $Group: $($_.Exception.Message)" WARN }
}

function New-ComputerIfAbsent {
    param([string]$Name, [string]$Path, [string]$Description = '')
    if (Get-ADComputer -Filter "Name -eq '$Name'" -ErrorAction SilentlyContinue) { return }
    New-ADComputer -Name $Name -SamAccountName "$Name`$" -Path $Path -Description $Description | Out-Null
    Write-Log "  Computer: $Name  -> $Path" OK
}

# ── Domain context ─────────────────────────────────────────────────────────────
Write-Log '=== Phase 3: Creating brownfield AD objects ==='
$domain    = Get-ADDomain
$DN        = $domain.DistinguishedName
$FQDN      = $domain.DNSRoot
$UsersPath = "CN=Users,$DN"      # default Users container — brownfield groups dumped here

$UserPw = 'LabUser2024!'         # all regular user passwords
$SvcPw  = 'SvcP@ss2024!'        # all service account passwords

# ── 1. OU STRUCTURE (flat/messy — brownfield reality) ─────────────────────────
Write-Log '--- OU structure ---'

$IT_OU    = New-OUIfAbsent 'IT'         $DN 'Information Technology'
$FIN_OU   = New-OUIfAbsent 'Finance'    $DN 'Finance Department'
$HR_OU    = New-OUIfAbsent 'HR'         $DN 'Human Resources'
$OPS_OU   = New-OUIfAbsent 'Operations' $DN 'Operations'
$SALES_OU = New-OUIfAbsent 'Sales'      $DN 'Sales'
$SVC_OU   = New-OUIfAbsent 'Service Accounts' $DN 'Service accounts — no tier separation applied'
$LEG_OU   = New-OUIfAbsent 'Legacy'     $DN 'Decommissioned and stale objects'

# IT sub-OUs (partial — many IT assets still end up in CN=Computers)
$IT_USR_OU = New-OUIfAbsent 'IT-Users'     $IT_OU 'IT staff accounts'
$IT_SRV_OU = New-OUIfAbsent 'IT-Servers'   $IT_OU 'IT-managed servers'
$IT_WKS_OU = New-OUIfAbsent 'Workstations' $IT_OU 'IT-owned workstations'

# ── 2. LEGACY SECURITY GROUPS ─────────────────────────────────────────────────
Write-Log '--- Security groups ---'

# Dumped in default Users container (classic brownfield behaviour)
New-GroupIfAbsent 'IT-Admins'            $UsersPath 'IT administrators — all seniority levels mixed'
New-GroupIfAbsent 'Server-Admins'        $UsersPath 'Server administration team'
New-GroupIfAbsent 'Helpdesk-Staff'       $UsersPath 'Helpdesk and desktop support'
New-GroupIfAbsent 'Network-Admins'       $UsersPath 'Network and DNS administrators'
New-GroupIfAbsent 'Finance-Users'        $UsersPath 'Finance department'
New-GroupIfAbsent 'HR-Users'             $UsersPath 'Human Resources department'
New-GroupIfAbsent 'Sales-Team'           $UsersPath 'Sales department'
New-GroupIfAbsent 'Operations-Staff'     $UsersPath 'Operations department'
New-GroupIfAbsent 'VPN-Access'           $UsersPath 'Users granted VPN access'
New-GroupIfAbsent 'Remote-Desktop-Users' $UsersPath 'RDP access — scope too broad for production'
New-GroupIfAbsent 'Software-Deploy'      $UsersPath 'Software deployment permissions'
New-GroupIfAbsent 'All-Staff' $UsersPath 'All staff distribution list' -Scope Universal -Category Distribution

# ── 3. IT STAFF USERS ─────────────────────────────────────────────────────────
Write-Log '--- IT staff ---'

New-UserIfAbsent 'john.smith'   'John'   'Smith'    $IT_USR_OU $UserPw `
    -Title 'IT Manager' -Department 'IT' -PwdNeverExpires $true `
    -Description 'IT Manager — uses this account for both email and admin (MEAM anti-pattern)'

New-UserIfAbsent 'jane.doe'     'Jane'   'Doe'      $IT_USR_OU $UserPw `
    -Title 'Senior Systems Administrator' -Department 'IT' `
    -Description 'Senior Sysadmin — directly in Domain Admins'

New-UserIfAbsent 'bob.jones'    'Bob'    'Jones'    $IT_USR_OU $UserPw `
    -Title 'Systems Administrator' -Department 'IT' `
    -Description 'Sysadmin — Server Operators + Server-Admins'

New-UserIfAbsent 'alice.anderson' 'Alice' 'Anderson' $IT_USR_OU $UserPw `
    -Title 'Helpdesk Team Lead' -Department 'IT' `
    -Description 'Helpdesk lead — Account Operators member (over-privileged)'

New-UserIfAbsent 'mike.wilson'  'Mike'   'Wilson'   $IT_USR_OU $UserPw `
    -Title 'Network Administrator' -Department 'IT' `
    -Description 'Network/DNS admin — DnsAdmins member (lateral-movement risk)'

New-UserIfAbsent 'sarah.tech'   'Sarah'  'Tech'     $IT_USR_OU $UserPw `
    -Title 'Desktop Support' -Department 'IT' `
    -Description 'Desktop support — Helpdesk-Staff'

New-UserIfAbsent 'peter.admin'  'Peter'  'Admin'    $IT_USR_OU $UserPw `
    -Title 'Junior Administrator' -Department 'IT' `
    -Description 'Junior IT — over-granted permissions'

# ── 4. FINANCE USERS ──────────────────────────────────────────────────────────
Write-Log '--- Finance ---'

@(
    @{ Sam='carol.white';  GN='Carol';  SN='White';  Title='Finance Director';   Dept='Finance'; Desc='Finance Director' }
    @{ Sam='david.black';  GN='David';  SN='Black';  Title='Senior Accountant';  Dept='Finance'; Desc='Finance' }
    @{ Sam='emma.green';   GN='Emma';   SN='Green';  Title='Accountant';         Dept='Finance'; Desc='Finance' }
    @{ Sam='frank.brown';  GN='Frank';  SN='Brown';  Title='Accounts Payable';   Dept='Finance'; Desc='Finance — infrequent logon (stale risk)' }
    @{ Sam='grace.taylor'; GN='Grace';  SN='Taylor'; Title='Financial Analyst';  Dept='Finance'; Desc='Finance' }
) | ForEach-Object {
    New-UserIfAbsent $_.Sam $_.GN $_.SN $FIN_OU $UserPw -Title $_.Title -Department $_.Dept -Description $_.Desc
}

# ── 5. HR USERS ───────────────────────────────────────────────────────────────
Write-Log '--- HR ---'

@(
    @{ Sam='helen.hr';      GN='Helen'; SN='HR';      Title='HR Manager';       Dept='HR'; Desc='HR Manager' }
    @{ Sam='ian.recruit';   GN='Ian';   SN='Recruit'; Title='Recruitment';      Dept='HR'; Desc='HR' }
    @{ Sam='julia.payroll'; GN='Julia'; SN='Payroll'; Title='Payroll Officer';  Dept='HR'; Desc='HR — handles sensitive payroll data' }
) | ForEach-Object {
    New-UserIfAbsent $_.Sam $_.GN $_.SN $HR_OU $UserPw -Title $_.Title -Department $_.Dept -Description $_.Desc
}

# ── 6. OPERATIONS USERS ───────────────────────────────────────────────────────
Write-Log '--- Operations ---'

@(
    @{ Sam='kevin.ops';  GN='Kevin';  SN='Ops'; Title='Operations Manager';  Dept='Operations' }
    @{ Sam='linda.ops';  GN='Linda';  SN='Ops'; Title='Senior Operator';     Dept='Operations' }
    @{ Sam='martin.ops'; GN='Martin'; SN='Ops'; Title='Operator';            Dept='Operations' }
    @{ Sam='nancy.ops';  GN='Nancy';  SN='Ops'; Title='Operator';            Dept='Operations' }
    @{ Sam='oliver.ops'; GN='Oliver'; SN='Ops'; Title='Operations Analyst';  Dept='Operations' }
) | ForEach-Object {
    New-UserIfAbsent $_.Sam $_.GN $_.SN $OPS_OU $UserPw -Title $_.Title -Department $_.Dept
}

# ── 7. SALES USERS ────────────────────────────────────────────────────────────
Write-Log '--- Sales ---'

@(
    @{ Sam='paul.sales';   GN='Paul';   SN='Sales'; Title='Sales Director';       Dept='Sales' }
    @{ Sam='quinn.sales';  GN='Quinn';  SN='Sales'; Title='Account Manager';      Dept='Sales' }
    @{ Sam='rachel.sales'; GN='Rachel'; SN='Sales'; Title='Account Manager';      Dept='Sales' }
    @{ Sam='steven.sales'; GN='Steven'; SN='Sales'; Title='Sales Representative'; Dept='Sales' }
    @{ Sam='tina.sales';   GN='Tina';   SN='Sales'; Title='Sales Representative'; Dept='Sales' }
) | ForEach-Object {
    New-UserIfAbsent $_.Sam $_.GN $_.SN $SALES_OU $UserPw -Title $_.Title -Department $_.Dept
}

# ── 8. STALE / ORPHANED ACCOUNTS ─────────────────────────────────────────────
Write-Log '--- Stale accounts ---'

New-UserIfAbsent 'old.sysadmin'    'Old'  'SysAdmin'    $LEG_OU $UserPw `
    -Title 'Former Systems Administrator' -Department 'IT' `
    -Description 'LEFT COMPANY 2022 — account not disabled (compliance finding)'

New-UserIfAbsent 'temp.contractor1' 'Temp' 'Contractor1' $LEG_OU $UserPw `
    -Description 'CONTRACT ENDED 2023 — account not disabled (compliance finding)'

# Test account left in default Users container — common brownfield slip
New-UserIfAbsent 'test.account' 'Test' 'Account' $UsersPath $UserPw `
    -Description 'TEST ACCOUNT — left in production environment (should not exist)'

# ── 9. SERVICE ACCOUNTS (non-gMSA, plain user objects — brownfield anti-patterns) ──
Write-Log '--- Service accounts ---'

@(
    @{ Sam='svc-sql';        GN='Service'; SN='SQL';
       Desc='SQL Server service — member of Domain Admins (CRITICAL: excessive privilege)'
       Title='SQL Server Service Account'; PNE=$true }

    @{ Sam='svc-vmware';     GN='Service'; SN='VMware';
       Desc='VMware vCenter service — member of Domain Admins (CRITICAL: excessive privilege)'
       Title='VMware vCenter Service Account'; PNE=$true }

    @{ Sam='svc-sccm';       GN='Service'; SN='SCCM';
       Desc='SCCM/ConfigMgr service — member of Domain Admins (CRITICAL: excessive privilege)'
       Title='SCCM Service Account'; PNE=$true }

    @{ Sam='svc-backup';     GN='Service'; SN='Backup';
       Desc='Backup Exec service — Backup Operators member, password never expires'
       Title='Backup Service Account'; PNE=$true }

    @{ Sam='svc-web';        GN='Service'; SN='Web';
       Desc='IIS/web service — SPN set, Kerberoastable target'
       Title='Web Application Service Account'; PNE=$true }

    @{ Sam='svc-monitoring'; GN='Service'; SN='Monitoring';
       Desc='Monitoring tool (Zabbix) — DoNotRequirePreAuth enabled (AS-REP Roasting target)'
       Title='Monitoring Service Account'; PNE=$true }

    @{ Sam='svc-exchange';   GN='Service'; SN='Exchange';
       Desc='Mail relay service — AllowReversiblePasswordEncryption enabled'
       Title='Exchange Service Account'; PNE=$true }

    @{ Sam='svc-helpdesk';   GN='Service'; SN='Helpdesk';
       Desc='ITSM tool service — Account Operators member'
       Title='Helpdesk Tool Service Account'; PNE=$true }
) | ForEach-Object {
    New-UserIfAbsent $_.Sam $_.GN $_.SN $SVC_OU $SvcPw `
        -Title $_.Title -Department 'IT' -Description $_.Desc -PwdNeverExpires $_.PNE
}

# ── 10. COMPUTER ACCOUNTS ─────────────────────────────────────────────────────
Write-Log '--- Computers ---'

# Servers — in IT-Servers OU (reasonable but untiered)
@('SQL01','APP01','APP02','FILE01','BACKUP01') | ForEach-Object {
    New-ComputerIfAbsent $_ $IT_SRV_OU "Server — $_ (untiered)"
}

# Workstations — dumped in CN=Computers (never moved, default container)
@('WKS001','WKS002','WKS003','WKS004','WKS005','LAPTOP001','LAPTOP002') | ForEach-Object {
    New-ComputerIfAbsent $_ "CN=Computers,$DN" "Workstation — $_ (unmanaged, default container)"
}

# ── 11. GROUP MEMBERSHIP ──────────────────────────────────────────────────────
Write-Log '--- Group membership ---'

# IT-Admins — senior + junior IT all in one flat group
@('john.smith','jane.doe','bob.jones','mike.wilson') | ForEach-Object { Add-MemberSafe 'IT-Admins' $_ }

# Server-Admins
@('jane.doe','bob.jones') | ForEach-Object { Add-MemberSafe 'Server-Admins' $_ }

# Helpdesk
@('alice.anderson','sarah.tech','peter.admin') | ForEach-Object { Add-MemberSafe 'Helpdesk-Staff' $_ }

# Network-Admins
Add-MemberSafe 'Network-Admins' 'mike.wilson'
Add-MemberSafe 'DnsAdmins'      'mike.wilson'   # DnsAdmins = lateral-movement path

# Department groups
@('carol.white','david.black','emma.green','frank.brown','grace.taylor') | ForEach-Object { Add-MemberSafe 'Finance-Users' $_ }
@('helen.hr','ian.recruit','julia.payroll') | ForEach-Object { Add-MemberSafe 'HR-Users' $_ }
@('paul.sales','quinn.sales','rachel.sales','steven.sales','tina.sales') | ForEach-Object { Add-MemberSafe 'Sales-Team' $_ }
@('kevin.ops','linda.ops','martin.ops','nancy.ops','oliver.ops') | ForEach-Object { Add-MemberSafe 'Operations-Staff' $_ }

# VPN-Access — IT + department managers (scope creep over the years)
@('john.smith','jane.doe','bob.jones','mike.wilson','carol.white','paul.sales','kevin.ops') |
    ForEach-Object { Add-MemberSafe 'VPN-Access' $_ }

# Remote-Desktop-Users — IT + helpdesk (too broad)
@('john.smith','jane.doe','bob.jones','alice.anderson','sarah.tech','peter.admin') |
    ForEach-Object { Add-MemberSafe 'Remote-Desktop-Users' $_ }

Write-Log '=== Phase 3: Brownfield objects created ===' OK
