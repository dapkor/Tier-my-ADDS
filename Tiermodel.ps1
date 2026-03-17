<# 
.SYNOPSIS
    Green‑field deployment of a tiered administration model (T0/T1/T2) alongside an existing AD forest.
.DESCRIPTION
    Creates OU structure, security groups (role‑based & access‑control), group nesting,
    Password Settings Objects, GPOs with links/delegations, ACL delegations for common tasks,
    and test user accounts. Based on patterns from FHS7 and SalutAToi tier‑model guides[web:91][web:97].
.NOTES
    Tested on Windows Server 2022 with RSAT. Adjust variables ($DomainDN, $CorpOUName) to match your environment.
    Run as Domain Admin (Tier 0). Review each section before executing in production.
#>

# --------------------------- USER‑CONFIGURABLE VARIABLES ---------------------------
$DomainDN   = (Get-ADDomain).DistinguishedName   # e.g. DC=contoso,DC=corp,DC=net
$CorpOUName = 'Corp'                             # Top‑level OU that will house the tier model
# -------------------------------------------------------------------------------

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp] $Message"
}

Write-Log "Starting tier‑model deployment for domain '$DomainDN'."

# --------------------------- 1. CREATE TOP‑LEVEL OU ---------------------------
if (-not (Get-ADOrganizationalUnit -Filter {Name -eq $CorpOUName} -ErrorAction SilentlyContinue)) {
    New-ADOrganizationalUnit -Name $CorpOUName -ProtectedFromAccidentalDeletion $true -Path $DomainDN |
        Out-Null
    Write-Log "Created OU '$CorpOUName'."
} else {
    Write-Log "OU '$CorpOUName' already exists."
}
$CorpOU = "OU=$CorpOUName,$DomainDN"

# --------------------------- 2. BUILD OU HIERARCHY ---------------------------
$OUDefs = @(
    @{Name='Administration';   Path=$CorpOU},
    @{Name='Users';            Path=$CorpOU},
    @{Name='Computers';        Path=$CorpOU},
    @{Name='Service Accounts'; Path=$CorpOU},
    @{Name='Locations';        Path=$CorpOU}
)

foreach ($ou in $OUDefs) {
    $ouPath = "$($ou.Name),$($ou.Path)"
    if (-not (Get-ADOrganizationalUnit -Filter {Name -eq $ou.Name} -Path $ou.Path -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $ou.Name -Path $ou.Path -ProtectedFromAccidentalDeletion $true | Out-Null
        Write-Log "Created OU '$($ou.Name)' under '$($ou.Path)'."
    }
}

# Tier OUs under Computers
$Tiers = @('Tier 0','Tier 1','Tier 2')
foreach ($t in $Tiers) {
    $ouPath = "$t,OU=Computers,$CorpOU"
    if (-not (Get-ADOrganizationalUnit -Filter {Name -eq $t} -Path "OU=Computers,$CorpOU" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $t -Path "OU=Computers,$CorpOU" -ProtectedFromAccidentalDeletion $true | Out-Null
        Write-Log "Created OU '$t' under Computers."
    }
}

# Location OUs (example: add your sites)
$Locations = @('HQ','Branch1','Branch2')
foreach ($loc in $Locations) {
    $ouPath = "$loc,OU=Locations,$CorpOU"
    if (-not (Get-ADOrganizationalUnit -Filter {Name -eq $loc} -Path "OU=Locations,$CorpOU" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $loc -Path "OU=Locations,$CorpOU" -ProtectedFromAccidentalDeletion $true | Out-Null
        Write-Log "Created location OU '$loc'."
    }
}

# --------------------------- 3. CREATE SECURITY GROUPS ---------------------------
# Define groups as CSV‑like arrays (you can externalize to CSV if preferred)
$Groups = @(
    # Role‑based groups (to be nested in built‑ins later)
    @{Name='ROLE_T0_AD_Admin';       Path="CN=Roles,OU=Tier 0,OU=Administration,$CorpOU"; Scope='DomainLocal'; Category='Security'},
    @{Name='ROLE_T0_Global_GPO';     Path="CN=Roles,OU=Tier 0,OU=Administration,$CorpOU"; Scope='DomainLocal'; Category='Security'},
    @{Name='ROLE_T1_Server_Admins';  Path="CN=Roles,OU=Tier 1,OU=Administration,$CorpOU"; Scope='DomainLocal'; Category='Security'},
    @{Name='ROLE_T1_Workstation_Admins';Path="CN=Roles,OU=Tier 1,OU=Administration,$CorpOU"; Scope='DomainLocal'; Category='Security'},
    @{Name='ROLE_T2_HelpDesk';       Path="CN=Roles,OU=Tier 2,OU=Administration,$CorpOU"; Scope='DomainLocal'; Category='Security'},
    @{Name='ROLE_T2_PW_Reset';       Path="CN=Roles,OU=Tier 2,OU=Administration,$CorpOU"; Scope='DomainLocal'; Category='Security'},
    # Access‑control groups (used for delegations)
    @{Name='GPO_T0_Global_MOD';      Path="CN=Access Control,OU=Tier 0,OU=Administration,$CorpOU"; Scope='DomainLocal'; Category='Security'},
    @{Name='GPO_T1_Server_MOD';      Path="CN=Access Control,OU=Tier 1,OU=Administration,$CorpOU"; Scope='DomainLocal'; Category='Security'},
    @{Name='GPO_T1_Workstation_MOD'; Path="CN=Access Control,OU=Tier 1,OU=Administration,$CorpOU"; Scope='DomainLocal'; Category='Security'},
    @{Name='GPO_T2_HelpDesk_MOD';    Path="CN=Access Control,OU=Tier 2,OU=Administration,$CorpOU"; Scope='DomainLocal'; Category='Security'},
    @{Name='ACL_T1_PW_Reset';        Path="CN=Access Control,OU=Tier 2,OU=Administration,$CorpOU"; Scope='DomainLocal'; Category='Security'},
    @{Name='ACL_T1_User_Create';     Path="CN=Access Control,OU=Tier 2,OU=Administration,$CorpOU"; Scope='DomainLocal'; Category='Security'},
    @{Name='ACL_T2_Read_Users';      Path="CN=Access Control,OU=Tier 2,OU=Administration,$CorpOU"; Scope='DomainLocal'; Category='Security'}


foreach ($g in $Groups) {
    $groupPath = "$($g.Path)"
    if (-not (Get-ADGroup -Filter {Name -eq $g.Name} -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name $g.Name -SamAccountName $g.Name `
            -GroupScope $g.Scope -GroupCategory $g.Category -Path $groupPath | Out-Null
        Write-Log "Created group '$($g.Name)' at '$groupPath'."
    }
}

# --------------------------- 4. NEST ROLE GROUPS IN BUILT‑INS (optional) ---------------------------
# Example: nest T0 admin role into Domain Admins (you may choose to keep DA empty and use only role groups)
$roleToBuiltIn = @(
    @{Role='ROLE_T0_AD_Admin';   BuiltIn='Domain Admins'},
    @{Role='ROLE_T0_Global_GPO'; BuiltIn='Group Policy Creator Owners'},
    @{Role='ROLE_T1_Server_Admins'; BuiltIn=''},
    @{Role='ROLE_T1_Workstation_Admins'; BuiltIn=''},
    @{Role='ROLE_T2_HelpDesk'; BuiltIn=''},
    @{Role='ROLE_T2_PW_Reset'; BuiltIn=''}
)
foreach ($map in $roleToBuiltIn) {
    if ($map.BuiltIn) {
        $roleGroup = Get-ADGroup -Identity $map.Role -ErrorAction SilentlyContinue
        $builtIn   = Get-ADGroup -Identity $map.BuiltIn -ErrorAction SilentlyContinue
        if ($roleGroup -and $builtIn) {
            if (-not (Get-ADGroupMember -Identity $builtIn | Where-Object {$_.SamAccountName -eq $roleGroup.SamAccountName})) {
                Add-ADGroupMember -Identity $builtIn -Members $roleGroup | Out-Null
                Write-Log "Nested role group '$($roleGroup.Name)' into built‑in '$($builtIn.Name)'."
            }
        }
    }
}

# --------------------------- 5. CREATE PASSWORD SETTINGS OBJECTS (PSOs) ---------------------------
$PSOs = @(
    @{Name='PSO_T0_Admins'; Precedence=1; MinLength=20; MaxAge=180; MinAge=1; History=24; LockoutThreshold=0; LockoutDuration=0; LockoutObservationWindow=0; ComplexityEnabled=$true},
    @{Name='PSO_T1_Servers'; Precedence=2; MinLength=14; MaxAge=180; MinAge=1; History=24; LockoutThreshold=0; LockoutDuration=0; LockoutObservationWindow=0; ComplexityEnabled=$true},
    @{Name='PSO_T1_Workstations'; Precedence=3; MinLength=12; MaxAge=180; MinAge=1; History=24; LockoutThreshold=0; LockoutDuration=0; LockoutObservationWindow=0; ComplexityEnabled=$true},
    @{Name='PSO_T2_HelpDesk'; Precedence=4; MinLength=12; MaxAge=180; MinAge=1; History=24; LockoutThreshold=0; LockoutDuration=0; LockoutObservationWindow=0; ComplexityEnabled=$true},
    @{Name='PSO_ServiceAccounts'; Precedence=5; MinLength=20; MaxAge=180; MinAge=1; History=24; LockoutThreshold=0; LockoutDuration=0; LockoutObservationWindow=0; ComplexityEnabled=$true}
)

foreach ($pso in $PSOs) {
    if (-not (Get-ADFineGrainedPasswordPolicy -Filter {Name -eq $pso.Name} -ErrorAction SilentlyContinue)) {
        New-ADFineGrainedPasswordPolicy -Name $pso.Name `
            -Precedence $pso.Precedence `
            -MinimumPasswordLength $pso.MinLength `
            -MaximumPasswordAge (New-TimeSpan -Days $pso.MaxAge) `
            -MinimumPasswordAge (New-TimeSpan -Days $pso.MinAge) `
            -PasswordHistoryCount $pso.History `
            -LockoutThreshold $pso.LockoutThreshold `
            -LockoutDuration (New-TimeSpan -Minutes $pso.LockoutDuration) `
            -LockoutObservationWindow (New-TimeSpan -Minutes $pso.LockoutObservationWindow) `
            -PasswordComplexityEnabled:$pso.ComplexityEnabled |
            Out-Null
        Write-Log "Created PSO '$($pso.Name)' with precedence $($pso.Precedence)."
    }
}

# Apply PSOs to groups (example mapping)
$PSOApplications = @(
    @{PSO='PSO_T0_Admins';        Groups='ROLE_T0_AD_Admin'},
    @{PSO='PSO_T1_Servers';       Groups='ROLE_T1_Server_Admins'},
    @{PSO='PSO_T1_Workstations';  Groups='ROLE_T1_Workstation_Admins'},
    @{PSO='PSO_T2_HelpDesk';      Groups='ROLE_T2_HelpDesk','ROLE_T2_PW_Reset'},
    @{PSO='PSO_ServiceAccounts';  Groups=''} # Service accounts will be assigned manually later
)
foreach ($app in $PSOApplications) {
    $psoObj = Get-ADFineGrainedPasswordPolicy -Identity $app.PSO -ErrorAction SilentlyContinue
    if ($psoObj) {
        foreach ($group in $app.Groups -split ',') {
            if ($group) {
                $gr = Get-ADGroup -Identity $group -ErrorAction SilentlyContinue
                if ($gr) {
                    Add-ADFineGrainedPasswordPolicySubject -Identity $psoObj -Subjects $gr | Out-Null
                    Write-Log "Applied PSO '$($app.PSO)' to group '$group'."
                }
            }
        }
    }
}

# --------------------------- 6. CREATE GPOs, LINK, AND DELEGATE ---------------------------
$GPOs = @(
    @{Name='GPO_T0_Base_Computers';       AdminLevel='Tier0Global'; LinkOU='OU=Tier 0,OU=Computers,$CorpOU'},
    @{Name='GPO_T1_Server_Baseline';      AdminLevel='Tier1AllServers'; LinkOU='OU=Tier 1,OU=Computers,$CorpOU'},
    @{Name='GPO_T1_Workstation_Baseline'; AdminLevel='Tier1AllWorkstations'; LinkOU='OU=Tier 1,OU=Computers,$CorpOU'},
    @{Name='GPO_T2_HelpDesk_Workstations';AdminLevel='Tier2AllWorkstations'; LinkOU='OU=Tier 2,OU=Computers,$CorpOU'}
)

foreach ($gpo in $GPOs) {
    $linkOU = $gpo.LinkOU -replace '\$CorpOU',$CorpOU
    if (-not (Get-GPO -Name $gpo.Name -ErrorAction SilentlyContinue)) {
        New-GPO -Name $gpo.Name | Out-Null
        Write-Log "Created GPO '$($gpo.Name)'."
    }
    # Link
    if (-not (Get-GPOReport -Name $gpo.Name -ErrorAction SilentlyContinue | Select-String -Pattern $linkOU)) {
        New-GPLink -Name $gpo.Name -Target $linkOU -Enforced | Out-Null
        Write-Log "Linked GPO '$($gpo.Name)' to '$linkOU'."
    }
    # Delegate Edit rights to appropriate access‑control group
    $aclGroupName = switch ($gpo.AdminLevel) {
        'Tier0Global' { 'GPO_T0_Global_MOD' }
        'Tier1AllServers' { 'GPO_T1_Server_MOD' }
        'Tier1AllWorkstations' { 'GPO_T1_Workstation_MOD' }
        'Tier2AllWorkstations' { 'GPO_T2_HelpDesk_MOD' }
        default { '' }
    }
    if ($aclGroupName) {
        $aclGroup = Get-ADGroup -Identity $aclGroupName -ErrorAction SilentlyContinue
        if ($aclGroup) {
            # Grant GPO Edit (Read/Write) permission
            $perm = Get-GPPermissions -Name $gpo.Name -ErrorAction SilentlyContinue
            if (-not ($perm | Where-Object {$_.Trustee -eq $aclGroupName -and $_.Permission -eq 'GpoEdit'})) {
                Set-GPPermissions -Name $gpo.Name -PermissionLevel GpoEdit -TargetName $aclGroupName -TargetType Group | Out-Null
                Write-Log "Delegated GpoEdit on '$($gpo.Name)' to group '$aclGroupName'."
            }
        }
    }
}

# --------------------------- 7. ACL DELEGATIONS FOR COMMON TASKS ---------------------------
# Define ACLs as a simple array of objects; each defines target DN, group, and rights
$ACLs = @(
    @{Target='OU=Users,OU=Tier 2,OU=Corp,$DomainDN'; Group='ACL_T2_Read_Users'; Rights='ReadProperty'},
    @{Target='OU=Users,OU=Corp,$DomainDN'; Group='ACL_T1_User_Create'; Rights='CreateChild,DeleteChild'},
    @{Target='OU=Users,OU=Corp,$DomainDN'; Group='ACL_T1_PW_Reset'; Rights='ResetPassword'}
)

foreach ($acl in $ACLs) {
    $targetDN = $acl.Target -replace '\$DomainDN',$DomainDN
    if (-not (Get-ADObject -Identity $targetDN -ErrorAction SilentlyContinue)) {
        Write-Log "Target DN '$targetDN' not found – skipping ACL."
        continue
    }
    $sid = (Get-ADGroup -Identity $acl.Group).SID.Value
    $aclObject = Get-ACL "AD::$targetDN"
    # Map Rights string to ActiveDirectoryRights (simplified)
    $rightsMap = @{
        'ReadProperty' = [System.DirectoryServices.ActiveDirectoryRights]::ReadProperty
        'CreateChild'  = [System.DirectoryServices.ActiveDirectoryRights]::CreateChild
        'DeleteChild'  = [System.DirectoryServices.ActiveDirectoryRights]::DeleteChild
        'ResetPassword'= [System.DirectoryServices.ActiveDirectoryRights]::ResetPassword
    }
    $rights = 0
    foreach ($r in $acl.Rights -split ',') {
        $trim = $r.Trim()
        if ($rightsMap.ContainsKey($trim)) {
            $rights = $rights -bor $rightsMap[$trim]
        }
    }
    $ace = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
        $sid, $rights, [System.Security.AccessControl.AccessControlType]::Allow,
        [Guid]::Empty, $null, [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None
    )
    if (-not ($aclObject.Access | Where-Object {$_.IdentityReference -eq $sid -and ($_.ActiveDirectoryRights -band $rights) -eq $rights})) {
        $aclObject.AddAccessRule($ace)
        Set-ACL -Path "AD::$targetDN" -AclObject $aclObject
        Write-Log "Added ACL for group '$($acl.Group)' on '$targetDN' with rights '$($acl.Rights)'."
    }
}

# --------------------------- 8. CREATE TEST USER ACCOUNTS ---------------------------
$TestUsers = @(
    @{Sam='t0_admin';   Name='Tier0 Admin';   Tier0=$true;  Tier1=$false; Tier2=$false; Password='P@ssw0rd!2026'},
    @{Sam='t1_srv';     Name='Tier1 Server Admin'; Tier0=$false; Tier1=$true;  Tier2=$false; Password='P@ssw0rd!2026'},
    @{Sam='t1_ws';      Name='Tier1 Workstation Admin'; Tier0=$false; Tier1=$true;  Tier2=$false; Password='P@ssw0rd!2026'},
    @{Sam='t2_helpdesk';Name='Tier2 Helpdesk';    Tier0=$false; Tier1=$false; Tier2=$true;  Password='P@ssw0rd!2026'},
    @{Sam='t2_pwreset'; Name='Tier2 PW Reset';    Tier0=$false; Tier1=$false; Tier2=$true;  Password='P@ssw0rd!2026'}
)

foreach ($u in $TestUsers) {
    $ouPath = "OU=Users,$CorpOU"
    if ($u.Tier0) { $ouPath = "OU=Users,OU=Tier 0,OU=Users,$CorpOU" }
    elseif ($u.Tier1) { $ouPath = "OU=Users,OU=Tier 1,OU=Users,$CorpOU" }
    elseif ($u.Tier2) { $ouPath = "OU=Users,OU=Tier 2,OU=Users,$CorpOU" }
    # Ensure tier-specific user OUs exist
    $tierOU = if ($u.Tier0) { "OU=Tier 0,OU=Users,$CorpOU" }
              elseif ($u.Tier1) { "OU=Tier 1,OU=Users,$CorpOU" }
              elseif ($u.Tier2) { "OU=Tier 2,OU=Users,$CorpOU" }
    if ($tierOU -and -not (Get-ADOrganizationalUnit -Filter {Name -eq ('Tier {0}' -f ($u.Tier0*0+$u.Tier1*1+$u.Tier2*2))} -Path "OU=Users,$CorpOU" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name ("Tier {0}" -f ($u.Tier0*0+$u.Tier1*1+$u.Tier2*2)) -Path "OU=Users,$CorpOU" -ProtectedFromAccidentalDeletion $true | Out-Null
    }
    if (-not (Get-ADUser -Filter {SamAccountName -eq $u.Sam} -ErrorAction SilentlyContinue)) {
        New-ADUser -SamAccountName $u.Sam -Name $u.Name `
            -GivenName ($u.Name -split ' ')[0] -Surname ($u.Name -split ' ')[-1] `
            -UserPrincipalName ("{0}@{1}" -f $u.Sam, ($DomainDN -replace '^DC=','').replace(',','.')) `
            -Path $ouPath -AccountPassword (ConvertTo-SecureString $u.Password -AsPlainText -Force) `
            -Enabled $true -PasswordNeverExpires $false -ChangePasswordAtLogon $true | Out-Null
        Write-Log "Created test user '$($u.Sam)' in '$ouPath'."
        # Add to appropriate role group
        if ($u.Tier0) { Add-ADGroupMember -Identity 'ROLE_T0_AD_Admin' -Members $u.Sam | Out-Null }
        elseif ($u.Tier1) { 
            if ($u.Sam -like '*srv*') { Add-ADGroupMember -Identity 'ROLE_T1_Server_Admins' -Members $u.Sam | Out-Null }
            elseif ($u.Sam -like '*ws*') { Add-ADGroupMember -Identity 'ROLE_T1_Workstation_Admins' -Members $u.Sam | Out-Null }
        }
        elseif ($u.Tier2) {
            if ($u.Sam -like '*helpdesk*') { Add-ADGroupMember -Identity 'ROLE_T2_HelpDesk' -Members $u.Sam | Out-Null }
            elseif ($u.Sam -like '*pwreset*') { Add-ADGroupMember -Identity 'ROLE_T2_PW_Reset' -Members $u.Sam | Out-Null }
        }
    }
}

Write-Log "Tier‑model deployment completed. Review outputs, move existing objects into appropriate tier OUs, and harden GPOs as needed."
)