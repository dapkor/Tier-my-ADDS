#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 2 (DC01): Post-promotion domain initialization.
    Vagrant provision tag: init-domain  (reboot: true — reboots for GP application)

    Performs:
      - Wait for AD services to be fully ready (post-reboot settle time)
      - Raise DFL + FFL to Windows2016Domain / Windows2016Forest
      - Create KDS Root Key (prerequisite for gMSAs)
      - Enable AD Recycle Bin
      - Add DNS forwarders (8.8.8.8 / 1.1.1.1) for external resolution
      - Configure DC as authoritative NTP source
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
    $line | Add-Content -Path "$LogDir\02-Init-Domain.log" -Encoding UTF8
}

Write-Log '=== Phase 2: Domain initialization ==='

Import-Module ActiveDirectory -Force
Import-Module DnsServer        -Force

# ── Wait for Active Directory to be ready ────────────────────────────────────
Write-Log 'Waiting for Active Directory services to stabilise...'
$maxAttempt = 36      # 6 min ceiling
$attempt    = 0
$domain     = $null
do {
    try {
        $domain = Get-ADDomain -ErrorAction Stop
        Write-Log "AD domain ready: $($domain.DNSRoot)  DN: $($domain.DistinguishedName)" OK
        break
    }
    catch {
        $attempt++
        if ($attempt -ge $maxAttempt) { throw "AD did not become ready within the timeout." }
        Write-Log "AD not ready yet (attempt $attempt / $maxAttempt) — sleeping 10 s..." WARN
        Start-Sleep -Seconds 10
    }
} while ($true)

$forest = Get-ADForest

# ── Raise Domain Functional Level ────────────────────────────────────────────
Write-Log 'Raising Domain Functional Level to Windows2016Domain...'
try {
    Set-ADDomainMode -Identity $domain.DistinguishedName -DomainMode Windows2016Domain -Confirm:$false
    Write-Log 'DFL: Windows2016Domain.' OK
}
catch {
    Write-Log "DFL (already current or error): $($_.Exception.Message)" WARN
}

# ── Raise Forest Functional Level ────────────────────────────────────────────
Write-Log 'Raising Forest Functional Level to Windows2016Forest...'
try {
    Set-ADForestMode -Identity $forest.RootDomain -ForestMode Windows2016Forest -Confirm:$false
    Write-Log 'FFL: Windows2016Forest.' OK
}
catch {
    Write-Log "FFL (already current or error): $($_.Exception.Message)" WARN
}

# ── KDS Root Key (gMSA prerequisite) ─────────────────────────────────────────
Write-Log 'Creating KDS Root Key for gMSA support...'
if (Get-KdsRootKey -ErrorAction SilentlyContinue) {
    Write-Log 'KDS Root Key already exists — skipping.' OK
}
else {
    # EffectiveTime in the past so the key is immediately usable in the lab
    Add-KdsRootKey -EffectiveTime (Get-Date).AddHours(-10) | Out-Null
    Write-Log 'KDS Root Key created (effective immediately for lab use).' OK
}

# ── AD Recycle Bin ────────────────────────────────────────────────────────────
Write-Log 'Enabling AD Recycle Bin...'
try {
    $rb = Get-ADOptionalFeature -Filter "Name -eq 'Recycle Bin Feature'" -ErrorAction SilentlyContinue
    if ($rb -and $rb.EnabledScopes.Count -gt 0) {
        Write-Log 'AD Recycle Bin already enabled.' OK
    }
    else {
        Enable-ADOptionalFeature `
            -Identity 'Recycle Bin Feature' `
            -Scope ForestOrConfigurationSet `
            -Target $forest.Name `
            -Confirm:$false | Out-Null
        Write-Log 'AD Recycle Bin enabled.' OK
    }
}
catch {
    Write-Log "AD Recycle Bin: $($_.Exception.Message)" WARN
}

# ── DNS Forwarders ────────────────────────────────────────────────────────────
Write-Log 'Adding DNS forwarders for external resolution...'
foreach ($ip in @('8.8.8.8', '1.1.1.1')) {
    try {
        Add-DnsServerForwarder -IPAddress $ip -ErrorAction SilentlyContinue | Out-Null
        Write-Log "  Forwarder added: $ip" OK
    }
    catch {
        Write-Log "  Forwarder $ip: $($_.Exception.Message)" WARN
    }
}

# ── NTP — DC is the authoritative time source ─────────────────────────────────
Write-Log 'Configuring DC as authoritative NTP source...'
try {
    & w32tm /config /manualpeerlist:"time.windows.com,0x8" /syncfromflags:manual /reliable:YES /update 2>&1 | Out-Null
    Restart-Service w32tm -Force -ErrorAction SilentlyContinue
    & w32tm /resync /force 2>&1 | Out-Null
    Write-Log 'NTP configured: time.windows.com (reliable).' OK
}
catch {
    Write-Log "NTP: $($_.Exception.Message)" WARN
}

Write-Log '=== Phase 2: Domain initialization complete ===' OK
Write-Log 'Vagrant will reboot for Group Policy refresh.' INFO
