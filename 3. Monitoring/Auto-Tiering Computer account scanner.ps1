# MEAM Auto-Tiering Scanner v3.1
# Requires: ActiveDirectory module
# Notes:
# - All environment and scoring configuration is loaded from JSON.
# - No deployment-specific values are hardcoded in this script.

[CmdletBinding()]
param(
    [Parameter(Mandatory, ParameterSetName = 'ConfigFile')]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigPath,

    [Parameter(Mandatory, ParameterSetName = 'ConfigInline')]
    [ValidateNotNullOrEmpty()]
    [string]$ConfigJson,

    [switch]$FailOnPhaseError,
    [switch]$LintConfigOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:RunReport = [ordered]@{
    StartTime = (Get-Date).ToString('o')
    EndTime = $null
    DurationSeconds = 0
    ConfigSource = $null
    DomainDN = $null
    Totals = [ordered]@{
        ComputersScanned = 0
        Misplacements = 0
        Unclassified = 0
        HighRiskMoves = 0
        AssessmentErrors = 0
    }
    Phases = @()
    Warnings = @()
    Errors = @()
    Outputs = [ordered]@{
        ReportPath = $null
        RunReportPath = $null
        PhaseCsvPath = $null
    }
}

$script:TelemetryCache = @{}
$script:MoveIndex = @{}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )

    $colors = @{ INFO = 'Cyan'; WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green' }
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')][$Level] $Message" -ForegroundColor $colors[$Level]
}

function Add-RunWarning {
    param([string]$Message)
    $script:RunReport.Warnings += $Message
    Write-Log $Message WARN
}

function Add-RunError {
    param([string]$Message)
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

    $phaseRecord = [ordered]@{
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
        $phaseRecord.Status = 'Failed'
        $phaseRecord.Error = $_.Exception.Message

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
        $phaseRecord.EndTime = $finish.ToString('o')
        $phaseRecord.DurationSeconds = [math]::Round(($finish - $start).TotalSeconds, 2)
        $script:RunReport.Phases += [pscustomobject]$phaseRecord
    }
}

function Resolve-ConfigObject {
    if ($PSCmdlet.ParameterSetName -eq 'ConfigFile') {
        if (-not (Test-Path $ConfigPath)) {
            throw "Config file not found: $ConfigPath"
        }
        $raw = Get-Content -Path $ConfigPath -Raw -Encoding UTF8
        $script:RunReport.ConfigSource = "file:$ConfigPath"
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

function Assert-Config {
    param([Parameter(Mandatory)]$Cfg)

    $requiredTop = @(
        'corpOU',
        'reportPath',
        'runReportPath',
        'zoneOUs',
        'tierSignals',
        'targetOUByTier',
        'weights',
        'signals',
        'alert'
    )

    foreach ($name in $requiredTop) {
        if (-not $Cfg.PSObject.Properties.Name.Contains($name)) {
            throw "Config missing required property '$name'."
        }
    }

    if ($Cfg.PSObject.Properties.Name.Contains('runReportPhaseCsvPath')) {
        if ([string]::IsNullOrWhiteSpace([string]$Cfg.runReportPhaseCsvPath)) {
            throw "Config.runReportPhaseCsvPath is present but empty."
        }
    }

    foreach ($tier in @('Tier 0', 'Tier 1', 'Tier 2')) {
        if (-not $Cfg.zoneOUs.PSObject.Properties.Name.Contains($tier)) {
            throw "Config.zoneOUs missing '$tier'."
        }
        if (-not $Cfg.tierSignals.PSObject.Properties.Name.Contains($tier)) {
            throw "Config.tierSignals missing '$tier'."
        }
        if (-not $Cfg.targetOUByTier.PSObject.Properties.Name.Contains($tier)) {
            throw "Config.targetOUByTier missing '$tier'."
        }
    }

    $requiredWeights = @(
        'OU', 'Name', 'Group', 'Description', 'SPN', 'DomainController', 'DomainControllersOU',
        'ServerOS', 'WorkstationOS', 'ServiceStrong', 'ServiceMedium', 'EventStrong', 'EventMedium'
    )
    foreach ($w in $requiredWeights) {
        if (-not $Cfg.weights.PSObject.Properties.Name.Contains($w)) {
            throw "Config.weights missing '$w'."
        }
    }

    $requiredSignals = @('useRoleSignals', 'useEventSignals', 'eventLookbackHours', 'eventMaxPerCheck', 'useMoveSignals', 'moveLookbackDays', 'moveEventMax')
    foreach ($s in $requiredSignals) {
        if (-not $Cfg.signals.PSObject.Properties.Name.Contains($s)) {
            throw "Config.signals missing '$s'."
        }
    }

    $requiredAlert = @('enabled', 'to', 'from', 'smtpServer')
    foreach ($a in $requiredAlert) {
        if (-not $Cfg.alert.PSObject.Properties.Name.Contains($a)) {
            throw "Config.alert missing '$a'."
        }
    }
}

function Ensure-DirectoryForFile {
    param([Parameter(Mandatory)][string]$FilePath)

    $dir = Split-Path -Parent $FilePath
    if ($dir -and -not (Test-Path $dir)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
}

function Get-CurrentTierFromDN {
    param([string]$DistinguishedName, [hashtable]$ZoneOUs)

    if ($DistinguishedName -like '*OU=Domain Controllers,*') { return 'Tier 0' }
    foreach ($tier in $ZoneOUs.Keys) {
        if ($DistinguishedName -like $ZoneOUs[$tier]) { return $tier }
    }
    return 'Unknown'
}

function Add-Score {
    param(
        [hashtable]$Scores,
        [hashtable]$Reasons,
        [string]$Tier,
        [int]$Value,
        [string]$Reason
    )

    $Scores[$Tier] = [int]$Scores[$Tier] + $Value
    $Reasons[$Tier].Add("+$Value $Reason")
}

function Get-EventDataMap {
    param([System.Diagnostics.Eventing.Reader.EventRecord]$Event)

    $map = @{}
    try {
        $xml = [xml]$Event.ToXml()
        foreach ($d in $xml.Event.EventData.Data) {
            $name = [string]$d.Name
            if ([string]::IsNullOrWhiteSpace($name)) { continue }
            $map[$name] = [string]$d.'#text'
        }
    }
    catch {
        # keep map empty
    }
    return $map
}

function Test-RecentEvent {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$LogName,
        [Parameter(Mandatory)][datetime]$StartTime,
        [int]$MaxEvents = 1
    )

    try {
        $evt = Get-WinEvent -ComputerName $ComputerName -FilterHashtable @{
            LogName = $LogName
            StartTime = $StartTime
        } -MaxEvents $MaxEvents -ErrorAction Stop
        return [bool]$evt
    }
    catch {
        return $false
    }
}

function Get-ComputerTelemetry {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)]$Signals
    )

    if ($script:TelemetryCache.ContainsKey($ComputerName)) {
        return $script:TelemetryCache[$ComputerName]
    }

    $telemetry = [pscustomobject]@{
        Reachable = $false
        IsServerOS = $null
        ServiceNames = @()
        HasDirectoryServiceEvents = $false
        HasDnsServerEvents = $false
        HasAdfsEvents = $false
        Error = $null
    }

    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ComputerName $ComputerName -ErrorAction Stop
        $telemetry.IsServerOS = ($os.ProductType -ne 1)

        if ([bool]$Signals.useRoleSignals) {
            $svc = Get-CimInstance -ClassName Win32_Service -ComputerName $ComputerName -ErrorAction Stop |
                Select-Object -ExpandProperty Name
            $telemetry.ServiceNames = @($svc)
        }

        if ([bool]$Signals.useEventSignals) {
            $start = (Get-Date).AddHours(-1 * [math]::Abs([int]$Signals.eventLookbackHours))
            $telemetry.HasDirectoryServiceEvents = Test-RecentEvent -ComputerName $ComputerName -LogName 'Directory Service' -StartTime $start -MaxEvents ([int]$Signals.eventMaxPerCheck)
            $telemetry.HasDnsServerEvents = Test-RecentEvent -ComputerName $ComputerName -LogName 'DNS Server' -StartTime $start -MaxEvents ([int]$Signals.eventMaxPerCheck)
            $telemetry.HasAdfsEvents = Test-RecentEvent -ComputerName $ComputerName -LogName 'AD FS/Admin' -StartTime $start -MaxEvents ([int]$Signals.eventMaxPerCheck)
        }

        $telemetry.Reachable = $true
    }
    catch {
        $telemetry.Error = $_.Exception.Message
    }

    $script:TelemetryCache[$ComputerName] = $telemetry
    return $telemetry
}

function Add-MoveIndexEntry {
    param(
        [hashtable]$Index,
        [string]$KeyDn,
        [datetime]$When,
        [string]$OldDn,
        [string]$NewDn,
        [string]$FromTier,
        [string]$ToTier
    )

    if ([string]::IsNullOrWhiteSpace($KeyDn)) { return }

    $key = $KeyDn.ToLowerInvariant()
    $entry = [pscustomobject]@{
        MoveTime = $When
        OldDN = $OldDn
        NewDN = $NewDn
        MoveFromTier = $FromTier
        MoveToTier = $ToTier
        MoveRisk = if ($FromTier -eq 'Tier 0' -and $ToTier -eq 'Tier 1') { 'HIGH:Tier0ToTier1' } else { 'Info' }
    }

    if (-not $Index.ContainsKey($key) -or $Index[$key].MoveTime -lt $When) {
        $Index[$key] = $entry
    }
}

function Build-MoveEventIndex {
    param(
        [Parameter(Mandatory)][string]$Server,
        [Parameter(Mandatory)][datetime]$StartTime,
        [Parameter(Mandatory)][int]$MaxEvents,
        [Parameter(Mandatory)][hashtable]$ZoneOUs
    )

    $index = @{}
    $events = Get-WinEvent -ComputerName $Server -FilterHashtable @{
        LogName = 'Security'
        Id = 5139
        StartTime = $StartTime
    } -MaxEvents $MaxEvents -ErrorAction Stop

    foreach ($evt in $events) {
        $data = Get-EventDataMap -Event $evt
        $objectClass = [string]$data['ObjectClass']
        if ($objectClass -and ($objectClass -notmatch 'computer')) {
            continue
        }

        $newDn = [string]$data['NewObjectDN']
        if (-not $newDn) { $newDn = [string]$data['ObjectDN'] }
        $oldDn = [string]$data['OldObjectDN']

        if ((-not $newDn) -and (-not $oldDn)) { continue }

        $fromTier = if ($oldDn) { Get-CurrentTierFromDN -DistinguishedName $oldDn -ZoneOUs $ZoneOUs } else { 'Unknown' }
        $toTier = if ($newDn) { Get-CurrentTierFromDN -DistinguishedName $newDn -ZoneOUs $ZoneOUs } else { 'Unknown' }

        if ($newDn) {
            Add-MoveIndexEntry -Index $index -KeyDn $newDn -When $evt.TimeCreated -OldDn $oldDn -NewDn $newDn -FromTier $fromTier -ToTier $toTier
        }
        if ($oldDn) {
            Add-MoveIndexEntry -Index $index -KeyDn $oldDn -When $evt.TimeCreated -OldDn $oldDn -NewDn $newDn -FromTier $fromTier -ToTier $toTier
        }
    }

    return $index
}

function To-StringArray {
    param($Value)

    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Array]) { return @($Value) }
    return @([string]$Value)
}

function Convert-TierSignals {
    param([Parameter(Mandatory)]$TierSignalsObject)

    $result = @{}
    foreach ($tier in @('Tier 0', 'Tier 1', 'Tier 2')) {
        $item = $TierSignalsObject.$tier
        $result[$tier] = @{
            NamePatterns = To-StringArray $item.NamePatterns
            GroupPatterns = To-StringArray $item.GroupPatterns
            DescriptionPatterns = To-StringArray $item.DescriptionPatterns
            SpnPatterns = To-StringArray $item.SpnPatterns
        }
    }
    return $result
}

function Convert-ZoneOUs {
    param([Parameter(Mandatory)]$ZoneOUsObject)

    $result = @{}
    foreach ($tier in @('Tier 0', 'Tier 1', 'Tier 2')) {
        $result[$tier] = [string]$ZoneOUsObject.$tier
    }
    return $result
}

function Convert-TargetOUs {
    param([Parameter(Mandatory)]$TargetObject)

    $result = @{}
    foreach ($tier in @('Tier 0', 'Tier 1', 'Tier 2')) {
        $result[$tier] = [string]$TargetObject.$tier
    }
    return $result
}

function Convert-Weights {
    param([Parameter(Mandatory)]$WeightsObject)

    $result = @{}
    foreach ($p in $WeightsObject.PSObject.Properties) {
        $result[$p.Name] = [int]$p.Value
    }
    return $result
}

function Get-TierAssessment {
    param(
        [Parameter(Mandatory)][Microsoft.ActiveDirectory.Management.ADComputer]$Computer,
        [Parameter(Mandatory)][hashtable]$ZoneOUs,
        [Parameter(Mandatory)][hashtable]$TierSignals,
        [Parameter(Mandatory)][hashtable]$TargetOUByTier,
        [Parameter(Mandatory)][hashtable]$Weights,
        [Parameter(Mandatory)]$Signals
    )

    $scores = @{
        'Tier 0' = 0
        'Tier 1' = 0
        'Tier 2' = 0
    }
    $reasons = @{
        'Tier 0' = [System.Collections.Generic.List[string]]::new()
        'Tier 1' = [System.Collections.Generic.List[string]]::new()
        'Tier 2' = [System.Collections.Generic.List[string]]::new()
    }

    $dn = [string]$Computer.DistinguishedName
    $name = [string]$Computer.Name
    $desc = [string]$Computer.Description
    $memberOf = @($Computer.MemberOf)
    $spns = @($Computer.ServicePrincipalName)
    $telemetry = Get-ComputerTelemetry -ComputerName $name -Signals $Signals

    $currentTier = Get-CurrentTierFromDN -DistinguishedName $dn -ZoneOUs $ZoneOUs
    $moveInfo = $null
    $moveKey = $dn.ToLowerInvariant()
    if ([bool]$Signals.useMoveSignals -and $script:MoveIndex.ContainsKey($moveKey)) {
        $moveInfo = $script:MoveIndex[$moveKey]
    }

    if ($Computer.PrimaryGroupID -eq 516) {
        Add-Score -Scores $scores -Reasons $reasons -Tier 'Tier 0' -Value $Weights.DomainController -Reason 'PrimaryGroupID=516 (Domain Controller)'
    }
    if ($dn -like '*OU=Domain Controllers,*') {
        Add-Score -Scores $scores -Reasons $reasons -Tier 'Tier 0' -Value $Weights.DomainControllersOU -Reason 'Located in Domain Controllers OU'
    }

    foreach ($tier in @('Tier 0', 'Tier 1', 'Tier 2')) {
        if ($dn -like $ZoneOUs[$tier]) {
            Add-Score -Scores $scores -Reasons $reasons -Tier $tier -Value $Weights.OU -Reason 'Current OU matches tier pattern'
        }

        foreach ($pattern in $TierSignals[$tier].NamePatterns) {
            if ($name -match $pattern) {
                Add-Score -Scores $scores -Reasons $reasons -Tier $tier -Value $Weights.Name -Reason "Name matches '$pattern'"
                break
            }
        }

        foreach ($pattern in $TierSignals[$tier].DescriptionPatterns) {
            if ($desc -and ($desc -match $pattern)) {
                Add-Score -Scores $scores -Reasons $reasons -Tier $tier -Value $Weights.Description -Reason "Description matches '$pattern'"
                break
            }
        }

        foreach ($pattern in $TierSignals[$tier].GroupPatterns) {
            if ($memberOf -match $pattern) {
                Add-Score -Scores $scores -Reasons $reasons -Tier $tier -Value $Weights.Group -Reason "Group membership matches '$pattern'"
                break
            }
        }

        foreach ($pattern in $TierSignals[$tier].SpnPatterns) {
            if ($spns -match $pattern) {
                Add-Score -Scores $scores -Reasons $reasons -Tier $tier -Value $Weights.SPN -Reason "SPN matches '$pattern'"
                break
            }
        }
    }

    if ($telemetry.Reachable -and $null -ne $telemetry.IsServerOS) {
        if ($telemetry.IsServerOS) {
            Add-Score -Scores $scores -Reasons $reasons -Tier 'Tier 1' -Value $Weights.ServerOS -Reason 'Server OS detected'
        }
        else {
            Add-Score -Scores $scores -Reasons $reasons -Tier 'Tier 2' -Value $Weights.WorkstationOS -Reason 'Workstation OS detected'
        }
    }

    if ([bool]$Signals.useRoleSignals -and $telemetry.Reachable) {
        $svcs = @($telemetry.ServiceNames)

        if ($svcs -contains 'NTDS') {
            Add-Score -Scores $scores -Reasons $reasons -Tier 'Tier 0' -Value $Weights.ServiceStrong -Reason 'NTDS service present'
        }
        if (($svcs -contains 'Kdc') -or ($svcs -contains 'ADWS')) {
            Add-Score -Scores $scores -Reasons $reasons -Tier 'Tier 0' -Value $Weights.ServiceMedium -Reason 'KDC/ADWS service present'
        }
        if ($svcs -contains 'DNS') {
            Add-Score -Scores $scores -Reasons $reasons -Tier 'Tier 1' -Value $Weights.ServiceMedium -Reason 'DNS service present'
        }
        if (($svcs -contains 'CcmExec') -or ($svcs -contains 'SMS_EXECUTIVE')) {
            Add-Score -Scores $scores -Reasons $reasons -Tier 'Tier 1' -Value $Weights.ServiceStrong -Reason 'SCCM services present'
        }
        if (($svcs -contains 'MSSQLSERVER') -or ($svcs -contains 'W3SVC') -or ($svcs -contains 'LanmanServer')) {
            Add-Score -Scores $scores -Reasons $reasons -Tier 'Tier 1' -Value $Weights.ServiceMedium -Reason 'Server workload services present'
        }
    }

    if ([bool]$Signals.useEventSignals -and $telemetry.Reachable) {
        if ($telemetry.HasDirectoryServiceEvents) {
            Add-Score -Scores $scores -Reasons $reasons -Tier 'Tier 0' -Value $Weights.EventStrong -Reason "Recent 'Directory Service' events"
        }
        if ($telemetry.HasAdfsEvents) {
            Add-Score -Scores $scores -Reasons $reasons -Tier 'Tier 0' -Value $Weights.EventMedium -Reason "Recent 'AD FS/Admin' events"
        }
        if ($telemetry.HasDnsServerEvents) {
            Add-Score -Scores $scores -Reasons $reasons -Tier 'Tier 1' -Value $Weights.EventMedium -Reason "Recent 'DNS Server' events"
        }
    }

    $sorted = $scores.GetEnumerator() | Sort-Object Value -Descending
    $top = $sorted[0]
    $second = $sorted[1]

    $expectedTier = if ($top.Value -ge 20) { [string]$top.Key } else { 'Unknown' }
    $confidence = [int]$top.Value - [int]$second.Value
    $compliant = ($expectedTier -eq 'Unknown') -or ($currentTier -eq $expectedTier)

    $issue = $null
    $fix = $null
    if (-not $compliant) {
        $issue = "Misplaced: expected $expectedTier, currently in $currentTier"
        $fix = "Move-ADObject '$($Computer.DistinguishedName)' -TargetPath '$($TargetOUByTier[$expectedTier])'"
    }

    if ($moveInfo -and $moveInfo.MoveRisk -eq 'HIGH:Tier0ToTier1') {
        $suffix = "Recent high-risk move detected: $($moveInfo.MoveFromTier) -> $($moveInfo.MoveToTier) at $($moveInfo.MoveTime)."
        if ($issue) {
            $issue = "$issue | $suffix"
        }
        else {
            $issue = $suffix
        }
    }

    return [pscustomobject]@{
        ObjectName = $name
        DistinguishedName = $dn
        CurrentTier = $currentTier
        ExpectedTier = $expectedTier
        ScoreTier0 = $scores['Tier 0']
        ScoreTier1 = $scores['Tier 1']
        ScoreTier2 = $scores['Tier 2']
        ConfidenceDelta = $confidence
        TopReason = if ($reasons[$top.Key].Count -gt 0) { $reasons[$top.Key][0] } else { 'No strong signal' }
        RecentlyMoved = [bool]$moveInfo
        MoveTime = if ($moveInfo) { $moveInfo.MoveTime } else { $null }
        MoveFromTier = if ($moveInfo) { $moveInfo.MoveFromTier } else { $null }
        MoveToTier = if ($moveInfo) { $moveInfo.MoveToTier } else { $null }
        MoveRisk = if ($moveInfo) { $moveInfo.MoveRisk } else { $null }
        TelemetryReachable = [bool]$telemetry.Reachable
        TelemetryError = $telemetry.Error
        Compliant = $compliant
        Issue = $issue
        Fix = $fix
    }
}

$cfg = $null
$domainDN = $null
$zoneOUs = $null
$tierSignals = $null
$targetOUByTier = $null
$weights = $null
$signals = $null
$alertCfg = $null

$computers = @()
$results = @()
$misplacements = @()
$unclassified = @()
$highRiskMoves = @()

Invoke-Phase -Name 'Load Configuration' -Block {
    $cfg = Resolve-ConfigObject
    Assert-Config -Cfg $cfg

    $zoneOUs = Convert-ZoneOUs -ZoneOUsObject $cfg.zoneOUs
    $tierSignals = Convert-TierSignals -TierSignalsObject $cfg.tierSignals
    $targetOUByTier = Convert-TargetOUs -TargetObject $cfg.targetOUByTier
    $weights = Convert-Weights -WeightsObject $cfg.weights
    $signals = $cfg.signals
    $alertCfg = $cfg.alert

    $domainDN = if ($cfg.PSObject.Properties.Name.Contains('domainDN') -and -not [string]::IsNullOrWhiteSpace([string]$cfg.domainDN)) {
        [string]$cfg.domainDN
    }
    else {
        (Get-ADDomain).DistinguishedName
    }

    $script:RunReport.DomainDN = $domainDN
    $script:RunReport.Outputs.ReportPath = [string]$cfg.reportPath
    $script:RunReport.Outputs.RunReportPath = [string]$cfg.runReportPath
    $phaseCsvPath = if ($cfg.PSObject.Properties.Name.Contains('runReportPhaseCsvPath') -and -not [string]::IsNullOrWhiteSpace([string]$cfg.runReportPhaseCsvPath)) {
        [string]$cfg.runReportPhaseCsvPath
    }
    else {
        $base = [System.IO.Path]::GetFileNameWithoutExtension([string]$cfg.runReportPath)
        $dir = Split-Path -Parent ([string]$cfg.runReportPath)
        Join-Path $dir "$base-phases.csv"
    }
    $script:RunReport.Outputs.PhaseCsvPath = $phaseCsvPath

    Ensure-DirectoryForFile -FilePath ([string]$cfg.reportPath)
    Ensure-DirectoryForFile -FilePath ([string]$cfg.runReportPath)
    Ensure-DirectoryForFile -FilePath $phaseCsvPath
} -ContinueOnError:$false

if ($LintConfigOnly) {
    Invoke-Phase -Name 'Lint Config' -Block {
        Write-Log 'Configuration schema validation passed.' OK
        Write-Host "Config source: $($script:RunReport.ConfigSource)"
        Write-Host "Run report path: $($script:RunReport.Outputs.RunReportPath)"
        Write-Host "Phase CSV path: $($script:RunReport.Outputs.PhaseCsvPath)"
    } -ContinueOnError:$false

    Invoke-Phase -Name 'Export Lint Report' -Block {
        $script:RunReport.EndTime = (Get-Date).ToString('o')
        $script:RunReport.DurationSeconds = [math]::Round(((Get-Date) - [datetime]$script:RunReport.StartTime).TotalSeconds, 2)

        $script:RunReport | ConvertTo-Json -Depth 20 | Set-Content -Path ([string]$script:RunReport.Outputs.RunReportPath) -Encoding UTF8
        $script:RunReport.Phases |
            Select-Object Name, Status, DurationSeconds, StartTime, EndTime, Error |
            Export-Csv -Path ([string]$script:RunReport.Outputs.PhaseCsvPath) -NoTypeInformation -Encoding UTF8

        Write-Log 'Lint mode complete. No AD queries or scan actions executed.' OK
    } -ContinueOnError:$false

    return
}

Invoke-Phase -Name 'Pre-Flight Checks' -Block {
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        throw 'ActiveDirectory module is required.'
    }

    if ([bool]$signals.useMoveSignals) {
        $moveEventServer = if ($signals.PSObject.Properties.Name.Contains('moveEventServer') -and -not [string]::IsNullOrWhiteSpace([string]$signals.moveEventServer)) {
            [string]$signals.moveEventServer
        }
        else {
            (Get-ADDomain).PDCEmulator
        }

        $moveStart = (Get-Date).AddDays(-1 * [math]::Abs([int]$signals.moveLookbackDays))
        $script:MoveIndex = Build-MoveEventIndex -Server $moveEventServer -StartTime $moveStart -MaxEvents ([int]$signals.moveEventMax) -ZoneOUs $zoneOUs
        Write-Log "Move signal index loaded from $moveEventServer: $($script:MoveIndex.Count) entries" INFO
    }
} -ContinueOnError

Invoke-Phase -Name 'Collect AD Computers' -Block {
    $computers = Get-ADComputer -Filter * -Properties DistinguishedName, Description, MemberOf, ServicePrincipalName, PrimaryGroupID |
        Select-Object Name, DistinguishedName, Description, MemberOf, ServicePrincipalName, PrimaryGroupID

    $script:RunReport.Totals.ComputersScanned = $computers.Count
    Write-Log "Collected $($computers.Count) computer objects" INFO
} -ContinueOnError:$false

Invoke-Phase -Name 'Assess Tier Placement' -Block {
    $total = $computers.Count
    $progress = 0

    foreach ($comp in $computers) {
        $progress++
        Write-Progress -Activity "Scanning $total computers" -PercentComplete (($progress / [math]::Max($total, 1)) * 100)

        try {
            $results += Get-TierAssessment -Computer $comp -ZoneOUs $zoneOUs -TierSignals $tierSignals -TargetOUByTier $targetOUByTier -Weights $weights -Signals $signals
        }
        catch {
            $script:RunReport.Totals.AssessmentErrors++
            Add-RunWarning "Assessment failed for '$($comp.Name)': $($_.Exception.Message)"
        }
    }

    $misplacements = $results | Where-Object { -not $_.Compliant }
    $unclassified = $results | Where-Object { $_.ExpectedTier -eq 'Unknown' }
    $highRiskMoves = $results | Where-Object { $_.MoveRisk -eq 'HIGH:Tier0ToTier1' }

    $script:RunReport.Totals.Misplacements = $misplacements.Count
    $script:RunReport.Totals.Unclassified = $unclassified.Count
    $script:RunReport.Totals.HighRiskMoves = $highRiskMoves.Count
} -ContinueOnError:$false

Invoke-Phase -Name 'Export Findings Report' -Block {
    $reportRows = $misplacements
    if ([bool]$cfg.includeUnclassified) {
        $reportRows = $results | Where-Object { (-not $_.Compliant) -or ($_.ExpectedTier -eq 'Unknown') }
    }

    if ($highRiskMoves.Count -gt 0) {
        $existingDns = @($reportRows | Select-Object -ExpandProperty DistinguishedName)
        $reportRows = @($reportRows + ($highRiskMoves | Where-Object { $_.DistinguishedName -notin $existingDns }))
    }

    $reportRows |
        Select-Object ObjectName, DistinguishedName, CurrentTier, ExpectedTier, ScoreTier0, ScoreTier1, ScoreTier2, ConfidenceDelta, TopReason, RecentlyMoved, MoveTime, MoveFromTier, MoveToTier, MoveRisk, TelemetryReachable, TelemetryError, Issue, Fix |
        Export-Csv -Path ([string]$cfg.reportPath) -NoTypeInformation -Encoding UTF8

    $color = if ($misplacements.Count -eq 0) { 'Green' } else { 'Red' }
    Write-Host "Report: $($cfg.reportPath) ($($misplacements.Count) misplacements, $($unclassified.Count) unclassified, $($highRiskMoves.Count) high-risk moves)" -ForegroundColor $color
} -ContinueOnError

Invoke-Phase -Name 'Send Alert Email' -Block {
    if (-not [bool]$alertCfg.enabled) {
        Write-Log 'Alerting disabled in config.alert.enabled' INFO
        return
    }

    if ($misplacements.Count -gt 0 -or $highRiskMoves.Count -gt 0) {
        $body = "Found $($misplacements.Count) tier misplacements and $($highRiskMoves.Count) high-risk moves. See $($cfg.reportPath)`n`n" +
            (($results |
                Where-Object { (-not $_.Compliant) -or ($_.MoveRisk -eq 'HIGH:Tier0ToTier1') } |
                Select-Object ObjectName, CurrentTier, ExpectedTier, MoveFromTier, MoveToTier, MoveRisk, ConfidenceDelta, Issue |
                Format-Table -AutoSize |
                Out-String))

        $attachments = @()
        if (Test-Path ([string]$cfg.reportPath)) { $attachments += [string]$cfg.reportPath }
        if (Test-Path ([string]$script:RunReport.Outputs.PhaseCsvPath)) { $attachments += [string]$script:RunReport.Outputs.PhaseCsvPath }

        $mailParams = @{
            To = [string]$alertCfg.to
            From = [string]$alertCfg.from
            Subject = 'MEAM Tier Violation Alert'
            Body = $body
            SmtpServer = [string]$alertCfg.smtpServer
            Priority = 'High'
        }
        if ($attachments.Count -gt 0) {
            $mailParams.Attachments = $attachments
        }

        Send-MailMessage @mailParams
        Write-Log 'Alert email sent.' OK
    }
    else {
        Write-Log 'No actionable findings. Alert not sent.' INFO
    }
} -ContinueOnError

Invoke-Phase -Name 'Export Run Report' -Block {
    $script:RunReport.EndTime = (Get-Date).ToString('o')
    $script:RunReport.DurationSeconds = [math]::Round(((Get-Date) - [datetime]$script:RunReport.StartTime).TotalSeconds, 2)

    $script:RunReport | ConvertTo-Json -Depth 20 | Set-Content -Path ([string]$cfg.runReportPath) -Encoding UTF8
    $script:RunReport.Phases |
        Select-Object Name, Status, DurationSeconds, StartTime, EndTime, Error |
        Export-Csv -Path ([string]$script:RunReport.Outputs.PhaseCsvPath) -NoTypeInformation -Encoding UTF8

    Write-Host ''
    Write-Host 'Run Summary' -ForegroundColor Cyan
    Write-Host "  ComputersScanned : $($script:RunReport.Totals.ComputersScanned)"
    Write-Host "  Misplacements    : $($script:RunReport.Totals.Misplacements)"
    Write-Host "  Unclassified     : $($script:RunReport.Totals.Unclassified)"
    Write-Host "  HighRiskMoves    : $($script:RunReport.Totals.HighRiskMoves)"
    Write-Host "  AssessmentErrors : $($script:RunReport.Totals.AssessmentErrors)"
    Write-Host "  Findings CSV     : $($cfg.reportPath)"
    Write-Host "  Run Report JSON  : $($cfg.runReportPath)"
    Write-Host "  Phases CSV       : $($script:RunReport.Outputs.PhaseCsvPath)"

    Write-Log 'Run report export complete.' OK
} -ContinueOnError
