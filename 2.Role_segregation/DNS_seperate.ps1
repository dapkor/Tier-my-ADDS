<#
.SYNOPSIS
    DNS role separation with config-driven execution and run reporting.

.DESCRIPTION
    Implements DNS separation so AD authority stays on DCs while client recursion
    is handled by a dedicated resolver. All deployment values are supplied by JSON
    input (file or inline), with phase-based execution, non-fatal error handling,
    and structured run artifacts.

.PARAMETER ConfigPath
    Path to JSON configuration file.

.PARAMETER ConfigJson
    Inline JSON configuration string.

.PARAMETER LintConfigOnly
    Validate configuration and exit without applying DNS changes.

.PARAMETER FailOnPhaseError
    Stop on first phase failure.

.EXAMPLE
    .\DNS_seperate.ps1 -ConfigPath .\dns-separation.config.json

.EXAMPLE
    .\DNS_seperate.ps1 -ConfigPath .\dns-separation.config.json -LintConfigOnly
#>

#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory, ParameterSetName = 'ConfigFile')]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath,

    [Parameter(Mandatory, ParameterSetName = 'ConfigInline')]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigJson,

    [switch]$LintConfigOnly,
    [switch]$FailOnPhaseError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:Cfg = $null
$script:Resolved = [ordered]@{
    DomainFqdn = $null
    DomainControllerIPs = @()
    ResolverIp = $null
    BaselinePath = $null
    Plan = @()
}

$script:RunReport = [ordered]@{
    StartTime = (Get-Date).ToString('o')
    EndTime = $null
    DurationSeconds = 0
    ConfigSource = $null
    Status = 'InProgress'
    Warnings = @()
    Errors = @()
    Phases = @()
    Outputs = [ordered]@{
        BaselineJsonPath = $null
        RunReportJsonPath = $null
        RunReportPhaseCsvPath = $null
        ChangePlanPath = $null
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )

    $colors = @{ INFO = 'Cyan'; WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green' }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')][$Level] $Message" -ForegroundColor $colors[$Level]
}

function Add-RunWarning {
    param([Parameter(Mandatory)][string]$Message)
    $script:RunReport.Warnings += $Message
    Write-Log $Message WARN
}

function Add-RunError {
    param([Parameter(Mandatory)][string]$Message)
    $script:RunReport.Errors += $Message
    Write-Log $Message ERROR
}

function Invoke-Phase {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Block,
        [switch]$ContinueOnError
    )

    $start = Get-Date
    Write-Log "=== PHASE START: $Name ===" INFO

    $phase = [ordered]@{
        Name = $Name
        StartTime = $start.ToString('o')
        EndTime = $null
        DurationSeconds = 0
        Status = 'Succeeded'
        Error = $null
    }

    try {
        & $Block
        Write-Log "=== PHASE COMPLETE: $Name ===" OK
    }
    catch {
        $phase.Status = 'Failed'
        $phase.Error = $_.Exception.Message

        if ($ContinueOnError) {
            Add-RunWarning "Phase '$Name' failed (non-fatal): $($_.Exception.Message)"
        }
        else {
            Add-RunError "Phase '$Name' failed: $($_.Exception.Message)"
            if ($FailOnPhaseError) {
                throw
            }
            throw
        }
    }
    finally {
        $finish = Get-Date
        $phase.EndTime = $finish.ToString('o')
        $phase.DurationSeconds = [math]::Round(($finish - $start).TotalSeconds, 2)
        $script:RunReport.Phases += [pscustomobject]$phase
    }
}

function Get-ConfigObject {
    if ($PSCmdlet.ParameterSetName -eq 'ConfigFile') {
        if (-not (Test-Path $ConfigPath)) {
            throw "Config file not found: $ConfigPath"
        }
        $raw = Get-Content -Path $ConfigPath -Raw -Encoding UTF8
        $script:RunReport.ConfigSource = "file:${ConfigPath}"
    }
    else {
        $raw = $ConfigJson
        $script:RunReport.ConfigSource = 'inline-json'
    }

    try {
        return ($raw | ConvertFrom-Json -Depth 20)
    }
    catch {
        throw "Invalid JSON configuration: $($_.Exception.Message)"
    }
}

function Test-ModuleAvailable {
    param([Parameter(Mandatory)][string]$Name)

    if (-not (Get-Module -ListAvailable -Name $Name)) {
        throw "Required module '$Name' not found. Install required RSAT/feature components and retry."
    }
}

function New-DirectoryForFilePath {
    param([Parameter(Mandatory)][string]$FilePath)

    $dir = Split-Path -Parent $FilePath
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
}

function Test-ConfigSchema {
    param([Parameter(Mandatory)]$Config)

    $requiredTop = @(
        'resolverServer',
        'upstreamResolvers',
        'forceConvertAuthoritativeZone',
        'configureDhcp',
        'autoApprove',
        'outputs'
    )

    foreach ($name in $requiredTop) {
        if (-not $Config.PSObject.Properties.Name.Contains($name)) {
            throw "Config missing required property '$name'."
        }
    }

    if (-not $Config.outputs.PSObject.Properties.Name.Contains('runReportJsonPath')) {
        throw "Config.outputs missing 'runReportJsonPath'."
    }
    if (-not $Config.outputs.PSObject.Properties.Name.Contains('runReportPhaseCsvPath')) {
        throw "Config.outputs missing 'runReportPhaseCsvPath'."
    }

    if ([string]::IsNullOrWhiteSpace([string]$Config.resolverServer)) {
        throw "Config.resolverServer cannot be empty."
    }

    $upstream = @($Config.upstreamResolvers)
    if ($upstream.Count -eq 0) {
        throw 'Config.upstreamResolvers must contain at least one IP.'
    }

    if ([bool]$Config.configureDhcp) {
        if (-not $Config.PSObject.Properties.Name.Contains('dhcpServer') -or [string]::IsNullOrWhiteSpace([string]$Config.dhcpServer)) {
            throw "Config.configureDhcp=true requires config.dhcpServer."
        }
        $scopes = @($Config.dhcpScopeIds)
        if ($scopes.Count -eq 0) {
            throw "Config.configureDhcp=true requires config.dhcpScopeIds."
        }
    }
}

function Get-HostIPv4Address {
    param([Parameter(Mandatory)][string]$ComputerName)

    $records = Resolve-DnsName -Name $ComputerName -Type A -ErrorAction Stop
    $ips = $records | Select-Object -ExpandProperty IPAddress
    if (-not $ips) {
        throw "No A record found for '$ComputerName'."
    }
    return $ips[0]
}

function New-BaselineSnapshot {
    param(
        [Parameter(Mandatory)][string]$Resolver,
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string[]]$DcIPs,
        [Parameter(Mandatory)][bool]$IncludeDhcp,
        [string]$DhcpSrv,
        [string[]]$Scopes,
        [Parameter(Mandatory)][string]$OutPath
    )

    $resolverZones = Get-DnsServerZone -ComputerName $Resolver -ErrorAction SilentlyContinue |
        Select-Object ZoneName, ZoneType, IsDsIntegrated, IsReverseLookupZone
    $resolverForwarders = (Get-DnsServerForwarder -ComputerName $Resolver -ErrorAction SilentlyContinue).IPAddress.IPAddressToString

    $domainZoneState = Get-DnsServerZone -ComputerName $Resolver -Name $Domain -ErrorAction SilentlyContinue |
        Select-Object ZoneName, ZoneType, IsDsIntegrated
    $msdcsZoneName = "_msdcs.$Domain"
    $msdcsZoneState = Get-DnsServerZone -ComputerName $Resolver -Name $msdcsZoneName -ErrorAction SilentlyContinue |
        Select-Object ZoneName, ZoneType, IsDsIntegrated

    $dhcpState = @()
    if ($IncludeDhcp -and $DhcpSrv -and $Scopes) {
        foreach ($scope in $Scopes) {
            $opt = Get-DhcpServerv4OptionValue -ComputerName $DhcpSrv -ScopeId $scope -OptionId 6 -ErrorAction SilentlyContinue
            $dnsOpt = $null
            if ($opt) {
                $dnsOpt = @($opt.Value)
            }
            $dhcpState += [pscustomobject]@{
                ScopeId = $scope
                Option006DnsServers = $dnsOpt
            }
        }
    }

    $payload = [pscustomobject]@{
        Timestamp = (Get-Date).ToString('o')
        ResolverServer = $Resolver
        DomainFqdn = $Domain
        DcDnsTargets = $DcIPs
        ResolverForwarders = $resolverForwarders
        ResolverZones = $resolverZones
        DomainZoneState = $domainZoneState
        MsdcsZoneState = $msdcsZoneState
        DhcpServer = $DhcpSrv
        DhcpScopes = $dhcpState
    }

    $payload | ConvertTo-Json -Depth 8 | Set-Content -Path $OutPath -Encoding UTF8
    return $OutPath
}

function Get-ActionPlan {
    param(
        [Parameter(Mandatory)][string]$Resolver,
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string[]]$DcIPs,
        [Parameter(Mandatory)][string[]]$Upstream,
        [Parameter(Mandatory)][bool]$IncludeDhcp,
        [string]$DhcpSrv,
        [string[]]$Scopes,
        [Parameter(Mandatory)][string]$ResolverIP,
        [Parameter(Mandatory)][bool]$AllowAuthoritativeReplace
    )

    $items = New-Object System.Collections.Generic.List[string]

    $feature = Get-WindowsFeature -Name DNS -ComputerName $Resolver
    if (-not $feature.Installed) {
        $items.Add("Install DNS Server role on $Resolver")
    }
    else {
        $items.Add("No role install needed on $Resolver (DNS role already installed)")
    }

    $currentForwarders = (Get-DnsServerForwarder -ComputerName $Resolver -ErrorAction SilentlyContinue).IPAddress.IPAddressToString
    $currentForwarders = @($currentForwarders | Where-Object { $_ })
    if ((@($currentForwarders) -join ',') -ne (@($Upstream) -join ',')) {
        $items.Add("Set resolver upstream forwarders on $Resolver to: $($Upstream -join ', ')")
    }
    else {
        $items.Add("No upstream forwarder change needed on $Resolver")
    }

    foreach ($zoneName in @($Domain, "_msdcs.$Domain")) {
        $zone = Get-DnsServerZone -ComputerName $Resolver -Name $zoneName -ErrorAction SilentlyContinue
        if (-not $zone) {
            $items.Add("Create conditional forwarder '$zoneName' -> $($DcIPs -join ', ')")
            continue
        }

        if ($zone.ZoneType -ne 'Forwarder') {
            if ($AllowAuthoritativeReplace) {
                $items.Add("Remove existing $($zone.ZoneType) zone '$zoneName' and replace with conditional forwarder")
            }
            else {
                $items.Add("STOP: '$zoneName' is $($zone.ZoneType). Set forceConvertAuthoritativeZone=true to replace it")
            }
            continue
        }

        $fwd = Get-DnsServerConditionalForwarderZone -ComputerName $Resolver -Name $zoneName -ErrorAction SilentlyContinue
        $masters = @()
        if ($fwd) {
            $masters = @($fwd.MasterServers | ForEach-Object { $_.IPAddressToString })
        }

        if ((@($masters) -join ',') -ne (@($DcIPs) -join ',')) {
            $items.Add("Update conditional forwarder '$zoneName' to: $($DcIPs -join ', ')")
        }
        else {
            $items.Add("No change needed for conditional forwarder '$zoneName'")
        }
    }

    if ($IncludeDhcp -and $DhcpSrv -and $Scopes) {
        foreach ($scope in $Scopes) {
            $opt = Get-DhcpServerv4OptionValue -ComputerName $DhcpSrv -ScopeId $scope -OptionId 6 -ErrorAction SilentlyContinue
            $currentDns = @()
            if ($opt) {
                $currentDns = @($opt.Value)
            }

            if ((@($currentDns) -join ',') -ne $ResolverIP) {
                $items.Add("Set DHCP scope $scope option 006 to resolver $ResolverIP")
            }
            else {
                $items.Add("No DHCP update needed for scope $scope")
            }
        }
    }

    return $items
}

function Confirm-Execution {
    param([Parameter(Mandatory)][string[]]$ActionPlan)

    Write-Host ''
    Write-Host 'Planned changes:' -ForegroundColor Cyan
    $index = 1
    foreach ($line in $ActionPlan) {
        Write-Host ("  [{0}] {1}" -f $index, $line)
        $index++
    }
    Write-Host ''

    while ($true) {
        $answer = (Read-Host 'Execute these changes? (yes/no)').Trim().ToLowerInvariant()
        switch ($answer) {
            'yes' { return $true }
            'y' { return $true }
            'no' { return $false }
            'n' { return $false }
            default { Write-Log 'Please type yes or no.' WARN }
        }
    }
}

function Set-DnsRoleInstalled {
    param([Parameter(Mandatory)][string]$ComputerName)

    $feature = Get-WindowsFeature -Name DNS -ComputerName $ComputerName
    if (-not $feature.Installed) {
        if ($PSCmdlet.ShouldProcess($ComputerName, 'Install DNS Server role')) {
            Install-WindowsFeature -Name DNS -ComputerName $ComputerName -IncludeManagementTools | Out-Null
            Write-Log "Installed DNS role on $ComputerName" OK
        }
    }
    else {
        Write-Log "DNS role already installed on $ComputerName" INFO
    }
}

function Set-ConditionalForwarder {
    param(
        [Parameter(Mandatory)][string]$DnsServer,
        [Parameter(Mandatory)][string]$ZoneName,
        [Parameter(Mandatory)][string[]]$MasterServers,
        [Parameter(Mandatory)][bool]$AllowAuthoritativeReplace
    )

    $existing = Get-DnsServerZone -ComputerName $DnsServer -Name $ZoneName -ErrorAction SilentlyContinue
    if ($existing -and $existing.ZoneType -ne 'Forwarder') {
        if (-not $AllowAuthoritativeReplace) {
            throw "Zone '$ZoneName' on '$DnsServer' is '$($existing.ZoneType)'. Set forceConvertAuthoritativeZone=true to replace it."
        }

        if ($PSCmdlet.ShouldProcess($DnsServer, "Remove zone $ZoneName ($($existing.ZoneType))")) {
            Remove-DnsServerZone -ComputerName $DnsServer -Name $ZoneName -Force
            Write-Log "Removed authoritative zone '$ZoneName' from $DnsServer" WARN
        }
    }

    $forwarder = Get-DnsServerConditionalForwarderZone -ComputerName $DnsServer -Name $ZoneName -ErrorAction SilentlyContinue
    if (-not $forwarder) {
        if ($PSCmdlet.ShouldProcess($DnsServer, "Create conditional forwarder $ZoneName")) {
            Add-DnsServerConditionalForwarderZone -ComputerName $DnsServer -Name $ZoneName -MasterServers $MasterServers -ReplicationScope Forest | Out-Null
            Write-Log "Created conditional forwarder '$ZoneName'" OK
        }
    }
    else {
        if ($PSCmdlet.ShouldProcess($DnsServer, "Update conditional forwarder $ZoneName")) {
            Set-DnsServerConditionalForwarderZone -ComputerName $DnsServer -Name $ZoneName -MasterServers $MasterServers | Out-Null
            Write-Log "Updated conditional forwarder '$ZoneName'" OK
        }
    }
}

function Set-ResolverForwarders {
    param(
        [Parameter(Mandatory)][string]$DnsServer,
        [Parameter(Mandatory)][string[]]$Forwarders
    )

    if ($PSCmdlet.ShouldProcess($DnsServer, 'Set upstream forwarders and disable root hints fallback')) {
        Set-DnsServerForwarder -ComputerName $DnsServer -IPAddress $Forwarders -UseRootHint $false | Out-Null
        Write-Log "Set upstream forwarders on $DnsServer" OK
    }
}

function Set-DhcpScopesDnsOption {
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][string[]]$ScopeIds,
        [Parameter(Mandatory)][string[]]$DnsIPs
    )

    foreach ($scopeId in $ScopeIds) {
        if ($PSCmdlet.ShouldProcess($Server, "Set DHCP scope $scopeId option 006")) {
            Set-DhcpServerv4OptionValue -ComputerName $Server -ScopeId $scopeId -DnsServer $DnsIPs | Out-Null
            Write-Log "DHCP scope $scopeId DNS servers updated" OK
        }
    }
}

function Export-RunArtifacts {
    param(
        [Parameter(Mandatory)][string]$RunReportJsonPath,
        [Parameter(Mandatory)][string]$RunReportPhaseCsvPath,
        [string]$Status
    )

    $script:RunReport.EndTime = (Get-Date).ToString('o')
    $script:RunReport.DurationSeconds = [math]::Round(((Get-Date) - [datetime]$script:RunReport.StartTime).TotalSeconds, 2)
    if ($Status) {
        $script:RunReport.Status = $Status
    }

    $script:RunReport | ConvertTo-Json -Depth 20 | Set-Content -Path $RunReportJsonPath -Encoding UTF8
    $script:RunReport.Phases |
        Select-Object Name, Status, DurationSeconds, StartTime, EndTime, Error |
        Export-Csv -Path $RunReportPhaseCsvPath -NoTypeInformation -Encoding UTF8
}

try {
    Invoke-Phase -Name 'Load And Validate Config' -Block {
        $script:Cfg = Get-ConfigObject
        Test-ConfigSchema -Config $script:Cfg

        $script:RunReport.Outputs.RunReportJsonPath = [string]$script:Cfg.outputs.runReportJsonPath
        $script:RunReport.Outputs.RunReportPhaseCsvPath = [string]$script:Cfg.outputs.runReportPhaseCsvPath

        if ($script:Cfg.outputs.PSObject.Properties.Name.Contains('baselineJsonPath')) {
            $script:RunReport.Outputs.BaselineJsonPath = [string]$script:Cfg.outputs.baselineJsonPath
        }
        else {
            $scriptDir = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $script:RunReport.Outputs.BaselineJsonPath = Join-Path $scriptDir "DNS-Baseline-$stamp.json"
        }

        if ($script:Cfg.outputs.PSObject.Properties.Name.Contains('changePlanPath')) {
            $script:RunReport.Outputs.ChangePlanPath = [string]$script:Cfg.outputs.changePlanPath
        }
        else {
            $scriptDir = if ($PSCommandPath) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $script:RunReport.Outputs.ChangePlanPath = Join-Path $scriptDir "DNS-Plan-$stamp.txt"
        }

        New-DirectoryForFilePath -FilePath ([string]$script:RunReport.Outputs.RunReportJsonPath)
        New-DirectoryForFilePath -FilePath ([string]$script:RunReport.Outputs.RunReportPhaseCsvPath)
        New-DirectoryForFilePath -FilePath ([string]$script:RunReport.Outputs.BaselineJsonPath)
        New-DirectoryForFilePath -FilePath ([string]$script:RunReport.Outputs.ChangePlanPath)
    } -ContinueOnError:$false

    if ($LintConfigOnly) {
        Invoke-Phase -Name 'Lint Config Only' -Block {
            Write-Log 'Configuration schema validation passed.' OK
            Export-RunArtifacts -RunReportJsonPath ([string]$script:RunReport.Outputs.RunReportJsonPath) -RunReportPhaseCsvPath ([string]$script:RunReport.Outputs.RunReportPhaseCsvPath) -Status 'LintPassed'
            Write-Host "Config source        : $($script:RunReport.ConfigSource)"
            Write-Host "Run report (JSON)   : $($script:RunReport.Outputs.RunReportJsonPath)"
            Write-Host "Phase report (CSV)  : $($script:RunReport.Outputs.RunReportPhaseCsvPath)"
        } -ContinueOnError:$false

        return
    }

    Invoke-Phase -Name 'Pre-Flight' -Block {
        Test-ModuleAvailable -Name ActiveDirectory
        Test-ModuleAvailable -Name DnsServer
        if ([bool]$script:Cfg.configureDhcp) {
            Test-ModuleAvailable -Name DhcpServer
        }

        if ($script:Cfg.PSObject.Properties.Name.Contains('domainFqdn') -and -not [string]::IsNullOrWhiteSpace([string]$script:Cfg.domainFqdn)) {
            $script:Resolved.DomainFqdn = [string]$script:Cfg.domainFqdn
        }
        else {
            $script:Resolved.DomainFqdn = (Get-ADDomain).DNSRoot
        }

        if ($script:Cfg.PSObject.Properties.Name.Contains('domainControllerIPs') -and @($script:Cfg.domainControllerIPs).Count -gt 0) {
            $script:Resolved.DomainControllerIPs = @($script:Cfg.domainControllerIPs)
        }
        else {
            $script:Resolved.DomainControllerIPs = Get-ADDomainController -Filter * |
                Select-Object -ExpandProperty HostName |
                ForEach-Object { Get-HostIPv4Address -ComputerName $_ } |
                Select-Object -Unique
        }

        if (-not $script:Resolved.DomainControllerIPs -or $script:Resolved.DomainControllerIPs.Count -eq 0) {
            throw 'No domain controller IPs resolved. Provide domainControllerIPs in config.'
        }

        if ([bool]$script:Cfg.configureDhcp) {
            if (-not $script:Cfg.PSObject.Properties.Name.Contains('dhcpServer') -or [string]::IsNullOrWhiteSpace([string]$script:Cfg.dhcpServer)) {
                throw 'configureDhcp=true but dhcpServer is missing.'
            }
            if (-not $script:Cfg.PSObject.Properties.Name.Contains('dhcpScopeIds') -or @($script:Cfg.dhcpScopeIds).Count -eq 0) {
                throw 'configureDhcp=true but dhcpScopeIds is missing.'
            }
        }

        $script:Resolved.ResolverIp = Get-HostIPv4Address -ComputerName ([string]$script:Cfg.resolverServer)

        Write-Log "Domain: $($script:Resolved.DomainFqdn)" INFO
        Write-Log "Resolver: $($script:Cfg.resolverServer) ($($script:Resolved.ResolverIp))" INFO
        Write-Log "DC DNS targets: $($script:Resolved.DomainControllerIPs -join ', ')" INFO
    } -ContinueOnError:$false

    Invoke-Phase -Name 'Create Baseline' -Block {
        $script:Resolved.BaselinePath = New-BaselineSnapshot `
            -Resolver ([string]$script:Cfg.resolverServer) `
            -Domain $script:Resolved.DomainFqdn `
            -DcIPs $script:Resolved.DomainControllerIPs `
            -IncludeDhcp ([bool]$script:Cfg.configureDhcp) `
            -DhcpSrv ([string]$script:Cfg.dhcpServer) `
            -Scopes @($script:Cfg.dhcpScopeIds) `
            -OutPath ([string]$script:RunReport.Outputs.BaselineJsonPath)

        Write-Log "Baseline backup saved: $($script:Resolved.BaselinePath)" OK
    } -ContinueOnError:$false

    Invoke-Phase -Name 'Build Plan' -Block {
        $script:Resolved.Plan = Get-ActionPlan `
            -Resolver ([string]$script:Cfg.resolverServer) `
            -Domain $script:Resolved.DomainFqdn `
            -DcIPs $script:Resolved.DomainControllerIPs `
            -Upstream @($script:Cfg.upstreamResolvers) `
            -IncludeDhcp ([bool]$script:Cfg.configureDhcp) `
            -DhcpSrv ([string]$script:Cfg.dhcpServer) `
            -Scopes @($script:Cfg.dhcpScopeIds) `
            -ResolverIP $script:Resolved.ResolverIp `
            -AllowAuthoritativeReplace ([bool]$script:Cfg.forceConvertAuthoritativeZone)

        $script:Resolved.Plan | Set-Content -Path ([string]$script:RunReport.Outputs.ChangePlanPath) -Encoding UTF8
        Write-Log "Change plan saved: $($script:RunReport.Outputs.ChangePlanPath)" OK
    } -ContinueOnError:$false

    if ($WhatIfPreference) {
        Invoke-Phase -Name 'WhatIf Preview' -Block {
            Write-Log 'WhatIf mode enabled. Planned changes:' WARN
            foreach ($line in $script:Resolved.Plan) {
                Write-Log $line INFO
            }
        } -ContinueOnError:$false

        Export-RunArtifacts -RunReportJsonPath ([string]$script:RunReport.Outputs.RunReportJsonPath) -RunReportPhaseCsvPath ([string]$script:RunReport.Outputs.RunReportPhaseCsvPath) -Status 'WhatIf'
        return
    }

    Invoke-Phase -Name 'Approval Gate' -Block {
        $approved = $true
        if (-not [bool]$script:Cfg.autoApprove) {
            $approved = Confirm-Execution -ActionPlan $script:Resolved.Plan
        }

        if (-not $approved) {
            throw 'Execution cancelled by user.'
        }
    } -ContinueOnError:$false

    Invoke-Phase -Name 'Apply DNS Separation' -Block {
        Set-DnsRoleInstalled -ComputerName ([string]$script:Cfg.resolverServer)
        Set-ResolverForwarders -DnsServer ([string]$script:Cfg.resolverServer) -Forwarders @($script:Cfg.upstreamResolvers)

        Set-ConditionalForwarder -DnsServer ([string]$script:Cfg.resolverServer) -ZoneName $script:Resolved.DomainFqdn -MasterServers $script:Resolved.DomainControllerIPs -AllowAuthoritativeReplace ([bool]$script:Cfg.forceConvertAuthoritativeZone)
        Set-ConditionalForwarder -DnsServer ([string]$script:Cfg.resolverServer) -ZoneName "_msdcs.$($script:Resolved.DomainFqdn)" -MasterServers $script:Resolved.DomainControllerIPs -AllowAuthoritativeReplace ([bool]$script:Cfg.forceConvertAuthoritativeZone)

        if ([bool]$script:Cfg.configureDhcp) {
            Set-DhcpScopesDnsOption -Server ([string]$script:Cfg.dhcpServer) -ScopeIds @($script:Cfg.dhcpScopeIds) -DnsIPs @($script:Resolved.ResolverIp)
        }
    } -ContinueOnError:$false

    Invoke-Phase -Name 'Validation Summary' -Block {
        $zoneDomain = Get-DnsServerConditionalForwarderZone -ComputerName ([string]$script:Cfg.resolverServer) -Name $script:Resolved.DomainFqdn -ErrorAction SilentlyContinue
        $zoneMsdcs = Get-DnsServerConditionalForwarderZone -ComputerName ([string]$script:Cfg.resolverServer) -Name "_msdcs.$($script:Resolved.DomainFqdn)" -ErrorAction SilentlyContinue
        $forwarders = (Get-DnsServerForwarder -ComputerName ([string]$script:Cfg.resolverServer) -ErrorAction SilentlyContinue).IPAddress.IPAddressToString

        $summary = [pscustomobject]@{
            ResolverServer = [string]$script:Cfg.resolverServer
            ResolverIp = $script:Resolved.ResolverIp
            Domain = $script:Resolved.DomainFqdn
            UpstreamForwarders = ($forwarders -join ', ')
            DomainForwarderPresent = [bool]$zoneDomain
            MsdcsForwarderPresent = [bool]$zoneMsdcs
            DhcpUpdated = [bool]$script:Cfg.configureDhcp
            BaselinePath = $script:Resolved.BaselinePath
            PlanPath = [string]$script:RunReport.Outputs.ChangePlanPath
        }

        $summary | Format-List | Out-String | Write-Host
    } -ContinueOnError

    Export-RunArtifacts -RunReportJsonPath ([string]$script:RunReport.Outputs.RunReportJsonPath) -RunReportPhaseCsvPath ([string]$script:RunReport.Outputs.RunReportPhaseCsvPath) -Status 'Completed'

    Write-Host ''
    Write-Host 'Run Artifacts' -ForegroundColor Cyan
    Write-Host "  Baseline JSON : $($script:RunReport.Outputs.BaselineJsonPath)"
    Write-Host "  Plan TXT      : $($script:RunReport.Outputs.ChangePlanPath)"
    Write-Host "  Run JSON      : $($script:RunReport.Outputs.RunReportJsonPath)"
    Write-Host "  Phases CSV    : $($script:RunReport.Outputs.RunReportPhaseCsvPath)"

    Write-Log 'DNS separation run complete.' OK
}
catch {
    Add-RunError $_.Exception.Message

    if ($script:RunReport.Outputs.RunReportJsonPath -and $script:RunReport.Outputs.RunReportPhaseCsvPath) {
        Export-RunArtifacts -RunReportJsonPath ([string]$script:RunReport.Outputs.RunReportJsonPath) -RunReportPhaseCsvPath ([string]$script:RunReport.Outputs.RunReportPhaseCsvPath) -Status 'Failed'
    }

    throw
}
