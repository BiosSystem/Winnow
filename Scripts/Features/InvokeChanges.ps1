<#
    .SYNOPSIS
        Applies a single feature/debloat operation.

    .DESCRIPTION
        Handles two categories of features:
        - Registry-backed: imports the .reg file via ImportRegistryFile, then runs
        any post-import side effects (e.g., removing companion app packages).
        - Custom logic: app removal, Windows optional features, start menu
        replacement, and other special-case features.
#>
function Invoke-FeatureApply {
    param(
        [Parameter(Mandatory)]
        [string]$FeatureId
    )

    # Resolve feature metadata from Features.json
    $feature = $script:Features[$FeatureId]
    $applyText = $feature.ApplyText

    # ---- Registry-backed features: import .reg file, then handle side effects ----
    if ($feature.RegistryKey) {
        ImportRegistryFile "> $applyText..." $feature.RegistryKey

        # Post-import side effects for specific features
        switch ($FeatureId) {
            'DisableBing' {
                # Also remove the app package for Bing search
                RemoveApps @('Microsoft.BingSearch')
            }
            'DisableCopilot' {
                # Also remove the app packages for Copilot
                RemoveApps @('Microsoft.Copilot', 'XP9CXNGPPJ97XX')
            }
            'DisableTelemetry' {
                # Also disable telemetry scheduled tasks and services
                Disable-TelemetryScheduledTasks
            }
            'DisableTelemetryServices' {
                Disable-TelemetryServices
            }
        }
        return
    }

    # ---- Custom features (no registry backing, or special handling required) ----
    switch ($FeatureId) {
        'RemoveApps' {
            Write-Host "> $applyText for $(GetFriendlyTargetUserName)..."
            $appsList = GenerateAppsList

            if ($appsList.Count -eq 0) {
                Write-Host "No valid apps were selected for removal" -ForegroundColor Yellow
                Write-Host ""
                return
            }

            Write-Host "$($appsList.Count) apps selected for removal"
            RemoveApps $appsList
            return
        }
        'RemoveGamingApps' {
            $appsList = @('Microsoft.GamingApp', 'Microsoft.XboxGameOverlay', 'Microsoft.XboxGamingOverlay')
            Write-Host "> $applyText..."
            RemoveApps $appsList
            return
        }
        'RemoveHPApps' {
            $appsList = @('AD2F1837.HPAIExperienceCenter', 'AD2F1837.HPJumpStarts', 'AD2F1837.HPPCHardwareDiagnosticsWindows', 'AD2F1837.HPPowerManager', 'AD2F1837.HPPrivacySettings', 'AD2F1837.HPSupportAssistant', 'AD2F1837.HPSureShieldAI', 'AD2F1837.HPSystemInformation', 'AD2F1837.HPQuickDrop', 'AD2F1837.HPWorkWell', 'AD2F1837.myHP', 'AD2F1837.HPDesktopSupportUtilities', 'AD2F1837.HPQuickTouch', 'AD2F1837.HPEasyClean', 'AD2F1837.HPConnectedMusic', 'AD2F1837.HPFileViewer', 'AD2F1837.HPRegistration', 'AD2F1837.HPWelcome', 'AD2F1837.HPConnectedPhotopoweredbySnapfish', 'AD2F1837.HPPrinterControl')
            Write-Host "> $applyText..."
            RemoveApps $appsList
            return
        }
        'DisableWidgets' {
            Write-Host "> $applyText..."
            # Stop widgets related processes before removing the app packages to prevent potential issues
            if (-not $script:Params.ContainsKey("WhatIf")) {
                Get-Process *Widget* -ErrorAction SilentlyContinue | Stop-Process
            }

            RemoveApps @('Microsoft.StartExperiencesApp','MicrosoftWindows.Client.WebExperience','Microsoft.WidgetsPlatformRuntime')
            return
        }
        'EnableWindowsSandbox' {
            Write-Host "> $applyText..."
            EnableWindowsFeature "Containers-DisposableClientVM"
            Write-Host ""
            return
        }
        'EnableWindowsSubsystemForLinux' {
            Write-Host "> $applyText..."
            EnableWindowsFeature "VirtualMachinePlatform"
            EnableWindowsFeature "Microsoft-Windows-Subsystem-Linux"
            Write-Host ""
            return
        }
        'ClearStart' {
            Write-Host "> $applyText for user $(GetUserName)..."
            $startMenuBinFile = GetStartMenuBinPathForUser -UserName (GetUserName)
            if (-not [string]::IsNullOrWhiteSpace($startMenuBinFile)) {
                ReplaceStartMenu -startMenuBinFile $startMenuBinFile
            }
            Write-Host ""
            return
        }
        'ReplaceStart' {
            Write-Host "> $applyText for user $(GetUserName)..."
            $startMenuBinFile = GetStartMenuBinPathForUser -UserName (GetUserName)
            if (-not [string]::IsNullOrWhiteSpace($startMenuBinFile)) {
                ReplaceStartMenu -startMenuBinFile $startMenuBinFile -startMenuTemplate $script:Params.Item("ReplaceStart")
            }
            Write-Host ""
            return
        }
        'ClearStartAllUsers' {
            ReplaceStartMenuForAllUsers
            return
        }
        'ReplaceStartAllUsers' {
            ReplaceStartMenuForAllUsers -startMenuTemplate $script:Params.Item("ReplaceStartAllUsers")
            return
        }
        'DisableStoreSearchSuggestions' {
            if ($script:Params.ContainsKey("Sysprep")) {
                Write-Host "> Disabling Microsoft Store search suggestions in the start menu for all users..."
                DisableStoreSearchSuggestionsForAllUsers
                Write-Host ""
                return
            }

            Write-Host "> Disabling Microsoft Store search suggestions for user $(GetUserName)..."
            $storeDb = GetStoreAppsDatabasePathForUser -UserName (GetUserName)
            if ($storeDb) {
                DisableStoreSearchSuggestions -StoreAppsDatabase $storeDb
            }
            Write-Host ""
            return
        }
        'DisableTelemetryServices' {
            Write-Host "> $applyText..."
            Disable-TelemetryServices
            return
        }
        'EnableGamingMode' {
            Enable-GamingMode
            return
        }
        'EnableExtendedAIPurge' {
            Disable-ExtendedAIPurge
            return
        }
        'EnableSecurityHardening' {
            Enable-SecurityHardening
            return
        }
        'EnableFirewallTelemetryBlock' {
            Invoke-BlockTelemetryFirewall -WhatIf:$script:Params.ContainsKey('WhatIf')
            return
        }
    }
}


<#
    .SYNOPSIS
        Undoes a single feature that has no RegistryUndoKey.

    .DESCRIPTION
        Handles undo for features that require custom logic rather than a simple
        .reg file import. Features with a RegistryUndoKey are handled directly
        via ImportRegistryFile in Invoke-UndoFeatures.
#>
function Invoke-FeatureUndo {
    param(
        [Parameter(Mandatory)]
        [string]$FeatureId
    )

    $feature = if ($script:Features.ContainsKey($FeatureId)) { $script:Features[$FeatureId] } else { $null }

    switch ($FeatureId) {
        'DisableStoreSearchSuggestions' {
            if ($script:Params.ContainsKey('Sysprep')) {
                Write-Host "> Re-enabling Microsoft Store search suggestions in the start menu for all users..."
                EnableStoreSearchSuggestionsForAllUsers
                Write-Host ""
                return
            }

            Write-Host "> Re-enabling Microsoft Store search suggestions for user $(GetUserName)..."
            $storeDb = GetStoreAppsDatabasePathForUser -UserName (GetUserName)
            if ($storeDb) {
                EnableStoreSearchSuggestions -StoreAppsDatabase $storeDb
            }
            Write-Host ""
            return
        }
        'EnableWindowsSandbox' {
            Write-Host "> $($feature.ApplyUndoText)..."
            DisableWindowsFeature 'Containers-DisposableClientVM'
            Write-Host ""
            return
        }
        'EnableWindowsSubsystemForLinux' {
            Write-Host "> $($feature.ApplyUndoText)..."
            DisableWindowsFeature 'Microsoft-Windows-Subsystem-Linux'
            DisableWindowsFeature 'VirtualMachinePlatform'
            Write-Host ""
            return
        }
        'DisableTelemetry' {
            # Also re-enable telemetry scheduled tasks
            Enable-TelemetryScheduledTasks
            return
        }
        'DisableTelemetryServices' {
            Enable-TelemetryServices
            return
        }
        'EnableFirewallTelemetryBlock' {
            Invoke-UnblockTelemetryFirewall -WhatIf:$script:Params.ContainsKey('WhatIf')
            return
        }
    }
}


# Features whose undo lives in the Invoke-FeatureUndo switch above rather than
# in a RegistryUndoKey. Test-CustomFeatureContracts asserts this stays in step
# with the switch, so adding a case there without listing it here fails the suite.
$script:CustomUndoFeatureIds = @(
    'DisableStoreSearchSuggestions',
    'EnableWindowsSandbox',
    'EnableWindowsSubsystemForLinux',
    'DisableTelemetry',
    'DisableTelemetryServices',
    'EnableFirewallTelemetryBlock'
)

<#
    .SYNOPSIS
        Reports whether a feature can be undone.

    .DESCRIPTION
        A feature is undoable when it declares a RegistryUndoKey or has a case in
        Invoke-FeatureUndo. Selecting anything else for undo would report success
        while doing nothing, so the caller is expected to reject it.

    .OUTPUTS
        System.Boolean.
#>
function Test-FeatureIsUndoable {
    param(
        [Parameter(Mandatory)]
        [string]$FeatureId
    )

    if (-not $script:Features.ContainsKey($FeatureId)) {
        return $false
    }

    $feature = $script:Features[$FeatureId]
    if (-not [string]::IsNullOrWhiteSpace([string]$feature.RegistryUndoKey)) {
        return $true
    }

    return ($FeatureId -in $script:CustomUndoFeatureIds)
}

<#
    .SYNOPSIS
        Resolves the path of an undo .reg file relative to $script:RegfilesPath.

    .DESCRIPTION
        Checks the Undo/ subfolder first, then falls back to the root Regfiles/
        folder. This allows undo files to be organized separately from apply files.
#>
function Resolve-UndoRegFilePath {
    param([string]$FileName)

    $undoSubPath = Join-Path 'Undo' $FileName
    if (Test-Path (Join-Path $script:RegfilesPath $undoSubPath)) {
        return $undoSubPath
    }
    return $FileName
}


<#
.SYNOPSIS
    Applies a list of features, reporting progress for each.

.DESCRIPTION
    Iterates through the provided feature IDs and calls Invoke-FeatureApply
    for each. Handles progress callbacks (GUI mode) and cancellation checks.
    This is called by Invoke-AllChanges during the apply phase.
#>
function Invoke-ApplyFeatures {
    param(
        [Parameter(Mandatory)]
        [string[]]$FeatureIds,
        [Parameter(Mandatory)]
        [int]$StartStep,
        [Parameter(Mandatory)]
        [int]$TotalSteps
    )

    if ($FeatureIds.Count -eq 0) { return }

    $step = $StartStep
    foreach ($featureId in $FeatureIds) {
        if ($script:CancelRequested) { return }

        # Resolve display name for the progress indicator
        $f = $script:Features[$featureId]
        $displayName = $f.ApplyText

        if ($script:ApplyProgressCallback) {
            & $script:ApplyProgressCallback $step $TotalSteps $displayName
        }

        Invoke-WinnowFeature -FeatureId $featureId

        # Record module features as they apply so rollback reverts only what ran.
        if ($featureId -in $script:ModuleRollbackFeatureIds -and $script:AppliedModuleFeatures -notcontains $featureId) {
            $script:AppliedModuleFeatures += $featureId
        }

        $step++
    }
}


<#
    .SYNOPSIS
        Undoes a list of features, reporting progress for each.

    .DESCRIPTION
        Iterates through the provided feature IDs. Features with a RegistryUndoKey
        are handled by importing the undo .reg file; all others delegate to
        Invoke-FeatureUndo for custom undo logic.
        This is called by Invoke-AllChanges during the undo phase.
#>
function Invoke-UndoFeatures {
    param(
        [Parameter(Mandatory)]
        [string[]]$FeatureIds,
        [Parameter(Mandatory)]
        [int]$StartStep,
        [Parameter(Mandatory)]
        [int]$TotalSteps
    )

    if ($FeatureIds.Count -eq 0) { return }

    $step = $StartStep
    foreach ($featureId in $FeatureIds) {
        if ($script:CancelRequested) { return }

        $f = if ($script:Features.ContainsKey($featureId)) { $script:Features[$featureId] } else { $null }
        $undoLabel = if ($f -and $f.UndoLabel) { $f.UndoLabel } else { $featureId }
        $undoText = if ($f -and $f.ApplyUndoText) { $f.ApplyUndoText } else { $undoLabel }

        if ($script:ApplyProgressCallback) {
            & $script:ApplyProgressCallback $step $TotalSteps $undoText
        }

        Undo-WinnowFeature -FeatureId $featureId
        $step++
    }
}


<#
    .SYNOPSIS
        Main orchestrator: applies and undoes all selected features.

    .DESCRIPTION
        Sequenced in four phases:
        1. Registry backup
        2. System restore point
        3. Apply phase - applies all selected features via Invoke-ApplyFeatures
        4. Undo phase - undoes selected features via Invoke-UndoFeatures

        Progress is reported through $script:ApplyProgressCallback when set
        (used by the GUI modal). Cancellation is checked between each step.
#>
function Invoke-AllChanges {
    # Guard: prevent running as SYSTEM account without explicit target user
    $isSystem = ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
    if ($isSystem -and -not $script:Params.ContainsKey("User") -and -not $script:Params.ContainsKey("Sysprep")) {
        throw "Winnow is running as the SYSTEM account. Use the '-User' or '-Sysprep' parameter to target a specific user."
    }

    $script:RegistryImportFailures = 0

    # The run summary export is guarded on this and nothing ever set it, so no
    # summary was written at all. The GUI's "View Last Report" had nothing to
    # open, and rollback had nowhere to be recorded.
    $script:RunStartTime = Get-Date

    # ---- Gather work items ----
    $applyIds = @()
    foreach ($key in $script:Params.Keys) {
        if ($script:ControlParams -contains $key) { continue }
        if ($key -eq 'Apps') { continue }
        if ($key -eq 'CreateRestorePoint') { continue }
        if (-not $script:Features.ContainsKey($key)) { continue }
        $applyIds += $key
    }
    $requiresRestorePoint = @($applyIds | Where-Object {
        $feature = $script:Features[$_]
        $feature -and $feature.RequiresRestorePoint -eq $true
    }).Count -gt 0
    # The extended gaming modules run outside the Features.json engine and make
    # low-level changes (BCD, HVCI/VBS, power plan) with no undo path, so force a
    # restore point when they are requested even though they are not FeatureIds.
    $invasiveExtended = $script:Params.ContainsKey('EnableCompetitiveGaming') -or $script:Params.ContainsKey('DisableMemoryIntegrity')
    if ($requiresRestorePoint -or $invasiveExtended -or $applyIds -contains 'RemoveApps' -or $applyIds -contains 'RemoveGamingApps' -or $applyIds -contains 'RemoveHPApps') {
        if (-not $script:Params.ContainsKey("CreateRestorePoint")) { $script:Params.Add("CreateRestorePoint", $true) }
    }
    $undoIds = @($script:UndoParams.Keys)

    # ---- Determine if registry backup is needed ----
    $needsBackup = $false
    foreach ($id in $applyIds) {
        $f = $script:Features[$id]
        if ($f -and -not [string]::IsNullOrWhiteSpace([string]$f.RegistryKey)) {
            $needsBackup = $true
            break
        }
    }
    if (-not $needsBackup) {
        foreach ($id in $undoIds) {
            $f = if ($script:Features.ContainsKey($id)) { $script:Features[$id] } else { $null }
            if ($f -and $f.RegistryUndoKey) { $needsBackup = $true; break }
        }
    }

    # Module features change non-registry state (services, firewall, HOSTS, tasks, SMB1) that the
    # registry backup does not cover. Snapshot it so a failed apply can revert it too.
    $hasModuleFeatures = @($applyIds | Where-Object { $_ -in $script:ModuleRollbackFeatureIds }).Count -gt 0

    # ---- Calculate total progress steps ----
    $totalSteps = $applyIds.Count + $undoIds.Count
    if ($needsBackup -and -not $script:Params.ContainsKey('SkipRegistryBackup')) { $totalSteps++ }
    if ($script:Params.ContainsKey("CreateRestorePoint")) { $totalSteps++ }
    $step = 0

    # ================================================================
    # Phase 1: Registry backup
    # ================================================================
    # Say this up front rather than at the moment rollback is needed and missing.
    if ($needsBackup -and $script:Params.ContainsKey('SkipRegistryBackup') -and -not $script:Params.ContainsKey('WhatIf')) {
        Write-Host "  [WARN] -SkipRegistryBackup disables automatic rollback. A failed apply will be left in place." -ForegroundColor Yellow
        Write-Host ""
    }

    if ($needsBackup -and -not $script:Params.ContainsKey('SkipRegistryBackup')) {
        $step++
        if ($script:ApplyProgressCallback) {
            & $script:ApplyProgressCallback $step $totalSteps "Creating registry backup..."
        }

        if ($script:Params.ContainsKey("WhatIf")) {
            Write-Host "[WhatIf] Create registry backup" -ForegroundColor Cyan
        }
        else {
            Write-Host "> Creating registry backup..."
            try {
                $undoSyntheticFeatures = @($undoIds | ForEach-Object {
                    $f = if ($script:Features.ContainsKey($_)) { $script:Features[$_] } else { $null }
                    if ($f -and $f.RegistryUndoKey) {
                        [PSCustomObject]@{ FeatureId = $_; RegistryKey = (Resolve-UndoRegFilePath $f.RegistryUndoKey) }
                    }
                } | Where-Object { $_ })
                # Keep the path: it is what automatic rollback restores from if
                # the apply phase fails.
                $script:RunRegistryBackupPath = New-RegistrySettingsBackup -ActionableKeys $applyIds -ExtraFeatures $undoSyntheticFeatures
                if ($applyIds -contains 'RemoveApps') {
                    Write-Host "  [INFO] Backing up Component-Based Servicing hive (HKLM\COMPONENTS)..."
                    reg export HKLM\COMPONENTS "$env:TEMP\Winnow_CBS_Backup.reg" /y | Out-Null
                }
            }
            catch {
                throw "Registry backup failed before applying changes. $($_.Exception.Message)"
            }
        }
    }

    # Module-state snapshot for full-module rollback: services, firewall, HOSTS, scheduled tasks
    # and SMB1. Runs even when there is no registry backup, since a module-only run still needs its
    # non-registry changes reverted on failure. Gated by -SkipRegistryBackup, which turns off
    # automatic rollback entirely.
    if ($hasModuleFeatures -and -not $script:Params.ContainsKey('SkipRegistryBackup') -and -not $script:Params.ContainsKey('WhatIf')) {
        try {
            $script:RunModuleBackupPath = New-ModuleStateSnapshot -ApplyIds $applyIds
        }
        catch {
            Write-Host "  [WARN] Could not capture module-state snapshot: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # ================================================================
    # Phase 2: System restore point
    # ================================================================
    if ($script:Params.ContainsKey("CreateRestorePoint")) {
        $step++
        if ($script:ApplyProgressCallback) {
            & $script:ApplyProgressCallback $step $totalSteps "Creating system restore point, this may take a moment..."
        }
        if ($script:Params.ContainsKey("WhatIf")) {
            Write-Host "[WhatIf] Create system restore point" -ForegroundColor Cyan
            Write-Host ""
        }
        else {
            Write-Host "> Creating a system restore point..."
            CreateSystemRestorePoint
            Write-Host ""
        }
    }

    # ================================================================
    # Phase 3: Apply features
    # ================================================================
    # Invoke-ApplyFeatures does not catch per-feature errors, and a missing .reg
    # file throws rather than only incrementing the failure counter. Without this
    # the exception would escape the whole function and skip rollback entirely,
    # which is the case rollback exists for.
    $applyException = $null
    if ($applyIds.Count -gt 0) {
        try {
            Invoke-ApplyFeatures -FeatureIds $applyIds -StartStep ($step + 1) -TotalSteps $totalSteps
        }
        catch {
            $applyException = $_
            Write-Host ""
            Write-Host "Apply phase failed: $($_.Exception.Message)" -ForegroundColor Red
        }
        $step += $applyIds.Count
    }

    # ================================================================
    # Phase 3b: Automatic rollback
    # ================================================================
    # Runs before any undo work so a failed apply is not compounded by undo
    # operations against a half-applied system.
    #
    # Only registry import failures trigger this. An app removal failure must
    # not: a registry backup cannot reinstall an uninstalled Appx package, so
    # restoring here would report a recovery that did not happen while the apps
    # stay gone.
    # A dry run reports what would happen and changes nothing, so it can never
    # count as a failed apply.
    $applyFailed = (-not $script:Params.ContainsKey("WhatIf")) -and
        (($script:RegistryImportFailures -gt 0) -or ($null -ne $applyException))

    if ($applyFailed) {
        $script:RunRollbackReason = if ($script:RegistryImportFailures -gt 0) {
            "$($script:RegistryImportFailures) registry import change(s) failed"
        }
        else {
            "the apply phase failed: $($applyException.Exception.Message)"
        }

        if ($script:Params.ContainsKey('NoAutoRollback')) {
            $script:RunRollbackOutcome = 'Skipped'
            Write-Host ""
            Write-Host "  [WARN] $($script:RunRollbackReason). Rollback skipped because -NoAutoRollback was passed." -ForegroundColor Yellow
        }
        else {
            Write-Host ""

            # Registry rollback. $registryOutcome: $true restored, $false failed, $null nothing to do.
            $registryOutcome = $null
            if (-not [string]::IsNullOrWhiteSpace($script:RunRegistryBackupPath)) {
                Write-Host "> $($script:RunRollbackReason). Rolling back registry changes..." -ForegroundColor Yellow
                try {
                    $rollbackBackup = Load-RegistryBackupFromFile -FilePath $script:RunRegistryBackupPath
                    $rollbackResult = Restore-RegistryBackupState -Backup $rollbackBackup
                    if ($rollbackResult -and $rollbackResult.Result) {
                        $registryOutcome = $true
                        Write-Host "Registry changes were rolled back." -ForegroundColor Yellow
                    }
                    else {
                        $registryOutcome = $false
                        Write-Host "Registry rollback did not complete. Restore manually from: $($script:RunRegistryBackupPath)" -ForegroundColor Red
                    }
                }
                catch {
                    $registryOutcome = $false
                    Write-Host "Registry rollback failed: $($_.Exception.Message). Restore manually from: $($script:RunRegistryBackupPath)" -ForegroundColor Red
                }
            }

            # Module rollback: services, firewall, HOSTS, scheduled tasks, SMB1.
            $moduleOutcome = $null
            if (-not [string]::IsNullOrWhiteSpace($script:RunModuleBackupPath) -and @($script:AppliedModuleFeatures).Count -gt 0) {
                Write-Host "> Rolling back module changes (services, firewall, tasks)..." -ForegroundColor Yellow
                $moduleResult = Restore-ModuleState -SnapshotPath $script:RunModuleBackupPath -AppliedFeatures $script:AppliedModuleFeatures
                if (@($moduleResult.Reverted).Count -gt 0) {
                    Write-Host "Reverted: $($moduleResult.Reverted -join ', ')." -ForegroundColor Yellow
                }
                if (@($moduleResult.Uncovered).Count -gt 0) {
                    Write-Host "Not restored (needs the original image or a manual step): $($moduleResult.Uncovered -join '; ')." -ForegroundColor Yellow
                }
                if (@($moduleResult.Failed).Count -eq 0) {
                    $moduleOutcome = $true
                }
                else {
                    $moduleOutcome = $false
                    Write-Host "Some module changes could not be reverted: $($moduleResult.Failed -join '; ')" -ForegroundColor Red
                }
            }

            # Combined outcome drives the exit code (3 rolled back, 4 rollback failed, 1 skipped).
            if ($registryOutcome -eq $false -or $moduleOutcome -eq $false) {
                $script:RunRollbackOutcome = 'RollbackFailed'
                Write-Host "Rollback did not fully complete. The system may be partially changed." -ForegroundColor Red
            }
            elseif ($registryOutcome -eq $true -or $moduleOutcome -eq $true) {
                $script:RunRollbackOutcome = 'RolledBack'
            }
            else {
                $script:RunRollbackOutcome = 'Skipped'
                Write-Host "  [WARN] $($script:RunRollbackReason), but no backup is available to roll back to." -ForegroundColor Yellow
            }
            Write-Host ""
        }
    }

    # ================================================================
    # Phase 4: Undo features
    # ================================================================
    # Skipped after a failed apply. The system has just been restored or is
    # known to be partially changed, and undo work on top of either would make
    # the final state harder to reason about.
    if ($applyFailed -and $undoIds.Count -gt 0) {
        Write-Host "  [WARN] Skipping $($undoIds.Count) undo operation(s) because the apply phase failed." -ForegroundColor Yellow
        Write-Host ""
    }
    elseif ($undoIds.Count -gt 0) {
        Invoke-UndoFeatures -FeatureIds $undoIds -StartStep ($step + 1) -TotalSteps $totalSteps
        $step += $undoIds.Count
    }

    # ================================================================
    # Final: Report registry import failures and export run summary
    # ================================================================
    if ($script:RegistryImportFailures -gt 0) {
        Write-Host ""
        Write-Host "$($script:RegistryImportFailures) registry import change(s) failed. See output above for details." -ForegroundColor Yellow
    }
    if ($script:AppRemovalFailures -gt 0) {
        Write-Host ""
        Write-Host "$($script:AppRemovalFailures) app removal(s) failed: $($script:AppRemovalFailedApps -join ', '). See output above for details." -ForegroundColor Yellow
    }
    if ($script:AppRemovalVerificationUnavailable) {
        Write-Host ""
        Write-Host "  [WARN] App removals could not be verified (winget list unavailable); some may not have succeeded." -ForegroundColor Yellow
    }

    # Export run summary JSON to %TEMP% for later review
    if ($script:RunStartTime -and (Get-Command Export-RunSummary -ErrorAction SilentlyContinue)) {
        $version = if ($script:AppVersion) { $script:AppVersion } else { 'Unknown' }
        Export-RunSummary `
            -AppliedFeatureIds $applyIds `
            -UndoneFeatureIds  $undoIds `
            -RemovedApps       @($script:AppRemovalRemovedApps) `
            -FailedApps        @($script:AppRemovalFailedApps) `
            -AppVerificationUnavailable $script:AppRemovalVerificationUnavailable `
            -FeatureErrors     @() `
            -StartTime         $script:RunStartTime `
            -WinnowVersion   $version
    }
}

