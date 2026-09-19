<#
.SYNOPSIS
    Self-contained payload for the Winnow update watchdog.

.DESCRIPTION
    Runs as SYSTEM from a scheduled task after a Windows update, or on the daily
    fallback. It re-asserts the privacy policy floor that Windows update and the
    in-box re-provisioning most often reset, then logs what it corrected.

    This file is copied verbatim to %ProgramData%\Winnow\Watchdog.ps1 at install
    time. The Winnow module is not present when the task fires, so the payload
    carries every function it needs and takes no external dependency.

    Tamper resistance:
      * The installer records this file's SHA256 under HKLM (admin/SYSTEM writable
        only). Before enforcing, the payload re-hashes itself and refuses to run
        when the hash does not match, so a rewritten payload cannot make the
        SYSTEM task enforce an attacker's settings. Missing or unreadable state
        fails closed.
      * The payload re-applies a locked ACL to its own directory on every run, so
        a directory that was loosened after install is tightened again before the
        SYSTEM task trusts anything inside it.

    Dot-sourcing this file (InvocationName '.') defines the functions without
    running the watchdog, which is how the unit tests exercise them.
#>

function Get-WinnowWatchdogContext {
    $dir = Join-Path $env:ProgramData 'Winnow'
    [PSCustomObject]@{
        Directory   = $dir
        PayloadPath = Join-Path $dir 'Watchdog.ps1'
        LogPath     = Join-Path $dir 'watchdog.log'
        RegPath     = 'HKLM:\SOFTWARE\Winnow\Watchdog'
    }
}

function Write-WinnowWatchdogLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [string]$LogPath
    )

    if (-not $LogPath) { $LogPath = (Get-WinnowWatchdogContext).LogPath }
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    try { Add-Content -LiteralPath $LogPath -Value "[$stamp] $Message" -ErrorAction Stop }
    catch { }
}

function Test-WinnowWatchdogEventSource {
    param([string]$Source = 'Winnow')
    try { return [System.Diagnostics.EventLog]::SourceExists($Source) }
    catch { return $false }
}

function Write-WinnowWatchdogEvent {
    # Mirror the security-relevant lines to the Windows event log so a tamper
    # attempt or a corrected drift is auditable centrally, not just in a text
    # file a local attacker could also edit. The installer registers the source;
    # if it is missing this is a no-op and the text log still records everything.
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('Information', 'Warning', 'Error')]
        [string]$EntryType = 'Information',
        [int]$EventId = 1000,
        [string]$Source = 'Winnow'
    )

    if (-not (Test-WinnowWatchdogEventSource -Source $Source)) { return }
    try { Write-EventLog -LogName Application -Source $Source -EntryType $EntryType -EventId $EventId -Message $Message -ErrorAction Stop }
    catch { }
}

function Set-WinnowWatchdogDirectoryAcl {
    # Lock the payload directory so only SYSTEM and Administrators can change what
    # a SYSTEM task later executes. Standard users keep read and execute, nothing
    # more. Inheritance is turned off so a loosened parent cannot widen it again.
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

function Test-WinnowWatchdogIntegrity {
    # Fail closed: the payload runs only when its own hash matches the value the
    # installer wrote to an admin-only registry key.
    param(
        [Parameter(Mandatory)]
        [string]$PayloadPath,
        [Parameter(Mandatory)]
        [string]$RegPath
    )

    if (-not (Test-Path -LiteralPath $PayloadPath)) { return $false }

    $expected = $null
    try {
        $expected = (Get-ItemProperty -LiteralPath $RegPath -Name 'PayloadSha256' -ErrorAction Stop).PayloadSha256
    }
    catch { return $false }

    if ([string]::IsNullOrWhiteSpace($expected)) { return $false }

    $actual = (Get-FileHash -LiteralPath $PayloadPath -Algorithm SHA256).Hash
    return ($actual -eq $expected)
}

function Get-WinnowWatchdogDesiredState {
    # The privacy floor: machine-wide (HKLM) policy keys, telemetry services, and
    # telemetry tasks. Everything here is a pure, idempotent re-assertion that is
    # safe to run blindly as SYSTEM. Per-user (HKCU) state is deliberately left
    # out: the watchdog has no user context and must not guess a hive.
    [PSCustomObject]@{
        Registry = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry'; Value = 0 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableAIDataAnalysis'; Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'AllowRecallEnablement'; Value = 0 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableClickToDo'; Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableSettingsAgent'; Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Photos'; Name = 'DisableGenerativeFill'; Value = 1 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'AllowCrossDeviceClipboard'; Value = 0 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsInkWorkspace'; Name = 'AllowWindowsInkWorkspace'; Value = 0 }
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'; Name = 'DisableFileSyncNGSC'; Value = 1 }
        )
        Services = @('DiagTrack', 'dmwappushservice')
        Tasks = @(
            @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'Consolidator' }
            @{ Path = '\Microsoft\Windows\Customer Experience Improvement Program\'; Name = 'UsbCeip' }
            @{ Path = '\Microsoft\Windows\Application Experience\'; Name = 'Microsoft Compatibility Appraiser' }
            @{ Path = '\Microsoft\Windows\Autochk\'; Name = 'Proxy' }
        )
    }
}

function Invoke-WinnowWatchdogEnforcement {
    # Re-assert every item in the desired state, touching only what has drifted.
    # Returns the human-readable names of the things that had to be corrected.
    param(
        [Parameter(Mandatory)]
        [object]$DesiredState
    )

    $reasserted = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in @($DesiredState.Registry)) {
        try {
            if (-not (Test-Path -LiteralPath $entry.Path)) {
                New-Item -Path $entry.Path -Force | Out-Null
            }
            $current = $null
            try { $current = (Get-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -ErrorAction Stop).$($entry.Name) }
            catch { $current = $null }

            if ($current -ne $entry.Value) {
                Set-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -Value $entry.Value -Type DWord -Force
                $reasserted.Add("$($entry.Path)\$($entry.Name)")
            }
        }
        catch {
            Write-WinnowWatchdogLog -Message "ERROR re-asserting $($entry.Path)\$($entry.Name): $($_.Exception.Message)"
        }
    }

    foreach ($serviceName in @($DesiredState.Services)) {
        try {
            $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
            if ($service -and $service.StartType -ne 'Disabled') {
                Set-Service -Name $serviceName -StartupType Disabled -ErrorAction Stop
                Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
                $reasserted.Add("service:$serviceName")
            }
        }
        catch {
            Write-WinnowWatchdogLog -Message "ERROR disabling service $($serviceName): $($_.Exception.Message)"
        }
    }

    foreach ($task in @($DesiredState.Tasks)) {
        try {
            $scheduledTask = Get-ScheduledTask -TaskPath $task.Path -TaskName $task.Name -ErrorAction SilentlyContinue
            if ($scheduledTask -and $scheduledTask.State -ne 'Disabled') {
                Disable-ScheduledTask -TaskPath $task.Path -TaskName $task.Name -ErrorAction Stop | Out-Null
                $reasserted.Add("task:$($task.Name)")
            }
        }
        catch {
            Write-WinnowWatchdogLog -Message "ERROR disabling task $($task.Name): $($_.Exception.Message)"
        }
    }

    return $reasserted.ToArray()
}

function Invoke-WinnowWatchdog {
    $context = Get-WinnowWatchdogContext

    Write-WinnowWatchdogLog -Message 'Watchdog fired. Checking the privacy floor.' -LogPath $context.LogPath

    # Re-harden the directory before trusting anything the SYSTEM task will read.
    try { Set-WinnowWatchdogDirectoryAcl -Path $context.Directory }
    catch { Write-WinnowWatchdogLog -Message "WARN could not re-harden the payload directory: $($_.Exception.Message)" -LogPath $context.LogPath }

    if (-not (Test-WinnowWatchdogIntegrity -PayloadPath $context.PayloadPath -RegPath $context.RegPath)) {
        $integrityMessage = 'The watchdog payload failed its integrity check. Refusing to enforce. Re-run Winnow to reinstall the watchdog.'
        Write-WinnowWatchdogLog -Message "SECURITY $integrityMessage" -LogPath $context.LogPath
        Write-WinnowWatchdogEvent -Message $integrityMessage -EntryType Error -EventId 2000
        return
    }

    $desiredState = Get-WinnowWatchdogDesiredState
    $reasserted = @(Invoke-WinnowWatchdogEnforcement -DesiredState $desiredState)

    if ($reasserted.Count -gt 0) {
        $driftMessage = "Corrected drift on: " + ($reasserted -join ', ')
        Write-WinnowWatchdogLog -Message $driftMessage -LogPath $context.LogPath
        Write-WinnowWatchdogEvent -Message $driftMessage -EntryType Warning -EventId 1000
    }
    else {
        Write-WinnowWatchdogLog -Message 'Privacy floor intact, nothing to re-apply.' -LogPath $context.LogPath
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    Invoke-WinnowWatchdog
}
