<#
    .SYNOPSIS
    Removes one or more Windows app packages based on the target scope.

    .DESCRIPTION
    Iterates over the provided list of app identifiers and removes each one.
    The removal method (winget vs. Appx cmdlets) is determined per-app from
    Apps.json. Microsoft Edge is deferred to the end of the loop so that all
    winget attempts run before any force-remove prompt. A scheduled task is
    only created when the User or Sysprep parameter was passed.
    After each winget removal, the system is checked to confirm whether the
    app is still installed before reporting an error.

    .PARAMETER appsList
    An array of app package identifiers to remove (e.g. 'Microsoft.BingNews').

    .EXAMPLE
    RemoveApps @('Microsoft.BingNews', 'Microsoft.BingWeather')

    .EXAMPLE
    RemoveApps -appsList (GenerateAppsList)
#>
function RemoveApps {
    param (
        $appslist
    )

    if ($script:Params.ContainsKey("WhatIf")) {
        foreach ($app in $appslist) {
            Write-Host "[WhatIf] Remove App Package: $app" -ForegroundColor Cyan
        }

        Write-Host ""
        return
    }

    $targetUser = GetTargetUserForAppRemoval
    $appCount = @($appsList).Count
    $appIndex = 0

    $edgeIds = @('Microsoft.Edge', 'XPFFTQ037JWMHS')
    $edgeAppsInList = @()
    $wingetRemovedApps = @()

    Foreach ($app in $appsList) {
        if ($script:CancelRequested) { return }

        $appIndex++

        if ($script:ApplySubStepCallback -and $appCount -gt 1) {
            & $script:ApplySubStepCallback "Removing apps ($appIndex/$appCount)" $appIndex $appCount
        }

        # Microsoft Edge is handled after the loop to avoid duplicate scheduled tasks and allow fallback if winget fails
        if ($edgeIds -contains $app) {
            $edgeAppsInList += $app
            continue
        }

        Write-Host "Removing $app"

        if ((Get-AppRemovalMethod $app) -eq 'WinGet') {
            Remove-WinGetApp -app $app
            $wingetRemovedApps += $app
        }
        else {
            Remove-AppxApp -app $app -targetUser $targetUser
        }
    }

    # Remove Microsoft Edge
    if ($edgeAppsInList.Count -gt 0) {
        Remove-EdgeApp -edgeAppsInList $edgeAppsInList
    }

    # An uninstall deferred to the next sign-in is expected to still be present
    # now, so it is not verified (or reported as failed) here.
    $wingetRemovedApps = @($wingetRemovedApps | Where-Object { @($script:AppRemovalDeferredApps) -notcontains $_ })

    # Check whether any winget-removed apps are still present, and report errors for each one.
    if ($wingetRemovedApps.Count -gt 0 -or $edgeAppsInList.Count -gt 0) {
        $postRemovalList = if ($script:WingetInstalled) { GetInstalledAppsViaWinget -TimeOut 10 -NonBlocking } else { $null }
        if ($null -eq $postRemovalList -and $wingetRemovedApps.Count -gt 0) {
            # Could not read the post-removal list, so these removals cannot be
            # confirmed either way. Flag it rather than reporting false success.
            $script:AppRemovalVerificationUnavailable = $true
        }
        foreach ($app in $wingetRemovedApps) {
            if ($null -eq $postRemovalList) { continue }
            if (Test-AppStillInstalled -appId $app -InstalledList $postRemovalList) {
                Write-Host "Unable to uninstall $app via WinGet" -ForegroundColor Red
                $script:AppRemovalFailures++
                $script:AppRemovalFailedApps += $app
            }
            else {
                $script:AppRemovalRemovedApps += $app
            }
        }

        # Verify Edge separately (triggers its own force-remove path if still installed)
        $edgeStillInstalled = $false
        foreach ($edgeApp in $edgeAppsInList) {
            if (Test-AppStillInstalled -appId $edgeApp -InstalledList $postRemovalList) {
                $edgeStillInstalled = $true
                break
            }
        }
        if ($edgeStillInstalled) {
            Write-Host "Unable to uninstall Microsoft Edge via WinGet" -ForegroundColor Red
            Request-EdgeForceRemove
        }
    }

    Write-Host ""
}

<#
    .SYNOPSIS
    Uninstalls a non-Edge app via WinGet and/or schedules its removal.

    .DESCRIPTION
    Runs winget uninstall for a single app. If the User or Sysprep
    parameter was passed, also schedules removal for future logins.
    After uninstall, the system is checked to confirm whether the app
    is still present - winget output is not trusted on its
    own, as it sometimes reports failure after a successful removal.
    Edge apps are handled separately after the main loop.

    WinGet refuses to uninstall a package installed for user scope while
    elevated, and Winnow always runs elevated. That refusal is detected and
    the uninstall is deferred to the next sign-in instead of being reported
    as a failure.

    .PARAMETER app
    The WinGet package ID to uninstall (e.g. 'Microsoft.BingNews').
#>
function Remove-WinGetApp {
    param([string]$app)

    if (-not $script:WingetInstalled) {
        Write-Host "ERROR: WinGet is either not installed or is outdated, $app could not be removed" -ForegroundColor Red
        return
    }

    $scheduledForTarget = $false
    if ($script:Params.ContainsKey("User")) {
        Write-Host "Adding scheduled task to uninstall $app for user $(GetUserName)..."
        $scheduledForTarget = [bool](Set-RunOnceWingetTask -appId $app)
    }
    elseif ($script:Params.ContainsKey("Sysprep")) {
        Write-Host "Adding scheduled task to uninstall $app for new users..."
        $scheduledForTarget = [bool](Set-RunOnceWingetTask -appId $app)
    }

    # Capture the exit code and output so a user-scope refusal can be told
    # apart from other failures. stderr is left alone: redirecting a native
    # command's stderr can raise a terminating error in Windows PowerShell.
    $result = Invoke-NonBlocking -ScriptBlock {
        param($appId)
        $output = @(winget uninstall --accept-source-agreements --disable-interactivity --id $appId | ForEach-Object { [string]$_ })
        [PSCustomObject]@{ Output = $output; ExitCode = $LASTEXITCODE }
    } -ArgumentList $app

    # Echo winget's messages, minus the spinner and progress-bar lines.
    foreach ($line in @($result.Output)) {
        if ($line -and $line.Trim() -and $line -notmatch '^[\s\-\\|/\u2588\u2592]+$') {
            Write-Host $line
        }
    }

    if (Test-WingetUserScopeBlocked -Result $result) {
        Add-DeferredWingetUninstall -app $app -AlreadyScheduled:$scheduledForTarget
    }
}

<#
    .SYNOPSIS
    Reports whether winget refused an uninstall because the package is
    installed for user scope and winget was running elevated.

    .PARAMETER Result
    The object Remove-WinGetApp builds from the winget run (Output, ExitCode).
#>
function Test-WingetUserScopeBlocked {
    param($Result)

    if ($null -eq $Result) { return $false }

    # APPINSTALLER_CLI_ERROR_ADMIN_CONTEXT_ACTION_PROHIBITED, 0x8A15007D.
    $exitCode = [string]$Result.ExitCode
    if ($exitCode -eq '-1978335107' -or $exitCode -match '^0x0?8A15007D$') {
        return $true
    }

    # Fallback for winget builds that do not return the specific code.
    return (@($Result.Output | Where-Object {
                $null -ne $_ -and [string]$_ -match 'installed for user scope cannot be uninstalled when running with administrator privileges'
            }).Count -gt 0)
}

<#
    .SYNOPSIS
    Defers a winget uninstall that was refused for a user-scope package to
    the next sign-in, and records it so it is not reported as a failure.

    .PARAMETER app
    The WinGet package ID.

    .PARAMETER AlreadyScheduled
    A RunOnce uninstall was already scheduled for the -User or -Sysprep
    target before winget ran, so nothing new is scheduled.
#>
function Add-DeferredWingetUninstall {
    param(
        [string]$app,
        [switch]$AlreadyScheduled
    )

    $scheduled = [bool]$AlreadyScheduled
    if (-not $scheduled) {
        $targets = @(Get-RunOnceWingetTargets)
        $scheduled = $targets.Count -gt 0
        foreach ($userName in $targets) {
            if (-not (Set-RunOnceWingetTask -appId $app -TargetUserName $userName)) {
                $scheduled = $false
            }
        }
    }

    if (-not $scheduled) {
        # Left out of the deferred list, so the post-removal check reports it.
        Write-Host "WinGet cannot uninstall $app while running as administrator because it is installed for user scope, and scheduling the uninstall for the next sign-in failed for one or more users." -ForegroundColor Red
        return
    }

    if (@($script:AppRemovalDeferredApps) -notcontains $app) {
        $script:AppRemovalDeferredApps = @($script:AppRemovalDeferredApps) + $app
    }
    Write-Host "WinGet cannot uninstall $app while running as administrator because it is installed for user scope. The uninstall will run at the next sign-in." -ForegroundColor Yellow
}

<#
    .SYNOPSIS
    Returns the user names whose RunOnce key should carry a deferred winget
    uninstall.

    .DESCRIPTION
    -Sysprep targets the Default profile and -User the named user. Otherwise
    the app removal target decides: CurrentUser or a named user gets that one
    user; AllUsers (the default) gets every existing profile that has a hive,
    plus Default so profiles created later run it too. Profiles whose account
    name cannot be resolved are skipped with a warning.
#>
function Get-RunOnceWingetTargets {
    if ($script:Params.ContainsKey('Sysprep')) { return @('Default') }
    if ($script:Params.ContainsKey('User')) { return @($script:Params['User']) }

    $target = GetTargetUserForAppRemoval
    if ($target -ieq 'CurrentUser') { return @($env:USERNAME) }
    if ($target -ine 'AllUsers') { return @($target) }

    $userNames = [System.Collections.Generic.List[string]]::new()
    try {
        foreach ($userProfile in @(Get-CimInstance -ClassName Win32_UserProfile -ErrorAction Stop)) {
            if ($userProfile.Special -or [string]::IsNullOrWhiteSpace([string]$userProfile.SID) -or
                [string]::IsNullOrWhiteSpace([string]$userProfile.LocalPath)) {
                continue
            }
            if (-not (Test-Path -LiteralPath (Join-Path $userProfile.LocalPath 'NTUSER.DAT'))) { continue }

            try {
                $sid = [System.Security.Principal.SecurityIdentifier]::new([string]$userProfile.SID)
                $userNames.Add($sid.Translate([System.Security.Principal.NTAccount]).Value)
            }
            catch {
                Write-Warning "Not scheduling the deferred uninstall for profile $($userProfile.SID): its account name could not be resolved."
            }
        }
    }
    catch {
        Write-Warning "Unable to list user profiles for the deferred uninstall: $($_.Exception.Message)"
        return @()
    }

    # RunOnce values in the Default profile are copied into profiles created later.
    $userNames.Add('Default')
    return @($userNames)
}

<#
    .SYNOPSIS
    Removes Microsoft Edge via WinGet (both AppIds), with fallback to force-remove.

    .DESCRIPTION
    Edge has multiple package IDs. Runs winget uninstall for each one,
    then creates a single scheduled task if the User or Sysprep parameter
    was passed. After all attempts, the system is checked to confirm
    whether Edge is still present. The force-remove prompt only
    appears if Edge remains installed - winget false positives are ignored.

    .PARAMETER edgeAppsInList
    The Edge AppIds that appear in the removal list (one or both).
#>
function Remove-EdgeApp {
    param([string[]]$edgeAppsInList)

    if (-not $script:WingetInstalled) {
        Write-Host "ERROR: WinGet is either not installed or is outdated, Microsoft Edge could not be removed" -ForegroundColor Red
        return
    }

    if ($script:Params.ContainsKey("User")) {
        Write-Host "Adding scheduled task to uninstall Microsoft Edge for user $(GetUserName)..."
        Set-RunOnceWingetTask -appId 'Microsoft.Edge'
    }
    elseif ($script:Params.ContainsKey("Sysprep")) {
        Write-Host "Adding scheduled task to uninstall Microsoft Edge for new users..."
        Set-RunOnceWingetTask -appId 'Microsoft.Edge'
    }

    foreach ($edgeApp in $edgeAppsInList) {
        Write-Host "Removing $edgeApp"
        Invoke-NonBlocking -ScriptBlock {
            param($appId)
            winget uninstall --accept-source-agreements --disable-interactivity --id $appId
        } -ArgumentList $edgeApp
    }
}

<#
    .SYNOPSIS
    Removes an app via Remove-AppxPackage / Remove-ProvisionedAppxPackage.

    .PARAMETER app
    The package identifier to remove (e.g. 'Clipchamp.Clipchamp').

    .PARAMETER targetUser
    Target scope: "AllUsers", "CurrentUser", or a specific username.
#>
function Remove-AppxApp {
    param([string]$app, [string]$targetUser)

    $appPattern = '*' + $app + '*'

    try {
        switch ($targetUser) {
            "AllUsers" {
                Invoke-NonBlocking -ScriptBlock {
                    param($pattern)
                    Get-AppxPackage -Name $pattern -AllUsers | Remove-AppxPackage -AllUsers -ErrorAction Continue
                    Get-AppxProvisionedPackage -Online | Where-Object { $_.PackageName -like $pattern } | ForEach-Object { Remove-ProvisionedAppxPackage -Online -AllUsers -PackageName $_.PackageName }
                    # 24H2 Resilient Appx Fallback via DISM
                    if ($pattern -like '*Copilot*' -or $pattern -like '*DevHome*' -or $pattern -like '*MSTeams*') {
                        try {
                            # Re-query so DISM only targets packages the cmdlet above left behind.
                            # /PackageName takes an exact provisioned package name; wildcards are rejected.
                            $stubborn = @(Get-AppxProvisionedPackage -Online | Where-Object { $_.PackageName -like $pattern })

                            foreach ($provisioned in $stubborn) {
                                $packageName = $provisioned.PackageName
                                $global:LASTEXITCODE = 0
                                DISM /Online /Remove-ProvisionedAppxPackage /PackageName:$packageName /quiet | Out-Null

                                # 3010 is success pending reboot.
                                if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) {
                                    Write-Warning "DISM fallback failed for $packageName with exit code $LASTEXITCODE"
                                }
                            }
                        } catch {
                            Write-Warning "DISM fallback encountered an error for $pattern : $_"
                        }
                    }
                } -ArgumentList $appPattern
            }
            "CurrentUser" {
                Invoke-NonBlocking -ScriptBlock {
                    param($pattern)
                    Get-AppxPackage -Name $pattern | Remove-AppxPackage -ErrorAction Continue
                } -ArgumentList $appPattern
            }
            default {
                Invoke-NonBlocking -ScriptBlock {
                    param($pattern, $user)
                    $userAccount = New-Object System.Security.Principal.NTAccount($user)
                    $userSid = $userAccount.Translate([System.Security.Principal.SecurityIdentifier]).Value
                    Get-AppxPackage -Name $pattern -User $userSid | Remove-AppxPackage -User $userSid -ErrorAction Continue
                } -ArgumentList @($appPattern, $targetUser)
            }
        }
    }
    catch {
        Write-Verbose "Something went wrong while trying to remove $($app): $_"
    }
}

<#
    .SYNOPSIS
    Checks whether an app package is still installed after a removal attempt.

    .DESCRIPTION
    Checks Get-AppxPackage across all users first (fast, no process launch),
    then falls back to a pre-fetched or live winget list for non-Appx packages.
    Uses Test-AppInWingetList which provides exact-match-first with substring
    fallback against the parsed winget objects.
    Returns $true if the app is still present, $false otherwise.

    .PARAMETER appId
    The package identifier to check (e.g. 'Microsoft.BingNews').

    .PARAMETER InstalledList
    Optional pre-fetched array of winget objects from GetInstalledAppsViaWinget.
    When provided, used directly; otherwise a live winget call is made.
#>
function Test-AppStillInstalled {
    param(
        [string]$appId,
        [object[]]$InstalledList
    )

    # Check Get-AppxPackage for all users first (fast, covers all Store apps).
    if (Get-AppxPackage -Name "$appId" -AllUsers -ErrorAction SilentlyContinue) {
        return $true
    }

    # Use the pre-fetched list if provided; otherwise fall back to a live winget call.
    if ($InstalledList) {
        return (Test-AppInWingetList -appId $appId -InstalledList $InstalledList)
    }

    if ($script:WingetInstalled) {
        $liveList = GetInstalledAppsViaWinget -TimeOut 10 -NonBlocking
        if (Test-AppInWingetList -appId $appId -InstalledList $liveList) {
            return $true
        }
    }
    else {
        Write-Warning "Unable to verify whether '$appId' is still installed (WinGet is unavailable)"
    }

    return $false
}

<#
    .SYNOPSIS
    Returns the removal method for an app identifier.

    .DESCRIPTION
    Parses Apps.json once (cached in script scope) to build a lookup of
    AppId -> RemovalMethod. Returns 'WinGet' if the app should be removed
    via winget, or 'Appx' if via Remove-AppxPackage. Defaults to 'Appx'
    for unknown IDs.

    .PARAMETER appId
    The package identifier (e.g. 'Clipchamp.Clipchamp').
#>
function Get-AppRemovalMethod {
    param([string]$appId)

    if (-not $script:AppRemovalMethodCache) {
        $script:AppRemovalMethodCache = @{}
        try {
            if (Test-Path $script:AppsListFilePath) {
                $appsJson = Get-Content -Path $script:AppsListFilePath -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($appData in $appsJson.Apps) {
                    $rawMethod = $appData.RemovalMethod
                    $method = if ($rawMethod -and $rawMethod -eq 'WinGet') { 'WinGet' } else { 'Appx' }
                    if ($appData.AppId -is [array]) {
                        foreach ($id in $appData.AppId) { $script:AppRemovalMethodCache[$id.Trim()] = $method }
                    }
                    else {
                        $script:AppRemovalMethodCache[$appData.AppId.Trim()] = $method
                    }
                }
            }
        }
        catch {
            Write-Warning "Failed to load app removal methods from '$script:AppsListFilePath'. Defaulting unknown apps to Appx. Error: $_"
        }
    }

    if ($script:AppRemovalMethodCache.ContainsKey($appId)) {
        return $script:AppRemovalMethodCache[$appId]
    }
    return 'Appx'
}

<#
    .SYNOPSIS
    Prompts the user to forcefully remove Microsoft Edge when winget cannot uninstall it.

    .DESCRIPTION
    Only invoked after it has been confirmed that Edge is still present
    following all winget uninstall attempts. In GUI mode, displays a
    warning message box; in CLI mode, prompts via Read-Host. On
    confirmation, performs a force-remove of the Edge package.
#>
function Request-EdgeForceRemove {
    if ($script:GuiWindow) {
        $result = Show-MessageBox -Message 'Unable to uninstall Microsoft Edge via WinGet. Would you like to forcefully uninstall it? NOT RECOMMENDED!' -Title 'Force Uninstall Microsoft Edge?' -Button 'YesNo' -Icon 'Warning'
        if ($result -eq 'Yes') {
            Write-Host ""
            $null = ForceRemoveEdge
        }
    }
    elseif ($(Read-Host -Prompt "Would you like to forcefully uninstall Microsoft Edge? NOT RECOMMENDED! (y/n)") -eq 'y') {
        Write-Host ""
        $null = ForceRemoveEdge
    }
}

<#
    .SYNOPSIS
    Dynamically sets a RunOnce registry key to schedule a winget uninstall.

    .DESCRIPTION
    Writes directly to HKEY_USERS\Default\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce
    via the PowerShell registry API within Invoke-WithTargetUserHive,
    which handles hive loading and HKEY_USERS\Default → SID remapping.
    Used instead of static .reg files to avoid file dependency for each WinGet app.

    The value starts winget.exe directly with the app ID as one quoted native
    argument. RunOnce values are started without a shell, so metacharacters such
    as &, |, <, > and ^ in an ID are passed through literally; embedded quotes and
    trailing backslashes are escaped for CommandLineToArgvW. Windows does not run
    a RunOnce command longer than 260 characters, so a longer one is refused
    instead of being written and silently skipped at sign-in.

    .PARAMETER appId
    The winget package ID to schedule for uninstall (e.g. 'XP9CXNGPPJ97XX').

    .PARAMETER TargetUserName
    The user whose hive receives the RunOnce value. Defaults to Default under
    -Sysprep and the -User account otherwise.

    .OUTPUTS
    System.Boolean. $true when the value was written; otherwise $false.
#>
function Set-RunOnceWingetTask {
    param(
        [string]$appId,
        [string]$TargetUserName
    )

    if (-not $TargetUserName) {
        $TargetUserName = if ($script:Params.ContainsKey("Sysprep")) { "Default" } else { $script:Params.Item("User") }
    }

    # Sanitize appId for use in registry value names (backslashes are path separators)
    $safeAppId = $appId.Replace('\', '_')

    $taskName = "Uninstall_$safeAppId"

    # Keep the ID one native argument: double backslashes before a quote or at the end,
    # escape embedded quotes. No cmd.exe or PowerShell parses the RunOnce value.
    $escapedAppId = $appId -replace '(\\*)"', '$1$1\"'
    $escapedAppId = $escapedAppId -replace '(\\+)$', '$1$1'
    $wingetCommand = "winget.exe uninstall --accept-source-agreements --disable-interactivity --id `"$escapedAppId`""
    if ($wingetCommand.Length -gt 260) {
        Write-Host "Failed to schedule uninstall task for $($appId): the RunOnce command is longer than the 260 characters Windows runs." -ForegroundColor Red
        return $false
    }

    $operation = [PSCustomObject]@{
        KeyPath       = 'HKEY_USERS\Default\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'
        ValueName     = $taskName
        ValueType     = 'String'
        ValueData     = $wingetCommand
        OperationType = 'SetValue'
    }

    try {
        $null = Invoke-WithTargetUserHive -TargetUserName $TargetUserName -ScriptBlock {
            param($op)
            Invoke-RegistryOperation -Operation $op -RegFilePath '<dynamic>'
        } -ArgumentObject $operation
        return $true
    }
    catch {
        Write-Host "Failed to schedule uninstall task for $($appId) for $($TargetUserName): $_" -ForegroundColor Red
        return $false
    }
}


