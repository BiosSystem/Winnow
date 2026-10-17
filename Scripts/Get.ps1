param (
    [switch]$Verbose,
    [switch]$WhatIf,
    [switch]$Dev,
    [switch]$CLI,
    [switch]$Silent,
    [switch]$Sysprep,
    [string]$LogPath,
    [string]$User,
    [Alias('NoRestartExplorer')]
    [switch]$SkipExplorerRestart,
    [switch]$CreateRestorePoint,
    [switch]$SkipRegistryBackup,
    [switch]$NoAutoRollback,
    [string[]]$Undo,
    [switch]$RunDefaults,
    [switch]$RunDefaultsLite,
    [switch]$RunSavedSettings,
    [string]$Config,
    [string]$Apps,
    [string]$AppRemovalTarget,
    [switch]$RemoveApps,
    [switch]$RemoveGamingApps,
    [switch]$RemoveHPApps,
    [switch]$ForceRemoveEdge,
    [switch]$DisableDVR,
    [switch]$DisableGameBarIntegration,
    [switch]$EnableWindowsSandbox,
    [switch]$EnableWindowsSubsystemForLinux,
    [switch]$DisableTelemetry,
    [switch]$DisableTelemetryServices,
    [switch]$DisableAdvertisingID,
    [switch]$DisableVoiceActivation,
    [switch]$DisableSearchHistory,
    [switch]$DisableFastStartup,
    [switch]$DisableBitlockerAutoEncryption,
    [switch]$DisableModernStandbyNetworking,
    [switch]$DisableStorageSense,
    [switch]$DisableUpdateASAP,
    [switch]$PreventUpdateAutoReboot,
    [switch]$DisableDeliveryOptimization,
    [switch]$DisableWUDriverSearch,
    [switch]$DisableFeatureUpdates,
    [switch]$DisableBing,
    [switch]$DisableStoreSearchSuggestions,
    [switch]$DisableDesktopSpotlight,
    [switch]$DisableLockscreenTips,
    [switch]$DisableSuggestions,
    [switch]$DisableLocationServices,
    [switch]$DisableFindMyDevice,
    [switch]$DisableEdgeAds,
    [switch]$DisableBraveBloat,
    [switch]$DisableSettings365Ads,
    [switch]$DisableSettingsHome,
    [switch]$ShowHiddenFolders,
    [switch]$ShowKnownFileExt,
    [switch]$HideDupliDrive,
    [switch]$EnableDarkMode,
    [switch]$DisableTransparency,
    [switch]$DisableAnimations,
    [switch]$TaskbarAlignLeft,
    [switch]$CombineTaskbarAlways, [switch]$CombineTaskbarWhenFull, [switch]$CombineTaskbarNever,
    [switch]$CombineMMTaskbarAlways, [switch]$CombineMMTaskbarWhenFull, [switch]$CombineMMTaskbarNever,
    [switch]$MMTaskbarModeAll, [switch]$MMTaskbarModeMainActive, [switch]$MMTaskbarModeActive,
    [switch]$HideSearchTb, [switch]$ShowSearchIconTb, [switch]$ShowSearchLabelTb, [switch]$ShowSearchBoxTb,
    [switch]$HideTaskview,
    [switch]$DisableStartRecommended,
    [switch]$DisableStartAllApps, [switch]$StartAllAppsCategory, [switch]$StartAllAppsGrid, [switch]$StartAllAppsList,
    [switch]$DisableStartPhoneLink,
    [switch]$DisableCopilot,
    [switch]$DisableRecall,
    [switch]$DisableClickToDo,
    [switch]$DisableAISvcAutoStart,
    [switch]$DisablePaintAI,
    [switch]$DisablePhotosGenerativeFill,
    [switch]$DisableNotepadAI,
    [switch]$DisableEdgeAI,
    [switch]$DisableChromeAI,
    [switch]$DisableSuggestedClipboardActions,
    [switch]$DisableM365AutoInstall,
    [switch]$DisableNarratorAIVoices,
    [switch]$DisableSearchHighlights,
    [switch]$DisableWidgets,
    [switch]$HideChat,
    [switch]$EnableEndTask,
    [switch]$EnableLastActiveClick,
    [switch]$ClearStart,
    [string]$ReplaceStart,
    [switch]$ClearStartAllUsers,
    [string]$ReplaceStartAllUsers,
    [switch]$RevertContextMenu,
    [switch]$DisableDragTray,
    [switch]$DisableMouseAcceleration,
    [switch]$DisableStickyKeys,
    [switch]$DisableWindowSnapping,
    [switch]$DisableSnapAssist,
    [switch]$DisableSnapLayouts,
    [switch]$HideTabsInAltTab, [switch]$Show3TabsInAltTab, [switch]$Show5TabsInAltTab, [switch]$Show20TabsInAltTab,
    [switch]$HideHome,
    [switch]$HideGallery,
    [switch]$ExplorerToHome,
    [switch]$ExplorerToThisPC,
    [switch]$ExplorerToDownloads,
    [switch]$ExplorerToOneDrive,
    [switch]$AddFoldersToThisPC,
    [switch]$HideOnedrive,
    [switch]$Hide3dObjects,
    [switch]$HideMusic,
    [switch]$HideIncludeInLibrary,
    [switch]$HideGiveAccessTo,
    [switch]$HideShare,
    [switch]$ShowDriveLettersFirst,
    [switch]$ShowDriveLettersLast,
    [switch]$ShowNetworkDriveLettersFirst,
    [switch]$HideDriveLetters,
    [switch]$EnableGamingMode,
    [switch]$EnablePerformanceTweaks,
    [switch]$DisableWindowsAds,
    [switch]$EnableExtendedAIPurge,
    [switch]$EnableSecurityHardening,
    [switch]$EnableCompetitiveGaming,
    [switch]$DisableMemoryIntegrity,
    [switch]$DisableSettingsAds,
    [switch]$DisableWidgetsDeep,
    [switch]$SkipUpdateCheck,
    [string]$Preset,
    [switch]$DryRun,
    [switch]$Verify,
    [string]$VerifyProfile,
    [switch]$VerifyWatchdog,
    [switch]$InstallSoftware,
    [string[]]$SoftwareList,
    [switch]$GenerateUnattend,
    [string]$UnattendOutPath,
    [switch]$EnableFirewallTelemetryBlock,
    [switch]$EnableUpdateWatchdog,
    [switch]$AddDefenderGamingExclusions,
    [switch]$RemoveDefenderGamingExclusions
)

# Show error if current powershell environment does not have LanguageMode set to FullLanguage 
if ($ExecutionContext.SessionState.LanguageMode -ne "FullLanguage") {
   Write-Host "Error: Winnow is unable to run on your system. PowerShell execution is restricted by security policies" -ForegroundColor Red
   Write-Output ""
   Write-Output "Press enter to exit..."
   Read-Host | Out-Null
   Exit
}

Clear-Host
Write-Output "-------------------------------------------------------------------------------------------"
Write-Output " Winnow Script"
Write-Output "-------------------------------------------------------------------------------------------"

$tempRootPath = $env:TEMP
$tempWorkPath = Join-Path $tempRootPath 'Winnow'
$tempArchivePath = Join-Path $tempRootPath 'Winnow.zip'

Write-Output "> Downloading Winnow..."

# Download Winnow from GitHub as a zip archive.
try {
    if ($Dev) {
        $sourceUri = "https://github.com/BiosSystem/Winnow/archive/refs/heads/master.zip"
    } else {
        $sourceUri = (Invoke-RestMethod https://api.github.com/repos/BiosSystem/Winnow/releases/latest).zipball_url
    }
    Invoke-RestMethod $sourceUri -OutFile $tempArchivePath
}
catch {
    Write-Host "Error: Unable to fetch required files from GitHub. Please check your internet connection and try again." -ForegroundColor Red
    Write-Output ""
    Write-Output "Press enter to exit..."
    Read-Host | Out-Null
    Exit
}

# Remove old script folder if it exists, but keep configs, logs and backups
if (Test-Path $tempWorkPath) {
    Write-Output ""
    Write-Output "> Cleaning up old script files..."

    Get-ChildItem -Path $tempWorkPath -Exclude Config,Logs,Backups | Remove-Item -Recurse -Force
}

$configDir = Join-Path $tempWorkPath 'Config'
$backupDir = Join-Path $tempWorkPath 'ConfigOld'

# Temporarily move existing config files if they exist to prevent them from being overwritten by the new script files, will be moved back after the new script is unpacked
if (Test-Path "$configDir") {
    Write-Output ""
    Write-Output "> Backing up existing config files..."

    New-Item -ItemType Directory -Path "$backupDir" -Force | Out-Null

    $filesToKeep = @(
        'LastUsedSettings.json'
    )

    Get-ChildItem -Path "$configDir" -Recurse | Where-Object { $_.Name -in $filesToKeep } | Move-Item -Destination "$backupDir"

    Remove-Item "$configDir" -Recurse -Force
}

Write-Output ""
Write-Output "> Unpacking..."

# Unzip archive to Winnow folder
Expand-Archive $tempArchivePath $tempWorkPath

# Remove archive
Remove-Item $tempArchivePath

# Move files
Get-ChildItem -Path (Join-Path $tempWorkPath '*Winnow-*') -Recurse | Move-Item -Destination $tempWorkPath

# Add existing config files back to Config folder
if (Test-Path "$backupDir") {
    if (-not (Test-Path "$configDir")) {
        New-Item -ItemType Directory -Path "$configDir" -Force | Out-Null
    }

    Write-Output ""
    Write-Output "> Restoring existing config files..."

    Get-ChildItem -Path "$backupDir" -Recurse | Move-Item -Destination "$configDir"
    Remove-Item "$backupDir" -Recurse -Force
}

function Format-LauncherArg {
    param([AllowEmptyString()][string]$Value)

    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"{0}"' -f $escaped
}

# Make a safely quoted argument list for the script. Exclude -Dev because it only affects this launcher.
$arguments = @()
foreach ($boundParameter in $PSBoundParameters.GetEnumerator() | Where-Object { $_.Key -ne 'Dev' }) {
    $arguments += "-$($boundParameter.Key)"
    if ($boundParameter.Value -is [System.Management.Automation.SwitchParameter] -or $boundParameter.Value -is [bool]) {
        continue
    }

    $argumentValue = if ($boundParameter.Value -is [array]) {
        $boundParameter.Value -join ','
    }
    else {
        [string]$boundParameter.Value
    }
    $arguments += Format-LauncherArg $argumentValue
}

Write-Output ""
Write-Output "> Launching Winnow..."

# Minimize the powershell window when no parameters are provided
if ($arguments.Count -eq 0) {
    $windowStyle = "Minimized"
}
else {
    $windowStyle = "Normal"
}

# Remove Powershell 7 modules from path to prevent module loading issues in the script
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $NewPSModulePath = $env:PSModulePath -split ';' | Where-Object -FilterScript { $_ -like '*WindowsPowerShell*' }
    $env:PSModulePath = $NewPSModulePath -join ';'
}

# Run Winnow script with the provided arguments
$debloatScriptPath = Join-Path $tempWorkPath 'Winnow.ps1'
$launchArguments = @(
    '-NoProfile'
    '-ExecutionPolicy'
    'Bypass'
    '-File'
    (Format-LauncherArg $debloatScriptPath)
) + $arguments

$exitCode = 1
try {
    $debloatProcess = Start-Process powershell.exe -WindowStyle $windowStyle -PassThru -ArgumentList $launchArguments -Verb RunAs -ErrorAction Stop
}
catch {
    Write-Host "Error: Unable to launch Winnow with administrator privileges. $($_.Exception.Message)" -ForegroundColor Red
    $debloatProcess = $null
}

# Wait for the process to finish before continuing
if ($null -ne $debloatProcess) {
    $debloatProcess.WaitForExit()
    $exitCode = $debloatProcess.ExitCode
}

# Remove all remaining script files, except for configs, logs and backups
if (Test-Path $tempWorkPath) {
    Write-Output ""
    Write-Output "> Cleaning up..."

    # Cleanup, remove Winnow directory
    Get-ChildItem -Path $tempWorkPath -Exclude Config,Logs,Backups | Remove-Item -Recurse -Force
}

Write-Output ""
Exit $exitCode

