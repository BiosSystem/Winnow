<#
.SYNOPSIS
    Winnow - The Ultimate Windows Debloater
.DESCRIPTION
    Lightweight PowerShell script to remove bloatware, disable telemetry,
    purge AI/Copilot integrations, and reclaim your Windows experience.
    Created by Bios-System | https://github.com/BiosSystem/Winnow
.VERSION
    4.2.0
#>
[CmdletBinding(SupportsShouldProcess)]
param (
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
    [switch]$DisableSearchHighlights,
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
    [switch]$DisableSuggestedClipboardActions,
    [switch]$DisableM365AutoInstall,
    [switch]$DisableNarratorAIVoices,
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
    # --- Winnow Extended Features (Bios-System) ---
    [switch]$EnableGamingMode,
    [switch]$EnablePerformanceTweaks,
    [switch]$DisableWindowsAds,
    [switch]$EnableExtendedAIPurge,
    [switch]$EnableSecurityHardening,
    # --- Winnow v2.2.0 Features (Bios-System) ---
    [switch]$EnableCompetitiveGaming,
    [switch]$DisableMemoryIntegrity,
    [switch]$DisableSettingsAds,
    [switch]$DisableWidgetsDeep,
    [switch]$SkipUpdateCheck,
    # --- Winnow v2.3.0 & v2.4.0 Features (Bios-System) ---
    [string]$Preset,
    [switch]$DryRun,
    [switch]$Verify,
    [string]$VerifyProfile,
    [switch]$VerifyWatchdog,
    [switch]$InstallSoftware,
    [string[]]$SoftwareList,
    [switch]$GenerateUnattend,
    [string]$UnattendOutPath = "C:\autounattend.xml",
    # --- Winnow v3.0.0 Features (Bios-System) ---
    [switch]$EnableFirewallTelemetryBlock,
    [switch]$EnableUpdateWatchdog,
    [switch]$AddDefenderGamingExclusions
)

if ($PSVersionTable.PSEdition -eq 'Core') {
    Write-Host "Winnow requires Windows PowerShell 5.1, but it is running under PowerShell $($PSVersionTable.PSVersion)." -ForegroundColor Red
    Write-Host "App removal and system restore points depend on modules that are unavailable in PowerShell 7." -ForegroundColor Red
    Write-Host "Run Winnow with powershell.exe." -ForegroundColor Yellow
    exit 1
}

Set-Variable -Name 'WINNOW_VERSION' -Value '4.2.0' -Option Constant

# Call Helper Scripts
. (Join-Path $PSScriptRoot 'Scripts\Helpers\Ensure-Admin.ps1') -OriginalCommandPath $PSCommandPath -OriginalBoundParameters $PSBoundParameters -OriginalUnboundArguments $MyInvocation.UnboundArguments

# Ensure-Admin is dot-sourced and cannot terminate this script itself, so the
# elevation outcome has to be acted on here. Anything other than 'Elevated'
# means the run must not continue in this process.
if ($script:ElevationOutcome -ne 'Elevated') {
    # 'Relaunched' handed the run to an elevated child, which is not a failure.
    if ($script:ElevationOutcome -eq 'Relaunched') {
        exit 0
    }

    exit 1
}

. (Join-Path $PSScriptRoot 'Scripts\Helpers\Initialize-Environment.ps1')

# Log script output to 'Winnow.log' at the specified path
if ($LogPath -and (Test-Path $LogPath)) {
    Start-Transcript -Path (Join-Path $LogPath 'Winnow.log') -Append -IncludeInvocationHeader -Force | Out-Null
}
else {
    Start-Transcript -Path $script:DefaultLogPath -Append -IncludeInvocationHeader -Force | Out-Null
}

# Remove Mark-of-the-Web only from marked PowerShell source files when Group Policy
# overrides the process execution policy. Leave all other downloaded files unchanged.
if (-not $WhatIfPreference) {
    $gpoExecutionPolicySet = (Get-ExecutionPolicy -Scope MachinePolicy) -ne 'Undefined' -or
        (Get-ExecutionPolicy -Scope UserPolicy) -ne 'Undefined'

    if ($gpoExecutionPolicySet) {
        $markedScriptFiles = @(Get-ChildItem -LiteralPath $scriptsPath -Recurse -File |
            Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' } |
            Where-Object {
                Get-Item -LiteralPath $_.FullName -Stream * -ErrorAction SilentlyContinue |
                    Where-Object { $_.Stream -eq 'Zone.Identifier' }
            })

        if ($markedScriptFiles.Count -gt 0) {
            Write-Host "Unblocking $($markedScriptFiles.Count) PowerShell file(s)..."
            $unblockErrors = @()
            $markedScriptFiles | Unblock-File -ErrorAction SilentlyContinue -ErrorVariable +unblockErrors
            if ($unblockErrors.Count -gt 0) {
                Write-Warning "Failed to unblock $($unblockErrors.Count) PowerShell file(s)."
            }
        }
    }
}

# Check if the device is domain-joined and warn the user (Group Policy may override changes)
try {
    $computerSystem = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($null -ne $computerSystem -and $computerSystem.PartOfDomain) {
        Write-Warning "This machine is domain-joined. Group Policy may override changes made by Winnow."
    }
}
catch { }

# Check if script has all required files
if (-not ((Test-Path $script:DefaultSettingsFilePath) -and (Test-Path $script:AppsListFilePath) -and (Test-Path $script:RegfilesPath) -and (Test-Path $script:AssetsPath) -and (Test-Path $script:AppSelectionSchema) -and (Test-Path $script:ApplyChangesWindowSchema) -and (Test-Path $script:SharedStylesSchema) -and (Test-Path $script:BubbleHintSchema) -and (Test-Path $script:RestoreBackupWindowSchema) -and (Test-Path $script:FeaturesFilePath))) {
    Write-Error "Winnow is unable to find required files, please ensure all script files are present"
    Write-Output ""
    Write-Output "Press any key to exit..."
    $null = [System.Console]::ReadKey()
    Exit 1
}

# Localization. Sourced here because the feature load below overlays
# translated text, which needs both of these already defined.
. "$PSScriptRoot/Scripts/FileIO/LoadJsonFile.ps1"
. "$PSScriptRoot/Scripts/FileIO/LoadLanguageFile.ps1"
. "$PSScriptRoot/Scripts/FileIO/LoadPreset.ps1"

# Load feature info from file
$script:Features = @{}
try {
    $featuresData = Get-Content -Path $script:FeaturesFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($feature in $featuresData.Features) {
        if ([string]::IsNullOrWhiteSpace([string]$feature.FeatureId) -or [string]::IsNullOrWhiteSpace([string]$feature.Label) -or [string]::IsNullOrWhiteSpace([string]$feature.ApplyText)) {
            Write-Warning "Feature '$($feature.FeatureId)' is missing a FeatureId, Label, or ApplyText in Features.json and will be skipped."
            continue
        }
        $script:Features[$feature.FeatureId] = $feature
    }

    # Overlay localized text onto the loaded features. A missing or partial
    # catalogue is not fatal: unresolved strings keep their English value.
    # UiGroups declares which switches are mutually exclusive. Presets are
    # validated against it.
    $script:FeatureUiGroups = @($featuresData.UiGroups)
    $script:Language = Import-LanguageFile
    $null = Update-FeatureTextFromLanguage
}
catch {
    Write-Error "Failed to load feature info from Features.json file"
    Write-Output ""
    Write-Output "Press any key to exit..."
    $null = [System.Console]::ReadKey()
    Exit 1
}

# Check if WinGet is installed & if it is, check if the version is at least v1.4
try {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        $script:WingetInstalled = $true
    }
    else {
        $script:WingetInstalled = $false
    }
}
catch {
    Write-Error "Unable to determine if WinGet is installed, winget command failed: $_"
    $script:WingetInstalled = $false
}

# Show WinGet warning that requires user confirmation, Suppress confirmation if Silent parameter was passed
if (-not $script:WingetInstalled -and -not $Silent) {
    Write-Warning "WinGet is not installed or outdated, this may prevent Winnow from removing certain apps"
    Write-Output ""
    Write-Output "Press any key to continue anyway..."
    $null = [System.Console]::ReadKey()
}



##################################################################################################################
#                                                                                                                #
#                                                FUNCTION IMPORTS                                                #
#                                                                                                                #
##################################################################################################################

# App removal functions
. "$PSScriptRoot/Scripts/AppRemoval/ForceRemoveEdge.ps1"
. "$PSScriptRoot/Scripts/AppRemoval/RemoveApps.ps1"
. "$PSScriptRoot/Scripts/AppRemoval/GetInstalledAppsViaWinget.ps1"
. "$PSScriptRoot/Scripts/AppRemoval/Test-AppInWingetList.ps1"

# CLI functions
. "$PSScriptRoot/Scripts/CLI/AwaitKeyToExit.ps1"
. "$PSScriptRoot/Scripts/CLI/ShowCLILastUsedSettings.ps1"  
. "$PSScriptRoot/Scripts/CLI/ShowCLIDefaultModeAppRemovalOptions.ps1"
. "$PSScriptRoot/Scripts/CLI/ShowCLIDefaultModeOptions.ps1"
. "$PSScriptRoot/Scripts/CLI/ShowCLIAppRemoval.ps1"
. "$PSScriptRoot/Scripts/CLI/ShowCLIMenuOptions.ps1"
. "$PSScriptRoot/Scripts/CLI/PrintPendingChanges.ps1"
. "$PSScriptRoot/Scripts/CLI/PrintHeader.ps1"

# Features functions
. "$PSScriptRoot/Scripts/Features/GetCurrentTweakState.ps1"
. "$PSScriptRoot/Scripts/Features/InvokeChanges.ps1"
. "$PSScriptRoot/Scripts/Features/DesiredStateVerification.ps1"
. "$PSScriptRoot/Scripts/Features/CreateSystemRestorePoint.ps1"
. "$PSScriptRoot/Scripts/Features/BackupRegistryFeatureSelection.ps1"
. "$PSScriptRoot/Scripts/Features/BackupRegistrySnapshotCapture.ps1"
. "$PSScriptRoot/Scripts/Features/BackupRegistryState.ps1"
. "$PSScriptRoot/Scripts/Features/BackupModuleState.ps1"
. "$PSScriptRoot/Scripts/Features/RegistryBackupValidation.ps1"
. "$PSScriptRoot/Scripts/Features/RestoreRegistryApplyState.ps1"
. "$PSScriptRoot/Scripts/Features/RestoreRegistryBackup.ps1"
. "$PSScriptRoot/Scripts/Features/StoreSearchSuggestions.ps1"
. "$PSScriptRoot/Scripts/Features/TelemetryScheduledTasks.ps1"
. "$PSScriptRoot/Scripts/Features/WindowsOptionalFeatures.ps1"
. "$PSScriptRoot/Scripts/Features/ImportRegistryFile.ps1"
. "$PSScriptRoot/Scripts/Features/ReplaceStartMenu.ps1"
. "$PSScriptRoot/Scripts/Features/RestartExplorer.ps1"
. "$PSScriptRoot/Scripts/Features/BlockTelemetryFirewall.ps1"
. "$PSScriptRoot/Scripts/Features/UpdateWatchdog.ps1"
. "$PSScriptRoot/Scripts/Features/AddDefenderGamingExclusions.ps1"

# File I/O functions
. "$PSScriptRoot/Scripts/FileIO/SaveToFile.ps1"
. "$PSScriptRoot/Scripts/FileIO/SaveSettings.ps1"
. "$PSScriptRoot/Scripts/FileIO/LoadSettings.ps1"
. "$PSScriptRoot/Scripts/FileIO/ValidateAppslist.ps1"
. "$PSScriptRoot/Scripts/FileIO/LoadAppsFromFile.ps1"
. "$PSScriptRoot/Scripts/FileIO/LoadAppsDetailsFromJson.ps1"
. "$PSScriptRoot/Scripts/FileIO/LoadAppPresetsFromJson.ps1"

# GUI functions
. "$PSScriptRoot/Scripts/GUI/GetSystemUsesDarkMode.ps1"
. "$PSScriptRoot/Scripts/GUI/SetWindowThemeResources.ps1"
. "$PSScriptRoot/Scripts/GUI/AttachShiftClickBehavior.ps1"
. "$PSScriptRoot/Scripts/GUI/ApplySettingsToUiControls.ps1"
. "$PSScriptRoot/Scripts/GUI/Show-MessageBox.ps1"
. "$PSScriptRoot/Scripts/GUI/Show-ConfigWindow.ps1"
. "$PSScriptRoot/Scripts/GUI/Show-ApplyModal.ps1"
. "$PSScriptRoot/Scripts/GUI/Show-AppSelectionWindow.ps1"
. "$PSScriptRoot/Scripts/GUI/Show-RestoreBackupWindow.ps1"
. "$PSScriptRoot/Scripts/GUI/RestoreBackupDialogFeatureLists.ps1"
. "$PSScriptRoot/Scripts/GUI/Show-RestoreBackupDialog.ps1"
. "$PSScriptRoot/Scripts/GUI/MainWindow-WindowChrome.ps1"
. "$PSScriptRoot/Scripts/GUI/MainWindow-AppSelection.ps1"
. "$PSScriptRoot/Scripts/GUI/MainWindow-TweaksBuilder.ps1"
. "$PSScriptRoot/Scripts/GUI/MainWindow-Navigation.ps1"
. "$PSScriptRoot/Scripts/GUI/MainWindow-Deployment.ps1"
. "$PSScriptRoot/Scripts/GUI/Show-MainWindow.ps1"
. "$PSScriptRoot/Scripts/GUI/Show-AboutDialog.ps1"
. "$PSScriptRoot/Scripts/GUI/Show-Bubble.ps1"

# Helper functions
. "$PSScriptRoot/Scripts/Helpers/AddParameter.ps1"
. "$PSScriptRoot/Scripts/Helpers/ResolveUserProfilePath.ps1"
. "$PSScriptRoot/Scripts/Helpers/UserHiveHelpers.ps1"
. "$PSScriptRoot/Scripts/Helpers/CheckIfUserExists.ps1"
. "$PSScriptRoot/Scripts/Helpers/CheckModernStandbySupport.ps1"
. "$PSScriptRoot/Scripts/Helpers/GenerateAppsList.ps1"
. "$PSScriptRoot/Scripts/Helpers/GetFriendlyRegistryBackupTarget.ps1"
. "$PSScriptRoot/Scripts/Helpers/GetFriendlyTargetUserName.ps1"
. "$PSScriptRoot/Scripts/Helpers/Test-ConfigConsistency.ps1"
. "$PSScriptRoot/Scripts/Helpers/ImportConfigToParams.ps1"
. "$PSScriptRoot/Scripts/Helpers/GetTargetUserForAppRemoval.ps1"
. "$PSScriptRoot/Scripts/Helpers/Get-RegFileOperations.ps1"
. "$PSScriptRoot/Scripts/Helpers/Test-TargetUserName.ps1"
. "$PSScriptRoot/Scripts/Helpers/GetUserDirectory.ps1"
. "$PSScriptRoot/Scripts/Helpers/GetUserName.ps1"
. "$PSScriptRoot/Scripts/Helpers/RegistryPathHelpers.ps1"
. "$PSScriptRoot/Scripts/Helpers/ApplyRegistryRegFile.ps1"
. "$PSScriptRoot/Scripts/Helpers/ConfirmUnsafeAppRemoval.ps1"

# Threading functions
. "$PSScriptRoot/Scripts/Threading/DoEvents.ps1"
. "$PSScriptRoot/Scripts/Threading/Invoke-NonBlocking.ps1"

# Winnow Extended Feature Modules (Bios-System)
. "$PSScriptRoot/Scripts/Features/GamingMode.ps1"
. "$PSScriptRoot/Scripts/Features/PerformanceTweaks.ps1"
. "$PSScriptRoot/Scripts/Features/SuppressWindowsAds.ps1"
. "$PSScriptRoot/Scripts/Features/ExtendedAIPurge.ps1"
. "$PSScriptRoot/Scripts/Features/SecurityHardening.ps1"

# Winnow v2.2.0 Feature Modules (Bios-System)
. "$PSScriptRoot/Scripts/Features/CompetitiveGaming.ps1"
. "$PSScriptRoot/Scripts/Features/SettingsAds.ps1"
. "$PSScriptRoot/Scripts/Features/WidgetsDeepDisable.ps1"
. "$PSScriptRoot/Scripts/Features/AutoUpdateCheck.ps1"

# Winnow v2.3.0 & v2.4.0 Feature Modules (Bios-System)
. "$PSScriptRoot/Scripts/Features/SoftwareInstaller.ps1"
. "$PSScriptRoot/Scripts/Features/UnattendGenerator.ps1"



##################################################################################################################
#                                                                                                                #
#                                                  SCRIPT START                                                  #
#                                                                                                                #
##################################################################################################################



# Get current Windows build version
$WinVersion = Get-ItemPropertyValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' CurrentBuild

$script:Params = $PSBoundParameters
$script:UndoParams = @{}

# Undo was reachable only from the GUI: nothing else ever populated UndoParams,
# so an unattended deployment could apply changes but never revert them.
if ($script:Params.ContainsKey('Undo')) {
    $unknownUndo = [System.Collections.Generic.List[string]]::new()
    $notUndoable = [System.Collections.Generic.List[string]]::new()

    foreach ($undoFeatureId in @($Undo)) {
        $trimmedId = ([string]$undoFeatureId).Trim()
        if ([string]::IsNullOrWhiteSpace($trimmedId)) { continue }

        if (-not $script:Features.ContainsKey($trimmedId)) {
            $unknownUndo.Add($trimmedId)
        }
        elseif (-not (Test-FeatureIsUndoable -FeatureId $trimmedId)) {
            # Accepting these would report success while doing nothing.
            $notUndoable.Add($trimmedId)
        }
        else {
            $script:UndoParams[$trimmedId] = $true
        }
    }

    if ($unknownUndo.Count -gt 0) {
        Write-Error "Unknown feature(s) passed to -Undo: $($unknownUndo -join ', ')"
        exit 1
    }

    if ($notUndoable.Count -gt 0) {
        Write-Error "Feature(s) passed to -Undo cannot be undone: $($notUndoable -join ', ')"
        exit 1
    }

    if ($script:UndoParams.Count -eq 0) {
        Write-Error "-Undo was passed without naming any feature to undo."
        exit 1
    }
}

# Auto-update check (queries GitHub API, silent if offline)
if (-not $script:Params.ContainsKey("SkipUpdateCheck")) {
    Invoke-UpdateCheck -CurrentVersion $WINNOW_VERSION -Silent
}

# Check if the machine supports Modern Standby, this is used to determine if the DisableModernStandbyNetworking option can be used
$script:ModernStandbySupported = CheckModernStandbySupport

# Handle Community Preset Profiles
if ($script:Params.ContainsKey("Preset")) {
    # A bad preset stops the run. Previously a missing file or a mistyped
    # switch only warned, and the apply phase then dropped what it did not
    # recognise, so the run reported success having changed nothing.
    try {
        $presetSwitches = Import-PresetSwitches -Preset $script:Params["Preset"]
    }
    catch {
        Write-Error $_.Exception.Message
        exit 1
    }

    Write-Host "> Loaded preset: $($script:Params["Preset"]) ($($presetSwitches.Count) switches)" -ForegroundColor Cyan
    foreach ($sw in $presetSwitches) {
        if (-not $script:Params.ContainsKey($sw)) {
            $script:Params.Add($sw, $true)
        }
    }
}

# Handle Dry-Run Mode
if ($script:Params.ContainsKey("DryRun")) {
    $WhatIfPreference = $true
    Write-Host "===========================================================" -ForegroundColor Magenta
    Write-Host " DRY-RUN MODE ENABLED - NO CHANGES WILL BE APPLIED " -ForegroundColor Magenta
    Write-Host "===========================================================" -ForegroundColor Magenta
    if (-not $script:Params.ContainsKey("WhatIf")) {
        $script:Params.Add("WhatIf", $true)
    }
}

# Add default Apps parameter when RemoveApps is requested and Apps was not explicitly provided
if ((-not $script:Params.ContainsKey("Apps")) -and $script:Params.ContainsKey("RemoveApps")) {
    $script:Params.Add('Apps', 'Default')
}

$controlParamsCount = 0

# Count how many control parameters are set, to determine if any changes were selected by the user during runtime
foreach ($Param in $script:ControlParams) {
    if ($script:Params.ContainsKey($Param)) {
        $controlParamsCount++
    }
}

# Hide progress bars for app removal, as they block Winnow's output
if (-not ($script:Params.ContainsKey("Verbose"))) {
    $ProgressPreference = 'SilentlyContinue'
}
else {
    Write-Host "Verbose mode is enabled"
    Write-Output ""
    Write-Output "Press any key to continue..."
    $null = [System.Console]::ReadKey()

    $ProgressPreference = 'Continue'
}

if ($script:Params.ContainsKey("Sysprep")) {
    GetUserDirectory -userName "Default" | Out-Null

    # Exit script if run in Sysprep mode on Windows 10
    if ($WinVersion -lt 22000) {
        Write-Error "Winnow Sysprep mode is not supported on Windows 10"
        AwaitKeyToExit
    }
}

# Ensure that target user exists, if User or AppRemovalTarget parameter was provided
if ($script:Params.ContainsKey("User")) {
    GetUserDirectory -userName $script:Params.Item("User") | Out-Null
}
if ($script:Params.ContainsKey("AppRemovalTarget")) {
    $appRemovalTargetValue = $script:Params.Item("AppRemovalTarget")
    # 'AllUsers' / 'CurrentUser' are sentinel scope values, not real usernames - don't resolve them as a profile
    if ($appRemovalTargetValue -notin @('AllUsers', 'CurrentUser')) {
        GetUserDirectory -userName $appRemovalTargetValue | Out-Null
    }
}

# Remove LastUsedSettings.json file if it exists and is empty
if ((Test-Path $script:SavedSettingsFilePath) -and ([String]::IsNullOrWhiteSpace((Get-content $script:SavedSettingsFilePath)))) {
    Remove-Item -Path $script:SavedSettingsFilePath -recurse
}

if ($VerifyWatchdog) {
    try {
        $watchdogHealth = Show-WinnowWatchdogHealth
        try { Stop-Transcript | Out-Null } catch { }
        if (-not $watchdogHealth.Healthy) {
            exit 2
        }
        exit 0
    }
    catch {
        Write-Error "Watchdog health check failed: $($_.Exception.Message)"
        try { Stop-Transcript | Out-Null } catch { }
        exit 2
    }
}

if ($Verify -or $VerifyProfile) {
    try {
        $verificationProfilePath = if ($VerifyProfile) { $VerifyProfile } elseif ($Config) { $Config } else { '' }
        $verificationInput = Get-WinnowVerificationInput -ProfilePath $verificationProfilePath -Parameters $script:Params
        $verification = Invoke-WinnowVerification -FeatureIds $verificationInput.FeatureIds -AppIds $verificationInput.AppIds
        try { Stop-Transcript | Out-Null } catch { }
        if ($verification.FailedCount -gt 0 -or $verification.ErrorCount -gt 0) {
            exit 2
        }
        exit 0
    }
    catch {
        Write-Error "Verification failed: $($_.Exception.Message)"
        try { Stop-Transcript | Out-Null } catch { }
        exit 2
    }
}

# Default to CLI mode for deployment-targeted parameters.
$launchInCLI = $CLI -or $script:Params.ContainsKey("User") -or $script:Params.ContainsKey("Sysprep") -or $script:Params.ContainsKey("AppRemovalTarget")

# -Undo names the work directly, so a run carrying it is never "nothing selected"
# even though Undo is itself a control parameter.
$script:HasPendingUndo = $script:UndoParams.Count -gt 0

# Change script execution based on provided parameters or user input
if (((-not $script:Params.Count) -or $RunDefaults -or $RunDefaultsLite -or $RunSavedSettings -or $Config -or ($controlParamsCount -eq $script:Params.Count)) -and -not $script:HasPendingUndo) {
    if ($RunDefaults -or $RunDefaultsLite) {
        ShowCLIDefaultModeOptions
    }
    elseif ($RunSavedSettings) {
        if (-not (Test-Path $script:SavedSettingsFilePath)) {
            PrintHeader 'Custom Mode'
            Write-Error "Unable to find LastUsedSettings.json file, no changes were made"
            AwaitKeyToExit
        }

        ShowCLILastUsedSettings
    }
    elseif ($Config) {
        try {
            ImportConfigToParams -ConfigPath $Config -CurrentBuild $WinVersion -ExpectedVersion '1.0'
        }
        catch {
            Write-Error "$_"
            AwaitKeyToExit
        }

        if (-not $Silent) {
            PrintHeader 'Custom Mode'
            PrintPendingChanges
            PrintHeader 'Custom Mode'
        }
    }
    else {
        if ($launchInCLI) {
            $Mode = ShowCLIMenuOptions 
        }
        else {
            try {
                $result = Show-MainWindow
            
                try {
                    Stop-Transcript
                }
                catch { }

                Exit
            }
            catch {
                Write-Warning "Unable to load WPF GUI, falling back to CLI mode: $($_.Exception.Message)"
                if (-not $Silent) {
                    Write-Host ""
                    Write-Host "Press any key to continue..."
                    $null = [System.Console]::ReadKey()
                }

                $Mode = ShowCLIMenuOptions
            }
        }
    }

    # Add execution parameters based on the mode
    switch ($Mode) {
        # Default mode, loads defaults and app removal options
        '1' { 
            ShowCLIDefaultModeOptions
        }

        # App removal, remove apps based on user selection
        '2' {
            ShowCLIAppRemoval
        }

        # Load last used options from the "LastUsedSettings.json" file
        '3' {
            ShowCLILastUsedSettings
        }
    }
}
else {
    PrintHeader 'Configuration'
}

# If the number of keys in ControlParams equals the number of keys in Params then no modifications/changes were selected
#  or added by the user, and the script can exit without making any changes.
if ((($controlParamsCount -eq $script:Params.Keys.Count) -or ($script:Params.Keys.Count -eq 1 -and ($script:Params.Keys -contains 'CreateRestorePoint' -or $script:Params.Keys -contains 'Apps'))) -and -not $script:HasPendingUndo) {
    Write-Output "The script completed without making any changes."
    AwaitKeyToExit
}

# Execute all selected/provided parameters using the consolidated function
# (This also handles restore point creation if requested)
Invoke-AllChanges

# --- Winnow Extended Features (Bios-System) ---
# These run outside the Features.json verify/rollback engine. Only run them when
# the main apply completed cleanly: after a rollback, a skipped rollback, or a
# user cancel, applying more (often invasive) changes would fight the recovery
# the pipeline just performed.
$applyWasClean = ($script:RunRollbackOutcome -eq 'None') -and (-not $script:CancelRequested)
if (-not $applyWasClean) {
    Write-Output ""
    Write-Output "Skipping extended modules because the main apply did not complete cleanly (outcome: $($script:RunRollbackOutcome))."
}
else {
    # -DryRun sets $WhatIfPreference; fold in a bare -WhatIf as well so neither
    # makes real changes here (SYSTEM task registration, file writes, Edge
    # uninstall). The ShouldProcess modules below already inherit $WhatIfPreference.
    $extendedWhatIf = $script:Params.ContainsKey("DryRun") -or $WhatIfPreference

    if ($script:Params.ContainsKey("EnablePerformanceTweaks")) { Enable-PerformanceTweaks }
    if ($script:Params.ContainsKey("DisableWindowsAds"))      { Disable-WindowsAds }

    # --- Winnow v2.2.0 Features (Bios-System) ---
    if ($script:Params.ContainsKey("EnableCompetitiveGaming")) {
        Enable-CompetitiveGaming -DisableMemoryIntegrity:($script:Params.ContainsKey("DisableMemoryIntegrity"))
    }
    if ($script:Params.ContainsKey("DisableSettingsAds"))     { Disable-SettingsAds }
    if ($script:Params.ContainsKey("DisableWidgetsDeep"))     { Disable-WidgetsDeep }

    # Force-remove Edge when the switch is passed. ForceRemoveEdge is the
    # non-interactive routine and honours -WhatIf/-DryRun itself; the switch is
    # an explicit request, so it runs without the y/n prompt.
    if ($script:Params.ContainsKey("ForceRemoveEdge")) {
        $null = ForceRemoveEdge
    }

    # --- Winnow v2.3.0 & v2.4.0 Features (Bios-System) ---
    if ($script:Params.ContainsKey("InstallSoftware")) {
        Install-Software -SoftwareList $script:Params["SoftwareList"]
    }
    if ($script:Params.ContainsKey("GenerateUnattend")) {
        Generate-UnattendXML -OutputPath $script:Params["UnattendOutPath"]
    }

    # --- Winnow v3.0.0 Features (Bios-System) ---
    if ($script:Params.ContainsKey("EnableUpdateWatchdog")) {
        Invoke-InstallUpdateWatchdog -WhatIf:$extendedWhatIf
    }
    if ($script:Params.ContainsKey("AddDefenderGamingExclusions")) {
        Invoke-AddDefenderGamingExclusions -WhatIf:$extendedWhatIf
    }
}

RestartExplorer

Write-Output ""
Write-Output ""
Write-Output ""
Write-Output "Script completed! Please check above for any errors."

# Exit codes: 0 success, 1 generic failure, 2 verification noncompliant,
# 3 apply failed and was rolled back, 4 apply failed and rollback failed too.
# 4 is the only outcome that needs someone at the machine, so it stays distinct
# from 3 rather than folding into a single "rolled back" code.
# 'Skipped' means the apply failed but no rollback ran (-NoAutoRollback, or no
# backup) so changes may persist: that is a failure, not success. A clean run
# that still had registry-import or app-removal failures also exits 1 rather
# than claiming success.
$rollbackExitCode = switch ($script:RunRollbackOutcome) {
    'RolledBack' { 3 }
    'RollbackFailed' { 4 }
    'Skipped' { 1 }
    default {
        if (([int]$script:RegistryImportFailures + [int]$script:AppRemovalFailures) -gt 0) { 1 } else { 0 }
    }
}

AwaitKeyToExit -ExitCode $rollbackExitCode
