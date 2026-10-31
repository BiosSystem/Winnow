<#
    .SYNOPSIS
        Loads a registry backup from a JSON file and normalizes its contents.

    .DESCRIPTION
        Loads a registry backup from disk and returns a normalized representation
        of its contents suitable for use by the restore workflow. Throws if the
        file is missing, unreadable, or not valid JSON.

    .PARAMETER FilePath
        The absolute path to the registry backup JSON file to load.

    .OUTPUTS
        PSCustomObject
        A normalized registry backup object produced by Normalize-RegistryBackup.
#>
function Load-RegistryBackupFromFile {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath
    )

    if (-not (Test-Path -LiteralPath $FilePath)) {
        throw "Backup file was not found: $FilePath"
    }

    try {
        # -Encoding UTF8 is required. SaveToFile writes these with a BOM, so a
        # Winnow backup happens to read correctly without it, but a file
        # produced anywhere else has no BOM and Windows PowerShell 5.1 would
        # fall back to the ANSI codepage and mangle every non-ASCII value.
        # Registry data holds such values, an accented profile path for one.
        $rawBackup = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "Failed to read backup file '$FilePath'. The file is not valid JSON."
    }

    return Normalize-RegistryBackup -Backup $rawBackup
}

<#
    .SYNOPSIS
        Validates and normalizes a raw registry backup object.

    .DESCRIPTION
        Validates the structure and content of the supplied backup and converts
        it into a normalized representation that can be safely consumed by the
        restore workflow. Throws if validation fails.

    .PARAMETER Backup
        The raw backup object (typically parsed from JSON) to normalize.

    .OUTPUTS
        PSCustomObject
        A normalized backup with Version, BackupType, CreatedAt, CreatedBy,
        ComputerName, Target, SelectedFeatures, SelectedUndoFeatures,
        RegistryKeys, UntrustedExecutableValues and ExecutableValuesConfirmed
        properties.

    .PARAMETER TrustExecutableValues
        Accept program-start values without confirmation. Only for a backup this
        run created and kept in memory (automatic rollback), never for a file.
#>
function Normalize-RegistryBackup {
    param(
        [Parameter(Mandatory)]
        $Backup,
        [switch]$TrustExecutableValues
    )

    $errors = New-Object System.Collections.Generic.List[string]

    if (-not $Backup.PSObject.Properties['Version']) {
        $errors.Add('Missing property: Version')
    }
    elseif ([string]$Backup.Version -ne '1.0') {
        $errors.Add("Unsupported backup version '$($Backup.Version)'.")
    }

    if (-not $Backup.PSObject.Properties['BackupType']) {
        $errors.Add('Missing property: BackupType')
    }
    elseif ([string]$Backup.BackupType -ne 'RegistryState') {
        $errors.Add("Unsupported BackupType '$($Backup.BackupType)'.")
    }

    $normalizedTarget = ''
    if (-not $Backup.PSObject.Properties['Target'] -or [string]::IsNullOrWhiteSpace([string]$Backup.Target)) {
        $errors.Add('Missing property: Target')
    }
    else {
        $normalizedTarget = [string]$Backup.Target

        if ($normalizedTarget -eq 'DefaultUserProfile') {
            # Valid target format.
        }
        elseif ($normalizedTarget -like 'User:*') {
            $targetUserName = $normalizedTarget.Substring(5)
            $targetValidation = Test-TargetUserName -UserName $targetUserName
            if (-not $targetValidation.IsValid) {
                $errors.Add("Invalid user '$normalizedTarget'")
            }
        }
        elseif ($normalizedTarget -like 'CurrentUser:*') {
            $targetCurrentUserName = $normalizedTarget.Substring(12)
            if ([string]::IsNullOrWhiteSpace($targetCurrentUserName) -or ($targetCurrentUserName -ne $env:USERNAME)) {
                 $errors.Add("Backup was made for '$targetCurrentUserName', this does not match current user '$env:USERNAME'.")
            }
        }
        else {
            $errors.Add("Unsupported Target '$normalizedTarget'.")
        }
    }

    $registryKeys = @()
    if (-not $Backup.PSObject.Properties['RegistryKeys']) {
        $errors.Add('Missing property: RegistryKeys')
    }
    else {
        $registryKeys = @($Backup.RegistryKeys)
    }

    $normalizedKeys = @()
    foreach ($keySnapshot in $registryKeys) {
        $normalizedKeys += @(Normalize-RegistryKeySnapshot -Snapshot $keySnapshot)
    }

    $selectedFeatureParseResult = Get-NormalizedSelectedFeatureIdsFromBackup -Backup $Backup
    $selectedFeatures = @($selectedFeatureParseResult.SelectedFeatures)
    foreach ($selectedFeatureParseError in @($selectedFeatureParseResult.Errors)) {
        $errors.Add([string]$selectedFeatureParseError)
    }

    $selectedUndoFeatureParseResult = Get-NormalizedSelectedUndoFeatureIdsFromBackup -Backup $Backup
    $selectedUndoFeatures = @($selectedUndoFeatureParseResult.SelectedUndoFeatures)
    foreach ($selectedUndoFeatureParseError in @($selectedUndoFeatureParseResult.Errors)) {
        $errors.Add([string]$selectedUndoFeatureParseError)
    }

    $executableValueWarnings = New-Object System.Collections.Generic.List[string]
    $allSelectedFeatures = @($selectedFeatures) + @($selectedUndoFeatures)
    if ($allSelectedFeatures.Count -eq 0) {
        $errors.Add('Backup must contain at least one feature ID in SelectedFeatures or SelectedUndoFeatures.')
    }
    else {
        try {
            $allowListValidationErrors = @(Test-RegistryBackupMatchesSelectedFeatures -SelectedFeatureIds @($selectedFeatures) -SelectedUndoFeatureIds @($selectedUndoFeatures) -Target $normalizedTarget -RegistryKeys @($normalizedKeys) -ExecutableValueWarnings $executableValueWarnings)
            foreach ($allowListValidationError in $allowListValidationErrors) {
                $errors.Add([string]$allowListValidationError)
            }

            if ($errors.Count -eq 0) {
                $planErrors = New-Object System.Collections.Generic.List[string]
                $planMap = Get-RegistryBackupAllowListPlanMap -SelectedFeatureIds @($selectedFeatures) -SelectedUndoFeatureIds @($selectedUndoFeatures) -Target $normalizedTarget -Errors $planErrors
                Set-RegistrySnapshotDeleteScope -RegistryKeys @($normalizedKeys) -PlanMap $planMap
            }
        }
        catch {
            $errors.Add("Failed to validate backup: $($_.Exception.Message)")
        }
    }

    if ($errors.Count -gt 0) {
        Write-Error "Backup validation failed: $($errors -join ' ')"
        if ($errors.Count -eq 1) {
            throw ("Validation failed: $($errors[0])")
        }
        else {
            throw ("Validation failed with $($errors.Count) errors. See console output for details.")
        }
    }

    return [PSCustomObject]@{
        Version = [string]$Backup.Version
        BackupType = [string]$Backup.BackupType
        CreatedAt = [string]$Backup.CreatedAt
        CreatedBy = [string]$Backup.CreatedBy
        ComputerName = [string]$Backup.ComputerName
        Target = $normalizedTarget
        SelectedFeatures = @($selectedFeatures)
        SelectedUndoFeatures = @($selectedUndoFeatures)
        RegistryKeys = @($normalizedKeys)
        # Values that can start a program and differ from what Winnow writes. The
        # restore refuses them unless the user confirmed them (ExecutableValuesConfirmed)
        # or the backup came from this run's memory (TrustExecutableValues).
        UntrustedExecutableValues = @(if ($TrustExecutableValues) { } else { $executableValueWarnings.ToArray() })
        ExecutableValuesConfirmed = [bool]$TrustExecutableValues
    }
}

<#
    .SYNOPSIS
        Restores registry state from a normalized backup object.

    .DESCRIPTION
        Applies the registry state described by the supplied backup back to the
        registry, loading the appropriate user hive when required.

    .PARAMETER Backup
        A normalized backup object (as produced by Normalize-RegistryBackup) whose
        RegistryKeys snapshots should be restored.

    .OUTPUTS
        PSCustomObject
        Returns an object with a Result property set to $true when the restore
        completes successfully.
#>
function Restore-RegistryBackupState {
    param(
        [Parameter(Mandatory)]
        $Backup
    )

    $friendlyTarget = GetFriendlyRegistryBackupTarget -Target ([string]$Backup.Target)

    $untrustedValues = @($Backup.UntrustedExecutableValues | Where-Object { $_ })
    if ($untrustedValues.Count -gt 0 -and -not $Backup.ExecutableValuesConfirmed) {
        throw "The backup sets $($untrustedValues.Count) registry value(s) that can start a program and do not match what Winnow writes: $($untrustedValues -join '; '). Restore was not started."
    }

    if ($script:Params.ContainsKey("WhatIf")) {
        Write-Host "[WhatIf] Restore registry backup for $friendlyTarget" -ForegroundColor Cyan
        return [PSCustomObject]@{ Result = $true }
    }

    $restoreAction = {
        param($normalizedBackup)

        Write-Host "Applying registry restore from $(@($normalizedBackup.RegistryKeys).Count) root snapshot(s)."
        # One key that cannot be restored must not leave every key after it
        # unrestored; report all failures together once the rest are done.
        $failedKeys = New-Object System.Collections.Generic.List[string]
        foreach ($rootSnapshot in @($normalizedBackup.RegistryKeys)) {
            try {
                Restore-RegistryKeySnapshot -Snapshot $rootSnapshot
            }
            catch {
                $failedKeys.Add("$($rootSnapshot.Path) ($($_.Exception.Message))")
                Write-Warning "Unable to restore $($rootSnapshot.Path): $($_.Exception.Message)"
            }
        }
        if ($failedKeys.Count -gt 0) {
            throw "Registry restore failed for $($failedKeys.Count) key(s): $($failedKeys -join '; ')"
        }
    }

    Write-Host "Starting restore for $friendlyTarget."

    if ($Backup.Target -eq 'DefaultUserProfile' -or $Backup.Target -like 'User:*') {
        Write-Host "Restore requires loading target user hive."
        Invoke-WithLoadedRestoreHive -Target $Backup.Target -ScriptBlock $restoreAction -ArgumentObject $Backup
        Write-Host "Restore completed for $friendlyTarget."
        return [PSCustomObject]@{ Result = $true }
    }

    & $restoreAction $Backup
    Write-Host "Restore completed for $friendlyTarget."
    return [PSCustomObject]@{ Result = $true }
}
