#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for Test-ConfigConsistency, the import/export config validator.
#>

Describe 'Test-ConfigConsistency' {

    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
        . (Join-Path $repoRoot 'Scripts\Helpers\Test-ConfigConsistency.ps1')

        # A config as ConvertFrom-Json would produce it: PSCustomObjects, with
        # Tweaks/Deployment as arrays of { Name, Value } objects.
        function New-Setting { param($Name, $Value) [pscustomobject]@{ Name = $Name; Value = $Value } }
    }

    Context 'structural validation' {

        It 'rejects a null config' {
            Test-ConfigConsistency -Config $null | Should -Match 'empty or could not be read'
        }

        It 'rejects a config with no Version' {
            $config = [pscustomobject]@{ Apps = @('Microsoft.Copilot') }
            Test-ConfigConsistency -Config $config | Should -Match 'missing a Version'
        }

        It 'rejects a config with nothing importable' {
            $config = [pscustomobject]@{ Version = '1.0' }
            Test-ConfigConsistency -Config $config | Should -Match 'no importable data'
        }

        It 'rejects Apps entries that are not strings' {
            $config = [pscustomobject]@{ Version = '1.0'; Apps = @([pscustomobject]@{ Id = 'x' }) }
            Test-ConfigConsistency -Config $config | Should -Match 'Apps entries must be strings'
        }

        It 'rejects Tweaks entries without Name and Value' {
            $config = [pscustomobject]@{ Version = '1.0'; Tweaks = @([pscustomobject]@{ Name = 'DisableTelemetry' }) }
            Test-ConfigConsistency -Config $config | Should -Match 'Tweaks entries must contain Name and Value'
        }

        It 'rejects Deployment entries without Name and Value' {
            $config = [pscustomobject]@{ Version = '1.0'; Deployment = @([pscustomobject]@{ Value = $true }) }
            Test-ConfigConsistency -Config $config | Should -Match 'Deployment entries must contain Name and Value'
        }
    }

    Context 'scope and user cross-consistency' {

        It 'rejects a non-numeric AppRemovalScopeIndex' {
            $config = [pscustomobject]@{ Version = '1.0'; Deployment = @((New-Setting 'AppRemovalScopeIndex' 'nope')) }
            Test-ConfigConsistency -Config $config | Should -Match 'AppRemovalScopeIndex must be a supported numeric value'
        }

        It 'rejects an out-of-range UserSelectionIndex' {
            $config = [pscustomobject]@{ Version = '1.0'; Deployment = @((New-Setting 'UserSelectionIndex' 7)) }
            Test-ConfigConsistency -Config $config | Should -Match 'UserSelectionIndex must be a supported numeric value'
        }

        It "requires the Current User target when scope is 'Current user only'" {
            $config = [pscustomobject]@{ Version = '1.0'; Deployment = @((New-Setting 'AppRemovalScopeIndex' 1), (New-Setting 'UserSelectionIndex' 1)) }
            Test-ConfigConsistency -Config $config | Should -Match "requires the deployment target 'Current User'"
        }

        It "requires the Other User target when scope is 'Target user only'" {
            $config = [pscustomobject]@{ Version = '1.0'; Deployment = @((New-Setting 'AppRemovalScopeIndex' 2), (New-Setting 'UserSelectionIndex' 0)) }
            Test-ConfigConsistency -Config $config | Should -Match "requires the deployment target 'Other User'"
        }

        It "requires an OtherUsername when scope is 'Target user only'" {
            $config = [pscustomobject]@{ Version = '1.0'; Deployment = @((New-Setting 'AppRemovalScopeIndex' 2), (New-Setting 'UserSelectionIndex' 1)) }
            Test-ConfigConsistency -Config $config | Should -Match "requires an 'OtherUsername' value"
        }
    }

    Context 'valid configurations' {

        It 'accepts an apps-only config' {
            $config = [pscustomobject]@{ Version = '1.0'; Apps = @('Microsoft.Copilot', 'Microsoft.BingSearch') }
            Test-ConfigConsistency -Config $config | Should -BeNullOrEmpty
        }

        It 'accepts a tweaks-only config' {
            $config = [pscustomobject]@{ Version = '1.0'; Tweaks = @((New-Setting 'DisableTelemetry' $true)) }
            Test-ConfigConsistency -Config $config | Should -BeNullOrEmpty
        }

        It 'accepts a matching Target-user-only deployment' {
            $config = [pscustomobject]@{
                Version    = '1.0'
                Apps       = @('Microsoft.Copilot')
                Deployment = @(
                    (New-Setting 'AppRemovalScopeIndex' 2),
                    (New-Setting 'UserSelectionIndex' 1),
                    (New-Setting 'OtherUsername' 'SampleUser')
                )
            }
            Test-ConfigConsistency -Config $config | Should -BeNullOrEmpty
        }
    }
}
