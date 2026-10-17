# List of known Windows telemetry-related scheduled tasks
<#
    .SYNOPSIS
    Returns the list of known Windows telemetry-related scheduled tasks.

    .DESCRIPTION
    Returns an array of hashtables, each with a Path and Name key, representing
    scheduled tasks that collect or report telemetry data on Windows.

    .EXAMPLE
    Get-TelemetryScheduledTasks
#>
function Get-TelemetryScheduledTasks {
    return @(
        # Application Experience
        @{ Path = "\Microsoft\Windows\Application Experience\"; Name = "Microsoft Compatibility Appraiser" },
        @{ Path = "\Microsoft\Windows\Application Experience\"; Name = "Microsoft Compatibility Appraiser Exp" },
        @{ Path = "\Microsoft\Windows\Application Experience\"; Name = "ProgramDataUpdater" },
        @{ Path = "\Microsoft\Windows\Application Experience\"; Name = "StartupAppTask" },
        # Customer Experience Improvement Program
        @{ Path = "\Microsoft\Windows\Customer Experience Improvement Program\"; Name = "Consolidator" },
        @{ Path = "\Microsoft\Windows\Customer Experience Improvement Program\"; Name = "UsbCeip" },
        # Disk and Storage Telemetry
        @{ Path = "\Microsoft\Windows\DiskDiagnostic\"; Name = "Microsoft-Windows-DiskDiagnosticDataCollector" },
        @{ Path = "\Microsoft\Windows\Autochk\"; Name = "Proxy" },
        # Device Census (hardware fingerprint upload)
        @{ Path = "\Microsoft\Windows\Device Information\"; Name = "Device" },
        # AppID / SmartScreen Telemetry
        @{ Path = "\Microsoft\Windows\AppID\"; Name = "SmartScreenSpecific" },
        # Feedback / SIUF Telemetry
        @{ Path = "\Microsoft\Windows\Feedback\Siuf\"; Name = "DmClient" },
        @{ Path = "\Microsoft\Windows\Feedback\Siuf\"; Name = "DmClientOnScenarioDownload" },
        # Maps Telemetry
        @{ Path = "\Microsoft\Windows\Maps\"; Name = "MapsToastTask" },
        @{ Path = "\Microsoft\Windows\Maps\"; Name = "MapsUpdateTask" },
        # Software Quality Metrics
        @{ Path = "\Microsoft\Windows\PI\"; Name = "Sqm-Tasks" },
        # Windows Store Telemetry
        @{ Path = "\Microsoft\Windows\WS\"; Name = "WSTask" },
        # Activation / License Telemetry
        @{ Path = "\Microsoft\Windows\Clip\"; Name = "License Validation" },
        # CloudExperienceHost
        @{ Path = "\Microsoft\Windows\CloudExperienceHost\"; Name = "CreateObjectTask" },
        # Shell / Family Safety (used for usage telemetry)
        @{ Path = "\Microsoft\Windows\Shell\"; Name = "FamilySafetyMonitor" },
        @{ Path = "\Microsoft\Windows\Shell\"; Name = "FamilySafetyRefreshTask" },
        # Device Inventory
        @{ Path = "\Microsoft\Windows\Device Inventory\"; Name = "RunUpdateUserDeviceInventoryTask" }
    )
}

<#
    .SYNOPSIS
    Disables known Windows telemetry-related scheduled tasks.

    .DESCRIPTION
    Iterates over a predefined list of Windows scheduled tasks associated with
    telemetry and disables each one that exists and is not already disabled.
    Supports -WhatIf to preview changes without applying them.

    .EXAMPLE
    Disable-TelemetryScheduledTasks
#>
function Disable-TelemetryScheduledTasks {
    Write-Host "> Disabling telemetry scheduled tasks..."
    $success = Set-TelemetryScheduledTaskState -Enable:$false
    Write-Host ""
    return $success
}

<#
    .SYNOPSIS
    Enables known Windows telemetry-related scheduled tasks.

    .DESCRIPTION
    Iterates over a predefined list of Windows scheduled tasks associated with
    telemetry and enables each one that exists and is currently disabled.
    Supports -WhatIf to preview changes without applying them.

    .EXAMPLE
    Enable-TelemetryScheduledTasks
#>
function Enable-TelemetryScheduledTasks {
    Write-Host "> Enabling telemetry scheduled tasks..."
    $success = Set-TelemetryScheduledTaskState -Enable:$true
    Write-Host ""
    return $success
}

<#
    .SYNOPSIS
    Enables or disables each telemetry scheduled task and reports whether all
    of them ended up in the requested state.

    .DESCRIPTION
    A task that does not exist counts as done. A lookup that fails for any
    other reason (access denied, the ScheduledTasks module failing to load)
    is a failure, not "not found": the lookup used to swallow every error,
    so those cases were reported as fine.

    .OUTPUTS
    System.Boolean. $true when every task is in the requested state, absent,
    or previewed under -WhatIf; otherwise $false.
#>
function Set-TelemetryScheduledTaskState {
    param([bool]$Enable)

    $verb = if ($Enable) { 'enable' } else { 'disable' }
    $success = $true

    foreach ($task in (Get-TelemetryScheduledTasks)) {
        if ($script:Params.ContainsKey("WhatIf")) {
            Write-Host "[WhatIf] $(if ($Enable) { 'Enable' } else { 'Disable' }) Scheduled Task: $($task.Path)$($task.Name)" -ForegroundColor Cyan
            continue
        }

        try {
            $result = Invoke-NonBlocking -ScriptBlock {
                param($path, $name, $enable)
                try {
                    Import-Module ScheduledTasks -ErrorAction Stop
                    $taskObj = Get-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction Stop
                }
                catch {
                    if ($_.Exception -isnot [System.Management.Automation.CommandNotFoundException] -and
                        $_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound) {
                        return @{ Status = 'NotFound' }
                    }
                    return @{ Status = 'Error'; Error = $_.Exception.Message }
                }

                $isDisabled = $taskObj.State -eq 'Disabled'
                if ($enable -ne $isDisabled) {
                    return @{ Status = 'Unchanged' }
                }

                try {
                    if ($enable) {
                        Enable-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction Stop | Out-Null
                    }
                    else {
                        Disable-ScheduledTask -TaskPath $path -TaskName $name -ErrorAction Stop | Out-Null
                    }
                    return @{ Status = 'Changed' }
                }
                catch {
                    return @{ Status = 'Error'; Error = $_.Exception.Message }
                }
            } -ArgumentList @($task.Path, $task.Name, $Enable)
        }
        catch {
            $result = @{ Status = 'Error'; Error = $_.Exception.Message }
        }

        $taskName = "$($task.Path)$($task.Name)"
        switch ($result.Status) {
            'Changed'   { Write-Host "$(if ($Enable) { 'Enabled' } else { 'Disabled' }) Scheduled Task: $taskName" }
            'Unchanged' { Write-Host "Scheduled Task $taskName is already $(if ($Enable) { 'enabled' } else { 'disabled' })" -ForegroundColor DarkGray }
            'NotFound'  { Write-Host "Scheduled Task $taskName not found" -ForegroundColor DarkGray }
            'Error' {
                Write-Host "Failed to $verb Scheduled Task: $taskName - $($result.Error)" -ForegroundColor Yellow
                $success = $false
            }
            default {
                Write-Host "Failed to $verb Scheduled Task: $taskName - no result was returned" -ForegroundColor Yellow
                $success = $false
            }
        }
    }

    return $success
}
