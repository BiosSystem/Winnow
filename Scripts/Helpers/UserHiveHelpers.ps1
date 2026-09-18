function New-TargetUserHiveContext {
    param(
        [Parameter(Mandatory)]
        [string]$TargetUserName,
        [AllowNull()]
        [object]$UserContext,
        [Parameter(Mandatory)]
        [string]$HiveDatPath,
        [AllowNull()]
        [string]$MountName,
        [bool]$WasAlreadyLoaded = $false,
        [bool]$WasLoadedByScript = $false
    )

    $effectiveMountName = if ([string]::IsNullOrWhiteSpace($MountName)) { 'Default' } else { $MountName }

    return [PSCustomObject]@{
        TargetUserName = $TargetUserName
        UserSid = if ($UserContext) { $UserContext.UserSid } else { $null }
        ProfilePath = if ($UserContext) { $UserContext.ProfilePath } else { $null }
        HiveDatPath = $HiveDatPath
        MountName = $effectiveMountName
        WasAlreadyLoaded = $WasAlreadyLoaded
        WasLoadedByScript = $WasLoadedByScript
    }
}

function Resolve-TargetUserHiveContext {
    param(
        [Parameter(Mandatory)]
        [string]$TargetUserName
    )

    $normalizedTargetUserName = NormalizeUserLookupValue -Value $TargetUserName
    if ([string]::IsNullOrWhiteSpace($normalizedTargetUserName)) {
        throw 'Target user name for registry hive resolution is empty.'
    }

    $userContext = ResolveUserProfileContext -UserName $normalizedTargetUserName
    if (-not $userContext -or [string]::IsNullOrWhiteSpace([string]$userContext.ProfilePath)) {
        throw "Unable to resolve profile path for target user '$normalizedTargetUserName'."
    }

    $hiveDatPath = Join-Path $userContext.ProfilePath 'NTUSER.DAT'
    if (-not (Test-Path -LiteralPath $hiveDatPath)) {
        throw "Unable to find target user hive at '$hiveDatPath'."
    }

    $isDefaultProfile = $normalizedTargetUserName.Equals('Default', [System.StringComparison]::OrdinalIgnoreCase)
    $userSid = if ($userContext) { [string]$userContext.UserSid } else { '' }

    if ((-not $isDefaultProfile) -and (-not [string]::IsNullOrWhiteSpace($userSid))) {
        $loadedHivePath = "Registry::HKEY_USERS\$userSid"
        if (Test-Path -LiteralPath $loadedHivePath) {
            return (New-TargetUserHiveContext `
                -TargetUserName $normalizedTargetUserName `
                -UserContext $userContext `
                -HiveDatPath $hiveDatPath `
                -MountName $userSid `
                -WasAlreadyLoaded $true `
                -WasLoadedByScript $false)
        }
    }

    return (New-TargetUserHiveContext `
        -TargetUserName $normalizedTargetUserName `
        -UserContext $userContext `
        -HiveDatPath $hiveDatPath `
        -MountName 'Default' `
        -WasAlreadyLoaded $false `
        -WasLoadedByScript $false)
}

function Resolve-LoadedTargetUserHiveContext {
    param(
        [Parameter(Mandatory)]
        $HiveContext
    )

    $userSid = [string]$HiveContext.UserSid
    if ([string]::IsNullOrWhiteSpace($userSid)) {
        return $null
    }

    $loadedHivePath = "Registry::HKEY_USERS\$userSid"
    if (-not (Test-Path -LiteralPath $loadedHivePath)) {
        return $null
    }

    return (New-TargetUserHiveContext `
        -TargetUserName $HiveContext.TargetUserName `
        -UserContext ([PSCustomObject]@{ UserSid = $HiveContext.UserSid; ProfilePath = $HiveContext.ProfilePath }) `
        -HiveDatPath $HiveContext.HiveDatPath `
        -MountName $userSid `
        -WasAlreadyLoaded $true `
        -WasLoadedByScript $false)
}

function Invoke-WinnowRegHiveUnload {
    # Thin wrapper around `reg unload` so the retry logic in Dismount-WinnowTargetUserHive can be
    # unit-tested; reg.exe is a native command and cannot be mocked directly. Returns the exit code.
    param(
        [Parameter(Mandatory)]
        [string]$MountName
    )

    $global:LASTEXITCODE = 0
    reg unload "HKU\$MountName" | Out-Null
    return $LASTEXITCODE
}

function Dismount-WinnowTargetUserHive {
    # Unloads a hive the script mounted. The registry provider and .NET RegistryKey objects keep
    # handles open into the hive until they are finalized, and `reg unload` fails while any handle is
    # still open, which previously left the hive mounted after a Sysprep or per-user run (the apply,
    # verification, and restore-to-another-user paths all read or write the loaded hive). Force a
    # garbage collection to release those handles before unloading, and retry once after a second
    # pass, since a handle can survive the first collect. Returns $true when the hive is unloaded.
    param(
        [Parameter(Mandatory)]
        [string]$MountName
    )

    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    if ((Invoke-WinnowRegHiveUnload -MountName $MountName) -eq 0) {
        return $true
    }

    Start-Sleep -Milliseconds 200
    [System.GC]::Collect()
    [System.GC]::WaitForPendingFinalizers()
    if ((Invoke-WinnowRegHiveUnload -MountName $MountName) -eq 0) {
        return $true
    }

    Write-Warning "Failed to unload registry hive 'HKU\$MountName' after a retry. It may stay mounted until the next reboot; close any tool browsing HKEY_USERS and re-run, or reboot."
    return $false
}

function Invoke-WithTargetUserHive {
    param(
        [Parameter(Mandatory)]
        [string]$TargetUserName,
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        $ArgumentObject = $null,
        [switch]$PassHiveContext
    )

    $hiveContext = Resolve-TargetUserHiveContext -TargetUserName $TargetUserName
    $previousHiveMountName = $script:RegistryTargetHiveMountName

    try {
        if (-not $hiveContext.WasAlreadyLoaded) {
            $global:LASTEXITCODE = 0
            reg load "HKU\$($hiveContext.MountName)" "$($hiveContext.HiveDatPath)" | Out-Null
            $loadExitCode = $LASTEXITCODE

            if ($loadExitCode -ne 0) {
                $loadedSidContext = Resolve-LoadedTargetUserHiveContext -HiveContext $hiveContext
                if ($loadedSidContext) {
                    $hiveContext = $loadedSidContext
                }
                else {
                    throw "Failed to load target user hive '$($hiveContext.HiveDatPath)' (exit code: $loadExitCode)."
                }
            }
            else {
                $hiveContext.WasLoadedByScript = $true
            }
        }

        $script:RegistryTargetHiveMountName = [string]$hiveContext.MountName

        if ($PassHiveContext) {
            return & $ScriptBlock $ArgumentObject $hiveContext
        }

        return & $ScriptBlock $ArgumentObject
    }
    finally {
        $script:RegistryTargetHiveMountName = $previousHiveMountName

        if ($hiveContext -and $hiveContext.WasLoadedByScript) {
            $null = Dismount-WinnowTargetUserHive -MountName ([string]$hiveContext.MountName)
        }
    }
}
