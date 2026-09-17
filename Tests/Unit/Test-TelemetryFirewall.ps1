#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $repoRoot 'Scripts\Features\BlockTelemetryFirewall.ps1')
    $script:domains = @('telemetry.microsoft.com', 'vortex.data.microsoft.com')
    $script:startMarker = '# Winnow-TelemetryBlock-Start'
    $script:endMarker = '# Winnow-TelemetryBlock-End'
}

Describe 'New-WinnowTelemetryHostsContent' {
    It 'sinkholes every domain to 0.0.0.0 between the markers' {
        $result = New-WinnowTelemetryHostsContent -CurrentHosts '' -Domains $script:domains

        $result | Should -Match ([regex]::Escape($script:startMarker))
        $result | Should -Match ([regex]::Escape($script:endMarker))
        foreach ($domain in $script:domains) {
            $result | Should -Match ("(?m)^0\.0\.0\.0 " + [regex]::Escape($domain) + '\s*$')
        }
    }

    It 'preserves existing non-Winnow hosts content' {
        $existing = "127.0.0.1 localhost`r`n10.0.0.5 myserver"
        $result = New-WinnowTelemetryHostsContent -CurrentHosts $existing -Domains $script:domains

        $result | Should -Match '127\.0\.0\.1 localhost'
        $result | Should -Match '10\.0\.0\.5 myserver'
    }

    It 'is idempotent: re-applying does not stack a second block' {
        $once = New-WinnowTelemetryHostsContent -CurrentHosts "127.0.0.1 localhost" -Domains $script:domains
        $twice = New-WinnowTelemetryHostsContent -CurrentHosts $once -Domains $script:domains

        $twice | Should -Be $once
        ([regex]::Matches($twice, [regex]::Escape($script:startMarker))).Count | Should -Be 1
    }

    It 'replaces a stale Winnow block rather than appending a new one' {
        $stale = "127.0.0.1 localhost`r`n`r`n$script:startMarker`r`n0.0.0.0 old.telemetry.example`r`n$script:endMarker`r`n"
        $result = New-WinnowTelemetryHostsContent -CurrentHosts $stale -Domains $script:domains

        $result | Should -Not -Match 'old\.telemetry\.example'
        ([regex]::Matches($result, [regex]::Escape($script:startMarker))).Count | Should -Be 1
        $result | Should -Match '127\.0\.0\.1 localhost'
    }

    It 'handles a null current hosts file' {
        $result = New-WinnowTelemetryHostsContent -CurrentHosts $null -Domains $script:domains
        $result | Should -Match '0\.0\.0\.0 telemetry\.microsoft\.com'
    }

    It 'covers every domain the block feature ships' {
        $all = @(Get-WinnowTelemetryDomains)
        $result = New-WinnowTelemetryHostsContent -CurrentHosts '' -Domains $all
        foreach ($domain in $all) {
            $result | Should -Match ("(?m)^0\.0\.0\.0 " + [regex]::Escape($domain) + '\s*$')
        }
    }
}
