# Define script-level variables & paths
# Mirrors the WINNOW_VERSION constant in Winnow.ps1. The literal is only
# used when this file is dot-sourced on its own, as the tests do.
$script:Version = if (Get-Variable -Name WINNOW_VERSION -Scope Global -ErrorAction SilentlyContinue) {
    $global:WINNOW_VERSION
} elseif ($WINNOW_VERSION) {
    $WINNOW_VERSION
} else {
    "4.2.3"
}
$script:AppVersion = $script:Version
$rootDir = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$configPath = Join-Path $rootDir 'Config'
$logsPath = Join-Path $rootDir 'Logs'
$schemasPath = Join-Path $rootDir 'Schemas'
$scriptsPath = Join-Path $rootDir 'Scripts'

$script:AppsListFilePath = Join-Path $configPath 'Apps.json'
$script:DefaultSettingsFilePath = Join-Path $configPath 'DefaultSettings.json'
$script:FeaturesFilePath = Join-Path $configPath 'Features.json'
$script:LanguagesPath = Join-Path $configPath 'Languages'
$script:PresetsPath = Join-Path $configPath 'Presets'
$script:SavedSettingsFilePath = Join-Path $configPath 'LastUsedSettings.json'
$script:DefaultLogPath = Join-Path $logsPath 'Winnow.log'
$script:RegfilesPath = Join-Path $rootDir 'Regfiles'
$script:RegistryBackupsPath = Join-Path $rootDir 'Backups'
$script:AssetsPath = Join-Path $rootDir 'Assets'
$script:AppSelectionSchema = Join-Path $schemasPath 'AppSelectionWindow.xaml'
$script:MainWindowSchema = Join-Path $schemasPath 'MainWindow.xaml'
$script:MessageBoxSchema = Join-Path $schemasPath 'MessageBox.xaml'
$script:AboutWindowSchema = Join-Path $schemasPath 'AboutWindow.xaml'
$script:ApplyChangesWindowSchema = Join-Path $schemasPath 'ApplyChangesWindow.xaml'
$script:SharedStylesSchema = Join-Path $schemasPath 'SharedStyles.xaml'
$script:BubbleHintSchema = Join-Path $schemasPath 'BubbleHint.xaml'
$script:ImportExportConfigSchema = Join-Path $schemasPath 'ImportExportConfigWindow.xaml'
$script:RestoreBackupWindowSchema = Join-Path $schemasPath 'RestoreBackupWindow.xaml'
$script:LoadAppsDetailsScriptPath = Join-Path (Join-Path $scriptsPath 'FileIO') 'LoadAppsDetailsFromJson.ps1'
$script:TestAppInWingetListScriptPath = Join-Path (Join-Path $scriptsPath 'AppRemoval') 'Test-AppInWingetList.ps1'

$script:ControlParams = 'WhatIf', 'Confirm', 'Verbose', 'Debug', 'LogPath', 'Silent', 'Sysprep', 'User', 'SkipExplorerRestart', 'SkipRegistryBackup', 'RunDefaults', 'RunDefaultsLite', 'RunSavedSettings', 'Config', 'CLI', 'AppRemovalTarget', 'Preset', 'DryRun', 'Verify', 'VerifyProfile', 'SkipUpdateCheck', 'NoAutoRollback', 'Undo'

# Script-level variables for GUI elements
$script:GuiWindow = $null
$script:CancelRequested = $false
$script:ApplyProgressCallback = $null
$script:ApplySubStepCallback = $null
$script:RegistryImportFailures = 0
$script:AppRemovalFailures = 0
$script:AppRemovalVerificationUnavailable = $false
# Names collected during app removal so the run summary and the completion
# screens report what actually happened instead of a hardcoded empty list.
$script:AppRemovalRemovedApps = @()
$script:AppRemovalFailedApps = @()

# Rollback state for the current run. The backup path is captured in phase 1 so
# the apply phase can restore from it without re-reading the Backups folder.
# Outcome is one of: None, RolledBack, RollbackFailed, Skipped.
$script:RunRegistryBackupPath = $null
# Full-module rollback: snapshot of non-registry module state and the module features
# that actually applied, so a failed run reverts services/firewall/HOSTS/tasks/SMB1 too.
$script:RunModuleBackupPath = $null
$script:AppliedModuleFeatures = @()
$script:RunRollbackOutcome = 'None'
$script:RunRollbackReason = $null

# Check if current powershell environment is limited by security policies
if ($ExecutionContext.SessionState.LanguageMode -ne "FullLanguage") {
    Write-Error "Winnow is unable to run on your system, powershell execution is restricted by security policies"
    Write-Output "Press any key to exit..."
    $null = [System.Console]::ReadKey()
    Exit 1
}

Clear-Host

# Ensure required Windows command paths are present in PATH for this session.
$system32Path = "$env:SystemRoot\System32"
if ($env:PATH -notmatch "(?i)(^|;)$([regex]::Escape($system32Path))(?=;|$)") {
    $env:PATH = "$env:SystemRoot\System32;$env:SystemRoot;" + $env:PATH
    Write-Warning "System32 path was missing from PATH environment variable, it has been added for this session."
}

# Display ASCII art launch logo in CLI
Write-Host ""
Write-Host ""
Write-Host "                   " -NoNewline; Write-Host "      ^" -ForegroundColor Blue
Write-Host "                   " -NoNewline; Write-Host "     / \" -ForegroundColor Blue
Write-Host "                   " -NoNewline; Write-Host "    /   \" -ForegroundColor Blue
Write-Host "                   " -NoNewline; Write-Host "   /     \" -ForegroundColor Blue
Write-Host "                   " -NoNewline; Write-Host "  / ===== \" -ForegroundColor Blue
Write-Host "                   " -NoNewline; Write-Host "  |" -ForegroundColor Blue -NoNewline; Write-Host "  ---  " -ForegroundColor White -NoNewline; Write-Host "|" -ForegroundColor Blue
Write-Host "                   " -NoNewline; Write-Host "  |" -ForegroundColor Blue -NoNewline; Write-Host " ( O ) " -ForegroundColor DarkCyan -NoNewline; Write-Host "|" -ForegroundColor Blue
Write-Host "                   " -NoNewline; Write-Host "  |" -ForegroundColor Blue -NoNewline; Write-Host "  ---  " -ForegroundColor White -NoNewline; Write-Host "|" -ForegroundColor Blue
Write-Host "                   " -NoNewline; Write-Host "  |       |" -ForegroundColor Blue
Write-Host "                   " -NoNewline; Write-Host " /|       |\" -ForegroundColor Blue
Write-Host "                   " -NoNewline; Write-Host "/ |       | \" -ForegroundColor Blue
Write-Host "                   " -NoNewline; Write-Host "  |  " -ForegroundColor DarkGray -NoNewline; Write-Host "'''" -ForegroundColor Red -NoNewline; Write-Host "  |" -ForegroundColor DarkGray -NoNewline; Write-Host "    *" -ForegroundColor Yellow
Write-Host "                   " -NoNewline; Write-Host "    (" -ForegroundColor Yellow -NoNewline; Write-Host "'''" -ForegroundColor Red -NoNewline; Write-Host ") " -ForegroundColor Yellow -NoNewline; Write-Host "   *  *" -ForegroundColor DarkYellow
Write-Host "                   " -NoNewline; Write-Host "    ( " -ForegroundColor DarkYellow -NoNewline; Write-Host "'" -ForegroundColor Red -NoNewline; Write-Host " )   " -ForegroundColor DarkYellow -NoNewline; Write-Host "*" -ForegroundColor Yellow
Write-Host ""
Write-Host "             Winnow is launching..." -ForegroundColor White
Write-Host "                Keep this window open" -ForegroundColor DarkGray
Write-Host ""
Write-Host ""
