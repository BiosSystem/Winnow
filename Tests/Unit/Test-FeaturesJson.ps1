#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for Features.json structural integrity.
.DESCRIPTION
    Validates that every entry in Features.json has all required fields,
    no duplicate FeatureIds, valid category values, and correct RegistryKey
    file references pointing to real files on disk.
#>

Describe 'Features.json' {

    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
        $configPath = Join-Path $repoRoot 'Config\Features.json'
        $script:regPath = Join-Path $repoRoot 'Regfiles'
        $script:json = Get-Content $configPath -Raw | ConvertFrom-Json
        $script:features = $script:json.Features
        $tokens = $null
        $errors = $null
        $entryAst = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $repoRoot 'Winnow.ps1'),
            [ref]$tokens,
            [ref]$errors
        )
        $script:entryParameterNames = @($entryAst.ParamBlock.Parameters.Name.VariablePath.UserPath)
    }

    It 'parses as valid JSON' {
        $script:features | Should -Not -BeNullOrEmpty
    }

    It 'has no duplicate FeatureIds' {
        $ids = $script:features | ForEach-Object { $_.FeatureId }
        $dupes = $ids | Group-Object | Where-Object { $_.Count -gt 1 } | Select-Object -ExpandProperty Name
        $dupes | Should -BeNullOrEmpty -Because "Duplicate FeatureIds: $($dupes -join ', ')"
    }

    It 'exposes every feature through a direct CLI parameter' {
        $missing = @($script:features.FeatureId | Where-Object { $_ -notin $script:entryParameterNames })
        $missing | Should -BeNullOrEmpty -Because "Missing Winnow.ps1 parameters: $($missing -join ', ')"
    }

    It 'every entry has a non-empty FeatureId' {
        $missing = $script:features | Where-Object { [string]::IsNullOrWhiteSpace($_.FeatureId) }
        $missing.Count | Should -Be 0
    }

    It 'every entry has a non-empty Label' {
        $missing = $script:features | Where-Object { [string]::IsNullOrWhiteSpace($_.Label) }
        $missing.Count | Should -Be 0
    }

    It 'every entry with a RegistryKey has a matching file on disk' {
        $broken = @()
        foreach ($f in $script:features) {
            if (-not [string]::IsNullOrWhiteSpace($f.RegistryKey)) {
                $filePath = Join-Path $script:regPath $f.RegistryKey
                if (-not (Test-Path $filePath)) {
                    $broken += "$($f.FeatureId) -> $($f.RegistryKey)"
                }
            }
        }
        $broken | Should -BeNullOrEmpty -Because "Missing registry files: $($broken -join '; ')"
    }

    It 'every entry with a RegistryUndoKey has a matching Undo file on disk' {
        $broken = @()
        foreach ($f in $script:features) {
            if (-not [string]::IsNullOrWhiteSpace($f.RegistryUndoKey)) {
                $undoPath = Join-Path (Join-Path $script:regPath 'Undo') $f.RegistryUndoKey
                $rootPath = Join-Path $script:regPath $f.RegistryUndoKey
                if (-not (Test-Path $undoPath) -and -not (Test-Path $rootPath)) {
                    $broken += "$($f.FeatureId) -> $($f.RegistryUndoKey)"
                }
            }
        }
        $broken | Should -BeNullOrEmpty -Because "Missing undo registry files: $($broken -join '; ')"
    }

    It 'MinVersion values are null or valid integers' {
        $invalid = $script:features | Where-Object {
            $null -ne $_.MinVersion -and -not ($_.MinVersion -is [int] -or $_.MinVersion -is [long])
        }
        $invalid.Count | Should -Be 0
    }

    It 'uses only supported verification adapters' {
        $supportedAdapters = @(
            'CurrentFeatureState',
            'GamingMode',
            'ExtendedAIPurge',
            'SecurityHardening',
            'TelemetryFirewall',
            'AppxAbsence',
            'StartLayout',
            'EdgeRemoved',
            'FeatureUpdatePin',
            'NotApplicable'
        )
        $invalid = $script:features | Where-Object {
            $_.VerificationAdapter -and $_.VerificationAdapter -notin $supportedAdapters
        }
        $invalid.Count | Should -Be 0
    }

    It 'gives every feature a verification story' {
        # A feature verifies through RegistryKey read-back or a declared adapter.
        # Anything with neither is silently unverifiable, which is what this guards against.
        $unverifiable = @($script:features | Where-Object {
            [string]::IsNullOrWhiteSpace($_.RegistryKey) -and
            [string]::IsNullOrWhiteSpace($_.VerificationAdapter)
        })
        $unverifiable.FeatureId | Should -BeNullOrEmpty -Because "Features with no verification story: $($unverifiable.FeatureId -join ', ')"
    }

    It 'exempts only the entries that carry no persistent desired state' {
        # Apps is a value-carrying parameter and CreateRestorePoint is a one-shot action,
        # so neither has a state to read back. Every other exemption is a coverage gap.
        $permittedExemptions = @('Apps', 'CreateRestorePoint')
        $exempt = @($script:features | Where-Object { $_.VerificationAdapter -eq 'NotApplicable' })
        $unexpected = @($exempt.FeatureId | Where-Object { $_ -notin $permittedExemptions })
        $unexpected | Should -BeNullOrEmpty -Because "Unexpected NotApplicable exemptions: $($unexpected -join ', ')"
    }

    It 'declares verification metadata for release custom modules' {
        $required = @(
            'EnableGamingMode',
            'EnableExtendedAIPurge',
            'EnableSecurityHardening',
            'EnableFirewallTelemetryBlock'
        )
        foreach ($featureId in $required) {
            $feature = $script:features | Where-Object FeatureId -eq $featureId
            $feature | Should -Not -BeNullOrEmpty
            $feature.VerificationAdapter | Should -Not -BeNullOrEmpty
            $feature.RequiresRestorePoint | Should -BeTrue
        }
    }

    It 'gives every feature a category that is defined' {
        # The GUI groups cards by category. A feature naming a category that does
        # not exist has no column to render in. A null category is allowed: those
        # are the CLI-only pseudo-features that are not shown as cards.
        $categoryNames = @($script:json.Categories.Name)
        $orphans = @($script:features | Where-Object { $_.Category -and $_.Category -notin $categoryNames } |
                ForEach-Object { "$($_.FeatureId) -> $($_.Category)" })
        $orphans | Should -BeNullOrEmpty -Because "features naming a category that is not defined: $($orphans -join '; ')"
    }

    It 'wires every UiGroup to real features and a real category' {
        # A combobox option maps to FeatureIds. If one names a feature that does
        # not exist, selecting that option applies nothing, silently. And the
        # group needs a category to render in, like any card.
        $featureIds = @($script:features.FeatureId)
        $categoryNames = @($script:json.Categories.Name)
        $problems = New-Object System.Collections.Generic.List[string]

        foreach ($group in @($script:json.UiGroups)) {
            if ($group.Category -notin $categoryNames) {
                $problems.Add("group $($group.GroupId) -> undefined category $($group.Category)")
            }
            foreach ($value in @($group.Values)) {
                foreach ($featureId in @($value.FeatureIds)) {
                    if ($featureId -notin $featureIds) {
                        $problems.Add("group $($group.GroupId) -> undefined feature $featureId")
                    }
                    elseif ($featureId -notin $script:entryParameterNames) {
                        $problems.Add("group $($group.GroupId) feature $featureId has no CLI parameter")
                    }
                }
            }
        }

        @($script:json.UiGroups).Count | Should -BeGreaterThan 0 -Because 'the config must actually define UI groups'
        $problems | Should -BeNullOrEmpty -Because "UiGroup wiring problems: $($problems -join '; ')"
    }
}
