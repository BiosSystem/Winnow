#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for full-module rollback (BackupModuleState): Restore-ModuleState reverts the
    reversible module state and reports what it cannot restore. All destructive cmdlets are mocked,
    so these are safe on any machine.
#>

Describe 'Restore-ModuleState' {

    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
        # BlockTelemetryFirewall defines Invoke-UnblockTelemetryFirewall, which the restore calls
        # and the tests mock; it must exist for Mock to bind.
        . (Join-Path $repoRoot 'Scripts\Features\BlockTelemetryFirewall.ps1')
        . (Join-Path $repoRoot 'Scripts\Features\BackupModuleState.ps1')

        function New-SnapshotFile {
            param([hashtable]$Snapshot)
            $path = Join-Path $TestDrive ('snap-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
            $Snapshot | ConvertTo-Json -Depth 6 | Out-File -FilePath $path -Encoding UTF8 -Force
            return $path
        }
    }

    It 'restores each service to its captured StartType and starts it if it was running' {
        $path = New-SnapshotFile @{ Services = @(@{ Name = 'DiagTrack'; StartType = 'Automatic'; Running = $true }) }
        Mock Set-Service { }
        Mock Start-Service { }

        $r = Restore-ModuleState -SnapshotPath $path -AppliedFeatures @('DisableTelemetryServices')

        Should -Invoke Set-Service -Times 1 -ParameterFilter { $Name -eq 'DiagTrack' -and $StartupType -eq 'Automatic' }
        Should -Invoke Start-Service -Times 1 -ParameterFilter { $Name -eq 'DiagTrack' }
        $r.Reverted | Should -Contain 'services'
    }

    It 're-enables only the scheduled tasks that were enabled before' {
        $path = New-SnapshotFile @{ Tasks = @(
                @{ Path = '\A\'; Name = 'WasReady'; State = 'Ready' },
                @{ Path = '\B\'; Name = 'WasDisabled'; State = 'Disabled' }
            ) }
        Mock Enable-ScheduledTask { }

        $r = Restore-ModuleState -SnapshotPath $path -AppliedFeatures @('DisableTelemetry')

        Should -Invoke Enable-ScheduledTask -Times 1
        Should -Invoke Enable-ScheduledTask -ParameterFilter { $TaskName -eq 'WasReady' }
        $r.Reverted | Should -Contain 'scheduled tasks'
    }

    It 'removes the telemetry firewall rules and HOSTS block' {
        $path = New-SnapshotFile @{ Marker = $true }
        Mock Invoke-UnblockTelemetryFirewall { }

        $r = Restore-ModuleState -SnapshotPath $path -AppliedFeatures @('EnableFirewallTelemetryBlock')

        Should -Invoke Invoke-UnblockTelemetryFirewall -Times 1
        $r.Reverted | Should -Contain 'telemetry firewall and HOSTS'
    }

    It 're-enables SMB1 and removes the port blocks when SMB1 was on, and flags the registry gap' {
        $path = New-SnapshotFile @{ Smb1State = 'Enabled' }
        Mock Remove-SecurityPortBlockRules { }
        Mock Enable-WindowsOptionalFeature { }
        Mock Set-SmbServerConfiguration { }

        $r = Restore-ModuleState -SnapshotPath $path -AppliedFeatures @('EnableSecurityHardening')

        Should -Invoke Remove-SecurityPortBlockRules -Times 1
        Should -Invoke Enable-WindowsOptionalFeature -Times 1
        $r.Reverted | Should -Contain 'security firewall and SMB1'
        ($r.Uncovered -join ' ') | Should -Match 'RDP|TLS|registry'
    }

    It 'does not re-enable SMB1 when it was already off' {
        $path = New-SnapshotFile @{ Smb1State = 'Disabled' }
        Mock Remove-SecurityPortBlockRules { }
        Mock Enable-WindowsOptionalFeature { }

        $null = Restore-ModuleState -SnapshotPath $path -AppliedFeatures @('EnableSecurityHardening')

        Should -Invoke Remove-SecurityPortBlockRules -Times 1
        Should -Invoke Enable-WindowsOptionalFeature -Times 0
    }

    It 'reports one-way and Scope-B changes as not restored' {
        $path = New-SnapshotFile @{ Marker = $true }

        $r = Restore-ModuleState -SnapshotPath $path -AppliedFeatures @('EnableGamingMode', 'EnableExtendedAIPurge')

        ($r.Uncovered -join ' ') | Should -Match 'GamingMode'
        ($r.Uncovered -join ' ') | Should -Match 'Recall'
    }

    It 'records a failure and does not claim the type reverted when a step throws' {
        $path = New-SnapshotFile @{ Services = @(@{ Name = 'DiagTrack'; StartType = 'Manual'; Running = $false }) }
        Mock Set-Service { throw 'access denied' }

        $r = Restore-ModuleState -SnapshotPath $path -AppliedFeatures @('DisableTelemetryServices')

        $r.Failed | Should -Not -BeNullOrEmpty
        $r.Reverted | Should -Not -Contain 'services'
    }

    It 'does nothing safely for a missing snapshot file' {
        $r = Restore-ModuleState -SnapshotPath (Join-Path $TestDrive 'no-such.json') -AppliedFeatures @('DisableTelemetryServices')
        $r.Reverted | Should -BeNullOrEmpty
        $r.Failed | Should -BeNullOrEmpty
    }
}

Describe 'New-ModuleStateSnapshot' {

    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
        . (Join-Path $repoRoot 'Scripts\Features\BackupModuleState.ps1')
    }

    It 'returns nothing when no module feature is being applied' {
        $script:RegistryBackupsPath = Join-Path $TestDrive 'backups'
        New-ModuleStateSnapshot -ApplyIds @('DisableCopilot', 'DisableBing') | Should -BeNullOrEmpty
    }
}
