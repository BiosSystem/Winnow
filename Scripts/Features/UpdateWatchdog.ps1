function Set-WinnowWatchdogDirectoryAcl {
    # Lock the payload directory so only SYSTEM and Administrators can change what
    # the SYSTEM task later executes. Standard users keep read and execute, nothing
    # more. Inheritance is turned off so a loosened parent cannot widen it again.
    # A SYSTEM task that runs a script from a directory non-admins can write to is
    # a local privilege-escalation path; this closes it.
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }

    $acl = New-Object System.Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)

    $full = [System.Security.AccessControl.FileSystemRights]::FullControl
    $readExec = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $noProp = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow

    $system = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'
    $admins = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    $users = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-545'

    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($system, $full, $inherit, $noProp, $allow)))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($admins, $full, $inherit, $noProp, $allow)))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($users, $readExec, $inherit, $noProp, $allow)))

    Set-Acl -LiteralPath $Path -AclObject $acl
}

function Resolve-WinnowWatchdogPayloadSource {
    # The payload ships as Scripts\Watchdog\WatchdogPayload.ps1 next to this file's
    # parent. It resolves the same way in the modular tree and in the standalone
    # build, which unpacks the whole Scripts folder before running.
    $scriptsRoot = Split-Path -Parent $PSScriptRoot
    Join-Path $scriptsRoot 'Watchdog\WatchdogPayload.ps1'
}

function Invoke-InstallUpdateWatchdog {
    param (
        [switch]$WhatIf
    )

    $taskName = 'Winnow_UpdateWatchdog'
    $taskPath = '\Winnow'
    $watchdogDir = Join-Path $env:ProgramData 'Winnow'
    $scriptPath = Join-Path $watchdogDir 'Watchdog.ps1'
    $regPath = 'HKLM:\SOFTWARE\Winnow\Watchdog'
    $schemaVersion = 2

    Write-Host "`n[*] Installing Windows Update Watchdog..." -ForegroundColor Cyan

    if ($WhatIf) {
        Write-Host "  [WhatIf] Would harden $watchdogDir, deploy the tamper-checked watchdog payload, record its hash under HKLM, and register a Scheduled Task triggered by Windows Update events." -ForegroundColor Yellow
        return
    }

    $payloadSource = Resolve-WinnowWatchdogPayloadSource
    if (-not (Test-Path -LiteralPath $payloadSource)) {
        Write-Host "  [ERROR] Watchdog payload source is missing: $payloadSource" -ForegroundColor Red
        return
    }

    try {
        # Harden the directory before writing the script the SYSTEM task will run.
        Set-WinnowWatchdogDirectoryAcl -Path $watchdogDir

        # Deploy the payload verbatim, then record its hash where only an admin or
        # SYSTEM can write. The payload checks itself against this value and
        # refuses to enforce anything if it was swapped out.
        Copy-Item -LiteralPath $payloadSource -Destination $scriptPath -Force
        $payloadHash = (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash

        if (-not (Test-Path -LiteralPath $regPath)) {
            New-Item -Path $regPath -Force | Out-Null
        }
        Set-ItemProperty -LiteralPath $regPath -Name 'PayloadSha256' -Value $payloadHash -Type String -Force
        Set-ItemProperty -LiteralPath $regPath -Name 'SchemaVersion' -Value $schemaVersion -Type DWord -Force
        Set-ItemProperty -LiteralPath $regPath -Name 'InstalledUtc' -Value ((Get-Date).ToUniversalTime().ToString('o')) -Type String -Force

        # Remove any prior task before re-registering.
        $existingTask = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
        if ($existingTask) {
            Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false
        }

        # Trigger on Windows Update install events (Microsoft-Windows-WindowsUpdateClient
        # in the System log). New-ScheduledTaskTrigger cannot build an event trigger, so
        # it is created through CIM. EventID 19 is "installation successful" and 43 is
        # "installation started"; both are caught so a reset is corrected promptly.
        $eventTrigger = $null
        try {
            $triggerClass = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler -ErrorAction Stop
            $eventTrigger = New-CimInstance -CimClass $triggerClass -ClientOnly
            $eventTrigger.Enabled = $true
            $eventTrigger.Subscription = '<QueryList><Query Id="0" Path="System"><Select Path="System">*[System[Provider[@Name=''Microsoft-Windows-WindowsUpdateClient''] and (EventID=19 or EventID=43)]]</Select></Query></QueryList>'
        }
        catch {
            Write-Host "  [WARN] Could not build the update-event trigger; falling back to the daily check only." -ForegroundColor Yellow
        }

        # Daily fallback so a missed event is still corrected within a day.
        $triggerDaily = New-ScheduledTaskTrigger -Daily -At 12:00PM
        $triggers = if ($eventTrigger) { @($eventTrigger, $triggerDaily) } else { @($triggerDaily) }

        $action = New-ScheduledTaskAction -Execute "PowerShell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptPath`""
        $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

        Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Trigger $triggers -Action $action -Principal $principal -Description "Re-asserts Winnow's privacy policy floor after a Windows update resets it." | Out-Null

        $triggerDesc = if ($eventTrigger) { "on Windows Update install events, with a daily fallback" } else { "daily (event trigger unavailable)" }
        Write-Host "  [+] Update Watchdog installed. It runs $triggerDesc and re-asserts the privacy policy floor." -ForegroundColor Green
    }
    catch {
        Write-Host "  [ERROR] Failed to install Update Watchdog: $_" -ForegroundColor Red
    }
}
