#Requires -Modules Pester
<#
.SYNOPSIS
    Live test for Scope B of full-module rollback: the modules' imperative registry writes.
.DESCRIPTION
    Tagged Mutating. Runs inside Windows Sandbox only. See README.md.

    The unit tests cover Restore-ModuleState with mocked cmdlets. This exercises the real path
    against the real registry, which is the only place the type preservation and the
    remove-a-value-that-did-not-exist behaviour are actually proven: it captures a module's targets,
    drifts a representative subset (mixing HKCU and HKLM, string and DWord), restores from the
    snapshot, and asserts every chosen target is back to exactly what was captured, type included.

    GamingMode is used because its rollback path is registry only (its one non-registry change, the
    power plan, is reported as uncovered), so nothing else is touched.
#>

BeforeDiscovery {
    $script:mrrElevated = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Describe 'Winnow module registry rollback (Scope B, live)' -Tag 'Mutating' -Skip:(-not $script:mrrElevated) {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'IntegrationCommon.ps1')
        $script:repoRoot = Get-WinnowRepoRoot
        . (Join-Path $script:repoRoot 'Scripts\Features\GamingMode.ps1')
        . (Join-Path $script:repoRoot 'Scripts\Features\SecurityHardening.ps1')
        . (Join-Path $script:repoRoot 'Scripts\Features\ExtendedAIPurge.ps1')
        . (Join-Path $script:repoRoot 'Scripts\Features\BlockTelemetryFirewall.ps1')
        . (Join-Path $script:repoRoot 'Scripts\Features\BackupModuleState.ps1')
        $script:RegistryBackupsPath = Join-Path $TestDrive 'backups'
    }

    It 'restores GamingMode registry values to their exact pre-apply state, types included' {
        $snapPath = New-ModuleStateSnapshot -ApplyIds @('EnableGamingMode')
        $snapPath | Should -Not -BeNullOrEmpty
        $snapshot = Get-Content -LiteralPath $snapPath -Raw | ConvertFrom-Json
        @($snapshot.RegistryValues).Count | Should -BeGreaterThan 0

        # A representative subset: HKCU and HKLM, string and DWord.
        $chosenNames = @('MouseSpeed', 'AppCaptureEnabled', 'HwSchMode', 'MaintenanceDisabled')
        $chosen = @($snapshot.RegistryValues | Where-Object { $_.Name -in $chosenNames })
        $chosen.Count | Should -BeGreaterThan 0

        # Drift each chosen target to a sentinel, creating the key if needed.
        foreach ($target in $chosen) {
            if (-not (Test-Path -LiteralPath $target.Path)) {
                New-Item -Path $target.Path -Force | Out-Null
            }
            Set-ItemProperty -LiteralPath $target.Path -Name $target.Name -Value 424242 -Type DWord -Force
        }

        $result = Restore-ModuleState -SnapshotPath $snapPath -AppliedFeatures @('EnableGamingMode')
        $result.Failed | Should -BeNullOrEmpty
        $result.Reverted | Should -Contain 'module registry settings'

        foreach ($target in $chosen) {
            $after = Get-ModuleRegistryValueSnapshot -Path $target.Path -Name $target.Name
            $after.Existed | Should -Be $target.Existed -Because "existence of $($target.Path)\$($target.Name) should match the capture"
            if ($target.Existed) {
                "$($after.Value)" | Should -Be "$($target.Value)" -Because "the value of $($target.Name) should be restored"
                $after.Kind | Should -Be $target.Kind -Because "the type of $($target.Name) should be restored"
            }
        }
    }

    It 'removes a value the module created where none existed before' {
        # A synthetic target the module could write to, guaranteed absent at capture.
        $testKey = 'HKCU:\Software\Winnow\ScopeBLiveTest'
        Remove-Item -LiteralPath $testKey -Recurse -Force -ErrorAction SilentlyContinue

        $snapshot = [ordered]@{
            RegistryValues = @(Get-ModuleRegistryValueSnapshot -Path $testKey -Name 'CreatedByApply')
        }
        $snapshot.RegistryValues[0].Existed | Should -BeFalse
        $snapPath = Join-Path $TestDrive ('synthetic-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.json')
        $snapshot | ConvertTo-Json -Depth 6 | Out-File -FilePath $snapPath -Encoding UTF8 -Force

        # Simulate the module writing the value.
        New-Item -Path $testKey -Force | Out-Null
        Set-ItemProperty -LiteralPath $testKey -Name 'CreatedByApply' -Value 1 -Type DWord -Force

        $result = Restore-ModuleState -SnapshotPath $snapPath -AppliedFeatures @('EnableGamingMode')
        $result.Failed | Should -BeNullOrEmpty

        (Get-ModuleRegistryValueSnapshot -Path $testKey -Name 'CreatedByApply').Existed | Should -BeFalse

        Remove-Item -LiteralPath $testKey -Recurse -Force -ErrorAction SilentlyContinue
    }
}
