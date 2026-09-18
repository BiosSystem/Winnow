#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Unit tests for the user-hive unload retry logic.
.DESCRIPTION
    reg unload fails while any handle into the loaded hive is still open. Dismount-WinnowTargetUserHive
    forces a garbage collection before unloading and retries once, so a lingering RegistryKey handle
    does not leave the hive mounted after a Sysprep, per-user, or restore-to-another-user run. reg.exe
    is native and cannot be mocked, so the actual unload is behind Invoke-WinnowRegHiveUnload, which
    these tests mock.
#>

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $repoRoot 'Scripts\Helpers\UserHiveHelpers.ps1')
}

Describe 'Dismount-WinnowTargetUserHive' {

    It 'unloads on the first attempt when reg unload succeeds' {
        Mock -CommandName Invoke-WinnowRegHiveUnload -MockWith { 0 }

        Dismount-WinnowTargetUserHive -MountName 'Default' | Should -BeTrue
        Should -Invoke -CommandName Invoke-WinnowRegHiveUnload -Times 1 -Exactly
    }

    It 'retries after a garbage collection and succeeds when the first unload fails' {
        $script:unloadCalls = 0
        Mock -CommandName Invoke-WinnowRegHiveUnload -MockWith {
            $script:unloadCalls++
            if ($script:unloadCalls -eq 1) { 1 } else { 0 }
        }

        Dismount-WinnowTargetUserHive -MountName 'Default' | Should -BeTrue
        Should -Invoke -CommandName Invoke-WinnowRegHiveUnload -Times 2 -Exactly
    }

    It 'warns and reports failure when both attempts fail' {
        Mock -CommandName Invoke-WinnowRegHiveUnload -MockWith { 1 }

        $result = Dismount-WinnowTargetUserHive -MountName 'Default' -WarningAction SilentlyContinue
        $result | Should -BeFalse
        Should -Invoke -CommandName Invoke-WinnowRegHiveUnload -Times 2 -Exactly
    }
}
