<#
.SYNOPSIS
    Generates a JSON run summary after a Winnow apply or undo operation.
.DESCRIPTION
    Collects the operation results, system metadata, and elapsed time, then
    writes a timestamped JSON file (Winnow_RunSummary_<timestamp>.json) to
    %TEMP% and prints its path. It is not written for a dry run.
    Created by Bios-System | https://github.com/BiosSystem/Winnow
#>

function Export-RunSummary {
    [CmdletBinding()]
    param(
        # AllowEmptyCollection because an apply-only run undoes nothing and an
        # undo-only run applies nothing. A mandatory string[] rejects @() by
        # default, which made both of those throw.
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$AppliedFeatureIds,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$UndoneFeatureIds,

        [string[]]$RemovedApps = @(),

        [string[]]$FailedApps = @(),

        [bool]$AppVerificationUnavailable = $false,

        [hashtable[]]$FeatureErrors = @(),

        [Parameter(Mandatory)]
        [datetime]$StartTime,

        [Parameter(Mandatory)]
        [string]$WinnowVersion
    )

    $endTime   = Get-Date
    $elapsed   = [math]::Round(($endTime - $StartTime).TotalSeconds, 1)
    $timestamp = $StartTime.ToString('yyyyMMdd_HHmmss')
    $outPath   = Join-Path $env:TEMP "Winnow_RunSummary_$timestamp.json"

    # Collect Windows build info
    $winBuild = try {
        (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop).CurrentBuildNumber
    } catch { 'Unknown' }

    $winVersion = try {
        $reg = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        "$($reg.ProductName) $($reg.DisplayVersion)"
    } catch { 'Unknown' }

    # Build applied feature detail list. After a rollback nothing requested is
    # left in effect (or, if the rollback itself failed, its state is unknown),
    # so those features must not be reported as applied.
    $rollbackOutcome = if ($script:RunRollbackOutcome) { [string]$script:RunRollbackOutcome } else { 'None' }
    $appliedStatus = switch ($rollbackOutcome) {
        'RolledBack' { 'RolledBack' }
        'RollbackFailed' { 'Unknown' }
        default { 'Applied' }
    }
    $appliedDetails = foreach ($id in $AppliedFeatureIds) {
        $errEntry = $FeatureErrors | Where-Object { $_.FeatureId -eq $id } | Select-Object -First 1
        [ordered]@{
            FeatureId = $id
            Status    = if ($errEntry) { 'Error' } else { $appliedStatus }
            Error     = if ($errEntry) { $errEntry.Message } else { $null }
        }
    }

    $undoneDetails = foreach ($id in $UndoneFeatureIds) {
        $errEntry = $FeatureErrors | Where-Object { $_.FeatureId -eq $id } | Select-Object -First 1
        [ordered]@{
            FeatureId = $id
            Status    = if ($errEntry) { 'Error' } else { 'Undone' }
            Error     = if ($errEntry) { $errEntry.Message } else { $null }
        }
    }

    $summary = [ordered]@{
        WinnowVersion      = $WinnowVersion
        GeneratedAt          = $endTime.ToString('o')
        DurationSeconds      = $elapsed
        WindowsVersion       = $winVersion
        WindowsBuild         = $winBuild
        FeaturesApplied      = @($appliedDetails)
        FeaturesUndone       = @($undoneDetails)
        AppsRemoved          = @($RemovedApps)
        AppRemoval           = [ordered]@{
            Removed                 = @($RemovedApps)
            Failed                  = @($FailedApps)
            VerificationUnavailable = $AppVerificationUnavailable
        }
        TotalFeaturesChanged = $AppliedFeatureIds.Count + $UndoneFeatureIds.Count
        RegistryImportFailures = [int]$script:RegistryImportFailures
        ErrorCount           = $FeatureErrors.Count + @($FailedApps).Count + [int]$script:RegistryImportFailures
        Rollback             = [ordered]@{
            # None, RolledBack, RollbackFailed, or Skipped.
            Outcome    = $rollbackOutcome
            Triggered  = ($script:RunRollbackOutcome -in @('RolledBack', 'RollbackFailed'))
            Reason     = $script:RunRollbackReason
            BackupPath = $script:RunRegistryBackupPath
        }
    }

    try {
        $summary | ConvertTo-Json -Depth 5 | Out-File -FilePath $outPath -Encoding UTF8 -Force
        Write-Host ""
        Write-Host "  [Report] Run summary saved to: $outPath" -ForegroundColor DarkGray
    } catch {
        Write-Host "  [WARN] Could not save run summary: $_" -ForegroundColor Yellow
    }
}
