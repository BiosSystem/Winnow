#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for the dynamic feature-update pin: the DisableFeatureUpdates feature
    pins the device to its current feature release (DisplayVersion) instead of a
    literal baked into the .reg file, and verifies against the running release.
    All registry cmdlets are mocked, so these are safe on any machine.
#>

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
    . (Join-Path $repoRoot 'Scripts\Features\DesiredStateVerification.ps1')
    . (Join-Path $repoRoot 'Scripts\Features\InvokeChanges.ps1')

    # ImportRegistryFile lives in another file the apply path calls; a stub lets
    # these tests mock it without loading the whole registry-import stack.
    function ImportRegistryFile { param($Message, $File) }
}

Describe 'Test-WinnowFeatureUpdatePinState' {

    It 'is compliant when the pin is on and points at the running release' {
        Mock Get-ItemProperty { [PSCustomObject]@{ TargetReleaseVersion = 1; TargetReleaseVersionInfo = '25H2' } }
        Mock Get-WinnowWindowsDisplayVersion { '25H2' }

        Test-WinnowFeatureUpdatePinState | Should -BeTrue
    }

    It 'is not compliant when the pin points at a different release than the one running' {
        Mock Get-ItemProperty { [PSCustomObject]@{ TargetReleaseVersion = 1; TargetReleaseVersionInfo = '24H2' } }
        Mock Get-WinnowWindowsDisplayVersion { '25H2' }

        Test-WinnowFeatureUpdatePinState | Should -BeFalse
    }

    It 'is not compliant when the pin is off' {
        Mock Get-ItemProperty { [PSCustomObject]@{ TargetReleaseVersion = 0; TargetReleaseVersionInfo = '25H2' } }
        Mock Get-WinnowWindowsDisplayVersion { '25H2' }

        Test-WinnowFeatureUpdatePinState | Should -BeFalse
    }

    It 'is not compliant when the policy key does not exist' {
        Mock Get-ItemProperty { throw 'not found' }

        Test-WinnowFeatureUpdatePinState | Should -BeFalse
    }

    It 'accepts any set target when the running DisplayVersion cannot be read' {
        Mock Get-ItemProperty { [PSCustomObject]@{ TargetReleaseVersion = 1; TargetReleaseVersionInfo = '24H2' } }
        Mock Get-WinnowWindowsDisplayVersion { $null }

        Test-WinnowFeatureUpdatePinState | Should -BeTrue
    }
}

Describe 'DisableFeatureUpdates apply side effect' {

    BeforeEach {
        $script:Features = @{
            'DisableFeatureUpdates' = [PSCustomObject]@{
                RegistryKey = 'Disable_Feature_Updates.reg'
                ApplyText   = 'Blocking Windows feature version upgrades'
            }
        }
        Mock ImportRegistryFile { }
        Mock Write-Host { }
        Mock Set-ItemProperty { }
        Mock Get-WinnowWindowsDisplayVersion { '25H2' }
    }

    It 'rewrites the pinned version to the running release' {
        $script:Params = @{}

        Invoke-FeatureApply -FeatureId 'DisableFeatureUpdates'

        Should -Invoke Set-ItemProperty -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'TargetReleaseVersionInfo' -and $Value -eq '25H2'
        }
    }

    It 'does not write anything under WhatIf' {
        $script:Params = @{ WhatIf = $true }

        Invoke-FeatureApply -FeatureId 'DisableFeatureUpdates'

        Should -Invoke Set-ItemProperty -Times 0 -Exactly
    }

    It 'skips the rewrite when the running DisplayVersion is unavailable' {
        Mock Get-WinnowWindowsDisplayVersion { $null }
        $script:Params = @{}

        Invoke-FeatureApply -FeatureId 'DisableFeatureUpdates'

        Should -Invoke Set-ItemProperty -Times 0 -Exactly
    }
}
