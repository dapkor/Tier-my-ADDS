<#
.SYNOPSIS
    Full greenfield deployment of the Monash Enterprise Access Model (MEAM)
    alongside an existing Active Directory forest.

.DESCRIPTION
    Implements the MEAM as documented by mon-csirt/active-directory-security:
      - Administrative Tiers (T0/T1/T2) with PAWs per tier
      - Zones within tiers (microsegmentation, horizontal isolation)
      - Services within zones (~18 fine-grained delegation groups each)
      - PAW Silos (per-tier) + Zone Silos (per-zone) using Authentication Policy Silos
      - All zoned user accounts in Protected Users; gMSAs for service accounts
      - Smartcard (PIV) enforcement for all zoned admin accounts
      - Deny-logon User Rights (URA) as AuthZ layer alongside Silo AuthN
      - LAPS, Credential Guard, Audit Policy via GPO
      - DNS Tier 1 delegation function
      - Full compliance validation report

.NOTES
    Based on:
      - MEAM: https://github.com/mon-csirt/active-directory-security/tree/main/MEAM
      - Microsoft Enterprise Access Model: https://aka.ms/EAM
    
    Run as Enterprise Admin on PDC Emulator or T0 PAW with RSAT.
    Requires: ActiveDirectory, GroupPolicy, DnsServer RSAT modules.
    TEST IN LAB FIRST. Idempotent – skips existing objects.
    Requires Domain Functional Level 2012R2+ for Auth Silos.
    Requires Server 2022 / Windows 11 for Windows LAPS (legacy LAPS otherwise).
#>

#Requires -RunAsAdministrator

param(
    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================
#region 0. CONFIGURATION  ← REVIEW BEFORE RUNNING
# ============================================================
$Config = @{

    # --- Domain (auto-detected in pre-flight) ---
    DomainDN   = $null
    DomainFQDN = $null
    DomainNB   = $null
    CorpOU     = 'Corp'   # Top-level OU name

    # --- MEAM Zone Definitions ---
    # Format: Tier -> ZoneKey -> ZoneLabel
    # Zones provide microsegmentation WITHIN a tier via Authentication Silos.
    # Add/remove zones to match your environment.
    Zones = @{
        T0 = [ordered]@{
            '0A' = 'Domain Management'       # DCs, AD admins, PKI
            '0B' = 'Hypervisor Management'   # Bare-metal hypervisors (Nutanix, VMware, Hyper-V host)
        }
        T1 = [ordered]@{
            '1A' = 'Workstation Management'  # SCCM/Intune infra, endpoint mgmt
            '1B' = 'Server Management'       # General member server admins
            '1C' = 'DNS Management'          # Dedicated DNS servers
            '1D' = 'Storage Management'      # NAS, SAN, file servers
        }
        T2 = [ordered]@{
            '2A' = 'Workstations'            # End-user workstations
            '2B' = 'Servers'                 # Business application servers (non-managed by T1)
        }
    }

    # --- MEAM Services per Zone ---
    # Services are delegation targets within a zone, each getting ~18 DLG groups.
    # Naming: Z[zone]-SVC-[ServiceName]
    ZoneServices = @{
        '0A' = @('DomainControllers','PKI','ADFS')
        '0B' = @('Hypervisors')
        '1A' = @('SCCM','Intune','AssetManagement')
        '1B' = @('AppServers','FileServers','BackupServers')
        '1C' = @('DNS')
        '1D' = @('NAS','SAN')
        '2A' = @('Workstations','Kiosks')
        '2B' = @('BusinessServers')
    }

    # --- Fine-Grained Password Policies ---
    PSO = @{
        T0 = @{ Name='PSO-Tier0';    Precedence=1; MinLength=20; MaxAge=180; MinAge=1; History=24; LockoutThreshold=0; LockoutDuration=0;  ObservationWindow=0  }
        T1 = @{ Name='PSO-Tier1';    Precedence=2; MinLength=14; MaxAge=180; MinAge=1; History=24; LockoutThreshold=5; LockoutDuration=30; ObservationWindow=30 }
        T2 = @{ Name='PSO-Tier2';    Precedence=3; MinLength=12; MaxAge=180; MinAge=1; History=12; LockoutThreshold=5; LockoutDuration=30; ObservationWindow=30 }
        SA = @{ Name='PSO-SvcAccts'; Precedence=4; MinLength=30; MaxAge=365; MinAge=1; History=24; LockoutThreshold=0; LockoutDuration=0;  ObservationWindow=0  }
    }

    # --- DNS ---
    DNS = @{
        Deploy               = $true
        ServerName           = 'dns01'       # <- Your Tier 1 DNS server FQDN
        ZoneName             = ''            # Auto-filled from DomainFQDN if empty
        ConfigDCsAsSecondary = $true
    }

    # --- Break-glass ---
    BreakGlass = @{
        Account1    = 'brk-glass-01'
        Account2    = 'brk-glass-02'
        TempPassword = 'ChangeMe!BrkGlass2026'  # <- CHANGE BEFORE RUNNING
    }

    # --- Feature flags ---
    EnableAuthSilos    = $true    # Requires DFL 2012R2+
    EnableSmartcard    = $true    # SmartcardLogonRequired on all zoned accounts
    EnableWindowsLAPS  = $false   # $true if Server 2022 / Win11; $false = legacy AdmPwd LAPS
    CreateTestAccounts = $true
}

#endregion

# ============================================================
#region 1. HELPER FUNCTIONS
# ============================================================

function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','OK')]$Level = 'INFO')
    $c = @{ INFO='Cyan'; WARN='Yellow'; ERROR='Red'; OK='Green' }
    Write-Host "[$(Get-Date -f 'HH:mm:ss')][$Level] $Message" -ForegroundColor $c[$Level]
}

function Test-OU {
    param([string]$Name, [string]$Path, [string]$Description = '')
    $dn = "OU=$Name,$Path"
    if (-not (Get-ADOrganizationalUnit -Identity $dn -ErrorAction SilentlyContinue)) {
        $p = @{ Name=$Name; Path=$Path; ProtectedFromAccidentalDeletion=$true }
        if ($Description) { $p.Description = $Description }
        New-ADOrganizationalUnit @p | Out-Null
        Write-Log "OU created: $dn" OK
    }
    return $dn
}

function New-GroupIfNotExists {
    param(
        [string]$Name, [string]$Path, [string]$Description = '',
        [ValidateSet('DomainLocal','Global','Universal')]$Scope = 'DomainLocal'
    )
    if (-not (Get-ADGroup -Filter "Name -eq '$Name'" -ErrorAction SilentlyContinue)) {
        $p = @{ Name=$Name; SamAccountName=$Name; GroupScope=$Scope
                GroupCategory='Security'; Path=$Path }
        if ($Description) { $p.Description = $Description }
        New-ADGroup @p -PassThru | Out-Null
        Write-Log "Group: $Name" OK
    }
}

function Set-Member {
    param([string]$Group, [string]$Member)
    $existing = Get-ADGroupMember -Identity $Group -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty SamAccountName
    if ($existing -notcontains $Member) {
        Add-ADGroupMember -Identity $Group -Members $Member
        Write-Log "  $Member -> $Group" OK
    }
}

function New-User {
    param(
        [string]$Sam, [string]$GN, [string]$SN, [string]$Path,
        [string]$Desc = '', [string]$Password,
        [bool]$PwdNeverExpires = $false, [bool]$SmartcardRequired = $false
    )
    if (-not (Get-ADUser -Filter "SamAccountName -eq '$Sam'" -ErrorAction SilentlyContinue)) {
        $p = @{
            SamAccountName=$Sam; Name="$GN $SN"; GivenName=$GN; Surname=$SN
            UserPrincipalName="$Sam@$DomainFQDN"; Path=$Path
            AccountPassword=(ConvertTo-SecureString $Password -AsPlainText -Force)
            Enabled=$true; ChangePasswordAtLogon=$(-not $PwdNeverExpires)
            PasswordNeverExpires=$PwdNeverExpires
            SmartcardLogonRequired=$SmartcardRequired
        }
        if ($Desc) { $p.Description = $Desc }
        New-ADUser @p -PassThru | Out-Null
        Write-Log "User: $Sam (Smartcard=$SmartcardRequired)" OK
    }
}

function New-gMSA {
    <#
    MEAM: service accounts should be gMSAs wherever possible.
    Creates a Group Managed Service Account for a given service in a zone.
    #>
    param([string]$Name, [string]$ZoneComputerGroup)
    if (-not (Get-ADServiceAccount -Filter "Name -eq '$Name'" -ErrorAction SilentlyContinue)) {
        New-ADServiceAccount -Name $Name `
            -DNSHostName "$Name.$DomainFQDN" `
            -PrincipalsAllowedToRetrieveManagedPassword $ZoneComputerGroup `
            -Description "MEAM gMSA for service $Name" | Out-Null
        Write-Log "gMSA created: $Name (retrievable by $ZoneComputerGroup)" OK
    }
}

function Set-GPOUserRight {
    <#
    Writes User Rights Assignment (Privilege Rights) into GptTmpl.inf in SYSVOL.
    This is the AuthZ layer that works alongside Auth Silos (AuthN layer) per MEAM.
    #>
    param([string]$GPOName, [string]$Privilege, [string[]]$GroupSamNames)

    $gpo        = Get-GPO -Name $GPOName -ErrorAction Stop
    $gpoGuid    = "{$($gpo.Id.ToString().ToUpper())}"
    $machPath   = "\\$DomainFQDN\SYSVOL\$DomainFQDN\Policies\$gpoGuid\Machine\Microsoft\Windows NT\SecEdit"
    $infPath    = "$machPath\GptTmpl.inf"
    $gptIniPath = "\\$DomainFQDN\SYSVOL\$DomainFQDN\Policies\$gpoGuid\gpt.ini"

    if (-not (Test-Path $machPath)) { New-Item -ItemType Directory -Path $machPath -Force | Out-Null }

    $sids = foreach ($g in $GroupSamNames) {
        $obj = Get-ADGroup -Identity $g -ErrorAction SilentlyContinue
        if ($obj) { "*$($obj.SID.Value)" }
        else { Write-Log "Group '$g' not found – skipped from $Privilege" WARN }
    }
    $sidStr = $sids -join ','

    $content = if (Test-Path $infPath) {
        Get-Content $infPath -Raw -Encoding Unicode
    } else {
        "[Unicode]`r`nUnicode=yes`r`n[Version]`r`nsignature=`"`$CHICAGO`$`"`r`nRevision=1`r`n[Privilege Rights]`r`n"
    }

    if ($content -notmatch '\[Privilege Rights\]') { $content += "`r`n[Privilege Rights]`r`n" }
    if ($content -match "(?m)^$Privilege\s*=") {
        $content = $content -replace "(?m)^$Privilege\s*=.*", "$Privilege = $sidStr"
    } else {
        $content = $content -replace '(\[Privilege Rights\])', "`$1`r`n$Privilege = $sidStr"
    }
    Set-Content -Path $infPath -Value $content -Encoding Unicode

    # Increment machine GPO version
    if (Test-Path $gptIniPath) {
        $ini    = Get-Content $gptIniPath -Raw
        if ($ini -match 'Version=(\d+)') {
            $ver    = [int]$Matches[1]
            $newVer = ($ver -band 0xFFFF0000) -bor (($ver -band 0x0000FFFF) + 1)
            Set-Content -Path $gptIniPath -Value ($ini -replace "Version=\d+", "Version=$newVer")
        }
    }
    Write-Log "  $GPOName | $Privilege = $sidStr" OK
}

function Set-AuditPolicyInGPO {
    param([string]$GPOName)
    $gpoGuid  = "{$((Get-GPO -Name $GPOName -ErrorAction Stop).Id.ToString().ToUpper())}"
    $auditDir = "\\$DomainFQDN\SYSVOL\$DomainFQDN\Policies\$gpoGuid\Machine\Microsoft\Windows NT\Audit"
    if (-not (Test-Path $auditDir)) { New-Item -ItemType Directory -Path $auditDir -Force | Out-Null }

    @"
Machine Name,Policy Target,Subcategory,Subcategory GUID,Inclusion Setting,Exclusion Setting,Setting Value
,System,Security State Change,{0CCE9210-69AE-11D9-BED3-505054503030},Success and Failure,,3
,System,Security System Extension,{0CCE9211-69AE-11D9-BED3-505054503030},Success and Failure,,3
,Logon/Logoff,Logon,{0CCE9215-69AE-11D9-BED3-505054503030},Success and Failure,,3
,Logon/Logoff,Logoff,{0CCE9216-69AE-11D9-BED3-505054503030},Success,,1
,Logon/Logoff,Account Lockout,{0CCE9217-69AE-11D9-BED3-505054503030},Success and Failure,,3
,Logon/Logoff,Special Logon,{0CCE921B-69AE-11D9-BED3-505054503030},Success,,1
,Account Management,User Account Management,{0CCE9235-69AE-11D9-BED3-505054503030},Success and Failure,,3
,Account Management,Security Group Management,{0CCE9237-69AE-11D9-BED3-505054503030},Success and Failure,,3
,Account Management,Computer Account Management,{0CCE9236-69AE-11D9-BED3-505054503030},Success and Failure,,3
,DS Access,Directory Service Changes,{0CCE923C-69AE-11D9-BED3-505054503030},Success and Failure,,3
,DS Access,Directory Service Access,{0CCE923B-69AE-11D9-BED3-505054503030},Success and Failure,,3
,Account Logon,Kerberos Authentication Service,{0CCE9242-69AE-11D9-BED3-505054503030},Success and Failure,,3
,Account Logon,Kerberos Service Ticket Operations,{0CCE9240-69AE-11D9-BED3-505054503030},Success and Failure,,3
,Account Logon,Credential Validation,{0CCE923F-69AE-11D9-BED3-505054503030},Success and Failure,,3
,Policy Change,Audit Policy Change,{0CCE922F-69AE-11D9-BED3-505054503030},Success and Failure,,3
,Privilege Use,Sensitive Privilege Use,{0CCE9228-69AE-11D9-BED3-505054503030},Success and Failure,,3
"@ | Set-Content "$auditDir\audit.csv" -Encoding UTF8
    Write-Log "  Audit policy -> '$GPOName'" OK
}

function Set-CredentialGuardGPO {
    param([string]$GPOName)
    Set-GPRegistryValue -Name $GPOName -Key 'HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard' -ValueName 'EnableVirtualizationBasedSecurity' -Type DWord -Value 1 | Out-Null
    Set-GPRegistryValue -Name $GPOName -Key 'HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard' -ValueName 'RequirePlatformSecurityFeatures'   -Type DWord -Value 1 | Out-Null
    Set-GPRegistryValue -Name $GPOName -Key 'HKLM\SYSTEM\CurrentControlSet\Control\Lsa'         -ValueName 'LsaCfgFlags'                        -Type DWord -Value 1 | Out-Null
    Write-Log "  Credential Guard -> '$GPOName'" OK
}

function Set-LAPSGPO {
    param([string]$GPOName, [bool]$UseWindowsLAPS = $false)
    if ($UseWindowsLAPS) {
        # Windows LAPS (Server 2022 / Win11) via CSP/Registry
        $key = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\LAPS'
        Set-GPRegistryValue -Name $GPOName -Key $key -ValueName 'BackupDirectory'         -Type DWord -Value 2       | Out-Null  # 2 = AD
        Set-GPRegistryValue -Name $GPOName -Key $key -ValueName 'PasswordAgeDays'          -Type DWord -Value 30      | Out-Null
        Set-GPRegistryValue -Name $GPOName -Key $key -ValueName 'PasswordLength'            -Type DWord -Value 20      | Out-Null
        Set-GPRegistryValue -Name $GPOName -Key $key -ValueName 'PasswordComplexity'        -Type DWord -Value 4       | Out-Null
        Set-GPRegistryValue -Name $GPOName -Key $key -ValueName 'PostAuthenticationActions' -Type DWord -Value 3       | Out-Null  # Reset PW + logoff
    } else {
        # Legacy AdmPwd LAPS
        $key = 'HKLM\SOFTWARE\Policies\Microsoft Services\AdmPwd'
        Set-GPRegistryValue -Name $GPOName -Key $key -ValueName 'AdmPwdEnabled'           -Type DWord -Value 1  | Out-Null
        Set-GPRegistryValue -Name $GPOName -Key $key -ValueName 'PasswordAgeDays'          -Type DWord -Value 30 | Out-Null
        Set-GPRegistryValue -Name $GPOName -Key $key -ValueName 'PasswordLength'            -Type DWord -Value 20 | Out-Null
        Set-GPRegistryValue -Name $GPOName -Key $key -ValueName 'PasswordComplexity'        -Type DWord -Value 4  | Out-Null
        Set-GPRegistryValue -Name $GPOName -Key $key -ValueName 'PwdExpirationProtection'   -Type DWord -Value 1  | Out-Null
    }
    Write-Log "  LAPS (WindowsLAPS=$UseWindowsLAPS) -> '$GPOName'" OK
}

function Set-ADDelegation {
    <#
    Sets an ACE on an AD OU for a delegation group.
    Used extensively for the MEAM ~18-group-per-service delegation model.
    #>
    param(
        [string]$TargetDN,
        [string]$GroupSam,
        [string[]]$Rights,
        [System.Guid]$ObjectType           = [System.Guid]::Empty,
        [System.Guid]$InheritedObjectType  = [System.Guid]::Empty,
        [System.DirectoryServices.ActiveDirectorySecurityInheritance]$Inheritance =
            [System.DirectoryServices.ActiveDirectorySecurityInheritance]::Descendents
    )
    $extRights = @{
        'ResetPassword'   = [System.Guid]'00299570-246d-11d0-a768-00aa006e0529'
        'ChangePassword'  = [System.Guid]'ab721a53-1e2f-11d0-9819-00aa0040529b'
        'ReadLAPS'        = [System.Guid]'ms-mcs-admpwd'   # resolved dynamically below
    }
    $rightFlags = @{
        'ReadProperty'  = [System.DirectoryServices.ActiveDirectoryRights]::ReadProperty
        'WriteProperty' = [System.DirectoryServices.ActiveDirectoryRights]::WriteProperty
        'CreateChild'   = [System.DirectoryServices.ActiveDirectoryRights]::CreateChild
        'DeleteChild'   = [System.DirectoryServices.ActiveDirectoryRights]::DeleteChild
        'GenericRead'   = [System.DirectoryServices.ActiveDirectoryRights]::GenericRead
        'ExtendedRight' = [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight
        'ResetPassword' = [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight
        'ChangePassword'= [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight
        'WriteDACL'     = [System.DirectoryServices.ActiveDirectoryRights]::WriteDacl
    }
    $sid = (Get-ADGroup -Identity $GroupSam).SID
    $acl = Get-Acl "AD:\$TargetDN"
    foreach ($r in $Rights) {
        $adRight = if ($rightFlags.ContainsKey($r)) { $rightFlags[$r] } else { [System.DirectoryServices.ActiveDirectoryRights]::ReadProperty }
        $objType = if ($extRights.ContainsKey($r)) { $extRights[$r] } else { $ObjectType }
        $ace     = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
            $sid, $adRight,
            [System.Security.AccessControl.AccessControlType]::Allow,
            $objType, $Inheritance, $InheritedObjectType
        )
        $acl.AddAccessRule($ace)
    }
    Set-Acl -Path "AD:\$TargetDN" -AclObject $acl
    Write-Log "  ACL: $GroupSam -> [$($Rights -join ',')] on $TargetDN" OK
}

function Invoke-PreFlightValidation {
    param(
        [hashtable]$Cfg,
        [switch]$ValidateOnlyMode
    )

    $errors   = New-Object System.Collections.Generic.List[string]
    $warnings = New-Object System.Collections.Generic.List[string]

    # Validate required modules are available before doing anything else.
    $requiredModules = @('ActiveDirectory','GroupPolicy')
    if ($Cfg.DNS.Deploy) { $requiredModules += 'DnsServer' }

    foreach ($moduleName in $requiredModules | Select-Object -Unique) {
        if (-not (Get-Module -ListAvailable -Name $moduleName)) {
            $errors.Add("Required module '$moduleName' not found (install RSAT component).")
        }
    }

    try {
        $domain = Get-ADDomain -ErrorAction Stop
        $Cfg.DomainDN   = $domain.DistinguishedName
        $Cfg.DomainFQDN = $domain.DNSRoot
        $Cfg.DomainNB   = $domain.NetBIOSName
    }
    catch {
        $errors.Add("Unable to query AD domain context via Get-ADDomain: $($_.Exception.Message)")
    }

    if ($Cfg.EnableAuthSilos -and $Cfg.DomainFQDN) {
        $modeRank = @{
            Windows2000Domain = 0
            Windows2003InterimDomain = 1
            Windows2003Domain = 2
            Windows2008Domain = 3
            Windows2008R2Domain = 4
            Windows2012Domain = 5
            Windows2012R2Domain = 6
            Windows2016Domain = 7
        }
        $dflName = [string]$domain.DomainMode
        if (-not $modeRank.ContainsKey($dflName) -or $modeRank[$dflName] -lt $modeRank['Windows2012R2Domain']) {
            $errors.Add("Domain functional level '$dflName' is too low for Authentication Policy Silos (need Windows2012R2Domain+).")
        }
    }

    if ($Cfg.DNS.Deploy -and [string]::IsNullOrWhiteSpace($Cfg.DNS.ServerName)) {
        $errors.Add('DNS deployment is enabled but Config.DNS.ServerName is empty.')
    }

    if ([string]::IsNullOrWhiteSpace($Cfg.DNS.ZoneName) -and $Cfg.DomainFQDN) {
        $Cfg.DNS.ZoneName = $Cfg.DomainFQDN
    }

    if ($Cfg.BreakGlass.TempPassword -like 'ChangeMe!*') {
        $warnings.Add('Break-glass TempPassword appears to be a default placeholder. Change it before production use.')
    }

    if ($Cfg.CreateTestAccounts) {
        $warnings.Add('CreateTestAccounts is enabled; test users and passwords will be created unless disabled.')
    }

    Write-Log '=== PRE-FLIGHT VALIDATION ===' INFO
    if ($warnings.Count -gt 0) {
        foreach ($w in $warnings) { Write-Log $w WARN }
    }
    if ($errors.Count -gt 0) {
        foreach ($e in $errors) { Write-Log $e ERROR }
        throw "Pre-flight validation failed with $($errors.Count) error(s)."
    }
    Write-Log 'Pre-flight validation passed.' OK

    if ($ValidateOnlyMode) {
        Write-Log 'ValidateOnly specified. Exiting before deployment phases.' INFO
    }
}

#endregion

# Run pre-flight before deriving deployment paths and before making changes.
Invoke-PreFlightValidation -Cfg $Config -ValidateOnlyMode:$ValidateOnly

# Shorthand (resolved after pre-flight populates domain values)
$DomainDN   = $Config.DomainDN
$DomainFQDN = $Config.DomainFQDN
$CorpOU     = "OU=$($Config.CorpOU),$DomainDN"

if ($ValidateOnly) { return }

# ============================================================
#region 2. OU HIERARCHY – MEAM ZONE/SERVICE STRUCTURE
# ============================================================
Write-Log '=== PHASE 2: OU HIERARCHY (MEAM) ===' INFO

# Top Corp OU
Test-OU -Name $Config.CorpOU -Path $DomainDN | Out-Null

# Root OUs
foreach ($root in @('Tiers','Users','Groups','Service Accounts')) {
    Test-OU -Name $root -Path $CorpOU | Out-Null
}

$TiersOU = "OU=Tiers,$CorpOU"

# ---- Build Zone/Service structure per tier ----
foreach ($tier in @('T0','T1','T2')) {
    $tierNum   = $tier.Substring(1)
    $tierLabel = switch ($tier) { 'T0' {'Tier 0 - Control Plane'}; 'T1' {'Tier 1 - Management Plane'}; 'T2' {'Tier 2 - Workload Plane'} }
    $tierOU    = Test-OU -Name "Tier $tierNum" -Path $TiersOU -Description $tierLabel

    # PAW OU at tier root (MEAM: PAWs per tier)
    Test-OU -Name "PAWs" -Path $tierOU -Description "Tier $tierNum Privileged Access Workstations" | Out-Null

    foreach ($zoneKey in $Config.Zones[$tier].Keys) {
        $zoneLabel = $Config.Zones[$tier][$zoneKey]
        $zoneOU    = Test-OU -Name "Zone $zoneKey" -Path $tierOU -Description "MEAM Zone $zoneKey – $zoneLabel"

        # Sub-OUs per zone
        foreach ($sub in @('Computers','Accounts','Service Accounts','Groups')) {
            Test-OU -Name $sub -Path $zoneOU | Out-Null
        }
        $groupsOU = "OU=Groups,$zoneOU"
        foreach ($sub in @('Roles','Delegation')) {
            Test-OU -Name $sub -Path $groupsOU | Out-Null
        }

        # Services within zone (MEAM: ~18 DLG groups per service)
        if ($Config.ZoneServices.ContainsKey($zoneKey)) {
            $svcOU = Test-OU -Name 'Services' -Path $zoneOU
            foreach ($svc in $Config.ZoneServices[$zoneKey]) {
                Test-OU -Name $svc -Path $svcOU -Description "Service: $svc (Zone $zoneKey)" | Out-Null
                $svcDN = "OU=$svc,$svcOU"
                foreach ($sub in @('Computers','Groups')) {
                    Test-OU -Name $sub -Path $svcDN | Out-Null
                }
            }
        }
    }
}

# Users / Groups top-level OUs
foreach ($sub in @('Standard','VIP','External')) {
    Test-OU -Name $sub -Path "OU=Users,$CorpOU" | Out-Null
}
foreach ($sub in @('Security','Distribution','Resource')) {
    Test-OU -Name $sub -Path "OU=Groups,$CorpOU" | Out-Null
}

Write-Log '=== OU HIERARCHY COMPLETE ===' OK

#endregion

# ============================================================
#region 3. SECURITY GROUPS – MEAM NAMING CONVENTION
# ============================================================
<#
MEAM group naming:
  Tier-level role groups : T[n]-ROLE-[FunctionName]
  Zone-level role groups : Z[zone]-ROLE-[FunctionName]
  Delegation groups      : Z[zone]-DLG-[Service]-[ObjectType]-[Permission]
  GPO groups             : Z[zone]-GPO-[PolicyName]-Edit
  PAW groups             : PAW-T[n]-Users
#>
Write-Log '=== PHASE 3: SECURITY GROUPS (MEAM) ===' INFO

# ---- Tier-level role groups ----
$tierRoleGroups = @(
    # Tier 0
    @{ Name='T0-ROLE-AD-Admins';     Path="OU=Roles,OU=Groups,OU=Zone 0A,OU=Tier 0,OU=Tiers,$CorpOU"; Desc='T0: Domain/AD administration (Zone 0A)' }
    @{ Name='T0-ROLE-PKI-Admins';    Path="OU=Roles,OU=Groups,OU=Zone 0A,OU=Tier 0,OU=Tiers,$CorpOU"; Desc='T0: PKI/ADCS administration' }
    @{ Name='T0-ROLE-Hyper-Admins';  Path="OU=Roles,OU=Groups,OU=Zone 0B,OU=Tier 0,OU=Tiers,$CorpOU"; Desc='T0: Bare-metal hypervisor administration (Zone 0B)' }
    @{ Name='T0-ROLE-GPO-Admins';    Path="OU=Roles,OU=Groups,OU=Zone 0A,OU=Tier 0,OU=Tiers,$CorpOU"; Desc='T0: Group Policy administration' }
    # Tier 1
    @{ Name='T1-ROLE-WS-Admins';     Path="OU=Roles,OU=Groups,OU=Zone 1A,OU=Tier 1,OU=Tiers,$CorpOU"; Desc='T1: Workstation management (Zone 1A)' }
    @{ Name='T1-ROLE-Server-Admins'; Path="OU=Roles,OU=Groups,OU=Zone 1B,OU=Tier 1,OU=Tiers,$CorpOU"; Desc='T1: Server management (Zone 1B)' }
    @{ Name='T1-ROLE-DNS-Admins';    Path="OU=Roles,OU=Groups,OU=Zone 1C,OU=Tier 1,OU=Tiers,$CorpOU"; Desc='T1: DNS management (Zone 1C)' }
    @{ Name='T1-ROLE-Storage-Admins';Path="OU=Roles,OU=Groups,OU=Zone 1D,OU=Tier 1,OU=Tiers,$CorpOU"; Desc='T1: Storage management (Zone 1D)' }
    # Tier 2
    @{ Name='T2-ROLE-HelpDesk';      Path="OU=Roles,OU=Groups,OU=Zone 2A,OU=Tier 2,OU=Tiers,$CorpOU"; Desc='T2: Helpdesk / workstation support' }
    @{ Name='T2-ROLE-PW-Reset';      Path="OU=Roles,OU=Groups,OU=Zone 2A,OU=Tier 2,OU=Tiers,$CorpOU"; Desc='T2: Password reset only' }
    # PAW groups (MEAM: per tier)
    @{ Name='PAW-T0-Users';          Path="OU=Groups,$CorpOU";             Desc='MEAM: Users allowed to logon to T0 PAWs' }
    @{ Name='PAW-T1-Users';          Path="OU=Groups,$CorpOU";             Desc='MEAM: Users allowed to logon to T1 PAWs' }
    @{ Name='PAW-T2-Users';          Path="OU=Groups,$CorpOU";             Desc='MEAM: Users allowed to logon to T2 PAWs' }
)
foreach ($g in $tierRoleGroups) { New-GroupIfNotExists @g }

# ---- MEAM Zone Delegation Groups (~18 per service) ----
# MEAM pattern: Z[zone]-DLG-[Service]-[ObjectType]-[Permission]
# We create them for each service defined in $Config.ZoneServices
$dlgPermissions = @(
    # Computer object delegations
    'Computers-DomainJoin',       # Allow joining computers to domain
    'Computers-Read',             # Read computer objects
    'Computers-Write',            # Write/modify computer objects
    'Computers-Delete',           # Delete computer objects
    'Computers-MoveOU',           # Move computers between OUs
    'Computers-BitLockerRead',    # Read BitLocker recovery keys
    'Computers-LAPSRead',         # Read LAPS local admin password
    'Computers-LAPSReset',        # Reset LAPS password immediately
    'Computers-GroupMembership',  # Manage computer group membership
    # User object delegations
    'Users-Create',               # Create user accounts
    'Users-Delete',               # Delete user accounts
    'Users-Read',                 # Read user attributes
    'Users-Write',                # Write user attributes
    'Users-PasswordReset',        # Reset user passwords
    'Users-Unlock',               # Unlock locked accounts
    'Users-Enable',               # Enable accounts
    'Users-Disable',              # Disable accounts
    'Users-GroupMembership'       # Manage user group membership
)

foreach ($zoneKey in $Config.ZoneServices.Keys) {
    foreach ($svc in $Config.ZoneServices[$zoneKey]) {
        # Determine tier from zone key
        $tierNum = $zoneKey.Substring(0,1)
        $dlgPath = "OU=Groups,OU=Services,OU=Zone $zoneKey,OU=Tier $tierNum,OU=Tiers,$CorpOU"

        foreach ($perm in $dlgPermissions) {
            $groupName = "Z$zoneKey-DLG-$svc-$perm"
            New-GroupIfNotExists -Name $groupName -Path $dlgPath `
                -Description "MEAM Delegation: Zone $zoneKey / $svc / $perm"
        }

        # Additional: GPO edit group per service zone
        New-GroupIfNotExists -Name "Z$zoneKey-GPO-$svc-Edit" -Path $dlgPath `
            -Description "MEAM: GPO edit rights for $svc in Zone $zoneKey"

        Write-Log "  Delegation groups created for Z$zoneKey / $svc ($(($dlgPermissions).Count + 1) groups)" OK
    }
}

# ---- LAPS Read ACL groups ----
foreach ($zoneKey in @('0A','0B','1A','1B','1C','1D','2A','2B')) {
    $tierNum = $zoneKey.Substring(0,1)
    $path    = "OU=Groups,$CorpOU"
    New-GroupIfNotExists -Name "Z$zoneKey-ACL-LAPS-Read" -Path $path -Description "Read LAPS passwords for Zone $zoneKey computers"
}

Write-Log '=== SECURITY GROUPS COMPLETE ===' OK

#endregion

# ============================================================
#region 4. GROUP NESTING (Role groups -> Built-ins; clean built-ins)
# ============================================================
Write-Log '=== PHASE 4: GROUP NESTING ===' INFO

# Nest T0 role groups into AD built-in groups
$nestings = @(
    @{ M='T0-ROLE-AD-Admins';    I='Domain Admins'               }
    @{ M='T0-ROLE-AD-Admins';    I='Administrators'              }
    @{ M='T0-ROLE-GPO-Admins';   I='Group Policy Creator Owners' }
    @{ M='T0-ROLE-PKI-Admins';   I='Cert Publishers'             }
)
foreach ($n in $nestings) {
    try { Set-Member -Group $n.I -Member $n.M }
    catch { Write-Log "Nesting '$($n.M)' -> '$($n.I)' failed: $_" WARN }
}

# PAW membership: T0 admins use T0 PAWs, T1 admins use T1 PAWs, etc.
Set-Member -Group 'PAW-T0-Users' -Member 'T0-ROLE-AD-Admins'
Set-Member -Group 'PAW-T0-Users' -Member 'T0-ROLE-PKI-Admins'
Set-Member -Group 'PAW-T1-Users' -Member 'T1-ROLE-Server-Admins'
Set-Member -Group 'PAW-T1-Users' -Member 'T1-ROLE-DNS-Admins'
Set-Member -Group 'PAW-T2-Users' -Member 'T2-ROLE-HelpDesk'

# Remove direct user members from Tier 0 built-ins (MEAM Rule #1)
$sensitiveBuiltIns = @('Domain Admins','Schema Admins','Enterprise Admins',
                        'Administrators','Server Operators','Account Operators',
                        'Print Operators','Backup Operators')
foreach ($grp in $sensitiveBuiltIns) {
    $g = Get-ADGroup -Identity $grp -ErrorAction SilentlyContinue
    if (-not $g) { continue }
    foreach ($m in (Get-ADGroupMember -Identity $g -ErrorAction SilentlyContinue)) {
        if ($m.objectClass -eq 'user') {
            Write-Log "  Removing user '$($m.SamAccountName)' from '$grp'" WARN
            Remove-ADGroupMember -Identity $g -Members $m -Confirm:$false
        }
    }
}

Write-Log '=== GROUP NESTING COMPLETE ===' OK

#endregion

# ============================================================
#region 5. FINE-GRAINED PASSWORD POLICIES
# ============================================================
Write-Log '=== PHASE 5: PSOs ===' INFO

foreach ($key in @('T0','T1','T2','SA')) {
    $p = $Config.PSO[$key]
    if (-not (Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$($p.Name)'" -ErrorAction SilentlyContinue)) {
        New-ADFineGrainedPasswordPolicy `
            -Name $p.Name -Precedence $p.Precedence `
            -MinimumPasswordLength $p.MinLength `
            -MaximumPasswordAge    (New-TimeSpan -Days $p.MaxAge) `
            -MinimumPasswordAge    (New-TimeSpan -Days $p.MinAge) `
            -PasswordHistoryCount  $p.History `
            -LockoutThreshold      $p.LockoutThreshold `
            -LockoutDuration       (New-TimeSpan -Minutes $p.LockoutDuration) `
            -LockoutObservationWindow (New-TimeSpan -Minutes $p.ObservationWindow) `
            -ComplexityEnabled $true -ReversibleEncryptionEnabled $false | Out-Null
        Write-Log "PSO '$($p.Name)' (precedence $($p.Precedence))" OK
    }
}

# Apply PSOs to role groups
@(
    @{ PSO='PSO-Tier0'; Groups=@('T0-ROLE-AD-Admins','T0-ROLE-PKI-Admins','T0-ROLE-Hyper-Admins','T0-ROLE-GPO-Admins') }
    @{ PSO='PSO-Tier1'; Groups=@('T1-ROLE-WS-Admins','T1-ROLE-Server-Admins','T1-ROLE-DNS-Admins','T1-ROLE-Storage-Admins') }
    @{ PSO='PSO-Tier2'; Groups=@('T2-ROLE-HelpDesk','T2-ROLE-PW-Reset') }
) | ForEach-Object {
    $pso = Get-ADFineGrainedPasswordPolicy -Identity $_.PSO -ErrorAction SilentlyContinue
    if ($pso) {
        foreach ($g in $_.Groups) {
            $grp = Get-ADGroup -Identity $g -ErrorAction SilentlyContinue
            if ($grp) {
                Add-ADFineGrainedPasswordPolicySubject -Identity $pso -Subjects $grp -ErrorAction SilentlyContinue | Out-Null
                Write-Log "  $($_.PSO) -> $g" OK
            }
        }
    }
}

Write-Log '=== PSOs COMPLETE ===' OK

#endregion

# ============================================================
#region 6. PROTECTED USERS
# ============================================================
Write-Log '=== PHASE 6: PROTECTED USERS ===' INFO
<#
MEAM: ALL zoned user accounts are members of Protected Users.
This provides: no NTLM, no RC4/DES, no delegation, 4h TGT limit, no cached creds.
gMSAs are deliberately EXCLUDED (they cannot be in Protected Users).
#>
$protectedGroups = @(
    'T0-ROLE-AD-Admins','T0-ROLE-PKI-Admins','T0-ROLE-Hyper-Admins','T0-ROLE-GPO-Admins',
    'T1-ROLE-WS-Admins','T1-ROLE-Server-Admins','T1-ROLE-DNS-Admins','T1-ROLE-Storage-Admins',
    'T2-ROLE-HelpDesk','T2-ROLE-PW-Reset',
    'PAW-T0-Users','PAW-T1-Users'
)
foreach ($g in $protectedGroups) {
    try { Set-Member -Group 'Protected Users' -Member $g }
    catch { Write-Log "Protected Users: '$g' failed: $_" WARN }
}
Write-Log '=== PROTECTED USERS COMPLETE ===' OK

#endregion

# ============================================================
#region 7. MEAM AUTHENTICATION POLICIES + SILOS (PAW + Zone)
# ============================================================
<#
MEAM implements TWO types of silos:

1. PAW Silos (per tier): Only PAW machines per tier. PAW-T[n]-Users can authenticate.
2. Zone Silos (per zone): Zone accounts can authenticate to:
   - PAW devices (T[n] PAW Silo)
   - Computers within their own zone
   - Zone 0A (DA zone) ALSO gets DC access

This creates a full "account/device firewall" at the Kerberos level.
#>
if ($Config.EnableAuthSilos) {
    Write-Log '=== PHASE 7: AUTH POLICIES + SILOS (MEAM) ===' INFO

    $dfl = (Get-ADDomain).DomainMode
    if ($dfl -lt 'Windows2012R2Domain') {
        Write-Log "DFL '$dfl' too low for Auth Silos – requires 2012R2+. Skipping." WARN
    } else {

        # --- Authentication Policies (TGT lifetimes) ---
        $authPolicies = @(
            @{ Name='AuthPolicy-T0'; TGT=60;  Desc='Tier 0: 60min TGT, Kerberos only, no NTLM' }
            @{ Name='AuthPolicy-T1'; TGT=120; Desc='Tier 1: 120min TGT, Kerberos only' }
            @{ Name='AuthPolicy-T2'; TGT=240; Desc='Tier 2: 240min TGT' }
        )
        foreach ($ap in $authPolicies) {
            if (-not (Get-ADAuthenticationPolicy -Filter "Name -eq '$($ap.Name)'" -ErrorAction SilentlyContinue)) {
                New-ADAuthenticationPolicy -Name $ap.Name -UserTGTLifetimeMins $ap.TGT `
                    -Description $ap.Desc | Out-Null
                Write-Log "AuthPolicy '$($ap.Name)' created" OK
            }
        }

        # --- PAW Silos (per tier, MEAM) ---
        $pawSilos = @(
            @{ Name='PAW-Silo-T0'; Policy='AuthPolicy-T0'; Desc='MEAM PAW Silo Tier 0: only T0 PAWs allowed' }
            @{ Name='PAW-Silo-T1'; Policy='AuthPolicy-T1'; Desc='MEAM PAW Silo Tier 1: only T1 PAWs allowed' }
            @{ Name='PAW-Silo-T2'; Policy='AuthPolicy-T2'; Desc='MEAM PAW Silo Tier 2: only T2 PAWs allowed' }
        )
        foreach ($silo in $pawSilos) {
            if (-not (Get-ADAuthenticationPolicySilo -Filter "Name -eq '$($silo.Name)'" -ErrorAction SilentlyContinue)) {
                New-ADAuthenticationPolicySilo -Name $silo.Name `
                    -UserAuthenticationPolicy    $silo.Policy `
                    -ComputerAuthenticationPolicy $silo.Policy `
                    -ServiceAuthenticationPolicy  $silo.Policy `
                    -Description $silo.Desc -Enforce | Out-Null
                Write-Log "PAW Silo '$($silo.Name)' created (ENFORCED)" OK
            }
        }

        # --- Zone Silos (per zone, MEAM core concept) ---
        foreach ($tier in @('T0','T1','T2')) {
            $tierNum = $tier.Substring(1)
            $policy  = switch ($tier) { 'T0' {'AuthPolicy-T0'}; 'T1' {'AuthPolicy-T1'}; 'T2' {'AuthPolicy-T2'} }
            foreach ($zoneKey in $Config.Zones[$tier].Keys) {
                $siloName = "Zone-Silo-$zoneKey"
                $zoneLabel = $Config.Zones[$tier][$zoneKey]
                if (-not (Get-ADAuthenticationPolicySilo -Filter "Name -eq '$siloName'" -ErrorAction SilentlyContinue)) {
                    New-ADAuthenticationPolicySilo -Name $siloName `
                        -UserAuthenticationPolicy    $policy `
                        -ComputerAuthenticationPolicy $policy `
                        -ServiceAuthenticationPolicy  $policy `
                        -Description "MEAM Zone Silo – Zone $zoneKey ($zoneLabel)" `
                        -Enforce | Out-Null
                    Write-Log "Zone Silo '$siloName' created (ENFORCED)" OK
                }
            }
        }

        Write-Log @"
POST-SILO MANUAL STEPS:
  Grant-ADAuthenticationPolicySiloAccess -Identity Zone-Silo-0A -Account T0-ROLE-AD-Admins
  Set-ADComputer -Identity DC01   -AuthenticationPolicySilo Zone-Silo-0A
  Set-ADComputer -Identity PAW-T0 -AuthenticationPolicySilo PAW-Silo-T0
  (Repeat for all zones and computer objects)
"@ WARN
    }
    Write-Log '=== AUTH POLICIES + SILOS COMPLETE ===' OK
}

#endregion

# ============================================================
#region 8. GPOs – CREATE / LINK / CONFIGURE
# ============================================================
Write-Log '=== PHASE 8: GPOs ===' INFO

$GPODefs = @(
    # T0
    @{ Name='GPO-T0-DenyLowerTier-Logon'; LinkOU="OU=Domain Controllers,$DomainDN";                          Tier=0 }
    @{ Name='GPO-T0-PAW-Baseline';        LinkOU="OU=PAWs,OU=Tier 0,OU=Tiers,$CorpOU";                      Tier=0 }
    @{ Name='GPO-T0-AuditPolicy';         LinkOU="OU=Domain Controllers,$DomainDN";                          Tier=0 }
    # T1
    @{ Name='GPO-T1-DenyTier2-Logon';     LinkOU="OU=Tier 1,OU=Tiers,$CorpOU";                              Tier=1 }
    @{ Name='GPO-T1-Server-Baseline';     LinkOU="OU=Tier 1,OU=Tiers,$CorpOU";                              Tier=1 }
    @{ Name='GPO-T1-LAPS';               LinkOU="OU=Tier 1,OU=Tiers,$CorpOU";                              Tier=1 }
    # T2
    @{ Name='GPO-T2-DenyT0T1-Logon';     LinkOU="OU=Tier 2,OU=Tiers,$CorpOU";                              Tier=2 }
    @{ Name='GPO-T2-Workstation-Baseline';LinkOU="OU=Tier 2,OU=Tiers,$CorpOU";                              Tier=2 }
    @{ Name='GPO-T2-LAPS';               LinkOU="OU=Tier 2,OU=Tiers,$CorpOU";                              Tier=2 }
    @{ Name='GPO-T2-CredentialGuard';     LinkOU="OU=Zone 2A,OU=Tier 2,OU=Tiers,$CorpOU";                   Tier=2 }
)

foreach ($gpo in $GPODefs) {
    if (-not (Get-GPO -Name $gpo.Name -ErrorAction SilentlyContinue)) {
        New-GPO -Name $gpo.Name -Comment "MEAM Tier $($gpo.Tier) GPO" | Out-Null
        Write-Log "GPO '$($gpo.Name)' created" OK
    }
    $existing = Get-GPInheritance -Target $gpo.LinkOU -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty GpoLinks |
                Where-Object { $_.DisplayName -eq $gpo.Name }
    if (-not $existing) {
        New-GPLink -Name $gpo.Name -Target $gpo.LinkOU -Enforced Yes | Out-Null
        Write-Log "  Linked '$($gpo.Name)' -> $($gpo.LinkOU)" OK
    }
    # Remove Authenticated Users write, keep Apply
    Set-GPPermissions -Name $gpo.Name -PermissionLevel None -TargetName 'Authenticated Users' -TargetType Group -ErrorAction SilentlyContinue | Out-Null
}

# ---- 8a. DENY LOGON (AuthZ layer – complements Auth Silo AuthN layer, MEAM) ----
Write-Log 'Setting User Rights Assignments (Deny logon)...' INFO

# T0 (DCs + PAWs): deny T1, T2, regular users
$t0Deny = @('T1-ROLE-WS-Admins','T1-ROLE-Server-Admins','T1-ROLE-DNS-Admins',
             'T1-ROLE-Storage-Admins','T2-ROLE-HelpDesk','T2-ROLE-PW-Reset','Domain Users')
Set-GPOUserRight 'GPO-T0-DenyLowerTier-Logon' 'SeDenyInteractiveLogonRight'       $t0Deny
Set-GPOUserRight 'GPO-T0-DenyLowerTier-Logon' 'SeDenyRemoteInteractiveLogonRight' $t0Deny
Set-GPOUserRight 'GPO-T0-DenyLowerTier-Logon' 'SeDenyNetworkLogonRight'           ($t0Deny | Where-Object {$_ -ne 'Domain Users'})

# T1 (Servers): deny T2 + regular users
$t1Deny = @('T2-ROLE-HelpDesk','T2-ROLE-PW-Reset','Domain Users')
Set-GPOUserRight 'GPO-T1-DenyTier2-Logon' 'SeDenyInteractiveLogonRight'       $t1Deny
Set-GPOUserRight 'GPO-T1-DenyTier2-Logon' 'SeDenyRemoteInteractiveLogonRight' $t1Deny

# T2 (Workstations): deny T0 + T1 admins (they use PAWs)
$t2Deny = @('T0-ROLE-AD-Admins','T0-ROLE-PKI-Admins','T0-ROLE-Hyper-Admins','T0-ROLE-GPO-Admins',
             'T1-ROLE-WS-Admins','T1-ROLE-Server-Admins','T1-ROLE-DNS-Admins','T1-ROLE-Storage-Admins')
Set-GPOUserRight 'GPO-T2-DenyT0T1-Logon' 'SeDenyInteractiveLogonRight'       $t2Deny
Set-GPOUserRight 'GPO-T2-DenyT0T1-Logon' 'SeDenyRemoteInteractiveLogonRight' $t2Deny

# ---- 8b. Audit, LAPS, Credential Guard ----
Set-AuditPolicyInGPO  'GPO-T0-AuditPolicy'
Set-LAPSGPO           'GPO-T1-LAPS' -UseWindowsLAPS $Config.EnableWindowsLAPS
Set-LAPSGPO           'GPO-T2-LAPS' -UseWindowsLAPS $Config.EnableWindowsLAPS
Set-CredentialGuardGPO 'GPO-T2-CredentialGuard'

Write-Log '=== GPOs COMPLETE ===' OK

#endregion

# ============================================================
#region 9. ACL DELEGATIONS (MEAM delegation groups)
# ============================================================
Write-Log '=== PHASE 9: ACL DELEGATIONS (MEAM) ===' INFO

$userGuid     = [System.Guid]'bf967aba-0de6-11d0-a285-00aa003049e2'
$computerGuid = [System.Guid]'bf967a86-0de6-11d0-a285-00aa003049e2'

# --- Password reset (T1+T2 via delegation groups) ---
$userStdDN = "OU=Standard,OU=Users,$CorpOU"
foreach ($g in @('Z1B-DLG-AppServers-Users-PasswordReset','Z2A-DLG-Workstations-Users-PasswordReset','T2-ROLE-PW-Reset')) {
    if (Get-ADGroup -Filter "Name -eq '$g'" -ErrorAction SilentlyContinue) {
        Set-ADDelegation -TargetDN $userStdDN -GroupSam $g -Rights @('ResetPassword','ChangePassword') -InheritedObjectType $userGuid
    }
}

# --- User create/delete/modify (T1 delegation groups) ---
foreach ($g in @('Z1B-DLG-AppServers-Users-Create','Z1B-DLG-AppServers-Users-Delete')) {
    if (Get-ADGroup -Filter "Name -eq '$g'" -ErrorAction SilentlyContinue) {
        Set-ADDelegation -TargetDN "OU=Users,$CorpOU" -GroupSam $g -Rights @('CreateChild','DeleteChild')
    }
}

# --- Computer domain join (T1 Zone 1A SCCM delegation group) ---
foreach ($g in @('Z1A-DLG-SCCM-Computers-DomainJoin','Z1A-DLG-SCCM-Computers-Write')) {
    if (Get-ADGroup -Filter "Name -eq '$g'" -ErrorAction SilentlyContinue) {
        Set-ADDelegation -TargetDN "OU=Tier 1,OU=Tiers,$CorpOU" -GroupSam $g `
            -Rights @('CreateChild','WriteProperty','ReadProperty') -InheritedObjectType $computerGuid
    }
}

# --- Read users (T2 helpdesk read-only) ---
if (Get-ADGroup -Filter "Name -eq 'Z2A-DLG-Workstations-Users-Read'" -ErrorAction SilentlyContinue) {
    Set-ADDelegation -TargetDN $userStdDN -GroupSam 'Z2A-DLG-Workstations-Users-Read' `
        -Rights @('ReadProperty','GenericRead') -InheritedObjectType $userGuid
}

Write-Log '=== ACL DELEGATIONS COMPLETE ===' OK

#endregion

# ============================================================
#region 10. BREAK-GLASS ACCOUNTS
# ============================================================
Write-Log '=== PHASE 10: BREAK-GLASS ACCOUNTS ===' INFO

$bkOU = "OU=Accounts,OU=Zone 0A,OU=Tier 0,OU=Tiers,$CorpOU"
foreach ($bk in @($Config.BreakGlass.Account1, $Config.BreakGlass.Account2)) {
    New-User -Sam $bk -GN 'Break' -SN 'Glass' -Path $bkOU `
        -Desc 'BREAK-GLASS: Emergency T0 account. Offline vault. Audit ALL usage.' `
        -Password $Config.BreakGlass.TempPassword -PwdNeverExpires $true `
        -SmartcardRequired $false   # break-glass explicitly no smartcard (vault credentials)
    Set-Member -Group 'T0-ROLE-AD-Admins' -Member $bk
    Disable-ADAccount -Identity $bk
    Write-Log "Break-glass '$bk': DISABLED. Store credentials in offline vault (printed, sealed safe)." WARN
}

Write-Log '=== BREAK-GLASS COMPLETE ===' OK

#endregion

# ============================================================
#region 11. TEST ADMIN ACCOUNTS + gMSAs (MEAM)
# ============================================================
if ($Config.CreateTestAccounts) {
    Write-Log '=== PHASE 11: TEST ACCOUNTS + gMSAs ===' INFO

    # MEAM: zoned admin accounts with smartcard enforcement
    $testAdmins = @(
        @{ Sam='adm-t0-test01'; GN='Test'; SN='T0Admin01';
           Path="OU=Accounts,OU=Zone 0A,OU=Tier 0,OU=Tiers,$CorpOU";
           Desc='TEST: Tier 0 / Zone 0A admin'; Groups=@('T0-ROLE-AD-Admins','PAW-T0-Users')
           Pwd='T0@dmin!MEAM2026'; Smartcard=$Config.EnableSmartcard }

        @{ Sam='adm-t1-srv01'; GN='Test'; SN='T1SrvAdmin01';
           Path="OU=Accounts,OU=Zone 1B,OU=Tier 1,OU=Tiers,$CorpOU";
           Desc='TEST: Tier 1 / Zone 1B server admin'; Groups=@('T1-ROLE-Server-Admins','PAW-T1-Users')
           Pwd='T1Srv!MEAM2026'; Smartcard=$Config.EnableSmartcard }

        @{ Sam='adm-t1-dns01'; GN='Test'; SN='T1DnsAdmin01';
           Path="OU=Accounts,OU=Zone 1C,OU=Tier 1,OU=Tiers,$CorpOU";
           Desc='TEST: Tier 1 / Zone 1C DNS admin'; Groups=@('T1-ROLE-DNS-Admins','PAW-T1-Users')
           Pwd='T1Dns!MEAM2026'; Smartcard=$Config.EnableSmartcard }

        @{ Sam='adm-t2-hd01'; GN='Test'; SN='T2HelpDesk01';
           Path="OU=Accounts,OU=Zone 2A,OU=Tier 2,OU=Tiers,$CorpOU";
           Desc='TEST: Tier 2 / Zone 2A helpdesk'; Groups=@('T2-ROLE-HelpDesk','PAW-T2-Users')
           Pwd='T2HD!MEAM2026'; Smartcard=$false }   # T2 helpdesk: smartcard optional
    )
    foreach ($a in $testAdmins) {
        New-User -Sam $a.Sam -GN $a.GN -SN $a.SN -Path $a.Path -Desc $a.Desc `
            -Password $a.Pwd -SmartcardRequired $a.Smartcard
        foreach ($g in $a.Groups) { Set-Member -Group $g -Member $a.Sam }
    }

    # MEAM: gMSAs for zone service accounts (not in Protected Users per MEAM spec)
    Write-Log 'Creating example gMSAs...' INFO
    $gmsaDefs = @(
        @{ Name='svc-z1a-sccm';  ZoneGroup='Z1A-DLG-SCCM-Computers-Read'  }
        @{ Name='svc-z1b-backup'; ZoneGroup='Z1B-DLG-AppServers-Computers-Read' }
        @{ Name='svc-z1c-dns';   ZoneGroup='Z1C-DLG-DNS-Computers-Read'    }
    )
    foreach ($g in $gmsaDefs) {
        if (Get-ADGroup -Filter "Name -eq '$($g.ZoneGroup)'" -ErrorAction SilentlyContinue) {
            New-gMSA -Name $g.Name -ZoneComputerGroup $g.ZoneGroup
        }
    }

    Write-Log '=== TEST ACCOUNTS + gMSAs COMPLETE ===' OK
}

#endregion

# ============================================================
#region 12. DNS TIER 1 DELEGATION (Zone 1C)
# ============================================================
function Add-DnsTierDelegation {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$DnsServerName,
        [Parameter(Mandatory)][string]$ZoneName,
        [string]$Tier1Group = 'T1-ROLE-DNS-Admins',
        [bool]$ConfigureDCsAsSecondary = $true
    )
    Write-Log "=== DNS TIER DELEGATION: $ZoneName on $DnsServerName ===" INFO

    $dnsInst = (Get-WindowsFeature -Name DNS -ComputerName $DnsServerName).Installed
    if (-not $dnsInst) {
        Install-WindowsFeature -Name DNS -ComputerName $DnsServerName -IncludeManagementTools | Out-Null
        Write-Log "DNS role installed on $DnsServerName" OK
    }

    $zone = Get-DnsServerZone -Name $ZoneName -ComputerName $DnsServerName -ErrorAction SilentlyContinue
    if (-not $zone) {
        if ($PSCmdlet.ShouldProcess($DnsServerName,"Create primary zone $ZoneName")) {
            Add-DnsServerPrimaryZone -Name $ZoneName -ComputerName $DnsServerName `
                -ZoneFile "$ZoneName.dns" -DynamicUpdate Secure | Out-Null
            Write-Log "Primary zone '$ZoneName' created on $DnsServerName (file-backed)" OK
        }
    }

    $dcs = Get-ADDomainController -Filter * | Select-Object -ExpandProperty HostName
    foreach ($dc in $dcs) {
        if ($ConfigureDCsAsSecondary) {
            if (-not (Get-DnsServerZone -Name $ZoneName -ComputerName $dc -ErrorAction SilentlyContinue)) {
                if ($PSCmdlet.ShouldProcess($dc,"Create secondary zone")) {
                    Add-DnsServerSecondaryZone -Name $ZoneName -ZoneFile "$ZoneName.dns" `
                        -MasterServers $DnsServerName -ComputerName $dc | Out-Null
                    Write-Log "  Secondary zone on DC $dc" OK
                }
            }
        } else {
            $fwds = (Get-DnsServerForwarder -ComputerName $dc -ErrorAction SilentlyContinue).IPAddress.IPAddressToString
            if ($fwds -notcontains $DnsServerName) {
                if ($PSCmdlet.ShouldProcess($dc,"Add forwarder $DnsServerName")) {
                    Add-DnsServerForwarder -IPAddress $DnsServerName -ComputerName $dc | Out-Null
                    Write-Log "  Forwarder $DnsServerName added to $dc" OK
                }
            }
        }
    }
    Write-Log "=== DNS TIER DELEGATION COMPLETE ===" OK
}

if ($Config.DNS.Deploy -and $Config.DNS.ServerName) {
    Add-DnsTierDelegation `
        -DnsServerName           $Config.DNS.ServerName `
        -ZoneName                $Config.DNS.ZoneName `
        -Tier1Group              'T1-ROLE-DNS-Admins' `
        -ConfigureDCsAsSecondary $Config.DNS.ConfigDCsAsSecondary
}

#endregion

# ============================================================
#region 13. VALIDATION + COMPLIANCE REPORT
# ============================================================
Write-Log '=== PHASE 13: VALIDATION ===' INFO

$report = [ordered]@{}

# OU checks
$checkOUs = @(
    "OU=Zone 0A,OU=Tier 0,OU=Tiers,$CorpOU"
    "OU=Zone 1A,OU=Tier 1,OU=Tiers,$CorpOU"
    "OU=Zone 1C,OU=Tier 1,OU=Tiers,$CorpOU"
    "OU=Zone 2A,OU=Tier 2,OU=Tiers,$CorpOU"
    "OU=PAWs,OU=Tier 0,OU=Tiers,$CorpOU"
)
$ouOK = $true
foreach ($ou in $checkOUs) {
    if (-not (Get-ADOrganizationalUnit -Identity $ou -ErrorAction SilentlyContinue)) {
        Write-Log "MISSING OU: $ou" ERROR; $ouOK = $false
    }
}
$report['MEAM_Zone_OUs'] = if ($ouOK) { 'PASS' } else { 'FAIL' }

# Group checks
$checkGroups = @('T0-ROLE-AD-Admins','T1-ROLE-DNS-Admins','T2-ROLE-HelpDesk',
                  'PAW-T0-Users','PAW-T1-Users','PAW-T2-Users')
$grpOK = $true
foreach ($g in $checkGroups) {
    if (-not (Get-ADGroup -Filter "Name -eq '$g'" -ErrorAction SilentlyContinue)) {
        Write-Log "MISSING GROUP: $g" ERROR; $grpOK = $false
    }
}
$report['MEAM_Role_Groups'] = if ($grpOK) { 'PASS' } else { 'FAIL' }

# PSO checks
$psoOK = $true
foreach ($key in @('T0','T1','T2','SA')) {
    if (-not (Get-ADFineGrainedPasswordPolicy -Filter "Name -eq '$($Config.PSO[$key].Name)'" -ErrorAction SilentlyContinue)) {
        Write-Log "MISSING PSO: $($Config.PSO[$key].Name)" ERROR; $psoOK = $false
    }
}
$report['PSOs'] = if ($psoOK) { 'PASS' } else { 'FAIL' }

# GPO checks
$gpoOK = $true
foreach ($g in $GPODefs) {
    if (-not (Get-GPO -Name $g.Name -ErrorAction SilentlyContinue)) {
        Write-Log "MISSING GPO: $($g.Name)" ERROR; $gpoOK = $false
    }
}
$report['GPOs'] = if ($gpoOK) { 'PASS' } else { 'FAIL' }

# Auth Silos checks
if ($Config.EnableAuthSilos) {
    $siloOK = $true
    foreach ($silo in @('PAW-Silo-T0','PAW-Silo-T1','Zone-Silo-0A','Zone-Silo-1A','Zone-Silo-2A')) {
        if (-not (Get-ADAuthenticationPolicySilo -Filter "Name -eq '$silo'" -ErrorAction SilentlyContinue)) {
            Write-Log "MISSING SILO: $silo" ERROR; $siloOK = $false
        }
    }
    $report['MEAM_Auth_Silos'] = if ($siloOK) { 'PASS' } else { 'FAIL' }
}

# Protected Users check
$pu = Get-ADGroupMember 'Protected Users' | Select-Object -ExpandProperty SamAccountName
$report['ProtectedUsers_HasT0'] = if ('T0-ROLE-AD-Admins' -in $pu) { 'PASS' } else { 'FAIL' }

# DA free of direct users?
$daUsers = Get-ADGroupMember 'Domain Admins' | Where-Object { $_.objectClass -eq 'user' }
$report['DomainAdmins_NoDirectUsers'] = if (-not $daUsers) { 'PASS' } else { "FAIL: $($daUsers.SamAccountName -join ',')" }

# Smartcard check on T0 test account
if ($Config.CreateTestAccounts) {
    $u = Get-ADUser 'adm-t0-test01' -Properties SmartcardLogonRequired -ErrorAction SilentlyContinue
    $report['T0_Smartcard_Enforced'] = if ($u -and $u.SmartcardLogonRequired) { 'PASS' } else { if (-not $Config.EnableSmartcard) { 'SKIPPED (EnableSmartcard=false)' } else { 'FAIL' } }
}

# Print report
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  MEAM DEPLOYMENT COMPLIANCE REPORT" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
foreach ($key in $report.Keys) {
    $color = switch -Wildcard ($report[$key]) { 'PASS' {'Green'}; 'SKIP*' {'Yellow'}; default {'Red'} }
    Write-Host ("  {0,-40} {1}" -f $key, $report[$key]) -ForegroundColor $color
}
Write-Host "========================================`n" -ForegroundColor Cyan

Write-Log @"
POST-DEPLOYMENT CHECKLIST (manual steps):
  1. Move existing computer objects into zone OUs (DCs -> Zone 0A, servers -> Zone 1B, etc.)
  2. Move existing user accounts into correct OU=Users/Standard or zone admin OUs.
  3. Assign accounts + computers to Auth Silos:
       Grant-ADAuthenticationPolicySiloAccess -Identity Zone-Silo-0A -Account T0-ROLE-AD-Admins
       Set-ADComputer -Identity DC01 -AuthenticationPolicySilo Zone-Silo-0A
       Set-ADComputer -Identity PAW-T0-01 -AuthenticationPolicySilo PAW-Silo-T0
  4. Configure PIV/Yubikey smartcard authentication for T0 + T1 admin accounts.
  5. Auto-rotate password on smartcard-only accounts (see MEAM recommendation).
  6. Deploy gMSAs to services (Install-ADServiceAccount on each service host).
  7. Populate Z[zone]-DLG-[svc]-[perm] groups to delegate specific rights.
  8. Configure PAW images: AppLocker/WDAC, no user apps, restricted internet, Credential Guard.
  9. Validate with BloodHound/PingCastle: no Tier1->Tier0 or Zone X->Zone Y attack paths.
 10. Store break-glass credentials in offline vault (sealed envelope in fireproof safe).
 11. Run MEAM validation quarterly: review silo membership, LAPS rotation, Protected Users.
"@ INFO

#endregion
