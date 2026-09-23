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

    It 're-enables SMB1 and removes the port blocks when SMB1 was on' {
        $path = New-SnapshotFile @{ Smb1State = 'Enabled' }
        Mock Remove-SecurityPortBlockRules { }
        Mock Enable-WindowsOptionalFeature { }
        Mock Set-SmbServerConfiguration { }

        $r = Restore-ModuleState -SnapshotPath $path -AppliedFeatures @('EnableSecurityHardening')

        Should -Invoke Remove-SecurityPortBlockRules -Times 1
        Should -Invoke Enable-WindowsOptionalFeature -Times 1
        $r.Reverted | Should -Contain 'security firewall and SMB1'
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

Describe 'Module registry rollback (Scope B)' {

    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
        . (Join-Path $repoRoot 'Scripts\Features\BlockTelemetryFirewall.ps1')
        . (Join-Path $repoRoot 'Scripts\Features\BackupModuleState.ps1')

        function New-RegSnapshotFile {
            param([hashtable]$Snapshot)
            $path = Join-Path $TestDrive ('regsnap-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
            $Snapshot | ConvertTo-Json -Depth 6 | Out-File -FilePath $path -Encoding UTF8 -Force
            return $path
        }
    }

    It 'restores a captured value that existed, with its type' {
        $path = New-RegSnapshotFile @{ RegistryValues = @(@{ Path = 'HKLM:\SOFTWARE\WinnowTest'; Name = 'fDenyTSConnections'; Existed = $true; Value = 0; Kind = 'DWord' }) }
        Mock Set-ItemProperty { }
        Mock Test-Path { $true }

        $r = Restore-ModuleState -SnapshotPath $path -AppliedFeatures @('EnableSecurityHardening')

        Should -Invoke Set-ItemProperty -Times 1 -Exactly
        $r.Reverted | Should -Contain 'module registry settings'
    }

    It 'removes a captured value that did not exist before' {
        $path = New-RegSnapshotFile @{ RegistryValues = @(@{ Path = 'HKCU:\Software\WinnowTest'; Name = 'StartupDelayInMSec'; Existed = $false; Value = $null; Kind = $null }) }
        Mock Remove-ItemProperty { }
        Mock Test-Path { $true }

        $r = Restore-ModuleState -SnapshotPath $path -AppliedFeatures @('EnableGamingMode')

        Should -Invoke Remove-ItemProperty -Times 1 -Exactly
        $r.Reverted | Should -Contain 'module registry settings'
    }

    It 'leaves registry alone when no registry-writing module applied' {
        $path = New-RegSnapshotFile @{ RegistryValues = @(@{ Path = 'HKLM:\SOFTWARE\WinnowTest'; Name = 'X'; Existed = $true; Value = 1; Kind = 'DWord' }) }
        Mock Set-ItemProperty { }
        Mock Remove-ItemProperty { }

        $null = Restore-ModuleState -SnapshotPath $path -AppliedFeatures @('DisableTelemetryServices')

        Should -Invoke Set-ItemProperty -Times 0 -Exactly
        Should -Invoke Remove-ItemProperty -Times 0 -Exactly
    }

    It 'records a failure and does not claim revert when a registry write throws' {
        $path = New-RegSnapshotFile @{ RegistryValues = @(@{ Path = 'HKLM:\SOFTWARE\WinnowTest'; Name = 'X'; Existed = $true; Value = 1; Kind = 'DWord' }) }
        Mock Set-ItemProperty { throw 'access denied' }
        Mock Test-Path { $true }

        $r = Restore-ModuleState -SnapshotPath $path -AppliedFeatures @('EnableSecurityHardening')

        $r.Failed | Should -Not -BeNullOrEmpty
        $r.Reverted | Should -Not -Contain 'module registry settings'
    }
}

Describe 'Module registry targets' {

    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
        . (Join-Path $repoRoot 'Scripts\Features\SecurityHardening.ps1')
        . (Join-Path $repoRoot 'Scripts\Features\ExtendedAIPurge.ps1')
        . (Join-Path $repoRoot 'Scripts\Features\GamingMode.ps1')
        $script:featuresPath = Join-Path $repoRoot 'Scripts\Features'

        function Get-SetItemPropertyNames {
            param([string]$FilePath)
            $tokens = $null
            $parseErrors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($FilePath, [ref]$tokens, [ref]$parseErrors)
            $calls = @($ast.FindAll({
                        param($n)
                        $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-ItemProperty'
                    }, $true))
            $names = New-Object System.Collections.Generic.HashSet[string]
            foreach ($call in $calls) {
                for ($i = 0; $i -lt $call.CommandElements.Count; $i++) {
                    $element = $call.CommandElements[$i]
                    if ($element -is [System.Management.Automation.Language.CommandParameterAst] -and $element.ParameterName -eq 'Name') {
                        $argument = if ($element.Argument) { $element.Argument } elseif (($i + 1) -lt $call.CommandElements.Count) { $call.CommandElements[$i + 1] } else { $null }
                        if ($argument -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
                            [void]$names.Add($argument.Value)
                        }
                    }
                }
            }
            return $names
        }
    }

    It 'SecurityHardening provider lists the core hardening values' {
        $names = @((Get-SecurityHardeningRegistryTargets).Name)
        $names | Should -Contain 'fDenyTSConnections'
        $names | Should -Contain 'NoDriveTypeAutoRun'
        $names | Should -Contain 'DisabledByDefault'
    }

    It 'ExtendedAIPurge provider lists the AI policy values' {
        $names = @((Get-ExtendedAIPurgeRegistryTargets).Name)
        $names | Should -Contain 'TurnOffWindowsCopilot'
        $names | Should -Contain 'AllowRecallEnablement'
        # 24H2/25H2 additions.
        $names | Should -Contain 'DisableClickToDo'
        $names | Should -Contain 'DisableSettingsAgent'
        $names | Should -Contain 'DisableCocreator'
        $names | Should -Contain 'DisableImageCreator'
    }

    It 'ExtendedAIPurge declares both scopes for the user-and-machine AI policies' {
        $targets = @(Get-ExtendedAIPurgeRegistryTargets)
        $clickToDo = @($targets | Where-Object { $_.Name -eq 'DisableClickToDo' })
        ($clickToDo | Where-Object { $_.Path -like 'HKLM:*' }) | Should -Not -BeNullOrEmpty
        ($clickToDo | Where-Object { $_.Path -like 'HKCU:*' }) | Should -Not -BeNullOrEmpty
        $paint = @($targets | Where-Object { $_.Path -like '*\Policies\Paint' -and $_.Name -eq 'DisableGenerativeFill' })
        $paint | Should -Not -BeNullOrEmpty
    }

    It 'every Set-ItemProperty name in each module is declared by its provider (drift guard)' {
        # TcpAckFrequency and TCPNoDelay are added per network interface at capture time,
        # so their presence in the provider output depends on live interfaces; they are
        # covered by construction and excluded from the static comparison.
        $dynamic = @('TcpAckFrequency', 'TCPNoDelay')
        $map = @{
            'SecurityHardening' = @((Get-SecurityHardeningRegistryTargets).Name)
            'ExtendedAIPurge'   = @((Get-ExtendedAIPurgeRegistryTargets).Name)
            'GamingMode'        = @((Get-GamingModeRegistryTargets).Name)
        }
        foreach ($module in $map.Keys) {
            $declared = $map[$module]
            $written = Get-SetItemPropertyNames -FilePath (Join-Path $script:featuresPath ("{0}.ps1" -f $module))
            foreach ($name in $written) {
                if ($name -in $dynamic) { continue }
                $declared | Should -Contain $name -Because "$module writes '$name' but its registry-target provider does not declare it"
            }
        }
    }
}

Describe 'Run summary' {

    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
        . (Join-Path $repoRoot 'Scripts\Features\ExportRunSummary.ps1')

        function Invoke-SummaryExport {
            param([datetime]$Start)
            Export-RunSummary -AppliedFeatureIds @('DisableTelemetry', 'DisableCopilot') -UndoneFeatureIds @() `
                -StartTime $Start -WinnowVersion 'test'
            $path = Join-Path $TestDrive ('Winnow_RunSummary_{0}.json' -f $Start.ToString('yyyyMMdd_HHmmss'))
            return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
        }
    }

    BeforeEach {
        $script:savedTemp = $env:TEMP
        $env:TEMP = $TestDrive
        Mock Write-Host { }
    }

    AfterEach {
        $env:TEMP = $script:savedTemp
        $script:RunRollbackOutcome = $null
        $script:RunRollbackReason = $null
        $script:RunRegistryBackupPath = $null
        $script:RegistryImportFailures = 0
    }

    It 'does not report features as applied after a clean rollback' {
        $script:RunRollbackOutcome = 'RolledBack'
        $script:RunRollbackReason = '1 registry import change(s) failed'
        $script:RunRegistryBackupPath = 'C:\backup.json'
        $script:RegistryImportFailures = 1

        $summary = Invoke-SummaryExport -Start (Get-Date).AddMinutes(-2)

        @($summary.FeaturesApplied.Status | Select-Object -Unique) | Should -Be @('RolledBack')
        $summary.Rollback.Outcome | Should -Be 'RolledBack'
        $summary.Rollback.Triggered | Should -BeTrue
        $summary.RegistryImportFailures | Should -Be 1
        $summary.ErrorCount | Should -Be 1
    }

    It 'reports the state as unknown when the rollback itself failed' {
        $script:RunRollbackOutcome = 'RollbackFailed'

        $summary = Invoke-SummaryExport -Start (Get-Date).AddMinutes(-3)

        @($summary.FeaturesApplied.Status | Select-Object -Unique) | Should -Be @('Unknown')
    }

    It 'reports features as applied when nothing was rolled back' {
        $script:RunRollbackOutcome = 'None'

        $summary = Invoke-SummaryExport -Start (Get-Date).AddMinutes(-4)

        @($summary.FeaturesApplied.Status | Select-Object -Unique) | Should -Be @('Applied')
        $summary.Rollback.Triggered | Should -BeFalse
    }
}
