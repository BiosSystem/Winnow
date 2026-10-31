#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for registry backup validation and the "key did not exist" restore.
.DESCRIPTION
    A backup file sits in a folder the user can write without elevation, and the
    restore runs elevated. These tests feed hand-made backups through the real
    Normalize-RegistryBackup with the real Features.json and .reg files:

    - a key snapshot needs an explicit Boolean Exists; a missing one used to read
      as false, which deletes the key on restore;
    - sub-keys are only accepted where the features capture sub-keys;
    - values Windows runs as a program (shell verbs, RunOnce, COM servers) must
      hold data Winnow itself writes, or be confirmed before restore;
    - "Exists = false" on a key a feature only writes values in removes those
      values, not the whole key tree.

    The last group writes to a throwaway HKCU key that each test creates and
    deletes; nothing else in the registry is touched.
#>

BeforeAll {
    $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
    . (Join-Path $script:repoRoot 'Scripts\Helpers\RegistryPathHelpers.ps1')
    . (Join-Path $script:repoRoot 'Scripts\Helpers\Get-RegFileOperations.ps1')
    . (Join-Path $script:repoRoot 'Scripts\Helpers\Test-TargetUserName.ps1')
    . (Join-Path $script:repoRoot 'Scripts\Helpers\GetFriendlyRegistryBackupTarget.ps1')
    . (Join-Path $script:repoRoot 'Scripts\Features\BackupRegistrySnapshotCapture.ps1')
    . (Join-Path $script:repoRoot 'Scripts\Features\RegistryBackupValidation.ps1')
    . (Join-Path $script:repoRoot 'Scripts\Features\RestoreRegistryBackup.ps1')
    . (Join-Path $script:repoRoot 'Scripts\Features\RestoreRegistryApplyState.ps1')

    function Resolve-UndoRegFilePath {
        param([string]$FileName)
        $undoSubPath = Join-Path 'Undo' $FileName
        if (Test-Path (Join-Path $script:RegfilesPath $undoSubPath)) { return $undoSubPath }
        return $FileName
    }

    $script:RegfilesPath = Join-Path $script:repoRoot 'Regfiles'
    $script:Params = @{}
    $script:Features = @{}
    $catalog = Get-Content -LiteralPath (Join-Path $script:repoRoot 'Config\Features.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($feature in $catalog.Features) { $script:Features[$feature.FeatureId] = $feature }

    $script:currentUserTarget = "CurrentUser:$env:USERNAME"

    function New-TestBackup {
        param(
            [string[]]$SelectedFeatures = @(),
            [string[]]$SelectedUndoFeatures = @(),
            [string]$Target = $script:currentUserTarget,
            [object[]]$RegistryKeys = @()
        )

        # Round-trip through JSON, as Load-RegistryBackupFromFile does.
        ([ordered]@{
            Version = '1.0'
            BackupType = 'RegistryState'
            Target = $Target
            SelectedFeatures = @($SelectedFeatures)
            SelectedUndoFeatures = @($SelectedUndoFeatures)
            RegistryKeys = @($RegistryKeys)
        } | ConvertTo-Json -Depth 25 | ConvertFrom-Json)
    }

    $script:gameBarCommandPath = 'HKEY_CLASSES_ROOT\ms-gamebar\shell\open\command'
}

Describe 'Registry backup snapshot shape' {
    BeforeEach { Mock Write-Error { } }

    It 'rejects a key snapshot without Exists instead of treating it as a deletion' {
        $backup = New-TestBackup -SelectedFeatures 'TaskbarAlignLeft' -RegistryKeys @(
            @{ Path = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Values = @() }
        )

        { Normalize-RegistryBackup -Backup $backup } | Should -Throw '*must set Exists to true or false*'
    }

    It 'rejects a key snapshot whose Exists is the text "false"' {
        $backup = New-TestBackup -SelectedFeatures 'TaskbarAlignLeft' -RegistryKeys @(
            @{ Path = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Exists = 'false'; Values = @() }
        )

        { Normalize-RegistryBackup -Backup $backup } | Should -Throw '*must set Exists to true or false*'
    }

    It 'rejects sub-keys under a key the features only write values in' {
        # Both paths are allowed on their own (TaskbarAlignLeft writes Advanced,
        # EnableEndTask writes Advanced\TaskbarDeveloperSettings). Nested, they made
        # the restore delete and rebuild all of Explorer\Advanced.
        $backup = New-TestBackup -SelectedFeatures 'TaskbarAlignLeft', 'EnableEndTask' -RegistryKeys @(
            @{
                Path = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
                Exists = $true
                Values = @()
                SubKeys = @(@{ Path = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings'; Exists = $true; Values = @() })
            }
        )

        { Normalize-RegistryBackup -Backup $backup } | Should -Throw
    }

    It 'rejects a value name containing a NUL character' {
        $backup = New-TestBackup -SelectedFeatures 'TaskbarAlignLeft' -RegistryKeys @(
            @{
                Path = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
                Exists = $true
                Values = @(@{ Name = "TaskbarAl$([char]0)x"; Exists = $true; Kind = 'DWord'; Data = 0 })
            }
        )

        { Normalize-RegistryBackup -Backup $backup } | Should -Throw
    }

    It 'accepts a backup Winnow writes for the same feature' {
        $backup = New-TestBackup -SelectedFeatures 'TaskbarAlignLeft' -RegistryKeys @(
            @{
                Path = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
                Exists = $true
                Values = @(@{ Name = 'TaskbarAl'; Exists = $true; Kind = 'DWord'; Data = 1 })
            }
        )

        $normalized = Normalize-RegistryBackup -Backup $backup
        @($normalized.RegistryKeys).Count | Should -Be 1
        @($normalized.UntrustedExecutableValues).Count | Should -Be 0
    }
}

Describe 'Values Windows runs as a program' {
    BeforeEach { Mock Write-Error { } }

    It 'flags a shell command that differs from what Winnow writes' {
        $backup = New-TestBackup -SelectedFeatures 'DisableGameBarIntegration' -RegistryKeys @(
            @{ Path = $script:gameBarCommandPath; Exists = $true; Values = @(@{ Name = ''; Exists = $true; Kind = 'String'; Data = 'C:\Users\Public\payload.exe' }) }
        )

        $normalized = Normalize-RegistryBackup -Backup $backup
        @($normalized.UntrustedExecutableValues).Count | Should -Be 1
        $normalized.UntrustedExecutableValues[0] | Should -BeLike '*payload.exe*'
        $normalized.ExecutableValuesConfirmed | Should -BeFalse
    }

    It 'refuses to restore an unconfirmed program-start value' {
        $backup = New-TestBackup -SelectedFeatures 'DisableGameBarIntegration' -RegistryKeys @(
            @{ Path = $script:gameBarCommandPath; Exists = $true; Values = @(@{ Name = ''; Exists = $true; Kind = 'String'; Data = 'C:\Users\Public\payload.exe' }) }
        )
        $normalized = Normalize-RegistryBackup -Backup $backup
        Mock Restore-RegistryKeySnapshot { throw 'must not be reached' }

        { Restore-RegistryBackupState -Backup $normalized } | Should -Throw '*can start a program*'
        Should -Invoke Restore-RegistryKeySnapshot -Times 0
    }

    It 'accepts the command Winnow writes there itself' {
        $backup = New-TestBackup -SelectedFeatures 'DisableGameBarIntegration' -RegistryKeys @(
            @{ Path = $script:gameBarCommandPath; Exists = $true; Values = @(@{ Name = ''; Exists = $true; Kind = 'String'; Data = '%SystemRoot%/System32/systray.exe' }) }
        )

        @((Normalize-RegistryBackup -Backup $backup).UntrustedExecutableValues).Count | Should -Be 0
    }

    It 'rejects binary data in a program-start value' {
        $backup = New-TestBackup -SelectedFeatures 'DisableGameBarIntegration' -RegistryKeys @(
            @{ Path = $script:gameBarCommandPath; Exists = $true; Values = @(@{ Name = ''; Exists = $true; Kind = 'Binary'; Data = @(1, 2) }) }
        )

        { Normalize-RegistryBackup -Backup $backup } | Should -Throw
    }

    It 'flags a new-user RunOnce command that is not the one Winnow writes' {
        $runOncePath = 'hkey_users\default\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
        $backup = New-TestBackup -SelectedFeatures 'DisableAnimations' -Target 'DefaultUserProfile' -RegistryKeys @(
            @{ Path = $runOncePath; Exists = $true; Values = @(@{ Name = 'DisableAnimations'; Exists = $true; Kind = 'String'; Data = 'cmd /c whoami' }) }
        )

        $flagged = @((Normalize-RegistryBackup -Backup $backup).UntrustedExecutableValues | Where-Object { $_ })
        $flagged.Count | Should -Be 1
        $flagged[0] | Should -BeLike '*cmd /c whoami*'
    }

    It 'trusts program-start values when the backup comes from this run''s memory' {
        $backup = New-TestBackup -SelectedFeatures 'DisableGameBarIntegration' -RegistryKeys @(
            @{ Path = $script:gameBarCommandPath; Exists = $true; Values = @(@{ Name = ''; Exists = $true; Kind = 'String'; Data = 'C:\Program Files\Vendor\bar.exe' }) }
        )

        $normalized = Normalize-RegistryBackup -Backup $backup -TrustExecutableValues
        @($normalized.UntrustedExecutableValues).Count | Should -Be 0
        $normalized.ExecutableValuesConfirmed | Should -BeTrue
    }
}

Describe 'Deletion scope for keys that did not exist' {
    BeforeEach { Mock Write-Error { } }

    It 'limits a key the feature only writes values in to those values' {
        $backup = New-TestBackup -SelectedFeatures 'TaskbarAlignLeft' -RegistryKeys @(
            @{ Path = 'HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Exists = $false; Values = @() }
        )

        $snapshot = @((Normalize-RegistryBackup -Backup $backup).RegistryKeys)[0]
        $snapshot.DeleteScope | Should -Be 'Values'
        @($snapshot.DeleteValueNames) | Should -Be @('TaskbarAl')
    }

    It 'keeps whole-tree deletion for a key the feature deletes outright' {
        $backup = New-TestBackup -SelectedUndoFeatures 'RevertContextMenu' -RegistryKeys @(
            @{ Path = 'HKEY_CURRENT_USER\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'; Exists = $false; Values = @() }
        )

        @((Normalize-RegistryBackup -Backup $backup).RegistryKeys)[0].DeleteScope | Should -Be 'Tree'
    }
}

Describe 'Restoring a key that did not exist' {
    BeforeEach {
        $script:scratchSubKey = "Software\WinnowRestoreTest-$([guid]::NewGuid().ToString('N'))"
        $script:scratchPath = "HKEY_CURRENT_USER\$script:scratchSubKey"
    }

    AfterEach {
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($script:scratchSubKey, $false)
    }

    It 'removes only the feature''s value and keeps everything else in the key' {
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($script:scratchSubKey)
        $key.SetValue('FeatureValue', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.SetValue('Unrelated', 'keep me')
        $null = $key.CreateSubKey('Child')
        $key.Close()

        Restore-RegistryKeySnapshot -Snapshot ([PSCustomObject]@{
            Path = $script:scratchPath; Exists = $false; Values = @(); SubKeys = @()
            DeleteScope = 'Values'; DeleteValueNames = @('FeatureValue')
        })

        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:scratchSubKey)
        $key | Should -Not -BeNullOrEmpty
        $key.GetValue('FeatureValue') | Should -BeNullOrEmpty
        $key.GetValue('Unrelated') | Should -Be 'keep me'
        @($key.GetSubKeyNames()) | Should -Contain 'Child'
        $key.Close()
    }

    It 'removes the key once the feature''s values were the only thing in it' {
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($script:scratchSubKey)
        $key.SetValue('FeatureValue', 1, [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.Close()

        Restore-RegistryKeySnapshot -Snapshot ([PSCustomObject]@{
            Path = $script:scratchPath; Exists = $false; Values = @(); SubKeys = @()
            DeleteScope = 'Values'; DeleteValueNames = @('FeatureValue')
        })

        [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:scratchSubKey) | Should -BeNullOrEmpty
    }
}
