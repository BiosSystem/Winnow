#Requires -Modules Pester
<#
.SYNOPSIS
    Proves that -DryRun reaches the apply pipeline without writing anything.
.DESCRIPTION
    Tagged DryRun rather than ReadOnly on purpose. The whole point is to assert
    that nothing is written, which means a regression in the dry-run guard would
    write to the host running the test. Run it on an ephemeral machine (CI) or
    inside Windows Sandbox, never on a workstation you care about.

    The assertion targets the exact values the selected feature would change,
    read out of its .reg file, rather than sweeping the registry broadly.
#>

BeforeDiscovery {
    # -Skip: is evaluated during discovery, before any BeforeAll runs, so the
    # elevation check has to be resolved here.
    . (Join-Path $PSScriptRoot 'IntegrationCommon.ps1')
    $script:IsElevated = Test-IsElevated
}

Describe 'Winnow -DryRun safety' -Tag 'DryRun' {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'IntegrationCommon.ps1')
        $repoRoot = Get-WinnowRepoRoot
        . (Join-Path $repoRoot 'Scripts\Helpers\Get-RegFileOperations.ps1')

        $script:regFile = Join-Path $repoRoot 'Regfiles\Disable_Telemetry.reg'
    }

    It 'has the feature registry file this test depends on' {
        Test-Path -LiteralPath $script:regFile | Should -BeTrue
    }

    It 'reaches the apply pipeline but changes no registry value' -Skip:(-not $script:IsElevated) {
        $before = Get-RegFileValueSnapshot -RegFilePath $script:regFile
        $before.Count | Should -BeGreaterThan 0 -Because 'the test is meaningless without values to watch'

        $result = Invoke-WinnowProcess -Arguments @('-DryRun', '-Silent', '-CLI', '-DisableTelemetry')

        $result.TimedOut | Should -BeFalse
        $result.Stdout | Should -Match '\[WhatIf\]' -Because 'the run must actually reach the apply pipeline'

        $after = Get-RegFileValueSnapshot -RegFilePath $script:regFile
        $changed = Compare-RegValueSnapshot -Before $before -After $after

        $changed | Should -BeNullOrEmpty -Because "DryRun wrote to the registry: $($changed -join '; ')"
    }

    It 'announces the registry backup without creating one' -Skip:(-not $script:IsElevated) {
        $result = Invoke-WinnowProcess -Arguments @('-DryRun', '-Silent', '-CLI', '-DisableTelemetry')

        $result.TimedOut | Should -BeFalse
        $result.Stdout | Should -Match '\[WhatIf\] Create registry backup'
    }

    It 'splits a comma-separated -Undo list passed through -File' -Skip:(-not $script:IsElevated) {
        # -File binds "A,B" to a [string[]] parameter as one value. Two unknown
        # names are rejected before anything runs, and reporting them separately
        # proves the list was split rather than looked up as one FeatureId.
        # The error record is wrapped to the console width, so a line break can
        # fall between the names; the unsplit value has no whitespace there.
        $result = Invoke-WinnowProcess -Arguments @('-DryRun', '-Silent', '-CLI', '-Undo', 'NoSuchFeatureA,NoSuchFeatureB')

        $result.TimedOut | Should -BeFalse
        $result.ExitCode | Should -Not -Be 0
        $result.Stderr | Should -Match 'Unknown feature\(s\) passed to -Undo: NoSuchFeatureA,\s+NoSuchFeatureB'
    }
}
