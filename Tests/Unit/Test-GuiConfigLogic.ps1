#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for the pure config import/export and deployment-summary logic.
.DESCRIPTION
    Show-ConfigWindow.ps1 and MainWindow-Deployment.ps1 mix WPF dialog code with
    functions that only shape data: which categories a saved config offers, the
    human-readable deployment summary, the category detail strings, and parsing
    the saved app list. Those are covered here.

    The files declare WPF types on other functions' parameters, but PowerShell
    resolves those at call time, so the files dot-source and the pure functions
    run without WPF loaded and without a UI thread. Only the pure functions are
    called here.
#>

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
    . (Join-Path $repoRoot 'Scripts\GUI\Show-ConfigWindow.ps1')
    . (Join-Path $repoRoot 'Scripts\GUI\MainWindow-Deployment.ps1')
}

Describe 'Get-AvailableImportExportCategories' {
    It 'lists only the sections the config actually contains' {
        Get-AvailableImportExportCategories -Config ([PSCustomObject]@{ Apps = @('x') }) | Should -Be @('Applications')
        Get-AvailableImportExportCategories -Config ([PSCustomObject]@{ Tweaks = @('x') }) | Should -Be @('System Tweaks')
        Get-AvailableImportExportCategories -Config ([PSCustomObject]@{ Deployment = @{} }) | Should -Be @('Deployment Settings')
    }

    It 'lists all three in order when all are present' {
        $config = [PSCustomObject]@{ Apps = @('x'); Tweaks = @('y'); Deployment = @{} }
        Get-AvailableImportExportCategories -Config $config | Should -Be @('Applications', 'System Tweaks', 'Deployment Settings')
    }

    It 'lists nothing for an empty config' {
        @(Get-AvailableImportExportCategories -Config ([PSCustomObject]@{})).Count | Should -Be 0
    }
}

Describe 'Get-DeploymentCategoryDetailString' {
    It 'describes each user selection' {
        Get-DeploymentCategoryDetailString -DeploymentSettings @(@{ Name = 'UserSelectionIndex'; Value = 0 }) | Should -Be 'User: Current User'
        Get-DeploymentCategoryDetailString -DeploymentSettings @(@{ Name = 'UserSelectionIndex'; Value = 2 }) | Should -Be 'User: Sysprep'
    }

    It 'names the other user when one is given, and falls back when not' {
        Get-DeploymentCategoryDetailString -DeploymentSettings @(
            @{ Name = 'UserSelectionIndex'; Value = 1 }, @{ Name = 'OtherUsername'; Value = 'Jeff' }
        ) | Should -Be 'User: Jeff'
        Get-DeploymentCategoryDetailString -DeploymentSettings @(@{ Name = 'UserSelectionIndex'; Value = 1 }) | Should -Be 'User: Other User'
    }

    It 'puts user/scope on one line and options on the next' {
        $result = Get-DeploymentCategoryDetailString -DeploymentSettings @(
            @{ Name = 'UserSelectionIndex'; Value = 0 },
            @{ Name = 'AppRemovalScopeIndex'; Value = 0 },
            @{ Name = 'CreateRestorePoint'; Value = $true },
            @{ Name = 'RestartExplorer'; Value = $true }
        )
        $result | Should -Be "User: Current User, App Removal: All Users`nOptions: Restore Point, Restart Explorer"
    }

    It 'omits an option that is present but false' {
        $result = Get-DeploymentCategoryDetailString -DeploymentSettings @(
            @{ Name = 'CreateRestorePoint'; Value = $true },
            @{ Name = 'RestartExplorer'; Value = $false }
        )
        $result | Should -Be 'Options: Restore Point'
    }

    It 'falls back to a default line when nothing is set' {
        Get-DeploymentCategoryDetailString -DeploymentSettings @() | Should -Be 'Default deployment settings'
    }
}

Describe 'Build-CategoryDetails' {
    It 'pluralizes app and tweak counts and handles zero' {
        (Build-CategoryDetails -AppCount 0 -TweakCount 0)['Applications'] | Should -Be 'No apps selected'
        (Build-CategoryDetails -AppCount 1 -TweakCount 0)['Applications'] | Should -Be '1 app selected'
        (Build-CategoryDetails -AppCount 3 -TweakCount 0)['Applications'] | Should -Be '3 apps selected'
        (Build-CategoryDetails -AppCount 0 -TweakCount 1)['System Tweaks'] | Should -Be '1 tweak selected'
        (Build-CategoryDetails -AppCount 0 -TweakCount 5)['System Tweaks'] | Should -Be '5 tweaks selected'
    }

    It 'includes the deployment summary only when deployment settings are given' {
        (Build-CategoryDetails -AppCount 1 -TweakCount 1).ContainsKey('Deployment Settings') | Should -BeFalse
        $withDeploy = Build-CategoryDetails -AppCount 1 -TweakCount 1 -DeploymentSettings @(@{ Name = 'UserSelectionIndex'; Value = 2 })
        $withDeploy['Deployment Settings'] | Should -Be 'User: Sysprep'
    }
}

Describe 'Get-SavedAppIdsFromSettingsJson' {
    It 'parses a comma-separated string, trimming and dropping empties' {
        $json = [PSCustomObject]@{ Settings = @(@{ Name = 'Apps'; Value = 'App.One, App.Two ,, App.Three' }) }
        Get-SavedAppIdsFromSettingsJson -SettingsJson $json | Should -Be @('App.One', 'App.Two', 'App.Three')
    }

    It 'accepts an array value' {
        $json = [PSCustomObject]@{ Settings = @(@{ Name = 'Apps'; Value = @('App.One', 'App.Two') }) }
        Get-SavedAppIdsFromSettingsJson -SettingsJson $json | Should -Be @('App.One', 'App.Two')
    }

    It 'returns nothing when there is no Apps setting or no value' {
        Get-SavedAppIdsFromSettingsJson -SettingsJson ([PSCustomObject]@{ Settings = @(@{ Name = 'DisableTelemetry'; Value = $true }) }) | Should -BeNullOrEmpty
        Get-SavedAppIdsFromSettingsJson -SettingsJson ([PSCustomObject]@{ Settings = @(@{ Name = 'Apps'; Value = '' }) }) | Should -BeNullOrEmpty
        Get-SavedAppIdsFromSettingsJson -SettingsJson ([PSCustomObject]@{}) | Should -BeNullOrEmpty
    }
}
