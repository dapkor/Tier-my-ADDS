#Requires -Modules ActiveDirectory
#Requires -Version 5.1
<#
.SYNOPSIS
    Validates a MEAM deployment after script_v2.ps1 has completed.

.DESCRIPTION
    Reads the same JSON configuration schema used by script_v2.ps1 and performs
    post-deployment acceptance checks against Active Directory and Group Policy.
    Outputs a structured JSON report and a concise PASS/WARN/FAIL summary.

.PARAMETER ConfigPath
    Path to the deployment JSON configuration file.

.PARAMETER ConfigJson
    Inline deployment JSON configuration string.

.PARAMETER OutputPath
    Optional JSON output path. Defaults to .\reports\MEAM-DeploymentValidation-<timestamp>.json.

.EXAMPLE
    .\Validate-MEAM-Deployment.ps1 -ConfigPath .\1. Main\script_v2.config.json

.EXAMPLE
    .\Validate-MEAM-Deployment.ps1 -ConfigPath .\1. Main\script_v2.config.json -OutputPath .\reports\meam-validation.json
#>

[CmdletBinding(DefaultParameterSetName = 'ConfigFile')]
param(
    [Parameter(Mandatory, ParameterSetName = 'ConfigFile')]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath,

    [Parameter(Mandatory, ParameterSetName = 'ConfigInline')]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigJson,

    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ValidationReport = [ordered]@{
    GeneratedAt = (Get-Date).ToString('o')
    ConfigSource = $null
    Domain = $null
    OutputPath = $null
    Summary = [ordered]@{
        Pass = 0
        Warn = 0
        Fail = 0
        Skipped = 0
    }
    Checks = @()
}

$script:QueryTuning = [ordered]@{
    RetryCount = 2
    RetryDelaySeconds = 2
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','OK')][string]$Level = 'INFO'
    )

    $colors = @{ INFO = 'Cyan'; WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green' }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')][$Level] $Message" -ForegroundColor $colors[$Level]
}

function Add-Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('PASS','WARN','FAIL','SKIPPED')][string]$Status,
        [string]$Detail = ''
    )

    $ValidationReport.Checks += [pscustomobject]@{
        Name = $Name
        Status = $Status
        Detail = $Detail
    }

    switch ($Status) {
        'PASS' { $ValidationReport.Summary.Pass++ }
        'WARN' { $ValidationReport.Summary.Warn++ }
        'FAIL' { $ValidationReport.Summary.Fail++ }
        'SKIPPED' { $ValidationReport.Summary.Skipped++ }
    }
}

function ConvertTo-HashtableDeep {
    param([Parameter(Mandatory)]$InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $ht = @{}
        foreach ($key in $InputObject.Keys) {
            $ht[$key] = ConvertTo-HashtableDeep -InputObject $InputObject[$key]
        }
        return $ht
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and -not ($InputObject -is [string])) {
        $items = @()
        foreach ($item in $InputObject) {
            $items += ,(ConvertTo-HashtableDeep -InputObject $item)
        }
        return $items
    }

    if ($InputObject.PSObject -and $InputObject.PSObject.Properties.Count -gt 0) {
        $ht = @{}
        foreach ($prop in $InputObject.PSObject.Properties) {
            $ht[$prop.Name] = ConvertTo-HashtableDeep -InputObject $prop.Value
        }
        return $ht
    }

    return $InputObject
}

function Get-OptionalIntValue {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$PropertyName,
        [Parameter(Mandatory)][int]$DefaultValue
    )

    if ($null -eq $Object -or -not $Object.ContainsKey($PropertyName)) {
        return $DefaultValue
    }

    $parsed = 0
    if ([int]::TryParse([string]$Object[$PropertyName], [ref]$parsed) -and $parsed -ge 0) {
        return $parsed
    }

    return $DefaultValue
}

function Initialize-QueryTuning {
    param([hashtable]$Config)

    $settings = $null
    if ($Config.ContainsKey('QueryTuning')) {
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
            Write-Log "$Operation failed on attempt $attempt. Retrying in $($script:QueryTuning.RetryDelaySeconds) second(s): $($_.Exception.Message)" WARN
            Start-Sleep -Seconds ([int]$script:QueryTuning.RetryDelaySeconds)
        }
    }
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

function Get-ConfigObject {
    if ($PSCmdlet.ParameterSetName -eq 'ConfigFile') {
        if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
            throw "Config file not found: $ConfigPath"
        }

        $ValidationReport.ConfigSource = "file:$ConfigPath"
        $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8
    }
    else {
        $ValidationReport.ConfigSource = 'inline-json'
        $raw = $ConfigJson
    }

    try {
        return ConvertTo-HashtableDeep -InputObject ($raw | ConvertFrom-Json -Depth 30)
    }
    catch {
        throw "Invalid JSON configuration: $($_.Exception.Message)"
    }
}

function Test-AdObjectExists {
    param([Parameter(Mandatory)][string]$DistinguishedName)

    return [bool](Invoke-WithRetry -Operation "Get-ADObject $DistinguishedName" -ScriptBlock {
        Get-ADObject -Identity $DistinguishedName -ErrorAction SilentlyContinue
    })
}

function Test-GpoExists {
    param([Parameter(Mandatory)][string]$Name)

    return [bool](Get-GPO -Name $Name -ErrorAction SilentlyContinue)
}

$Config = Get-ConfigObject
Initialize-QueryTuning -Config $Config

$domain = Invoke-WithRetry -Operation 'Get-ADDomain' -ScriptBlock { Get-ADDomain }
$domainDn = if ($Config.ContainsKey('DomainDN') -and -not [string]::IsNullOrWhiteSpace([string]$Config.DomainDN)) {
    [string]$Config.DomainDN
}
else {
    [string]$domain.DistinguishedName
}

$ValidationReport.Domain = [string]$domain.DNSRoot
$corpOuDn = "OU=$($Config.CorpOU),$domainDn"
$tiersOuDn = "OU=Tiers,$corpOuDn"

if (-not $PSBoundParameters.ContainsKey('OutputPath') -or [string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = ".\reports\MEAM-DeploymentValidation-$(Get-Date -Format 'yyyyMMdd-HHmmss').json"
}
$ValidationReport.OutputPath = $OutputPath

Write-Log 'Running MEAM post-deployment validation...' INFO

# OU checks
$requiredOus = @(
    @{ Name = 'Corp OU'; Dn = $corpOuDn },
    @{ Name = 'Tiers OU'; Dn = $tiersOuDn },
    @{ Name = 'Users OU'; Dn = "OU=Users,$corpOuDn" },
    @{ Name = 'Groups OU'; Dn = "OU=Groups,$corpOuDn" },
    @{ Name = 'Service Accounts OU'; Dn = "OU=Service Accounts,$corpOuDn" }
)

foreach ($tierKey in @('T0','T1','T2')) {
    $tierNum = $tierKey.Substring(1)
    $tierDn = "OU=Tier $tierNum,$tiersOuDn"
    $requiredOus += @(
        @{ Name = "Tier $tierNum OU"; Dn = $tierDn },
        @{ Name = "Tier $tierNum PAWs OU"; Dn = "OU=PAWs,$tierDn" }
    )

    foreach ($zoneKey in $Config.Zones[$tierKey].Keys) {
        $zoneDn = "OU=Zone $zoneKey,$tierDn"
        $requiredOus += @(
            @{ Name = "Zone $zoneKey OU"; Dn = $zoneDn },
            @{ Name = "Zone $zoneKey Computers OU"; Dn = "OU=Computers,$zoneDn" },
            @{ Name = "Zone $zoneKey Accounts OU"; Dn = "OU=Accounts,$zoneDn" },
            @{ Name = "Zone $zoneKey Service Accounts OU"; Dn = "OU=Service Accounts,$zoneDn" },
            @{ Name = "Zone $zoneKey Groups OU"; Dn = "OU=Groups,$zoneDn" },
            @{ Name = "Zone $zoneKey Roles OU"; Dn = "OU=Roles,OU=Groups,$zoneDn" },
            @{ Name = "Zone $zoneKey Delegation OU"; Dn = "OU=Delegation,OU=Groups,$zoneDn" }
        )

        if ($Config.ZoneServices.ContainsKey($zoneKey)) {
            $requiredOus += @{ Name = "Zone $zoneKey Services OU"; Dn = "OU=Services,$zoneDn" }
            foreach ($serviceName in @($Config.ZoneServices[$zoneKey])) {
                $serviceDn = "OU=$serviceName,OU=Services,$zoneDn"
                $requiredOus += @(
                    @{ Name = "Service $serviceName OU"; Dn = $serviceDn },
                    @{ Name = "Service $serviceName Computers OU"; Dn = "OU=Computers,$serviceDn" },
                    @{ Name = "Service $serviceName Groups OU"; Dn = "OU=Groups,$serviceDn" }
                )
            }
        }
    }
}

foreach ($ou in $requiredOus) {
    Add-Check -Name $ou.Name -Status $(if (Test-AdObjectExists -DistinguishedName $ou.Dn) { 'PASS' } else { 'FAIL' }) -Detail $ou.Dn
}

# PSO checks
foreach ($psoKey in @('T0','T1','T2','SA')) {
    $psoName = [string]$Config.PSO[$psoKey].Name
    $exists = [bool](Invoke-WithRetry -Operation "Get-ADFineGrainedPasswordPolicy $psoName" -ScriptBlock { Get-ADFineGrainedPasswordPolicy -Identity $psoName -ErrorAction SilentlyContinue })
    Add-Check -Name "PSO $psoName" -Status $(if ($exists) { 'PASS' } else { 'FAIL' })
}

# GPO checks
$groupPolicyAvailable = [bool](Get-Module -ListAvailable -Name GroupPolicy)
if ($groupPolicyAvailable) {
    Import-Module GroupPolicy -ErrorAction SilentlyContinue | Out-Null
    foreach ($gpoName in @(
        'GPO-KerberosArmoring',
        'GPO-T0-NTLM-Restrict',
        'GPO-T0-DenyLowerTier-Logon',
        'GPO-T0-PAW-Baseline',
        'GPO-T0-AuditPolicy',
        'GPO-T1-DenyTier2-Logon',
        'GPO-T1-Server-Baseline',
        'GPO-T1-LAPS',
        'GPO-T2-DenyT0T1-Logon',
        'GPO-T2-Workstation-Baseline',
        'GPO-T2-LAPS',
        'GPO-T2-CredentialGuard'
    )) {
        Add-Check -Name "GPO $gpoName" -Status $(if (Test-GpoExists -Name $gpoName) { 'PASS' } else { 'FAIL' })
    }
}
else {
    Add-Check -Name 'GroupPolicy module available' -Status 'WARN' -Detail 'GPO validation skipped because the GroupPolicy module is not installed.'
}

# Auth silo checks
if ([bool]$Config.EnableAuthSilos) {
    foreach ($siloName in @('PAW-Silo-T0','PAW-Silo-T1','PAW-Silo-T2')) {
        $silo = Invoke-WithRetry -Operation "Get-ADAuthenticationPolicySilo $siloName" -ScriptBlock { Get-ADAuthenticationPolicySilo -Identity $siloName -ErrorAction SilentlyContinue }
        Add-Check -Name "Auth silo $siloName" -Status $(if ($silo) { 'PASS' } else { 'FAIL' })
    }

    foreach ($tierKey in $Config.Zones.Keys) {
        foreach ($zoneKey in $Config.Zones[$tierKey].Keys) {
            $siloName = "Zone-Silo-$zoneKey"
            $silo = Invoke-WithRetry -Operation "Get-ADAuthenticationPolicySilo $siloName" -ScriptBlock { Get-ADAuthenticationPolicySilo -Identity $siloName -ErrorAction SilentlyContinue }
            Add-Check -Name "Auth silo $siloName" -Status $(if ($silo) { 'PASS' } else { 'FAIL' })
        }
    }
}
else {
    Add-Check -Name 'Authentication silos enabled' -Status 'SKIPPED' -Detail 'EnableAuthSilos=false in configuration.'
}

# Protected Users and privileged group hygiene
$protectedGroups = @(
    'T0-ROLE-AD-Admins','T0-ROLE-PKI-Admins','T0-ROLE-Hyper-Admins','T0-ROLE-GPO-Admins',
    'T1-ROLE-WS-Admins','T1-ROLE-Server-Admins','T1-ROLE-DNS-Admins','T1-ROLE-Storage-Admins',
    'T2-ROLE-HelpDesk','T2-ROLE-PW-Reset','PAW-T0-Users','PAW-T1-Users'
)

$protectedUsersMembers = @(
    Invoke-WithRetry -Operation 'Get-ADGroupMember Protected Users' -ScriptBlock { Get-ADGroupMember 'Protected Users' -ErrorAction SilentlyContinue } |
        Select-Object -ExpandProperty SamAccountName
)
$missingProtected = @($protectedGroups | Where-Object { $_ -notin $protectedUsersMembers })
Add-Check -Name 'Protected Users role nesting' -Status $(if ($missingProtected.Count -eq 0) { 'PASS' } else { 'FAIL' }) -Detail $(if ($missingProtected.Count -gt 0) { 'Missing: ' + ($missingProtected -join ', ') } else { 'All expected role groups are nested.' })

$directDaUsers = @(
    Invoke-WithRetry -Operation 'Get-ADGroupMember Domain Admins' -ScriptBlock { Get-ADGroupMember 'Domain Admins' -ErrorAction SilentlyContinue } |
        Where-Object { $_.objectClass -eq 'user' }
)
Add-Check -Name 'Domain Admins direct user members' -Status $(if ($directDaUsers.Count -eq 0) { 'PASS' } else { 'FAIL' }) -Detail $(if ($directDaUsers.Count -gt 0) { $directDaUsers.SamAccountName -join ', ' } else { 'No direct user members.' })

# Break-glass checks
foreach ($accountName in @([string]$Config.BreakGlass.Account1, [string]$Config.BreakGlass.Account2)) {
    if ([string]::IsNullOrWhiteSpace($accountName)) {
        continue
    }

    $breakGlassUser = Invoke-WithRetry -Operation "Get-ADUser $accountName" -ScriptBlock {
        Get-ADUser -Identity $accountName -Properties Enabled, SmartcardLogonRequired, PasswordNeverExpires -ErrorAction SilentlyContinue
    }

    if (-not $breakGlassUser) {
        Add-Check -Name "Break-glass account $accountName" -Status 'FAIL' -Detail 'Account not found.'
        continue
    }

    Add-Check -Name "Break-glass account $accountName exists" -Status 'PASS'
    Add-Check -Name "Break-glass account $accountName disabled" -Status $(if (-not $breakGlassUser.Enabled) { 'PASS' } else { 'FAIL' })
}

Set-TextFileContent -FilePath $OutputPath -Value ($ValidationReport | ConvertTo-Json -Depth 10)

Write-Host ''
Write-Host 'MEAM Deployment Validation Summary' -ForegroundColor Cyan
Write-Host "  Pass    : $($ValidationReport.Summary.Pass)"
Write-Host "  Warn    : $($ValidationReport.Summary.Warn)"
Write-Host "  Fail    : $($ValidationReport.Summary.Fail)"
Write-Host "  Skipped : $($ValidationReport.Summary.Skipped)"
Write-Host "  Output  : $OutputPath"

[pscustomobject]@{
    Domain = $ValidationReport.Domain
    Pass = $ValidationReport.Summary.Pass
    Warn = $ValidationReport.Summary.Warn
    Fail = $ValidationReport.Summary.Fail
    Skipped = $ValidationReport.Summary.Skipped
    OutputPath = $OutputPath
}