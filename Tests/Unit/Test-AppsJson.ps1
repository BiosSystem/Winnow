#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for Apps.json structural integrity.
.DESCRIPTION
    Validates that every entry in Apps.json has required fields, no duplicate
    AppIds, valid RemovalMethod enum values, and that all Preset AppIds
    reference entries that exist in the Apps array.
#>

Describe 'Apps.json' {

    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
        $configPath = Join-Path $repoRoot 'Config\Apps.json'
        $script:json    = Get-Content $configPath -Raw | ConvertFrom-Json
        $script:apps    = $script:json.Apps
        $script:presets = $script:json.Presets
        $script:validMethods = @('Appx', 'WinGet', 'ForceRemoveEdge')
    }

    It 'parses as valid JSON' {
        $script:apps | Should -Not -BeNullOrEmpty
    }

    It 'has no duplicate AppIds' {
        $ids   = $script:apps | ForEach-Object { $_.AppId }
        $dupes = $ids | Group-Object | Where-Object { $_.Count -gt 1 } | Select-Object -ExpandProperty Name
        $dupes | Should -BeNullOrEmpty -Because "Duplicate AppIds: $($dupes -join ', ')"
    }

    It 'every entry has a non-empty FriendlyName' {
        $missing = $script:apps | Where-Object { [string]::IsNullOrWhiteSpace($_.FriendlyName) }
        $missing.Count | Should -Be 0
    }

    It 'every entry has a non-empty AppId' {
        $missing = $script:apps | Where-Object { [string]::IsNullOrWhiteSpace($_.AppId) }
        $missing.Count | Should -Be 0
    }

    It 'every entry has a valid RemovalMethod' {
        $invalid = $script:apps | Where-Object { $script:validMethods -notcontains $_.RemovalMethod }
        $invalid | ForEach-Object { $_.FriendlyName } | Should -BeNullOrEmpty -Because (
            "Invalid RemovalMethod values found: $($invalid.FriendlyName -join ', ')"
        )
    }

    It 'every entry has a boolean SelectedByDefault' {
        $invalid = $script:apps | Where-Object { $_.SelectedByDefault -isnot [bool] }
        $invalid.Count | Should -Be 0
    }

    It 'all Preset AppIds exist in the Apps array' {
        $knownIds = $script:apps | ForEach-Object { $_.AppId }
        $broken   = @()
        foreach ($preset in $script:presets) {
            foreach ($id in $preset.AppIds) {
                if ($knownIds -notcontains $id) {
                    $broken += "$($preset.Name): $id"
                }
            }
        }
        $broken | Should -BeNullOrEmpty -Because "Preset references unknown AppIds: $($broken -join '; ')"
    }

    It 'removes the ASUS apps by their published package names' {
        # B9ECED6F.MyASUS and B9ECED6F.ASUSArmouryCrate match no installed package;
        # they stay second so older saved selections still resolve.
        $firstIds = @($script:apps | ForEach-Object { @($_.AppId)[0] })
        $firstIds | Should -Contain 'B9ECED6F.ASUSPCAssistant'
        $firstIds | Should -Contain 'B9ECED6F.ArmouryCrate'
    }
}
