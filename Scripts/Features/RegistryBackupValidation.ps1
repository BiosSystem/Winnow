function Get-NormalizedSelectedFeatureIdsFromBackup {
    param(
        [Parameter(Mandatory)]
        $Backup
    )

    $selectedFeatures = New-Object System.Collections.Generic.List[string]
    $selectedFeatureIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $errors = New-Object System.Collections.Generic.List[string]
    $hasInvalidSelectedFeatureId = $false

    if (-not $Backup.PSObject.Properties['SelectedFeatures']) {
        $errors.Add('Missing property: SelectedFeatures')
        return [PSCustomObject]@{
            SelectedFeatures = $selectedFeatures.ToArray()
            Errors = $errors.ToArray()
        }
    }

    foreach ($featureId in @($Backup.SelectedFeatures)) {
        if ($featureId -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$featureId)) {
            $hasInvalidSelectedFeatureId = $true
            continue
        }

        $normalizedFeatureId = [string]$featureId
        if ($selectedFeatureIds.Add($normalizedFeatureId)) {
            $selectedFeatures.Add($normalizedFeatureId)
        }
    }

    if ($hasInvalidSelectedFeatureId) {
        $errors.Add('SelectedFeatures must contain non-empty string feature IDs.')
    }

    return [PSCustomObject]@{
        SelectedFeatures = $selectedFeatures.ToArray()
        Errors = $errors.ToArray()
    }
}

function Get-NormalizedSelectedUndoFeatureIdsFromBackup {
    param(
        [Parameter(Mandatory)]
        $Backup
    )

    $selectedUndoFeatures = New-Object System.Collections.Generic.List[string]
    $selectedUndoFeatureIds = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $errors = New-Object System.Collections.Generic.List[string]

    # SelectedUndoFeatures is optional - only process if present
    if (-not $Backup.PSObject.Properties['SelectedUndoFeatures']) {
        return [PSCustomObject]@{
            SelectedUndoFeatures = $selectedUndoFeatures.ToArray()
            Errors = $errors.ToArray()
        }
    }

    $hasInvalidSelectedUndoFeatureId = $false
    foreach ($featureId in @($Backup.SelectedUndoFeatures)) {
        if ($featureId -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$featureId)) {
            $hasInvalidSelectedUndoFeatureId = $true
            continue
        }

        $normalizedFeatureId = [string]$featureId
        if ($selectedUndoFeatureIds.Add($normalizedFeatureId)) {
            $selectedUndoFeatures.Add($normalizedFeatureId)
        }
    }

    if ($hasInvalidSelectedUndoFeatureId) {
        $errors.Add('SelectedUndoFeatures must contain non-empty string feature IDs.')
    }

    return [PSCustomObject]@{
        SelectedUndoFeatures = $selectedUndoFeatures.ToArray()
        Errors = $errors.ToArray()
    }
}

function Normalize-RegistryKeySnapshot {
    param(
        [Parameter(Mandatory)]
        $Snapshot
    )

    if (-not $Snapshot.PSObject.Properties['Path'] -or [string]::IsNullOrWhiteSpace([string]$Snapshot.Path)) {
        throw 'Backup validation failed: Registry key snapshot is missing Path.'
    }

    # A missing or non-Boolean Exists used to read as $false, and restoring a key
    # with Exists false deletes it. Only an explicit false may mean "delete".
    if (-not $Snapshot.PSObject.Properties['Exists'] -or $Snapshot.Exists -isnot [bool]) {
        throw "Backup validation failed: Registry key snapshot '$($Snapshot.Path)' must set Exists to true or false."
    }
    $exists = $Snapshot.Exists

    $values = @()
    if ($Snapshot.PSObject.Properties['Values']) {
        foreach ($valueSnapshot in @($Snapshot.Values)) {
            $valueExists = $true
            if ($valueSnapshot.PSObject.Properties['Exists']) {
                $valueExists = [bool]$valueSnapshot.Exists
            }

            $values += [PSCustomObject]@{
                Name = [string]$valueSnapshot.Name
                Exists = $valueExists
                Kind = if ($valueSnapshot.PSObject.Properties['Kind']) { [string]$valueSnapshot.Kind } else { $null }
                Data = if ($valueSnapshot.PSObject.Properties['Data']) { $valueSnapshot.Data } else { $null }
            }
        }
    }

    $subKeys = @()
    if ($Snapshot.PSObject.Properties['SubKeys']) {
        foreach ($subKeySnapshot in @($Snapshot.SubKeys)) {
            $subKeys += @(Normalize-RegistryKeySnapshot -Snapshot $subKeySnapshot)
        }
    }

    # DeleteScope and DeleteValueNames come from the selected features' capture plans
    # (Set-RegistrySnapshotDeleteScope), never from the backup file.
    return [PSCustomObject]@{
        Path = [string]$Snapshot.Path
        Exists = $exists
        Values = @($values)
        SubKeys = @($subKeys)
        DeleteScope = 'Tree'
        DeleteValueNames = @()
    }
}

function Test-RegistryBackupMatchesSelectedFeatures {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$SelectedFeatureIds,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$SelectedUndoFeatureIds,
        [Parameter(Mandatory)]
        [string]$Target,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$RegistryKeys,
        [AllowNull()]
        [System.Collections.Generic.List[string]]$ExecutableValueWarnings = $null
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $planMap = Get-RegistryBackupAllowListPlanMap -SelectedFeatureIds @($SelectedFeatureIds) -SelectedUndoFeatureIds @($SelectedUndoFeatureIds) -Target $Target -Errors $errors
    if ($errors.Count -gt 0) {
        return $errors.ToArray()
    }

    if ($planMap.Count -eq 0 -and @($RegistryKeys).Count -gt 0) {
        $errors.Add('Backup contains registry snapshots but no allowed registry paths were derived from the selected features.')
    }

    $trustedValueMap = $null
    if ($planMap.Count -gt 0) {
        $trustedValueMap = Get-RegistryBackupTrustedValueMap -Features @($script:Features.Values)
    }

    foreach ($rootSnapshot in @($RegistryKeys)) {
        Test-RegistrySnapshotAgainstAllowList -Snapshot $rootSnapshot -PlanMap $planMap -Errors $errors -TrustedValueMap $trustedValueMap -ExecutableValueWarnings $ExecutableValueWarnings
    }

    return $errors.ToArray()
}

<#
    .SYNOPSIS
        Builds the registry allow-list from the capture plans of the selected features.

    .DESCRIPTION
        The backup only names feature IDs; every path, value name and deletion it
        may restore comes from Winnow's own .reg files for those features.
#>
function Get-RegistryBackupAllowListPlanMap {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$SelectedFeatureIds,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$SelectedUndoFeatureIds,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Target,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Errors
    )

    if (-not $script:Features -or $script:Features.Count -eq 0) {
        $Errors.Add('Unable to validate registry backup allowlist because feature definitions are not loaded.')
        return @{}
    }

    $selectedRegistryFeatures = @(Get-SelectedRegistryFeaturesForBackupValidation -SelectedFeatureIds @($SelectedFeatureIds) -IsUndoFeature:$false -Errors $Errors)
    $undoRegistryFeatures = @(Get-SelectedRegistryFeaturesForBackupValidation -SelectedFeatureIds @($SelectedUndoFeatureIds) -IsUndoFeature:$true -Errors $Errors)
    $useSysprepRegFiles = ($Target -eq 'DefaultUserProfile') -or ($Target -like 'User:*')

    $capturePlans = @()
    if ($Errors.Count -eq 0 -and ($selectedRegistryFeatures.Count -gt 0 -or $undoRegistryFeatures.Count -gt 0)) {
        $capturePlans = @(Get-RegistryBackupCapturePlans -SelectedRegistryFeatures @($selectedRegistryFeatures) -UndoRegistryFeatures @($undoRegistryFeatures) -UseSysprepRegFiles:$useSysprepRegFiles)
    }

    return (New-RegistryBackupAllowListPlanMap -CapturePlans @($capturePlans))
}

<#
    .SYNOPSIS
        Records, on each validated snapshot, what restoring "Exists = false" may delete.

    .DESCRIPTION
        Restoring a key that did not exist before used to delete the whole key tree,
        whatever the feature had written there. A key a feature deletes outright
        ([-KEY] in a .reg file, or anything under it) keeps that whole-tree scope.
        Any other key may only lose the value names its features write; the key
        itself goes only once nothing else is left in it (Restore-RegistryKeySnapshot).
#>
function Set-RegistrySnapshotDeleteScope {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$RegistryKeys,
        [Parameter(Mandatory)]
        [hashtable]$PlanMap
    )

    foreach ($snapshot in @($RegistryKeys)) {
        $normalizedPath = Get-NormalizedRegistryPathKey -Path ([string]$snapshot.Path)
        $planMatch = if ($normalizedPath) { Find-RegistryAllowListPlanMatch -NormalizedPath $normalizedPath -PlanMap $PlanMap } else { $null }

        if ($planMatch -and $planMatch.IncludeSubKeys) {
            $snapshot.DeleteScope = 'Tree'
            $snapshot.DeleteValueNames = @()
        }
        else {
            $snapshot.DeleteScope = 'Values'
            $snapshot.DeleteValueNames = if ($planMatch) { @($planMatch.ValueNames) } else { @() }
        }

        Set-RegistrySnapshotDeleteScope -RegistryKeys @($snapshot.SubKeys) -PlanMap $PlanMap
    }
}

<#
    .SYNOPSIS
        Reads the executable-capable value data Winnow's own .reg files write.

    .DESCRIPTION
        Covers every catalog feature in both directions and both the normal and the
        Sysprep files. This only supplies data to compare against; which paths and
        value names a backup may touch is still decided by the selected features.
#>
function Get-RegistryBackupTrustedValueMap {
    param(
        [object[]]$Features = @()
    )

    $filePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($feature in @($Features)) {
        foreach ($useSysprep in @($false, $true)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$feature.RegistryKey)) {
                $null = $filePaths.Add((Get-RegistryFilePathForFeature -RegistryKey $feature.RegistryKey -UseSysprepRegFiles:$useSysprep))
            }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$feature.RegistryUndoKey)) {
            $undoPath = Resolve-RegistryBackupUndoFilePath -Feature $feature
            if ($undoPath) { $null = $filePaths.Add($undoPath) }
        }
    }

    $trustedValueMap = @{}
    foreach ($filePath in $filePaths) {
        if (-not (Test-Path -LiteralPath $filePath)) { continue }
        foreach ($operation in @(Get-RegFileOperations -regFilePath $filePath)) {
            if ($operation.OperationType -ne 'SetValue') { continue }
            $kindName = if ($operation.ValueType -eq 'Hex2') { 'ExpandString' } else { [string]$operation.ValueType }
            if (-not (Test-RegistryValueMayExecuteCode -Path $operation.KeyPath -ValueName ([string]$operation.ValueName) -KindName $kindName)) { continue }

            $pathKey = Get-NormalizedRegistryPathKey -Path $operation.KeyPath
            if (-not $pathKey) { continue }
            if (-not $trustedValueMap.ContainsKey($pathKey)) {
                $trustedValueMap[$pathKey] = @{}
            }
            $valueKey = ([string]$operation.ValueName).ToLowerInvariant()
            $trustedValueMap[$pathKey][$valueKey] = @($trustedValueMap[$pathKey][$valueKey]) + @([PSCustomObject]@{ Kind = $kindName; Data = [string]$operation.ValueData })
        }
    }

    return $trustedValueMap
}

<#
    .SYNOPSIS
        Identifies registry locations whose data Windows runs or loads as code.

    .DESCRIPTION
        Run/RunOnce command lines, COM server registrations, shell verbs and context
        menu handlers, and value names that name a handler or surrogate. Restoring
        data there from a backup file can start a program, so such data must match
        what Winnow itself writes or be confirmed by the user.
#>
function Test-RegistryValueMayExecuteCode {
    param(
        [string]$Path,
        [AllowEmptyString()]
        [string]$ValueName,
        [string]$KindName = 'String'
    )

    $parts = Split-RegistryPath -path $Path
    if (-not $parts) { return $false }
    $subKey = [string]$parts.SubKey

    return ($subKey -match '(?i)(?:^|\\)(?:Run|RunOnce|RunOnceEx|InprocServer(?:32)?|InprocHandler(?:32)?|LocalServer(?:32)?|TreatAs|AutoTreatAs|AutoConvertTo|ScriptletURL)(?:\\|$)') -or
        ($subKey -match '(?i)\\shell\\[^\\]+\\(?:command|ddeexec)(?:\\|$)') -or
        ($ValueName -eq '' -and $subKey -match '(?i)\\shellex\\ContextMenuHandlers\\[^\\]+$') -or
        ($KindName -notin @('DWord', 'QWord') -and $subKey -match '(?i)(?:^|\\)CLSID\\[^\\]+(?:\\|$)') -or
        ($ValueName -match '^(?i:DelegateExecute|ExplorerCommandHandler|ScriptletURL|DllSurrogate|DllSurrogateExecutable)$')
}

<#
    .SYNOPSIS
        Checks backup data for an executable-capable value against Winnow's own .reg data.

    .OUTPUTS
        'Trusted' when the data is empty or matches what a catalog .reg file writes,
        'Untrusted' for any other string data, 'Invalid' for a kind that cannot hold
        a command line here.
#>
function Get-RegistryExecutableValueTrust {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [AllowEmptyString()]
        [string]$ValueName,
        [string]$KindName,
        $Data,
        [hashtable]$TrustedValueMap
    )

    if ($KindName -in @('DWord', 'QWord')) { return 'Trusted' }
    if ($KindName -notin @('String', 'ExpandString')) { return 'Invalid' }
    if ($null -eq $Data -or [string]$Data -ceq '') { return 'Trusted' }

    $pathKey = Get-NormalizedRegistryPathKey -Path $Path
    if ($null -ne $TrustedValueMap -and $pathKey -and $TrustedValueMap.ContainsKey($pathKey)) {
        foreach ($trusted in @($TrustedValueMap[$pathKey][$ValueName.ToLowerInvariant()])) {
            if ($null -eq $trusted) { continue }
            if ($trusted.Kind -eq $KindName -and $trusted.Data -ceq [string]$Data) { return 'Trusted' }
        }
    }

    return 'Untrusted'
}

function Get-SelectedRegistryFeaturesForBackupValidation {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$SelectedFeatureIds,
        [Parameter(Mandatory)]
        [bool]$IsUndoFeature,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        $Errors
    )

    if ($null -eq $Errors -or -not ($Errors -is [System.Collections.IList])) {
        throw 'Get-SelectedRegistryFeaturesForBackupValidation requires Errors to be a mutable list collection.'
    }

    $selectedRegistryFeatures = New-Object System.Collections.Generic.List[object]
    foreach ($featureId in @($SelectedFeatureIds)) {
        if (-not $script:Features.ContainsKey($featureId)) {
            $Errors.Add("Selected feature '$featureId' was not found in the current feature catalog.")
            continue
        }

        $feature = $script:Features[$featureId]
        if (-not $feature) {
            continue
        }

        # For undo features, check RegistryUndoKey if present (real features)
        # Otherwise check RegistryKey (for synthetic features from backup capture)
        $registryKeyToUse = if ($IsUndoFeature) {
            $key = [string]$feature.RegistryUndoKey
            if (-not [string]::IsNullOrWhiteSpace($key)) {
                $key
            }
            else {
                [string]$feature.RegistryKey
            }
        }
        else {
            [string]$feature.RegistryKey
        }

        if (-not [string]::IsNullOrWhiteSpace($registryKeyToUse)) {
            $selectedRegistryFeatures.Add($feature)
        }
    }

    return $selectedRegistryFeatures.ToArray()
}

function New-RegistryBackupAllowListPlanMap {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$CapturePlans
    )

    $planMap = @{}
    foreach ($plan in @($CapturePlans)) {
        $normalizedPath = Get-NormalizedRegistryPathKey -Path $plan.Path
        if ([string]::IsNullOrWhiteSpace($normalizedPath)) {
            continue
        }

        $planMap[$normalizedPath] = [PSCustomObject]@{
            Path = $plan.Path
            NormalizedPath = $normalizedPath
            IncludeSubKeys = [bool]$plan.IncludeSubKeys
            CaptureAllValues = [bool]$plan.CaptureAllValues
            ValueNames = ConvertTo-RegistryValueNameSet -ValueNames @($plan.ValueNames)
        }
    }

    return $planMap
}

function ConvertTo-RegistryValueNameSet {
    param(
        [AllowEmptyCollection()]
        [string[]]$ValueNames
    )

    $valueNameSet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($valueName in @($ValueNames)) {
        $null = $valueNameSet.Add([string]$valueName)
    }

    return $valueNameSet
}

function Test-RegistrySnapshotAgainstAllowList {
    param(
        [Parameter(Mandatory)]
        $Snapshot,
        [Parameter(Mandatory)]
        [hashtable]$PlanMap,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$Errors,
        [AllowNull()]
        [hashtable]$TrustedValueMap = $null,
        [AllowNull()]
        [System.Collections.Generic.List[string]]$ExecutableValueWarnings = $null
    )

    $snapshotPath = [string]$Snapshot.Path
    $normalizedPath = Get-NormalizedRegistryPathKey -Path $snapshotPath
    if ([string]::IsNullOrWhiteSpace($normalizedPath) -or $snapshotPath.IndexOf([char]0) -ge 0) {
        $Errors.Add("Backup contains unsupported registry path '$snapshotPath'.")
        return
    }

    $planMatch = Find-RegistryAllowListPlanMatch -NormalizedPath $normalizedPath -PlanMap $PlanMap
    if ($null -eq $planMatch) {
        $Errors.Add("Backup contains unexpected registry path '$snapshotPath' that is not allowed by SelectedFeatures.")
        return
    }

    # Restoring a snapshot with sub-keys replaces the whole tree, so only a key the
    # features capture with its sub-keys may carry them.
    if (@($Snapshot.SubKeys).Count -gt 0 -and -not $planMatch.IncludeSubKeys) {
        $Errors.Add("Backup contains sub-keys under '$snapshotPath', which the selected features do not capture.")
    }

    foreach ($valueSnapshot in @($Snapshot.Values)) {
        $valueName = Get-NormalizedRegistryValueName -ValueName $valueSnapshot.Name
        $valueExists = [bool]$valueSnapshot.Exists

        if ($valueName.IndexOf([char]0) -ge 0 -or -not (Test-RegistryValueAllowedByPlan -PlanMatch $planMatch -ValueName $valueName)) {
            $Errors.Add("Backup contains unexpected value '$valueName' under '$snapshotPath'.")
        }

        $kindName = if ($valueSnapshot.PSObject.Properties['Kind']) { [string]$valueSnapshot.Kind } else { '' }
        $valueReference = Get-RegistryValueReferenceForError -SnapshotPath $snapshotPath -ValueName $valueName
        if ($valueExists) {
            if (-not (Test-RegistryValueKindNameSupported -KindName $kindName)) {
                $Errors.Add("Backup contains unsupported registry value kind '$kindName' for '$valueReference'.")
            }
            elseif (Test-RegistryValueMayExecuteCode -Path $snapshotPath -ValueName $valueName -KindName $kindName) {
                $normalizedKind = [System.Enum]::Parse([Microsoft.Win32.RegistryValueKind], $kindName, $true).ToString()
                switch (Get-RegistryExecutableValueTrust -Path $snapshotPath -ValueName $valueName -KindName $normalizedKind -Data $valueSnapshot.Data -TrustedValueMap $TrustedValueMap) {
                    'Invalid' {
                        $Errors.Add("Backup value '$valueReference' can start a program and must be a string, not '$kindName'.")
                    }
                    'Untrusted' {
                        if ($null -ne $ExecutableValueWarnings) {
                            $ExecutableValueWarnings.Add("$valueReference = $([string]$valueSnapshot.Data)")
                        }
                        else {
                            $Errors.Add("Backup value '$valueReference' can start a program and does not match what Winnow writes there.")
                        }
                    }
                }
            }
        }
        elseif (-not [string]::IsNullOrWhiteSpace($kindName)) {
            $Errors.Add("Backup value '$valueReference' must not define Kind when Exists is false.")
        }
    }

    foreach ($subKeySnapshot in @($Snapshot.SubKeys)) {
        Test-RegistrySnapshotAgainstAllowList -Snapshot $subKeySnapshot -PlanMap $PlanMap -Errors $Errors -TrustedValueMap $TrustedValueMap -ExecutableValueWarnings $ExecutableValueWarnings
    }
}

function Test-RegistryValueAllowedByPlan {
    param(
        [Parameter(Mandatory)]
        $PlanMatch,
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ValueName
    )

    $ValueName = Get-NormalizedRegistryValueName -ValueName $ValueName

    if ($PlanMatch.CaptureAllValues -or $PlanMatch.IsDescendant) {
        return $true
    }

    return $PlanMatch.ValueNames.Contains($ValueName)
}

function Get-RegistryValueReferenceForError {
    param(
        [Parameter(Mandatory)]
        [string]$SnapshotPath,
        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ValueName
    )

    $ValueName = Get-NormalizedRegistryValueName -ValueName $ValueName

    if ([string]::IsNullOrWhiteSpace($ValueName)) {
        return "$SnapshotPath\\(Default)"
    }

    return "$SnapshotPath\\$ValueName"
}

function Get-NormalizedRegistryValueName {
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [object]$ValueName
    )

    if ($null -eq $ValueName) {
        return ''
    }

    return [string]$ValueName
}

function Find-RegistryAllowListPlanMatch {
    param(
        [Parameter(Mandatory)]
        [string]$NormalizedPath,
        [Parameter(Mandatory)]
        [hashtable]$PlanMap
    )

    if ($PlanMap.ContainsKey($NormalizedPath)) {
        $plan = $PlanMap[$NormalizedPath]
        return [PSCustomObject]@{
            IsDescendant = $false
            IncludeSubKeys = [bool]$plan.IncludeSubKeys
            CaptureAllValues = [bool]$plan.CaptureAllValues
            ValueNames = $plan.ValueNames
        }
    }

    foreach ($plan in @($PlanMap.Values)) {
        if (-not [bool]$plan.IncludeSubKeys) {
            continue
        }

        $subKeyPrefix = "$($plan.NormalizedPath)\"
        if ($NormalizedPath.StartsWith($subKeyPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return [PSCustomObject]@{
                IsDescendant = $true
                IncludeSubKeys = $true
                CaptureAllValues = $true
                ValueNames = $plan.ValueNames
            }
        }
    }

    return $null
}

function Get-NormalizedRegistryPathKey {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $parts = Split-RegistryPath -path $Path
    if (-not $parts) {
        return $null
    }

    $hiveName = [string]$parts.Hive
    if ([string]::IsNullOrWhiteSpace($hiveName)) {
        return $null
    }

    $normalizedHive = $hiveName.ToUpperInvariant()
    $subKey = [string]$parts.SubKey
    if ([string]::IsNullOrWhiteSpace($subKey)) {
        return $normalizedHive
    }

    $normalizedSubKey = ($subKey -replace '/', '\\').Trim('\')
    if ([string]::IsNullOrWhiteSpace($normalizedSubKey)) {
        return $normalizedHive
    }

    return "$normalizedHive\\$normalizedSubKey"
}

function Test-RegistryValueKindNameSupported {
    param(
        [string]$KindName
    )

    if ([string]::IsNullOrWhiteSpace($KindName)) {
        return $false
    }

    try {
        $kind = [System.Enum]::Parse([Microsoft.Win32.RegistryValueKind], $KindName, $true)
        return $kind -ne [Microsoft.Win32.RegistryValueKind]::Unknown
    }
    catch {
        return $false
    }
}
