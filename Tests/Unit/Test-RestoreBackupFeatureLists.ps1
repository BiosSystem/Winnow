#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for the restore-backup dialog's feature-list logic.
.DESCRIPTION
    RestoreBackupDialogFeatureLists.ps1 decides, from a saved backup, which
    features the restore dialog shows and which of them can be reverted
    automatically (they have an apply .reg file) versus by hand. The functions
    are pure: they take a Features hashtable and a backup object and return data,
    no WPF. They ran without any test until now.
#>

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
    . (Join-Path $repoRoot 'Scripts\GUI\RestoreBackupDialogFeatureLists.ps1')

    # A small stand-in for the Features.json catalog. A feature is auto-revertible
    # when it has a RegistryKey and is shown in the overview when it has a Category.
    $script:features = @{
        'DisableTelemetry'        = [PSCustomObject]@{ Label = 'Disable telemetry'; RegistryKey = 'Disable_Telemetry.reg'; Category = 'Privacy & Suggested Content' }
        'EnableGamingMode'        = [PSCustomObject]@{ Label = 'Enable gaming mode'; RegistryKey = $null; Category = 'Gaming' }
        'CreateRestorePoint'      = [PSCustomObject]@{ Label = 'Create restore point'; RegistryKey = $null; Category = $null }
    }
}

Describe 'Restore dialog feature classification' {

    It 'treats a feature with a RegistryKey as auto-revertible' {
        Test-RestoreDialogFeatureCanAutoRevert -FeatureId 'DisableTelemetry' -Features $script:features | Should -BeTrue
    }

    It 'treats a custom feature with no RegistryKey as not auto-revertible' {
        Test-RestoreDialogFeatureCanAutoRevert -FeatureId 'EnableGamingMode' -Features $script:features | Should -BeFalse
    }

    It 'treats an unknown feature as not auto-revertible' {
        Test-RestoreDialogFeatureCanAutoRevert -FeatureId 'NoSuchFeature' -Features $script:features | Should -BeFalse
    }

    It 'shows a categorized feature in the overview and hides a category-less one' {
        Test-RestoreDialogFeatureVisibleInOverview -FeatureId 'DisableTelemetry' -Features $script:features | Should -BeTrue
        Test-RestoreDialogFeatureVisibleInOverview -FeatureId 'CreateRestorePoint' -Features $script:features | Should -BeFalse
    }

    It 'uses the catalog label, and falls back to the id then to a placeholder' {
        Get-RestoreDialogFeatureDisplayLabel -FeatureId 'DisableTelemetry' -Features $script:features | Should -Be 'Disable telemetry'
        Get-RestoreDialogFeatureDisplayLabel -FeatureId 'NoSuchFeature' -Features $script:features | Should -Be 'NoSuchFeature'
        Get-RestoreDialogFeatureDisplayLabel -FeatureId '' -Features $script:features | Should -Be 'Unknown feature'
    }
}

Describe 'Selected feature IDs from a backup' {

    It 'returns forward feature ids, de-duplicated case-insensitively' {
        $backup = [PSCustomObject]@{ SelectedFeatures = @('DisableTelemetry', 'disabletelemetry', 'EnableGamingMode', '', $null) }
        $ids = Get-SelectedForwardFeatureIdsFromBackup -SelectedBackup $backup
        $ids | Should -Be @('DisableTelemetry', 'EnableGamingMode')
    }

    It 'merges forward and undo lists without duplicates' {
        $backup = [PSCustomObject]@{
            SelectedFeatures     = @('DisableTelemetry', 'EnableGamingMode')
            SelectedUndoFeatures = @('EnableGamingMode', 'DisableBing')
        }
        $ids = Get-SelectedFeatureIdsFromBackup -SelectedBackup $backup
        $ids | Should -Be @('DisableTelemetry', 'EnableGamingMode', 'DisableBing')
    }

    It 'returns nothing for a backup that selected no features' {
        $backup = [PSCustomObject]@{ SelectedFeatures = @(); SelectedUndoFeatures = @() }
        @(Get-SelectedFeatureIdsFromBackup -SelectedBackup $backup).Count | Should -Be 0
    }
}

Describe 'Get-RestoreBackupFeatureLists' {

    It 'splits visible features into auto-revertible and manual, and drops hidden ones' {
        $result = Get-RestoreBackupFeatureLists -SelectedFeatureIds @('DisableTelemetry', 'EnableGamingMode', 'CreateRestorePoint', 'NoSuchFeature') -Features $script:features

        # DisableTelemetry has a reg file -> revertible; EnableGamingMode is custom
        # -> manual; CreateRestorePoint has no category -> hidden; the unknown id -> hidden.
        @($result.Revertible).Count | Should -Be 1
        $result.Revertible[0].DisplayText | Should -Be '- Disable telemetry'
        @($result.NonRevertible).Count | Should -Be 1
        $result.NonRevertible[0].DisplayText | Should -Be '- Enable gaming mode'
    }

    It 'returns two empty lists when nothing is selected' {
        $result = Get-RestoreBackupFeatureLists -SelectedFeatureIds @() -Features $script:features
        @($result.Revertible).Count | Should -Be 0
        @($result.NonRevertible).Count | Should -Be 0
    }
}
