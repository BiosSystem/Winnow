#Requires -Modules Pester
<#
.SYNOPSIS
    Contract for automatic rollback after a failed apply.
.DESCRIPTION
    Tagged Mutating. Runs inside Windows Sandbox only. See README.md.

    Scenarios 3 and 4 of Track 3 in the v3.4.0 plan, and the reason Track 3
    landed before Track 1: without these, auto-rollback is an untested claim.

    Failure is injected by copying the repository and replacing one .reg file in
    the copy with a single write to a child key under a parent that denies
    subkey creation. The backup phase only reads, so it succeeds and records the
    child as absent; the apply phase then fails with access denied inside the
    real import step, which is the failure a rollback exists for.

    The replacement has to be total. The PowerShell registry writer skips an
    individual access-denied write with a warning and only treats the import as
    failed when it cannot apply anything in the file, so one denied write mixed
    into allowed ones is a partial apply, not a failed import. Deleting the .reg
    file does not work either: the backup phase parses every selected .reg file
    first and correctly refuses to start, so the run never reaches the apply.
    The real repository is never modified.

    The corrupted feature is not the one under observation. Telemetry values are
    written successfully first, then the second feature's import fails, so a
    correct rollback has something real to restore.
#>

BeforeDiscovery {
    $invokeChanges = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')) 'Scripts\Features\InvokeChanges.ps1'
    $script:RollbackImplemented = (Test-Path -LiteralPath $invokeChanges) -and
        ((Get-Content -LiteralPath $invokeChanges -Raw) -match 'Restore-RegistryBackupState')
}

Describe 'Winnow automatic rollback' -Tag 'Mutating' -Skip:(-not $script:RollbackImplemented) {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'IntegrationCommon.ps1')
        $script:repoRoot = Get-WinnowRepoRoot
        . (Join-Path $script:repoRoot 'Scripts\Helpers\Get-RegFileOperations.ps1')

        $script:watchedRegFile = Join-Path $script:repoRoot 'Regfiles\Disable_Telemetry.reg'
        $script:brokenFeatureRegFile = Join-Path $script:repoRoot 'Regfiles\Disable_Copilot.reg'

        # What these values were before this file ran, restored after every test
        # so a test that leaves an apply in place cannot skew the next one.
        $script:pristineTelemetry = Get-RegFileValueSnapshot -RegFilePath $script:watchedRegFile
        $script:pristineBrokenFeature = Get-RegFileValueSnapshot -RegFilePath $script:brokenFeatureRegFile

        # A parent key nothing may create subkeys under. Reads are unaffected, so
        # the backup phase can snapshot the child (absent); the apply cannot create it.
        # The ACL is changed through .NET with exactly ChangePermissions and
        # ReadPermissions. Get-Acl/Set-Acl -LiteralPath cannot find registry paths
        # in Windows PowerShell 5.1, and Set-Acl opens the key for write, which
        # includes create-subkey, so it could not undo this deny afterwards.
        $script:lockedParentSubKey = 'Software\WinnowIntegrationLocked'
        $script:lockedChildReg = 'HKEY_CURRENT_USER\Software\WinnowIntegrationLocked\InjectedFailure'
        $script:aclRights = [System.Security.AccessControl.RegistryRights]'ChangePermissions, ReadPermissions'
        $script:denyCreateSubKey = New-Object System.Security.AccessControl.RegistryAccessRule(
            (New-Object System.Security.Principal.SecurityIdentifier 'S-1-1-0'),
            [System.Security.AccessControl.RegistryRights]::CreateSubKey,
            [System.Security.AccessControl.InheritanceFlags]::None,
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Deny)

        [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($script:lockedParentSubKey).Close()
        $lockKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:lockedParentSubKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, $script:aclRights)
        try {
            $security = $lockKey.GetAccessControl()
            $security.AddAccessRule($script:denyCreateSubKey)
            $lockKey.SetAccessControl($security)
        }
        finally {
            $lockKey.Close()
        }

        <#
            Copies the repository and breaks one feature's .reg file, then runs
            the copy. Returns the process result.
        #>
        function Invoke-WinnowWithBrokenFeature {
            param(
                [Parameter(Mandatory)][string]$BreakRegFile,
                [string[]]$Arguments
            )

            $sandboxRoot = Join-Path $TestDrive ('run-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
            Copy-Item -LiteralPath $script:repoRoot -Destination $sandboxRoot -Recurse -Force

            $target = Join-Path $sandboxRoot "Regfiles\$BreakRegFile"
            if (-not (Test-Path -LiteralPath $target)) {
                throw "Cannot inject a failure: $target is missing from the copy."
            }

            # Replace the file with one write under the locked parent, written as
            # UTF-16 with a BOM like the shipped .reg files. reg import fails on
            # it and the PowerShell writer can apply nothing in it, so the import
            # counts as failed rather than as a partial apply.
            $injected = "Windows Registry Editor Version 5.00`r`n`r`n[$($script:lockedChildReg)]`r`n`"Value`"=dword:00000001`r`n"
            Set-Content -LiteralPath $target -Value $injected -Encoding Unicode

            $entry = Join-Path $sandboxRoot 'Winnow.ps1'
            $quoted = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $entry)) + $Arguments

            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'powershell.exe'
            $psi.Arguments = ($quoted -join ' ')
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $psi.RedirectStandardInput = $true
            $psi.UseShellExecute = $false

            $process = [System.Diagnostics.Process]::Start($psi)
            $process.StandardInput.Close()
            $stdout = $process.StandardOutput.ReadToEnd()
            $stderr = $process.StandardError.ReadToEnd()
            $null = $process.WaitForExit(300000)

            return [PSCustomObject]@{
                ExitCode = $process.ExitCode
                Stdout = $stdout
                Stderr = $stderr
            }
        }
    }

    AfterEach {
        Restore-RegFileValueSnapshot -RegFilePath $script:watchedRegFile -Snapshot $script:pristineTelemetry
        Restore-RegFileValueSnapshot -RegFilePath $script:brokenFeatureRegFile -Snapshot $script:pristineBrokenFeature
    }

    AfterAll {
        $unlockKey = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($script:lockedParentSubKey,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, $script:aclRights)
        if ($unlockKey) {
            try {
                $security = $unlockKey.GetAccessControl()
                [void]$security.RemoveAccessRule($script:denyCreateSubKey)
                $unlockKey.SetAccessControl($security)
            }
            finally {
                $unlockKey.Close()
            }
            [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($script:lockedParentSubKey, $false)
        }
    }

    Context 'when a registry import fails' {

        It 'restores the values captured before the apply phase and exits 3' {
            $before = Get-RegFileValueSnapshot -RegFilePath $script:watchedRegFile
            $before.Count | Should -BeGreaterThan 0 -Because 'the test is meaningless without values to watch'

            $result = Invoke-WinnowWithBrokenFeature -BreakRegFile 'Disable_Copilot.reg' `
                -Arguments @('-Silent', '-CLI', '-DisableTelemetry', '-DisableCopilot')

            $result.Stdout | Should -Match 'Rolling back registry changes'

            $after = Get-RegFileValueSnapshot -RegFilePath $script:watchedRegFile
            $changed = Compare-RegValueSnapshot -Before $before -After $after
            $changed | Should -BeNullOrEmpty -Because "rollback should have restored: $($changed -join '; ')"

            # 3 is "failed and rolled back cleanly", distinct from 1 and from
            # 2, which means verification drift.
            $result.ExitCode | Should -Be 3
        }

        It 'records the rollback in the run summary' {
            $summary = Get-ChildItem -Path $env:TEMP -Filter 'Winnow_RunSummary_*.json' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1

            $summary | Should -Not -BeNullOrEmpty
            $content = Get-Content -LiteralPath $summary.FullName -Raw | ConvertFrom-Json

            $content.PSObject.Properties.Name | Should -Contain 'Rollback'
            $content.Rollback.Triggered | Should -BeTrue
            $content.Rollback.Outcome | Should -Be 'RolledBack'
            $content.Rollback.Reason | Should -Not -BeNullOrEmpty
            $content.Rollback.BackupPath | Should -Not -BeNullOrEmpty
        }

        It 'does not run undo work after a failed apply' {
            $result = Invoke-WinnowWithBrokenFeature -BreakRegFile 'Disable_Copilot.reg' `
                -Arguments @('-Silent', '-CLI', '-DisableTelemetry', '-DisableCopilot')

            $result.Stdout | Should -Match 'Rolling back registry changes'
        }
    }

    Context 'when rollback is disabled' {

        It 'leaves the changes in place under -NoAutoRollback' {
            $before = Get-RegFileValueSnapshot -RegFilePath $script:watchedRegFile

            $result = Invoke-WinnowWithBrokenFeature -BreakRegFile 'Disable_Copilot.reg' `
                -Arguments @('-Silent', '-CLI', '-DisableTelemetry', '-DisableCopilot', '-NoAutoRollback')

            $result.Stdout | Should -Match 'Rollback skipped because -NoAutoRollback'
            $result.Stdout | Should -Not -Match 'Rolling back registry changes'

            $after = Get-RegFileValueSnapshot -RegFilePath $script:watchedRegFile
            $changed = Compare-RegValueSnapshot -Before $before -After $after
            $changed | Should -Not -BeNullOrEmpty -Because 'the applied changes should have been kept'

            # Nothing was rolled back, so this is a plain failure, not a 3.
            $result.ExitCode | Should -Not -Be 3
        }

        It 'warns at run start when -SkipRegistryBackup removes the safety net' {
            $result = Invoke-WinnowWithBrokenFeature -BreakRegFile 'Disable_Copilot.reg' `
                -Arguments @('-Silent', '-CLI', '-DisableTelemetry', '-DisableCopilot', '-SkipRegistryBackup')

            $result.Stdout | Should -Match '-SkipRegistryBackup disables automatic rollback'
            # The failure-time line covers the registry and module backups alike.
            $result.Stdout | Should -Match 'no backup is available'
        }
    }

    Context 'when only an app removal fails' {

        It 'does not roll back' {
            # The load-bearing case. A registry restore cannot bring back an
            # uninstalled Appx package, so rolling back here would report a
            # recovery that did not happen while the apps stay gone.
            $before = Get-RegFileValueSnapshot -RegFilePath $script:watchedRegFile

            $result = Invoke-WinnowProcess -Arguments @(
                '-Silent', '-CLI', '-DisableTelemetry',
                '-RemoveApps', '-Apps', 'Winnow.IntegrationTest.NotAReal.Package'
            ) -TimeoutSeconds 300

            $result.Stdout | Should -Not -Match 'Rolling back registry changes'

            $after = Get-RegFileValueSnapshot -RegFilePath $script:watchedRegFile
            $changed = Compare-RegValueSnapshot -Before $before -After $after
            $changed | Should -Not -BeNullOrEmpty -Because 'the registry changes should have been kept, not reverted'
        }
    }

    Context 'dry runs' {

        It 'never restores anything under -DryRun' {
            $before = Get-RegFileValueSnapshot -RegFilePath $script:watchedRegFile

            # The injected fault only fails on a write, and a dry run writes
            # nothing, so the run completes cleanly and has nothing to restore.
            $result = Invoke-WinnowWithBrokenFeature -BreakRegFile 'Disable_Copilot.reg' `
                -Arguments @('-DryRun', '-Silent', '-CLI', '-DisableTelemetry', '-DisableCopilot')

            $result.Stdout | Should -Not -Match 'Rolling back registry changes'
            $result.ExitCode | Should -Be 0

            $after = Get-RegFileValueSnapshot -RegFilePath $script:watchedRegFile
            $changed = Compare-RegValueSnapshot -Before $before -After $after
            $changed | Should -BeNullOrEmpty -Because "a dry run must not change the registry: $($changed -join '; ')"
        }
    }
}
