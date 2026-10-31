<#
    .SYNOPSIS
        Creates the user data folders and brings over data from earlier versions.

    .DESCRIPTION
        Saved settings, logs and registry backups live in $script:UserDataPath
        (%LOCALAPPDATA%\Winnow). Earlier versions kept them in the script folder,
        and the old launcher reused %TEMP%\Winnow between runs. The first run with
        the new location copies LastUsedSettings.json and the registry backups
        from there, so they stay available in the GUI. Existing files are never
        overwritten and the old copies are left in place.
#>
function Initialize-WinnowUserData {
    param(
        [Parameter(Mandatory)]
        [string]$UserDataPath,
        [string[]]$LegacyPaths = @()
    )

    $configDir = Join-Path $UserDataPath 'Config'
    $backupsDir = Join-Path $UserDataPath 'Backups'
    foreach ($dir in @((Join-Path $UserDataPath 'Logs'), $configDir)) {
        if (-not (Test-Path -LiteralPath $dir)) {
            $null = New-Item -ItemType Directory -Path $dir -Force
        }
    }

    $resolvedUserDataPath = [System.IO.Path]::GetFullPath($UserDataPath).TrimEnd('\')
    foreach ($legacyPath in @($LegacyPaths | Where-Object { $_ -and (Test-Path -LiteralPath $_) })) {
        if ([System.IO.Path]::GetFullPath($legacyPath).TrimEnd('\') -ieq $resolvedUserDataPath) { continue }

        $settingsFile = Join-Path $legacyPath 'Config\LastUsedSettings.json'
        $targetSettings = Join-Path $configDir 'LastUsedSettings.json'
        if ((Test-Path -LiteralPath $settingsFile) -and -not (Test-Path -LiteralPath $targetSettings)) {
            Copy-Item -LiteralPath $settingsFile -Destination $targetSettings -ErrorAction SilentlyContinue
        }

        $legacyBackups = Join-Path $legacyPath 'Backups'
        if (Test-Path -LiteralPath $legacyBackups) {
            foreach ($backupFile in @(Get-ChildItem -LiteralPath $legacyBackups -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
                if (-not (Test-Path -LiteralPath $backupsDir)) {
                    $null = New-Item -ItemType Directory -Path $backupsDir -Force
                }
                $target = Join-Path $backupsDir $backupFile.Name
                if (-not (Test-Path -LiteralPath $target)) {
                    Copy-Item -LiteralPath $backupFile.FullName -Destination $target -ErrorAction SilentlyContinue
                }
            }
        }
    }
}
