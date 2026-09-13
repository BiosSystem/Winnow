<#
.SYNOPSIS
    Captures and restores the reversible non-registry state changed by module features, so
    automatic rollback can revert it alongside the registry backup.
.DESCRIPTION
    The registry backup only covers features with a RegistryKey. Module features
    (DisableTelemetryServices, EnableFirewallTelemetryBlock, EnableSecurityHardening,
    EnableExtendedAIPurge, DisableTelemetry's scheduled-task side effect) change service state,
    firewall rules, the HOSTS file, scheduled tasks, and the SMB1 optional feature imperatively.
    This is Scope A of full-module rollback: the cleanly-reversible types. It does NOT cover the
    imperative registry writes those modules also make (Scope B), and it cannot restore one-way
    operations (Recall component removal, Appx removal, Edge removal) — those are reported, never
    faked. The extended CLI switches (competitive gaming, etc.) run only after a clean apply and so
    never need rollback.
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
        CreatedAt = (Get-Date).ToString('o')
        Services  = @()
        Tasks     = @()
        Smb1State = $null
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

    if ($snapshot.Services.Count -eq 0 -and $snapshot.Tasks.Count -eq 0 -and $null -eq $snapshot.Smb1State) {
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
        $result.Uncovered += 'SecurityHardening registry hardening (RDP policy, TLS, AutoRun, WSH)'
    }

    # GamingMode changes (power plan + imperative registry) are Scope B.
    if ('EnableGamingMode' -in $applied) {
        $result.Uncovered += 'GamingMode power plan and registry tweaks'
    }
    # ExtendedAIPurge one-way and registry parts.
    if ('EnableExtendedAIPurge' -in $applied) {
        $result.Uncovered += 'ExtendedAIPurge registry policies and Recall component removal (one-way)'
    }

    return $result
}
