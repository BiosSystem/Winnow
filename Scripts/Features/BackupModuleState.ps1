<#
.SYNOPSIS
    Captures and restores the reversible non-registry state changed by module features, so
    automatic rollback can revert it alongside the registry backup.
.DESCRIPTION
    The registry backup only covers features with a RegistryKey. Module features
    (DisableTelemetryServices, EnableFirewallTelemetryBlock, EnableSecurityHardening,
    EnableExtendedAIPurge, DisableTelemetry's scheduled-task side effect) change service state,
    firewall rules, the HOSTS file, scheduled tasks, and the SMB1 optional feature imperatively.
    Scope A covers the cleanly-reversible non-registry types above. Scope B additionally captures and
    restores the imperative registry writes SecurityHardening, ExtendedAIPurge, and GamingMode make,
    each value snapshotted with its type before apply and put back (or removed) on rollback. It still
    cannot restore one-way operations (Recall component removal, Appx removal, Edge removal) or the
    powercfg power-plan change — those are reported, never faked. The extended CLI switches
    (competitive gaming, etc.) run only after a clean apply and so never need rollback.
    Created by Bios-System | https://github.com/BiosSystem/Winnow
#>

# Module features whose non-registry state this snapshot/restore covers. Tracked as they apply so
# restore only touches what actually ran. EnableGamingMode is listed so rollback can report it as
# uncovered (its changes are powercfg + imperative registry, both Scope B).
$script:ModuleRollbackFeatureIds = @(
    'DisableTelemetry',
    'DisableTelemetryServices',
    'EnableFirewallTelemetryBlock',
    'EnableSecurityHardening',
    'EnableExtendedAIPurge',
    'EnableGamingMode'
)

# Scope B: module features whose imperative registry writes are captured and restored. Each maps to
# the function that declares the exact (Path, Name) targets the module writes, so the snapshot never
# drifts from the apply. Modules without registry writes (telemetry service/task/firewall) are not here.
$script:ModuleRegistryTargetProviders = @{
    'EnableSecurityHardening' = 'Get-SecurityHardeningRegistryTargets'
    'EnableExtendedAIPurge'   = 'Get-ExtendedAIPurgeRegistryTargets'
    'EnableGamingMode'        = 'Get-GamingModeRegistryTargets'
}

<#
    .SYNOPSIS
    Snapshots the reversible module state for the module features in $ApplyIds.

    .OUTPUTS
    System.String path to the snapshot JSON, or $null when no in-scope module feature applies.
#>
function New-ModuleStateSnapshot {
    param(
        [string[]]$ApplyIds
    )

    $ApplyIds = @($ApplyIds)
    $inScope = @($ApplyIds | Where-Object { $_ -in $script:ModuleRollbackFeatureIds })
    if ($inScope.Count -eq 0) {
        return $null
    }

    $snapshot = [ordered]@{
        CreatedAt      = (Get-Date).ToString('o')
        Services       = @()
        Tasks          = @()
        Smb1State      = $null
        RegistryValues = @()
    }

    # Services: capture the current StartType (and whether running) so restore returns the exact
    # prior state rather than a hardcoded default.
    if ('DisableTelemetryServices' -in $ApplyIds -and $script:TelemetryServices) {
        foreach ($svc in $script:TelemetryServices) {
            $obj = Get-Service -Name $svc.Name -ErrorAction SilentlyContinue
            if ($obj) {
                $snapshot.Services += [ordered]@{
                    Name      = $svc.Name
                    StartType = "$($obj.StartType)"
                    Running   = ($obj.Status -eq 'Running')
                }
            }
        }
    }

    # Scheduled tasks: the ExtendedAIPurge tasks are a subset of the telemetry task list, so the one
    # list covers both. Capture the prior State so restore only re-enables tasks that were enabled.
    if (('DisableTelemetry' -in $ApplyIds -or 'EnableExtendedAIPurge' -in $ApplyIds) -and (Get-Command Get-TelemetryScheduledTasks -ErrorAction SilentlyContinue)) {
        foreach ($task in (Get-TelemetryScheduledTasks)) {
            $obj = Get-ScheduledTask -TaskPath $task.Path -TaskName $task.Name -ErrorAction SilentlyContinue
            if ($obj) {
                $snapshot.Tasks += [ordered]@{
                    Path  = $task.Path
                    Name  = $task.Name
                    State = "$($obj.State)"
                }
            }
        }
    }

    # SMB1 optional feature (Get-WindowsOptionalFeature is slow, so only when hardening applies).
    if ('EnableSecurityHardening' -in $ApplyIds) {
        try {
            $smb1 = Get-WindowsOptionalFeature -Online -FeatureName 'SMB1Protocol' -ErrorAction Stop
            if ($smb1) { $snapshot.Smb1State = "$($smb1.State)" }
        }
        catch { }
    }

    # Scope B: capture the current value and type of every registry target each applying module
    # writes, so restore returns the exact prior state (or removes a value that did not exist).
    foreach ($featureId in $inScope) {
        $providerName = $script:ModuleRegistryTargetProviders[$featureId]
        if ([string]::IsNullOrWhiteSpace($providerName)) { continue }
        if (-not (Get-Command $providerName -ErrorAction SilentlyContinue)) { continue }
        try {
            foreach ($target in @(& $providerName)) {
                if ([string]::IsNullOrWhiteSpace($target.Path) -or [string]::IsNullOrWhiteSpace($target.Name)) { continue }
                $snapshot.RegistryValues += Get-ModuleRegistryValueSnapshot -Path $target.Path -Name $target.Name
            }
        }
        catch { }
    }

    if ($snapshot.Services.Count -eq 0 -and $snapshot.Tasks.Count -eq 0 -and $null -eq $snapshot.Smb1State -and @($snapshot.RegistryValues).Count -eq 0) {
        # Nothing capturable (e.g. only firewall/HOSTS, which restore removes without a snapshot).
        # Still write a marker file so restore knows a module run happened.
        $snapshot.Marker = $true
    }

    $backupDirectory = $script:RegistryBackupsPath
    if (-not (Test-Path $backupDirectory)) {
        New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null
    }
    $backupFilePath = Join-Path $backupDirectory ('Winnow-ModuleBackup-{0}.json' -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $snapshot | ConvertTo-Json -Depth 6 | Out-File -FilePath $backupFilePath -Encoding UTF8 -Force

    Write-Host "Module state snapshot created: $backupFilePath"
    return $backupFilePath
}

# Reads the current value and type of one registry target, or records that it does not exist, so
# restore can put back exactly what was there (or remove a value the module created).
function Get-ModuleRegistryValueSnapshot {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [string]$Name
    )

    $existed = $false
    $value = $null
    $kind = $null
    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        if (@($key.GetValueNames()) -contains $Name) {
            $existed = $true
            $value = $key.GetValue($Name)
            $kind = "$($key.GetValueKind($Name))"
        }
    }
    catch { }

    return [ordered]@{
        Path    = $Path
        Name    = $Name
        Existed = $existed
        Value   = $value
        Kind    = $kind
    }
}

# Deletes the inbound port-block firewall rules SecurityHardening adds. Wrapped so it can be
# mocked in tests (netsh is a native command and cannot be mocked directly).
function Remove-SecurityPortBlockRules {
    foreach ($ruleName in @('Block-RPC-135', 'Block-NetBIOS-139', 'Block-SMB-445')) {
        netsh advfirewall firewall delete rule name="$ruleName" 2>$null | Out-Null
    }
}

<#
    .SYNOPSIS
    Reverts the reversible module state captured in the snapshot, for the features that applied.

    .OUTPUTS
    PSCustomObject with Reverted (types restored), Uncovered (module changes not restorable under
    Scope A), and Failed (restore steps that errored).
#>
function Restore-ModuleState {
    param(
        [Parameter(Mandatory)]
        [string]$SnapshotPath,
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$AppliedFeatures
    )

    $result = [pscustomobject]@{ Reverted = @(); Uncovered = @(); Failed = @() }

    $snapshot = $null
    if (Test-Path -LiteralPath $SnapshotPath) {
        try { $snapshot = Get-Content -LiteralPath $SnapshotPath -Raw -Encoding UTF8 | ConvertFrom-Json }
        catch { $result.Failed += "Could not read module snapshot: $($_.Exception.Message)"; return $result }
    }
    if (-not $snapshot) { return $result }

    $applied = @($AppliedFeatures)

    # Services -> prior StartType (and start if it was running).
    $svcList = @($snapshot.Services | Where-Object { $_ })
    if ('DisableTelemetryServices' -in $applied -and $svcList.Count -gt 0) {
        $ok = $true
        foreach ($s in $svcList) {
            try {
                Set-Service -Name $s.Name -StartupType $s.StartType -ErrorAction Stop
                if ($s.Running) { Start-Service -Name $s.Name -ErrorAction SilentlyContinue }
            }
            catch { $ok = $false; $result.Failed += "service $($s.Name): $($_.Exception.Message)" }
        }
        if ($ok) { $result.Reverted += 'services' }
    }

    # Scheduled tasks -> re-enable those that were enabled before.
    $taskList = @($snapshot.Tasks | Where-Object { $_ })
    if (('DisableTelemetry' -in $applied -or 'EnableExtendedAIPurge' -in $applied) -and $taskList.Count -gt 0) {
        $ok = $true
        foreach ($t in $taskList) {
            if ($t.State -ne 'Disabled') {
                try { Enable-ScheduledTask -TaskPath $t.Path -TaskName $t.Name -ErrorAction Stop | Out-Null }
                catch { $ok = $false; $result.Failed += "task $($t.Path)$($t.Name): $($_.Exception.Message)" }
            }
        }
        if ($ok) { $result.Reverted += 'scheduled tasks' }
    }

    # Telemetry firewall rules + HOSTS block -> remove what Winnow added.
    if ('EnableFirewallTelemetryBlock' -in $applied -and (Get-Command Invoke-UnblockTelemetryFirewall -ErrorAction SilentlyContinue)) {
        try { Invoke-UnblockTelemetryFirewall; $result.Reverted += 'telemetry firewall and HOSTS' }
        catch { $result.Failed += "telemetry firewall/HOSTS: $($_.Exception.Message)" }
    }

    # SecurityHardening: remove the inbound port-block rules and re-enable SMB1 if it was on. The
    # registry hardening it also applies (RDP policy, TLS, AutoRun, WSH) is Scope B, not reverted.
    if ('EnableSecurityHardening' -in $applied) {
        Remove-SecurityPortBlockRules
        if ($snapshot.Smb1State -eq 'Enabled') {
            try {
                Enable-WindowsOptionalFeature -Online -FeatureName 'SMB1Protocol' -NoRestart -ErrorAction Stop | Out-Null
                Set-SmbServerConfiguration -EnableSMB1Protocol $true -Force -ErrorAction SilentlyContinue
            }
            catch { $result.Failed += "SMB1 re-enable: $($_.Exception.Message)" }
        }
        $result.Reverted += 'security firewall and SMB1'
    }

    # Scope B: restore each captured module registry value. A value that existed is written back with
    # its original type; one that did not exist is removed. Restoring all captured targets is safe even
    # for a module that did not run, because its targets were captured before apply and are unchanged.
    $regList = @($snapshot.RegistryValues | Where-Object { $_ })
    $regModulesApplied = @($applied | Where-Object { $script:ModuleRegistryTargetProviders.ContainsKey($_) })
    if ($regList.Count -gt 0 -and $regModulesApplied.Count -gt 0) {
        $ok = $true
        foreach ($entry in $regList) {
            try {
                if ($entry.Existed) {
                    if (-not (Test-Path -LiteralPath $entry.Path)) {
                        New-Item -Path $entry.Path -Force | Out-Null
                    }
                    if ([string]::IsNullOrWhiteSpace([string]$entry.Kind)) {
                        Set-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -Value $entry.Value -Force -ErrorAction Stop
                    }
                    else {
                        Set-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -Value $entry.Value -Type $entry.Kind -Force -ErrorAction Stop
                    }
                }
                elseif (Test-Path -LiteralPath $entry.Path) {
                    Remove-ItemProperty -LiteralPath $entry.Path -Name $entry.Name -Force -ErrorAction SilentlyContinue
                }
            }
            catch {
                $ok = $false
                $result.Failed += "registry $($entry.Path)\$($entry.Name): $($_.Exception.Message)"
            }
        }
        if ($ok) { $result.Reverted += 'module registry settings' }
    }

    # What is still not restorable, after Scope B covers the registry writes.
    if ('EnableGamingMode' -in $applied) {
        $result.Uncovered += 'GamingMode power plan (powercfg)'
    }
    if ('EnableExtendedAIPurge' -in $applied) {
        $result.Uncovered += 'ExtendedAIPurge Recall component removal (one-way)'
    }

    return $result
}
