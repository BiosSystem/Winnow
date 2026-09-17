#Requires -Modules Pester
<#
.SYNOPSIS
    Live test for the hardened update watchdog.
.DESCRIPTION
    Tagged Mutating. Runs inside Windows Sandbox only. See README.md.

    The unit tests cover the watchdog functions with mocks. This installs the real thing and checks
    the mutations that only happen against a live system: the SYSTEM scheduled task is registered,
    the payload directory is locked down, the payload's recorded hash makes the integrity check pass,
    a drifted machine policy is re-asserted against the real registry, and a tampered payload fails
    the integrity check closed.

    Everything is removed in AfterAll. The sandbox is discarded regardless, but a clean teardown lets
    the file be re-run in the same session.
#>

BeforeDiscovery {
    $script:wdElevated = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Describe 'Winnow update watchdog (live)' -Tag 'Mutating' -Skip:(-not $script:wdElevated) {

    BeforeAll {
        . (Join-Path $PSScriptRoot 'IntegrationCommon.ps1')
        $script:repoRoot = Get-WinnowRepoRoot
        . (Join-Path $script:repoRoot 'Scripts\Features\UpdateWatchdog.ps1')
        . (Join-Path $script:repoRoot 'Scripts\Watchdog\WatchdogPayload.ps1')
        $script:context = Get-WinnowWatchdogContext

        Invoke-InstallUpdateWatchdog
    }

    AfterAll {
        try { Unregister-ScheduledTask -TaskName 'Winnow_UpdateWatchdog' -TaskPath '\Winnow' -Confirm:$false -ErrorAction SilentlyContinue } catch { }
        try { Remove-Item -LiteralPath $script:context.Directory -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-Item -LiteralPath 'HKLM:\SOFTWARE\Winnow' -Recurse -Force -ErrorAction SilentlyContinue } catch { }
        try { if ([System.Diagnostics.EventLog]::SourceExists('Winnow')) { [System.Diagnostics.EventLog]::DeleteEventSource('Winnow') } } catch { }
    }

    It 'registers the SYSTEM task and reports healthy' {
        $task = Get-ScheduledTask -TaskName 'Winnow_UpdateWatchdog' -TaskPath '\Winnow' -ErrorAction SilentlyContinue
        $task | Should -Not -BeNullOrEmpty
        $task.Principal.UserId | Should -Match 'SYSTEM'

        $health = Get-WinnowWatchdogHealth
        $health.Installed     | Should -BeTrue
        $health.IntegrityOk   | Should -BeTrue
        $health.AclLockedDown | Should -BeTrue
        $health.Healthy       | Should -BeTrue
    }

    It 'locks the payload directory so standard users cannot write it' {
        $acl = Get-Acl -LiteralPath $script:context.Directory
        $acl.AreAccessRulesProtected | Should -BeTrue

        $writeRights = [int][System.Security.AccessControl.FileSystemRights]::Write
        foreach ($rule in $acl.Access) {
            $sid = ''
            try { $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value } catch { $sid = '' }
            if ($sid -in @('S-1-5-32-545', 'S-1-5-11', 'S-1-1-0')) {
                ([int]$rule.FileSystemRights -band $writeRights) | Should -Be 0
            }
        }
    }

    It 're-asserts a drifted machine policy value against the real registry' {
        $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
        $desired = [PSCustomObject]@{
            Registry = @(@{ Path = $policyPath; Name = 'AllowTelemetry'; Value = 0 })
            Services = @()
            Tasks    = @()
        }

        if (-not (Test-Path -LiteralPath $policyPath)) { New-Item -Path $policyPath -Force | Out-Null }
        Set-ItemProperty -LiteralPath $policyPath -Name 'AllowTelemetry' -Value 1 -Type DWord -Force

        $reasserted = @(Invoke-WinnowWatchdogEnforcement -DesiredState $desired)

        (Get-ItemProperty -LiteralPath $policyPath -Name 'AllowTelemetry').AllowTelemetry | Should -Be 0
        ($reasserted -join ' ') | Should -Match 'AllowTelemetry'
    }

    It 'leaves an already-correct value untouched and reports no drift' {
        $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'
        Set-ItemProperty -LiteralPath $policyPath -Name 'AllowTelemetry' -Value 0 -Type DWord -Force
        $desired = [PSCustomObject]@{
            Registry = @(@{ Path = $policyPath; Name = 'AllowTelemetry'; Value = 0 })
            Services = @()
            Tasks    = @()
        }

        $reasserted = @(Invoke-WinnowWatchdogEnforcement -DesiredState $desired)

        $reasserted.Count | Should -Be 0
    }

    It 'fails closed when the deployed payload is tampered with' {
        # Runs last: it corrupts the deployed payload, which AfterAll then removes.
        Add-Content -LiteralPath $script:context.PayloadPath -Value "`n# tampered by the integration test"

        Test-WinnowWatchdogIntegrity -PayloadPath $script:context.PayloadPath -RegPath $script:context.RegPath | Should -BeFalse

        $health = Get-WinnowWatchdogHealth
        $health.IntegrityOk | Should -BeFalse
        $health.Healthy | Should -BeFalse
    }
}
