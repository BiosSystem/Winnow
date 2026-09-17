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

        # Register a Windows event log source so the payload can record integrity
        # failures and corrected drift centrally, not only in its text log. This
        # needs admin, which the installer already has; if it fails the payload
        # falls back to the text log alone.
        try {
            if (-not [System.Diagnostics.EventLog]::SourceExists('Winnow')) {
                New-EventLog -LogName Application -Source 'Winnow' -ErrorAction Stop
            }
        }
        catch {
            Write-Host "  [WARN] Could not register the Winnow event source; the watchdog will log to its text file only." -ForegroundColor Yellow
        }

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

function Get-WinnowWatchdogHealth {
    # Read-only health report for the watchdog. A fail-closed control that refuses
    # to run is silent by design, so this surfaces whether it is installed, whether
    # the payload still matches the hash recorded at install, whether the directory
    # is still locked down, and when it last ran.
    [CmdletBinding()]
    param()

    $taskName = 'Winnow_UpdateWatchdog'
    $taskPath = '\Winnow'
    $watchdogDir = Join-Path $env:ProgramData 'Winnow'
    $scriptPath = Join-Path $watchdogDir 'Watchdog.ps1'
    $regPath = 'HKLM:\SOFTWARE\Winnow\Watchdog'

    $task = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
    $installed = [bool]$task

    $lastRun = $null
    $lastResult = $null
    if ($task) {
        $info = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
        if ($info) {
            $lastRun = $info.LastRunTime
            $lastResult = $info.LastTaskResult
        }
    }

    $recordedHash = $null
    $schemaVersion = $null
    $installedUtc = $null
    try {
        $props = Get-ItemProperty -LiteralPath $regPath -ErrorAction Stop
        $recordedHash = $props.PayloadSha256
        $schemaVersion = $props.SchemaVersion
        $installedUtc = $props.InstalledUtc
    }
    catch { }

    $payloadPresent = Test-Path -LiteralPath $scriptPath
    $currentHash = if ($payloadPresent) { (Get-FileHash -LiteralPath $scriptPath -Algorithm SHA256).Hash } else { $null }
    $integrityOk = ($payloadPresent -and -not [string]::IsNullOrWhiteSpace($recordedHash) -and $currentHash -eq $recordedHash)

    $aclProtected = $false
    $aclLockedDown = $false
    if (Test-Path -LiteralPath $watchdogDir) {
        try {
            $acl = Get-Acl -LiteralPath $watchdogDir
            $aclProtected = [bool]$acl.AreAccessRulesProtected
            $writeRights = [int][System.Security.AccessControl.FileSystemRights]::Write
            $userWrite = $false
            foreach ($rule in $acl.Access) {
                $sid = ''
                try { $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value }
                catch { $sid = '' }
                if ($sid -in @('S-1-5-32-545', 'S-1-5-11', 'S-1-1-0') -and (([int]$rule.FileSystemRights -band $writeRights) -ne 0)) {
                    $userWrite = $true
                }
            }
            $aclLockedDown = ($aclProtected -and -not $userWrite)
        }
        catch { }
    }

    [PSCustomObject]@{
        Installed      = $installed
        PayloadPresent = $payloadPresent
        IntegrityOk    = $integrityOk
        AclProtected   = $aclProtected
        AclLockedDown  = $aclLockedDown
        SchemaVersion  = $schemaVersion
        InstalledUtc   = $installedUtc
        LastRunTime    = $lastRun
        LastTaskResult = $lastResult
        RecordedHash   = $recordedHash
        CurrentHash    = $currentHash
        Healthy        = ($installed -and $integrityOk -and $aclLockedDown)
    }
}

function Show-WinnowWatchdogHealth {
    [CmdletBinding()]
    param()

    $health = Get-WinnowWatchdogHealth

    Write-Host ''
    Write-Host 'Winnow update watchdog health' -ForegroundColor Cyan

    if (-not $health.Installed) {
        Write-Host '[NotInstalled] The watchdog scheduled task is not registered. Run Winnow with -EnableUpdateWatchdog to install it.' -ForegroundColor Yellow
        return $health
    }

    $line = {
        param($Ok, $Label, $Detail)
        $mark = if ($Ok) { 'OK' } else { 'FAIL' }
        $color = if ($Ok) { 'Green' } else { 'Red' }
        Write-Host ("[{0}] {1}: {2}" -f $mark, $Label, $Detail) -ForegroundColor $color
    }

    & $line $health.Installed 'Scheduled task' 'Registered under \Winnow.'
    & $line $health.IntegrityOk 'Payload integrity' $(if ($health.IntegrityOk) { 'Payload matches the hash recorded at install.' } else { 'Payload is missing or does not match the recorded hash. Re-run Winnow to reinstall.' })
    & $line $health.AclLockedDown 'Directory lockdown' $(if ($health.AclLockedDown) { 'Only SYSTEM and Administrators can write the payload directory.' } else { 'The payload directory is not locked down. Re-run Winnow to re-harden it.' })

    if ($health.InstalledUtc) { Write-Host ("       Installed (UTC): {0}" -f $health.InstalledUtc) -ForegroundColor DarkGray }
    if ($health.LastRunTime) { Write-Host ("       Last run: {0} (result 0x{1:X})" -f $health.LastRunTime, [int]$health.LastTaskResult) -ForegroundColor DarkGray }

    $overallColor = if ($health.Healthy) { 'Green' } else { 'Red' }
    Write-Host ("Watchdog health: {0}" -f $(if ($health.Healthy) { 'healthy' } else { 'degraded' })) -ForegroundColor $overallColor

    return $health
}
