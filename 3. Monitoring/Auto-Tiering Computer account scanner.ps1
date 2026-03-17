# MEAM Auto-Tiering Scanner v1.0
# Requires: ActiveDirectory module, SMTP for alerts

param(
    [string]$DomainDN = (Get-ADDomain).DistinguishedName,
    [string]$ReportPath = "C:\MEAM\TierScan-$(Get-Date -f 'yyyyMMdd').csv",
    [string]$AlertTo = "admin@contoso.com"
)

# Tier definitions from your script
$TierPatterns = @{
    'Tier 0' = @('^DC\d+$', 'PKI|ADCS', '^Hypervisor|^VMHost')
    'Tier 1' = @('^SCCM|^Intune', '^Server\d+$', '^DNS\d+$', '^NAS|^SAN|^Storage')
    'Tier 2' = @('^WS\d+$|^Workstation|^Kiosk')
}
$ZoneOUs = @{
    'Tier 0' = "*OU=Zone 0*,OU=Tier 0*"
    'Tier 1' = "*OU=Zone 1*,OU=Tier 1*"
    'Tier 2' = "*OU=Zone 2*,OU=Tier 2*"
}

function Test-TierCompliance {
    param($ObjectName, $CurrentPath, $ObjectType)
    
    $expectedTier = $null
    foreach ($tier in $TierPatterns.Keys) {
        foreach ($pattern in $TierPatterns[$tier]) {
            if ($ObjectName -match $pattern) { $expectedTier = $tier; break }
        }
        if ($expectedTier) { break }
    }
    
    if (-not $expectedTier) { return @{Compliant=$true} }
    
    $expectedOU = $ZoneOUs[$expectedTier]
    $inExpectedOU = $CurrentPath -like $expectedOU
    
    return @{
        Compliant = $inExpectedOU
        ExpectedTier = $expectedTier
        CurrentOU = $CurrentPath
        Issue = if (-not $inExpectedOU) { "Misplaced: $expectedTier asset in non-$expectedTier OU" } else { $null }
        Fix = if (-not $inExpectedOU) { "Move-ADObject '$ObjectName' -TargetPath 'OU=Computers,OU=Zone $($expectedTier -replace 'Tier ','')A,...'" } else { $null }
    }
}

# Scan computers (extend to users/services)
$misplacements = @()
$computers = Get-ADComputer -Filter * -Properties DistinguishedName | Select-Object Name, DistinguishedName
$total = $computers.Count
$progress = 0

foreach ($comp in $computers) {
    $progress++
    Write-Progress -Activity "Scanning $($total) computers" -PercentComplete (($progress / $total) * 100)
    
    $result = Test-TierCompliance $comp.Name $comp.DistinguishedName 'Computer'
    if (-not $result.Compliant) { $misplacements += $result }
}

# Generate Report [code_file:85]
$report = $misplacements | Select-Object ObjectName, CurrentOU, ExpectedTier, Issue, Fix
$report | Export-Csv -Path $ReportPath -NoTypeInformation
Write-Host "Report: $ReportPath ($( $misplacements.Count ) issues)" -ForegroundColor $(if($misplacements.Count -eq 0){'Green'}else{'Red'})

# Alert
if ($misplacements) {
    $body = "Found $($misplacements.Count) tier misplacements. See $ReportPath`n`n" + ($misplacements | Format-Table -AutoSize | Out-String)
    Send-MailMessage -To $AlertTo -From "meam-scanner@contoso.com" -Subject "MEAM Tier Violation Alert" -Body $body -SmtpServer "smtp.contoso.com" -Priority High
}

# Auto-Migrate (opt-in, dangerous!)
# if ($AutoFix) { foreach ($m in $misplacements) { Invoke-Expression $m.Fix } }
