#Requires -Modules Pester
<#
.SYNOPSIS
    Applies a registry-backed feature for real and verifies the result.
.DESCRIPTION
    Tagged Mutating. This writes to the registry of the machine it runs on.
    Run it inside Windows Sandbox, or on a throwaway VM. See README.md.

    This is scenario 1 of Track 3 in the v3.4.0 plan. Scenario 2, the undo half
    of the round trip, is blocked; see the pending test at the bottom.
#>

BeforeDiscovery {
    # -Skip: is evaluated during discovery, before any BeforeAll runs, so the
    # elevation check has to be resolved here.
    . (Join-Path $PSScriptRoot 'IntegrationCommon.ps1')
    $script:IsElevated = Test-IsElevated
}

Describe 'Winnow apply round trip' -Tag 'Mutating' {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'IntegrationCommon.ps1')
        $repoRoot = Get-WinnowRepoRoot
        . (Join-Path $repoRoot 'Scripts\Helpers\Get-RegFileOperations.ps1')

        $script:regFile = Join-Path $repoRoot 'Regfiles\Disable_Telemetry.reg'
        $script:profilePath = Join-Path $TestDrive 'applied.json'
        @{ Switches = @('DisableTelemetry') } | ConvertTo-Json |
            Set-Content -LiteralPath $script:profilePath -Encoding utf8
    }

    It 'applies a registry-backed feature and reports it compliant' -Skip:(-not $script:IsElevated) {
        $apply = Invoke-WinnowProcess -Arguments @('-Silent', '-CLI', '-DisableTelemetry') -TimeoutSeconds 300
        $apply.TimedOut | Should -BeFalse

        $verify = Invoke-WinnowProcess -Arguments @('-Verify', '-VerifyProfile', $script:profilePath)
        $verify.TimedOut | Should -BeFalse
        $verify.Stdout | Should -Match 'Compliant\] DisableTelemetry'
        $verify.ExitCode | Should -Be 0
    }

    It 'wrote every value the feature registry file declares' -Skip:(-not $script:IsElevated) {
        # Verification reports one verdict for the feature. This checks the
        # individual values underneath it, so a partially applied .reg file
        # cannot pass as compliant.
        $missing = [System.Collections.Generic.List[string]]::new()

        foreach ($operation in @(Get-RegFileOperations -regFilePath $script:regFile)) {
            if ($operation.OperationType -ne 'SetValue') { continue }

            $psPath = $operation.KeyPath `
                -replace '^HKEY_LOCAL_MACHINE', 'HKLM:' `
                -replace '^HKEY_CURRENT_USER', 'HKCU:'
            if ($psPath -notmatch '^(HKLM|HKCU):') { continue }

            try {
                $null = Get-ItemProperty -LiteralPath $psPath -Name $operation.ValueName -ErrorAction Stop
            }
            catch {
                $missing.Add(('{0}\{1}' -f $psPath, $operation.ValueName))
            }
        }

        $missing | Should -BeNullOrEmpty -Because "values the feature should have written are absent: $($missing -join '; ')"
    }

    It 'reverses the feature through -Undo' -Skip:(-not $script:IsElevated) {
        # Scenario 2 of Track 3, unblocked by the -Undo parameter.
        #
        # The assertion is on the verification verdict rather than on the exact
        # pre-apply values: an undo .reg restores the Windows default state,
        # which is not necessarily what this machine had beforehand.
        $applied = Invoke-WinnowProcess -Arguments @('-Verify', '-VerifyProfile', $script:profilePath)
        $applied.Stdout | Should -Match 'Compliant\] DisableTelemetry' -Because 'the previous test applied it'

        $undo = Invoke-WinnowProcess -Arguments @('-Silent', '-CLI', '-Undo', 'DisableTelemetry') -TimeoutSeconds 300
        $undo.TimedOut | Should -BeFalse
        $undo.Stdout | Should -Not -Match 'completed without making any changes' -Because '-Undo names real work'

        $after = Invoke-WinnowProcess -Arguments @('-Verify', '-VerifyProfile', $script:profilePath)
        $after.Stdout | Should -Match 'NonCompliant\] DisableTelemetry'
        $after.ExitCode | Should -Be 2
    }

    It 'rejects a feature that cannot be undone' -Skip:(-not $script:IsElevated) {
        # CreateRestorePoint is an action with no undo path. Accepting it would
        # report success while doing nothing.
        $result = Invoke-WinnowProcess -Arguments @('-Silent', '-CLI', '-Undo', 'CreateRestorePoint')

        $result.ExitCode | Should -Not -Be 0
        $result.Stderr | Should -Match 'cannot be undone'
    }

    It 'rejects an unknown feature passed to -Undo' -Skip:(-not $script:IsElevated) {
        $result = Invoke-WinnowProcess -Arguments @('-Silent', '-CLI', '-Undo', 'NoSuchFeatureExists')

        $result.ExitCode | Should -Not -Be 0
        $result.Stderr | Should -Match 'Unknown feature'
    }
}

Describe 'Winnow code-implemented feature round trip' -Tag 'Mutating' {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'IntegrationCommon.ps1')
        $script:servicesProfile = Join-Path $TestDrive 'services.json'
        @{ Switches = @('DisableTelemetryServices') } | ConvertTo-Json |
            Set-Content -LiteralPath $script:servicesProfile -Encoding utf8
    }

    It 'applies a feature implemented in code, not a .reg file, and reports it compliant' -Skip:(-not $script:IsElevated) {
        # DisableTelemetryServices has no .reg file; its apply and undo live in
        # TelemetryServices.ps1. Winnow.ps1 once did not load that file, so every
        # apply died with "command not found" and was rolled back.
        $apply = Invoke-WinnowProcess -Arguments @('-Silent', '-CLI', '-DisableTelemetryServices') -TimeoutSeconds 300
        $apply.TimedOut | Should -BeFalse
        $apply.Stdout | Should -Not -Match 'Rolling back'
        $apply.ExitCode | Should -Be 0
        (Get-Service -Name 'DiagTrack').StartType | Should -Be 'Disabled'

        # The run summary is written at the end of every real apply.
        $apply.Stdout | Should -Match 'Run summary saved to'

        $verify = Invoke-WinnowProcess -Arguments @('-Verify', '-VerifyProfile', $script:servicesProfile)
        $verify.Stdout | Should -Match 'Compliant\] DisableTelemetryServices'
    }

    It 'reverses it through -Undo' -Skip:(-not $script:IsElevated) {
        $undo = Invoke-WinnowProcess -Arguments @('-Silent', '-CLI', '-Undo', 'DisableTelemetryServices') -TimeoutSeconds 300
        $undo.TimedOut | Should -BeFalse
        $undo.ExitCode | Should -Be 0
        (Get-Service -Name 'DiagTrack').StartType | Should -Not -Be 'Disabled'
    }
}
