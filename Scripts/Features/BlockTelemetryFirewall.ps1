<#
.SYNOPSIS
    Blocks Microsoft telemetry and AI inference endpoints via Windows Firewall and HOSTS file.
.DESCRIPTION
    Creates outbound Windows Defender Firewall rules for all known telemetry domains.
    When DNS resolution fails (e.g., the domain is already sinkholed), falls back to
    writing a permanent HOSTS file entry as defense-in-depth. Covers original telemetry
    endpoints plus new 24H2/25H2 AI inference and data pipeline routes.
#>
function Get-WinnowTelemetryDomains {
    return @(
        'vortex.data.microsoft.com',
        'settings-win.data.microsoft.com',
        'watson.telemetry.microsoft.com',
        'telemetry.microsoft.com',
        'sqm.microsoft.com',
        'oca.telemetry.microsoft.com.nsatc.net',
        'us.vortex-win.data.microsoft.com',
        'east.pipe.aria.microsoft.com',
        'api.msai.microsoft.com',
        'inference.windows.microsoft.com',
        'copilot.microsoft.com',
        'substrate.office.com',
        'canary.designerapp.office.com',
        'designer.microsoft.com'
    )
}

function New-WinnowTelemetryHostsContent {
    # Compose the hosts file text with a single Winnow block that sinkholes every
    # telemetry domain to 0.0.0.0. Any previous Winnow block is stripped first, so
    # re-applying is idempotent and never stacks duplicate blocks. Pure string work
    # so it can be unit tested without touching the real hosts file.
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$CurrentHosts,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Domains
    )

    $hostsMarkerStart = '# Winnow-TelemetryBlock-Start'
    $hostsMarkerEnd = '# Winnow-TelemetryBlock-End'

    if ($null -eq $CurrentHosts) { $CurrentHosts = '' }

    # Strip any previous Winnow block, then trim trailing blank lines it left behind.
    $stripped = $CurrentHosts -replace "(?s)$hostsMarkerStart.*?$hostsMarkerEnd`r?`n?", ''
    $stripped = $stripped -replace "(\r?\n)+$", ''

    $entries = @($Domains | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { "0.0.0.0 $_" })
    if ($entries.Count -eq 0) {
        return $stripped
    }

    $block = "$hostsMarkerStart`r`n" + ($entries -join "`r`n") + "`r`n$hostsMarkerEnd"
    if ([string]::IsNullOrWhiteSpace($stripped)) {
        return $block + "`r`n"
    }

    return $stripped + "`r`n`r`n" + $block + "`r`n"
}

function Invoke-BlockTelemetryFirewall {
    param (
        [switch]$WhatIf
    )

    $telemetryDomains = @(Get-WinnowTelemetryDomains)

    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"

    Write-Host ""
    Write-Host "[*] Blocking telemetry endpoints via HOSTS sinkhole + Windows Defender Firewall..." -ForegroundColor Cyan

    if ($WhatIf) {
        Write-Host "  [WhatIf] Would sinkhole these domains in HOSTS and add outbound firewall rules where DNS resolves:" -ForegroundColor Yellow
        foreach ($domain in $telemetryDomains) {
            Write-Host "    - $domain" -ForegroundColor DarkGray
        }
        return
    }

    try {
        # HOSTS sinkhole is the durable layer: 0.0.0.0 blocks the name regardless of
        # which CDN IP the endpoint rotates to. The firewall rules are the second
        # layer, catching traffic that reaches a hardcoded IP, but they resolve to
        # specific addresses at apply time and go stale as those addresses change,
        # so they are additive to HOSTS rather than the primary block.
        foreach ($domain in $telemetryDomains) {
            $ruleName = "Winnow_BlockTelemetry_$domain"

            $existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
            if ($existing) {
                Remove-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
            }

            $ips = @()
            try {
                $ips = (Resolve-DnsName -Name $domain -ErrorAction SilentlyContinue |
                    Where-Object { $_.Type -eq 'A' -or $_.Type -eq 'AAAA' }).IPAddress
            } catch {}

            if ($null -ne $ips -and $ips.Count -gt 0) {
                New-NetFirewallRule -DisplayName $ruleName -Direction Outbound -Action Block `
                    -RemoteAddress $ips -ErrorAction Stop | Out-Null
                Write-Host "  [FW] $domain ($($ips -join ', '))" -ForegroundColor Green
            }
            else {
                Write-Host "  [FW] $domain - DNS did not resolve; HOSTS sinkhole still covers it." -ForegroundColor DarkGray
            }
        }

        # Sinkhole every domain in HOSTS, not only the ones whose DNS failed.
        $currentHosts = Get-Content -Path $hostsPath -Raw -ErrorAction SilentlyContinue
        $newHosts = New-WinnowTelemetryHostsContent -CurrentHosts $currentHosts -Domains $telemetryDomains
        Set-Content -Path $hostsPath -Value $newHosts -Encoding ASCII -Force -NoNewline -ErrorAction Stop
        Write-Host "  [HOSTS] Sinkholed $($telemetryDomains.Count) telemetry domains." -ForegroundColor Green

        Write-Host "  [+] Telemetry blocks applied (HOSTS + Firewall)." -ForegroundColor Green
    }
    catch {
        Write-Host "  [ERROR] Failed to apply telemetry blocks: $_" -ForegroundColor Red
    }
}

function Invoke-UnblockTelemetryFirewall {
    param (
        [switch]$WhatIf
    )

    $hostsPath = "$env:SystemRoot\System32\drivers\etc\hosts"
    $hostsMarkerStart = "# Winnow-TelemetryBlock-Start"
    $hostsMarkerEnd   = "# Winnow-TelemetryBlock-End"

    Write-Host ""
    Write-Host "[*] Removing Winnow telemetry blocks..." -ForegroundColor Cyan

    if ($WhatIf) {
        Write-Host "  [WhatIf] Would remove all Winnow_BlockTelemetry_ firewall rules and HOSTS entries" -ForegroundColor Yellow
        return
    }

    # Remove firewall rules
    $rules = Get-NetFirewallRule -DisplayName "Winnow_BlockTelemetry_*" -ErrorAction SilentlyContinue
    foreach ($rule in $rules) {
        Remove-NetFirewallRule -DisplayName $rule.DisplayName -ErrorAction SilentlyContinue
        Write-Host "  [-] Removed firewall rule: $($rule.DisplayName)" -ForegroundColor DarkGray
    }

    # Remove HOSTS block
    if (Test-Path $hostsPath) {
        $currentHosts = Get-Content -Path $hostsPath -Raw -ErrorAction SilentlyContinue
        $cleaned = $currentHosts -replace "(?s)$hostsMarkerStart.*?$hostsMarkerEnd`r?`n?", ""
        $cleaned | Set-Content -Path $hostsPath -Encoding ASCII -Force -ErrorAction SilentlyContinue
        Write-Host "  [-] Removed Winnow HOSTS block" -ForegroundColor DarkGray
    }

    Write-Host "  [+] Telemetry blocks removed." -ForegroundColor Green
}
