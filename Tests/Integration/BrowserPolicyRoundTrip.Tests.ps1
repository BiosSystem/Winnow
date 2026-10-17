#Requires -Modules Pester
<#
.SYNOPSIS
    Applies and undoes the browser AI policy features for real.
.DESCRIPTION
    Tagged Mutating. This writes machine policy under HKLM on the machine it
    runs on. Run it inside Windows Sandbox, or on a throwaway VM. See README.md.

    DisableChromeAI and DisableEdgeAI are pure policy features: each writes the
    values in its .reg file and its undo file deletes them. The unit suite
    checks the files; this checks that a real apply writes every value with the
    declared data, that -Verify then reports the feature compliant, and that
    -Undo removes every value again. It does not check how the browsers react.

    The values each feature touches are snapshotted first and restored at the
    end, so later tests in the same Sandbox start from the same registry.
#>

BeforeDiscovery {
    # -Skip: is evaluated during discovery, before any BeforeAll runs, so the
    # elevation check has to be resolved here.
    . (Join-Path $PSScriptRoot 'IntegrationCommon.ps1')
    $script:IsElevated = Test-IsElevated

    $script:browserFeatures = @(
        @{ FeatureId = 'DisableChromeAI'; RegFile = 'Disable_Chrome_AI_Features.reg' }
        @{ FeatureId = 'DisableEdgeAI'; RegFile = 'Disable_Edge_AI_Features.reg' }
    )
}

Describe 'Browser policy round trip: <FeatureId>' -Tag 'Mutating' -ForEach $script:browserFeatures {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'IntegrationCommon.ps1')
        $repoRoot = Get-WinnowRepoRoot
        . (Join-Path $repoRoot 'Scripts\Helpers\Get-RegFileOperations.ps1')

        $script:regFile = Join-Path $repoRoot (Join-Path 'Regfiles' $RegFile)
        $script:before = Get-RegFileValueSnapshot -RegFilePath $script:regFile

        # Expected data per value, keyed like the snapshot (HKLM:\path\name).
        $script:expected = @{}
        foreach ($operation in @(Get-RegFileOperations -regFilePath $script:regFile)) {
            if ($operation.OperationType -ne 'SetValue') { continue }
            $psPath = $operation.KeyPath -replace '^HKEY_LOCAL_MACHINE', 'HKLM:' -replace '^HKEY_CURRENT_USER', 'HKCU:'
            $script:expected['{0}\{1}' -f $psPath, $operation.ValueName] = $operation.ValueData
        }

        $script:profilePath = Join-Path $TestDrive "$FeatureId.json"
        @{ Switches = @($FeatureId) } | ConvertTo-Json | Set-Content -LiteralPath $script:profilePath -Encoding utf8
    }

    AfterAll {
        Restore-RegFileValueSnapshot -RegFilePath $script:regFile -Snapshot $script:before
    }

    It 'declares values to check' {
        $script:expected.Count | Should -BeGreaterThan 0
    }

    It 'writes every policy value with the declared data and verifies compliant' -Skip:(-not $script:IsElevated) {
        $apply = Invoke-WinnowProcess -Arguments @('-Silent', '-CLI', "-$FeatureId") -TimeoutSeconds 300
        $apply.TimedOut | Should -BeFalse

        $after = Get-RegFileValueSnapshot -RegFilePath $script:regFile
        $wrong = @($script:expected.Keys | Where-Object { "$($after[$_])" -ne "$($script:expected[$_])" } |
                ForEach-Object { '{0}: expected [{1}] got [{2}]' -f $_, $script:expected[$_], $after[$_] })
        $wrong | Should -BeNullOrEmpty -Because ($wrong -join '; ')

        $verify = Invoke-WinnowProcess -Arguments @('-Verify', '-VerifyProfile', $script:profilePath)
        $verify.Stdout | Should -Match ('Compliant\] {0}' -f $FeatureId)
        $verify.ExitCode | Should -Be 0
    }

    It 'removes every policy value through -Undo' -Skip:(-not $script:IsElevated) {
        $undo = Invoke-WinnowProcess -Arguments @('-Silent', '-CLI', '-Undo', $FeatureId) -TimeoutSeconds 300
        $undo.TimedOut | Should -BeFalse

        $after = Get-RegFileValueSnapshot -RegFilePath $script:regFile
        $left = @($script:expected.Keys | Where-Object { $null -ne $after[$_] })
        $left | Should -BeNullOrEmpty -Because "still present after undo: $($left -join '; ')"

        $verify = Invoke-WinnowProcess -Arguments @('-Verify', '-VerifyProfile', $script:profilePath)
        $verify.Stdout | Should -Match ('NonCompliant\] {0}' -f $FeatureId)
    }
}
