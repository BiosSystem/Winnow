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

# Quote a value so it survives CommandLineToArgvW parsing in the child process.
function Format-LauncherArg {
    param([AllowEmptyString()][string]$Value)

    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"{0}"' -f $escaped
}

# Picks the release archive and the SHA-256 GitHub published for it. A release
# without the archive asset or its digest is refused rather than run unverified.
function Get-WinnowReleaseArchive {
    param([Parameter(Mandatory)]$Release)

    $asset = @($Release.assets | Where-Object { $_.name -match '^Winnow-v[0-9][0-9.]*\.zip$' }) | Select-Object -First 1
    if (-not $asset) {
        throw "Release $($Release.tag_name) has no Winnow-v*.zip asset."
    }
    if ([string]$asset.digest -notmatch '^sha256:([0-9a-fA-F]{64})$') {
        throw "Release asset $($asset.name) has no SHA-256 digest to verify against."
    }

    return [PSCustomObject]@{
        Uri = [string]$asset.browser_download_url
        Name = [string]$asset.name
        Sha256 = $Matches[1].ToUpperInvariant()
    }
}

# Builds the script the elevated process runs. It copies the archive into a new
# folder under %SystemRoot%\Temp that only Administrators and SYSTEM can change
# (a standard user cannot rename or replace it, unlike a locked folder in their
# own %TEMP%), checks the copy against the hash taken right after the download,
# unpacks it there and runs Winnow.ps1 from it. Nothing the elevated run loads
# comes from a folder the standard user controls.
function New-WinnowBootstrapScript {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$ArchiveSha256,
        [AllowEmptyCollection()][string[]]$WinnowArguments = @(),
        [string]$RunRoot = ''
    )

    $quote = { param([string]$Text) "'" + $Text.Replace("'", "''") + "'" }
    $argumentLiteral = '@(' + ((@($WinnowArguments) | ForEach-Object { & $quote $_ }) -join ', ') + ')'
    $runRootLiteral = if ($RunRoot) { & $quote $RunRoot } else { '(Join-Path $env:SystemRoot ''Temp'')' }

    return @"
`$ErrorActionPreference = 'Stop'
`$exitCode = 1
`$runPath = Join-Path $runRootLiteral ('Winnow-' + [guid]::NewGuid().ToString('N'))
try {
    `$null = New-Item -ItemType Directory -Path `$runPath
    `$acl = New-Object System.Security.AccessControl.DirectorySecurity
    `$acl.SetAccessRuleProtection(`$true, `$false)
    foreach (`$sid in 'S-1-5-18', 'S-1-5-32-544') {
        `$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier `$sid), 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
    }
    Set-Acl -LiteralPath `$runPath -AclObject `$acl

    `$archiveCopy = Join-Path `$runPath 'Winnow.zip'
    Copy-Item -LiteralPath $(& $quote $ArchivePath) -Destination `$archiveCopy
    if ((Get-FileHash -LiteralPath `$archiveCopy -Algorithm SHA256).Hash -ne $(& $quote $ArchiveSha256)) {
        throw 'The downloaded archive changed after it was verified. Winnow was not started.'
    }

    `$appPath = Join-Path `$runPath 'app'
    Expand-Archive -LiteralPath `$archiveCopy -DestinationPath `$appPath
    if (-not (Test-Path -LiteralPath (Join-Path `$appPath 'Winnow.ps1'))) {
        # Branch archives (-Dev) unpack into one Winnow-<branch> folder.
        `$nested = @(Get-ChildItem -LiteralPath `$appPath -Directory -Filter 'Winnow-*')
        if (`$nested.Count -eq 1) { `$appPath = `$nested[0].FullName }
    }

    `$scriptPath = Join-Path `$appPath 'Winnow.ps1'
    `$launchArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + `$scriptPath + '"')) + $argumentLiteral
    `$winnowProcess = Start-Process powershell.exe -ArgumentList `$launchArguments -NoNewWindow -Wait -PassThru
    `$exitCode = `$winnowProcess.ExitCode
}
catch {
    Write-Host "Error: `$(`$_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Press enter to exit...'
    Read-Host | Out-Null
}
finally {
    Remove-Item -LiteralPath `$runPath -Recurse -Force -ErrorAction SilentlyContinue
}
exit `$exitCode
"@
}

Clear-Host
Write-Output "-------------------------------------------------------------------------------------------"
Write-Output " Winnow Script"
Write-Output "-------------------------------------------------------------------------------------------"

# A new name for every run, so the download is never at a path prepared in advance.
$tempArchivePath = Join-Path $env:TEMP ("Winnow-{0}.zip" -f [guid]::NewGuid().ToString('N'))
$expectedArchiveHash = $null

Write-Output "> Downloading Winnow..."

try {
    if ($Dev) {
        Write-Warning 'Downloading the master branch. Branch archives have no published checksum to verify against.'
        $sourceUri = "https://github.com/BiosSystem/Winnow/archive/refs/heads/master.zip"
    } else {
        $release = Invoke-RestMethod https://api.github.com/repos/BiosSystem/Winnow/releases/latest
        $releaseArchive = Get-WinnowReleaseArchive -Release $release
        $sourceUri = $releaseArchive.Uri
        $expectedArchiveHash = $releaseArchive.Sha256
    }
    Invoke-RestMethod $sourceUri -OutFile $tempArchivePath
}
catch {
    Remove-Item -LiteralPath $tempArchivePath -Force -ErrorAction SilentlyContinue
    Write-Host "Error: Unable to fetch Winnow from GitHub. $($_.Exception.Message)" -ForegroundColor Red
    Write-Output ""
    Write-Output "Press enter to exit..."
    Read-Host | Out-Null
    Exit 1
}

# Hash the download straight away; the elevated step checks its own copy against this.
$archiveHash = (Get-FileHash -LiteralPath $tempArchivePath -Algorithm SHA256).Hash
if ($expectedArchiveHash -and $archiveHash -ne $expectedArchiveHash) {
    Remove-Item -LiteralPath $tempArchivePath -Force -ErrorAction SilentlyContinue
    Write-Host "Error: The downloaded archive does not match the SHA-256 GitHub published for this release. Winnow was not started." -ForegroundColor Red
    Write-Output ""
    Write-Output "Press enter to exit..."
    Read-Host | Out-Null
    Exit 1
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

# The elevated process gets the whole bootstrap on its command line, so no file it
# runs from sits where a standard user can change it.
$bootstrapScript = New-WinnowBootstrapScript -ArchivePath $tempArchivePath -ArchiveSha256 $archiveHash -WinnowArguments $arguments
$encodedBootstrap = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($bootstrapScript))
$launchArguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedBootstrap)

$exitCode = 1
if ($encodedBootstrap.Length -gt 30000) {
    Write-Host "Error: The argument list is too long to pass to the elevated process." -ForegroundColor Red
    $debloatProcess = $null
}
else {
    try {
        $debloatProcess = Start-Process powershell.exe -WindowStyle $windowStyle -PassThru -ArgumentList $launchArguments -Verb RunAs -ErrorAction Stop
    }
    catch {
        Write-Host "Error: Unable to launch Winnow with administrator privileges. $($_.Exception.Message)" -ForegroundColor Red
        $debloatProcess = $null
    }
}

# Wait for the process to finish before continuing
if ($null -ne $debloatProcess) {
    $debloatProcess.WaitForExit()
    $exitCode = $debloatProcess.ExitCode
}

Write-Output ""
Write-Output "> Cleaning up..."
Remove-Item -LiteralPath $tempArchivePath -Force -ErrorAction SilentlyContinue

Write-Output ""
Exit $exitCode
