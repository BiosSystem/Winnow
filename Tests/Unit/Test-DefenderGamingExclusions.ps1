#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Unit tests for the Defender gaming exclusions add/remove parity.
.DESCRIPTION
    The add and remove operations must act on the same set of paths so an enabled exclusion set can be
    fully reverted. Add-MpPreference / Remove-MpPreference are Defender cmdlets and are mocked.
#>

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $repoRoot 'Scripts\Features\AddDefenderGamingExclusions.ps1')
}

Describe 'Defender gaming exclusions' {

    It 'exposes a non-empty shared path list' {
        @(Get-DefenderGamingExclusionPaths).Count | Should -BeGreaterThan 0
    }

    It 'removes an exclusion for every path in the shared list' {
        Mock -CommandName Remove-MpPreference -MockWith { }
        $expected = @(Get-DefenderGamingExclusionPaths).Count

        Invoke-RemoveDefenderGamingExclusions

        Should -Invoke -CommandName Remove-MpPreference -Times $expected -Exactly
        foreach ($path in (Get-DefenderGamingExclusionPaths)) {
            Should -Invoke -CommandName Remove-MpPreference -ParameterFilter { $ExclusionPath -eq $path } -Times 1 -Exactly
        }
    }

    It 'removes exclusions even when the game directory no longer exists' {
        Mock -CommandName Remove-MpPreference -MockWith { }
        Mock -CommandName Test-Path -MockWith { $false }

        Invoke-RemoveDefenderGamingExclusions

        Should -Invoke -CommandName Remove-MpPreference -Times (@(Get-DefenderGamingExclusionPaths).Count) -Exactly
    }

    It 'only adds exclusions for directories that exist' {
        Mock -CommandName Add-MpPreference -MockWith { }
        Mock -CommandName Test-Path -MockWith { $false }

        Invoke-AddDefenderGamingExclusions

        Should -Invoke -CommandName Add-MpPreference -Times 0 -Exactly
    }

    It 'changes nothing under -WhatIf' {
        Mock -CommandName Remove-MpPreference -MockWith { }
        Mock -CommandName Add-MpPreference -MockWith { }

        Invoke-RemoveDefenderGamingExclusions -WhatIf
        Invoke-AddDefenderGamingExclusions -WhatIf

        Should -Invoke -CommandName Remove-MpPreference -Times 0 -Exactly
        Should -Invoke -CommandName Add-MpPreference -Times 0 -Exactly
    }
}
