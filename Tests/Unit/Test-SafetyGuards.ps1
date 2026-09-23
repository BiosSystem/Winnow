#Requires -Modules Pester

Describe 'Winnow startup safety guards' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
        $script:entryScript = Get-Content (Join-Path $repoRoot 'Winnow.ps1') -Raw
        $script:adminScript = Get-Content (Join-Path $repoRoot 'Scripts\Helpers\Ensure-Admin.ps1') -Raw
        $script:launcherScript = Get-Content (Join-Path $repoRoot 'Scripts\Get.ps1') -Raw
    }

    It 'stops PowerShell Core before loading runtime modules' {
        $guardPosition = $script:entryScript.IndexOf("if (`$PSVersionTable.PSEdition -eq 'Core')")
        $modulePosition = $script:entryScript.IndexOf('Ensure-Admin.ps1')

        $guardPosition | Should -BeGreaterThan -1
        $guardPosition | Should -BeLessThan $modulePosition
        $script:entryScript | Should -Match "(?s)PSEdition -eq 'Core'.*?exit 1"
    }

    It 'limits Mark-of-the-Web handling to PowerShell source files' {
        $script:entryScript | Should -Match 'Zone\.Identifier'
        $script:entryScript | Should -Match '\.ps1.*\.psm1.*\.psd1'
        $script:entryScript | Should -Match 'Get-ExecutionPolicy -Scope MachinePolicy'
        $script:entryScript | Should -Match 'Get-ExecutionPolicy -Scope UserPolicy'
    }

    It 'uses Win32-safe elevation argument escaping' {
        $script:adminScript | Should -Match 'function Format-ElevatedArg'
        $script:adminScript | Should -Match '\$escaped = \$Value -replace'
        $script:adminScript | Should -Match 'Start-Process powershell\.exe'
        $script:adminScript | Should -Match '-ErrorAction Stop'
    }

    It 'reports the elevation outcome instead of relying on exit' {
        # `exit` inside a dot-sourced script does not terminate the caller, so a
        # non-elevated run used to continue into the apply pipeline.
        $script:adminScript | Should -Match "\`$script:ElevationOutcome = 'Elevated'"
        $script:adminScript | Should -Match "\`$script:ElevationOutcome = 'Denied'"
        $script:adminScript | Should -Match "\`$script:ElevationOutcome = 'Relaunched'"
        $script:adminScript | Should -Match "\`$script:ElevationOutcome = 'Failed'"
        $script:adminScript | Should -Not -Match '(?m)^\s*exit \d'
    }

    It 'stops the run when elevation was not obtained' {
        $guardPosition = $script:entryScript.IndexOf('$script:ElevationOutcome -ne')
        $environmentPosition = $script:entryScript.IndexOf('Initialize-Environment.ps1')

        $guardPosition | Should -BeGreaterThan -1
        $guardPosition | Should -BeLessThan $environmentPosition -Because 'the run must stop before any runtime module loads'
    }

    It 'refuses a non-interactive run that cannot elevate' -Skip:(
        ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    ) {
        # Only meaningful unelevated. CI runners are administrators, so this is
        # skipped there and the source assertions above carry the contract.
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..')
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -DryRun -Silent -CLI -DisableTelemetry' -f (Join-Path $repoRoot 'Winnow.ps1')
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.RedirectStandardInput = $true
        $psi.UseShellExecute = $false

        $process = [System.Diagnostics.Process]::Start($psi)
        $process.StandardInput.Close()
        $stdout = $process.StandardOutput.ReadToEnd()
        $null = $process.WaitForExit(90000)

        $process.ExitCode | Should -Not -Be 0
        $stdout | Should -Not -Match '\[WhatIf\]' -Because 'the apply pipeline must never be reached without elevation'
    }

    It 'rolls back a failed apply before any undo work' {
        $changes = Get-Content (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')) 'Scripts\Features\InvokeChanges.ps1') -Raw

        $rollbackPosition = $changes.IndexOf('Restore-RegistryBackupState')
        $undoPosition = $changes.IndexOf('Invoke-UndoFeatures -FeatureIds')

        $rollbackPosition | Should -BeGreaterThan -1
        $undoPosition | Should -BeGreaterThan -1
        $rollbackPosition | Should -BeLessThan $undoPosition -Because 'undo must not run on top of a half-applied system'
    }

    It 'catches apply failures so rollback is reachable' {
        # Invoke-ApplyFeatures does not catch per-feature errors, and a missing
        # .reg file throws. Without this the exception escapes Invoke-AllChanges
        # and skips rollback, which is the case rollback exists for.
        $changes = Get-Content (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')) 'Scripts\Features\InvokeChanges.ps1') -Raw

        $changes | Should -Match '(?s)try\s*\{\s*Invoke-ApplyFeatures.*?\}\s*catch\s*\{'
        $changes | Should -Match '\$applyException'
    }

    It 'never rolls back on an app removal failure alone' {
        # A registry restore cannot reinstall an uninstalled Appx package, so
        # only registry import failures may trigger it.
        $changes = Get-Content (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')) 'Scripts\Features\InvokeChanges.ps1') -Raw

        $changes | Should -Match '\$applyFailed\s*=\s*\(-not \$script:Params\.ContainsKey\("WhatIf"\)\)'
        $changes | Should -Match '\$script:RegistryImportFailures -gt 0'
        $changes | Should -Not -Match '\$applyFailed[^\r\n]*AppRemovalFailures'
    }

    It 'maps rollback outcomes to distinct exit codes' {
        # 0 success, 1 generic, 2 verification drift, 3 rolled back,
        # 4 rollback also failed. 4 is the only outcome needing a human.
        $script:entryScript | Should -Match "'RolledBack'\s*\{\s*3\s*\}"
        $script:entryScript | Should -Match "'RollbackFailed'\s*\{\s*4\s*\}"
        $script:entryScript | Should -Match 'AwaitKeyToExit -ExitCode \$rollbackExitCode'
    }

    It 'produces a run summary so the rollback record exists' {
        # The export is guarded on $script:RunStartTime, which nothing ever set,
        # so no summary was written at all and rollback had nowhere to be recorded.
        $changes = Get-Content (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')) 'Scripts\Features\InvokeChanges.ps1') -Raw
        $summaryScript = Get-Content (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')) 'Scripts\Features\ExportRunSummary.ps1') -Raw

        $assignPosition = $changes.IndexOf('$script:RunStartTime = Get-Date')
        $guardPosition = $changes.IndexOf('if ($script:RunStartTime -and')

        $assignPosition | Should -BeGreaterThan -1 -Because 'the summary guard is never true otherwise'
        $assignPosition | Should -BeLessThan $guardPosition

        # An apply-only run undoes nothing, and a mandatory string[] rejects @().
        $summaryScript | Should -Match '(?s)AllowEmptyCollection\(\).*?\$UndoneFeatureIds'
        $summaryScript | Should -Match 'Rollback\s*=\s*\[ordered\]'
    }

    It 'warns up front when -SkipRegistryBackup removes the safety net' {
        $changes = Get-Content (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')) 'Scripts\Features\InvokeChanges.ps1') -Raw
        $changes | Should -Match '-SkipRegistryBackup disables automatic rollback'
    }

    It 'quotes bound arrays and unbound arguments during elevation' {
        $script:adminScript | Should -Match 'paramValue -is \[array\]'
        $script:adminScript | Should -Match 'OriginalUnboundArguments'
        $script:adminScript | Should -Match 'Format-ElevatedArg'
    }

    It 'quotes bootstrap arguments before administrator launch' {
        $script:launcherScript | Should -Match 'function Format-LauncherArg'
        $script:launcherScript | Should -Match '\$boundParameter\.Value -is \[array\]'
        $script:launcherScript | Should -Match 'Format-LauncherArg \$argumentValue'
        $script:launcherScript | Should -Match '-ArgumentList \$launchArguments'
    }

    It 'propagates bootstrap launch failures and child exit codes' {
        $script:launcherScript | Should -Match 'Start-Process powershell\.exe.*-ErrorAction Stop'
        $script:launcherScript | Should -Match '\$exitCode = \$debloatProcess\.ExitCode'
        $script:launcherScript | Should -Match 'Exit \$exitCode'
    }
}

Describe 'Winnow script loading' {
    BeforeAll {
        $script:loadRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
        $entry = Get-Content (Join-Path $script:loadRoot 'Winnow.ps1') -Raw
        # Both forms the entry script uses: . (Join-Path $PSScriptRoot 'Scripts\...')
        # and . "$PSScriptRoot/Scripts/...".
        $pattern = '(?m)^\s*\.\s+(?:\(Join-Path \$PSScriptRoot ''|")(?:\$PSScriptRoot/)?(Scripts[\\/][^''"]+\.ps1)'
        $script:loadedScripts = @([regex]::Matches($entry, $pattern) | ForEach-Object {
                ($_.Groups[1].Value -replace '/', '\').ToLowerInvariant()
            })
    }

    It 'dot-sources every script under Scripts apart from the ones kept out by design' {
        # A script that is never dot-sourced defines functions nothing can call.
        # ExportRunSummary.ps1 and TelemetryServices.ps1 were in that state: the
        # run summary was never written and DisableTelemetryServices failed with
        # "command not found". Get.ps1 is the download launcher and
        # WatchdogPayload.ps1 is copied to ProgramData for the scheduled task, so
        # neither belongs in the Winnow process.
        $notLoadedByDesign = @('scripts\get.ps1', 'scripts\watchdog\watchdogpayload.ps1')
        $unloaded = @(Get-ChildItem -LiteralPath (Join-Path $script:loadRoot 'Scripts') -Recurse -Filter '*.ps1' | ForEach-Object {
                $relative = $_.FullName.Substring($script:loadRoot.Length + 1).ToLowerInvariant()
                if ($relative -notin $script:loadedScripts -and $relative -notin $notLoadedByDesign) { $relative }
            })

        $script:loadedScripts.Count | Should -BeGreaterThan 50 -Because 'the dot-source pattern must actually match the entry script'
        $unloaded | Should -BeNullOrEmpty -Because "not dot-sourced by Winnow.ps1: $($unloaded -join ', ')"
    }
}
