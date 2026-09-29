#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for the custom-feature apply and undo bodies.
.DESCRIPTION
    Enable-GamingMode, Enable-PerformanceTweaks, Enable-SecurityHardening and
    Disable-ExtendedAIPurge (plus their undo counterparts) do real registry,
    service, power, firewall and optional-feature changes. They were only
    exercised end to end by the Windows Sandbox mutating suite; the static
    drift guard in Test-ModuleRollback checks the declared target lists but
    never runs a body. These tests run each body with every OS-touching command
    mocked and assert what it writes, that it creates missing keys, that -WhatIf
    gates every change, and that its undo reverses the right values.

    Two safety measures keep this off the real machine: powercfg and netsh are
    shadowed by no-op functions before anything runs, so the native executables
    can never be reached even if a mock were missing, and every mutating cmdlet
    is mocked. Nothing here is tagged Mutating; it is pure unit coverage.

    The runtime drift check is stronger than the static one: it confirms every
    Path+Name a body actually writes is declared by that module's
    registry-target provider, so a wrong key path (not just a wrong value name)
    is caught. The reverse direction is deliberately not asserted, since a body
    skips conditional writes when a key is absent.
#>

BeforeAll {
    $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
    $script:featuresPath = Join-Path $script:repoRoot 'Scripts\Features'
    . (Join-Path $script:featuresPath 'GamingMode.ps1')
    . (Join-Path $script:featuresPath 'PerformanceTweaks.ps1')
    . (Join-Path $script:featuresPath 'SecurityHardening.ps1')
    . (Join-Path $script:featuresPath 'ExtendedAIPurge.ps1')

    # Shadow the native executables so a missed mock can never touch the real
    # power plan or firewall. A function outranks an application in command
    # resolution, so these win even before Mock replaces them.
    function powercfg { }
    function netsh { }

    # Two fake network interfaces so the Nagle writes and the provider that
    # enumerates them both see the same set of interface keys.
    $script:fakeInterfaces = @(
        [pscustomobject]@{ PSPath = 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{iface-1}' }
        [pscustomobject]@{ PSPath = 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{iface-2}' }
    )

    # Every write a body issues, so the drift check can compare against the
    # module's declared targets.
    $script:regWrites = [System.Collections.Generic.List[object]]::new()
    $script:regRemoves = [System.Collections.Generic.List[object]]::new()
    $script:keysCreated = [System.Collections.Generic.List[string]]::new()

    function Get-UndeclaredWrites {
        param([object[]]$Targets)
        $undeclared = New-Object System.Collections.Generic.List[string]
        foreach ($write in $script:regWrites) {
            $match = @($Targets | Where-Object { $_.Path -ieq $write.Path -and $_.Name -ieq $write.Name })
            if ($match.Count -eq 0) {
                $undeclared.Add(('{0}\{1}' -f $write.Path, $write.Name))
            }
        }
        return $undeclared
    }

    # Mocks common to every context. Recording mocks push into the script-scoped
    # lists that BeforeEach clears before each test. Invoked from each Describe's
    # BeforeAll so the mocks bind to that Describe.
    function Set-CommonFeatureMocks {
        Mock Write-Host { }
        Mock Set-ItemProperty { $script:regWrites.Add([pscustomobject]@{ Path = $Path; Name = $Name; Value = $Value }) }
        Mock Remove-ItemProperty { $script:regRemoves.Add([pscustomobject]@{ Path = $Path; Name = $Name }) }
        Mock New-Item { $script:keysCreated.Add([string]$Path) }
        Mock Test-Path { $false }
        Mock Get-ChildItem { $script:fakeInterfaces }
        Mock Set-Service { }
        Mock Stop-Service { }
        Mock Start-Service { }
        Mock Set-SmbServerConfiguration { }
        Mock Disable-WindowsOptionalFeature { }
        Mock Get-WindowsOptionalFeature { [pscustomobject]@{ State = 'Enabled' } }
        Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Ready' } }
        Mock Disable-ScheduledTask { }
        Mock powercfg { 'Power Scheme GUID: 381b4222-f694-41f0-9685-ff5bb260df2e  (High performance)' }
        Mock netsh { }
    }
}

Describe 'Enable-GamingMode' {
    BeforeAll { Set-CommonFeatureMocks }
    BeforeEach {
        $script:regWrites.Clear(); $script:regRemoves.Clear(); $script:keysCreated.Clear()
    }

    It 'writes the curated tweak values and creates the keys it needs' {
        Enable-GamingMode

        ($script:regWrites | Where-Object { $_.Path -eq 'HKCU:\Control Panel\Mouse' -and $_.Name -eq 'MouseSpeed' -and $_.Value -eq '0' }) | Should -Not -BeNullOrEmpty
        ($script:regWrites | Where-Object { $_.Name -eq 'HwSchMode' -and $_.Value -eq 2 }) | Should -Not -BeNullOrEmpty
        ($script:regWrites | Where-Object { $_.Name -eq 'AllowGameDVR' -and $_.Value -eq 0 }) | Should -Not -BeNullOrEmpty
        ($script:regWrites | Where-Object { $_.Name -eq 'MaintenanceDisabled' -and $_.Value -eq 1 }) | Should -Not -BeNullOrEmpty
        $script:keysCreated | Should -Contain 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'
    }

    It 'disables Nagle on every network interface' {
        Enable-GamingMode

        $nagle = @($script:regWrites | Where-Object { $_.Name -eq 'TcpAckFrequency' })
        $nagle.Count | Should -Be $script:fakeInterfaces.Count
    }

    It 'sets the High Performance power plan by GUID' {
        Enable-GamingMode
        Should -Invoke powercfg -Times 1 -Exactly -ParameterFilter { $args -contains '-setactive' -and $args -contains '381b4222-f694-41f0-9685-ff5bb260df2e' }
    }

    It 'writes nothing under -WhatIf' {
        Enable-GamingMode -WhatIf
        Should -Invoke Set-ItemProperty -Times 0
        Should -Invoke New-Item -Times 0
    }

    It 'writes only values its registry-target provider declares' {
        Enable-GamingMode
        Get-UndeclaredWrites -Targets @(Get-GamingModeRegistryTargets) | Should -BeNullOrEmpty
    }
}

Describe 'Disable-GamingMode' {
    BeforeAll { Set-CommonFeatureMocks }
    BeforeEach {
        $script:regWrites.Clear(); $script:regRemoves.Clear(); $script:keysCreated.Clear()
    }

    It 'removes the Nagle values and restores automatic maintenance' {
        Disable-GamingMode

        @($script:regRemoves | Where-Object { $_.Name -eq 'TcpAckFrequency' }) | Should -Not -BeNullOrEmpty
        @($script:regRemoves | Where-Object { $_.Name -eq 'MaintenanceDisabled' }) | Should -Not -BeNullOrEmpty
    }

    It 'restores the Balanced power plan' {
        Disable-GamingMode
        Should -Invoke powercfg -Times 1 -Exactly -ParameterFilter { $args -contains 'SCHEME_BALANCED' }
    }
}

Describe 'Enable-PerformanceTweaks' {
    BeforeAll { Set-CommonFeatureMocks }
    BeforeEach {
        $script:regWrites.Clear(); $script:regRemoves.Clear(); $script:keysCreated.Clear()
    }

    It 'disables the heavy background services' {
        Enable-PerformanceTweaks

        Should -Invoke Set-Service -ParameterFilter { $Name -eq 'SysMain' -and $StartupType -eq 'Disabled' }
        Should -Invoke Set-Service -ParameterFilter { $Name -eq 'WSearch' -and $StartupType -eq 'Disabled' }
        Should -Invoke Set-Service -ParameterFilter { $Name -eq 'Spooler' -and $StartupType -eq 'Disabled' }
        Should -Invoke Stop-Service -ParameterFilter { $Name -eq 'SysMain' }
    }

    It 'turns off hibernate and writes the responsiveness tweaks' {
        Enable-PerformanceTweaks

        Should -Invoke powercfg -ParameterFilter { $args -contains '-h' -and $args -contains 'off' }
        ($script:regWrites | Where-Object { $_.Name -eq 'StartupDelayInMSec' -and $_.Value -eq 0 }) | Should -Not -BeNullOrEmpty
        ($script:regWrites | Where-Object { $_.Name -eq 'ShowSecondsInSystemClock' -and $_.Value -eq 1 }) | Should -Not -BeNullOrEmpty
    }

    It 'touches no service and writes nothing under -WhatIf' {
        Enable-PerformanceTweaks -WhatIf
        Should -Invoke Set-Service -Times 0
        Should -Invoke Stop-Service -Times 0
        Should -Invoke Set-ItemProperty -Times 0
    }
}

Describe 'Disable-PerformanceTweaks' {
    BeforeAll { Set-CommonFeatureMocks }
    BeforeEach {
        $script:regWrites.Clear(); $script:regRemoves.Clear(); $script:keysCreated.Clear()
    }

    It 're-enables and starts the services it disabled' {
        Disable-PerformanceTweaks

        Should -Invoke Set-Service -ParameterFilter { $Name -eq 'SysMain' -and $StartupType -eq 'Automatic' }
        Should -Invoke Set-Service -ParameterFilter { $Name -eq 'WSearch' -and $StartupType -eq 'Automatic' }
        Should -Invoke Start-Service -ParameterFilter { $Name -eq 'Spooler' }
    }

    It 're-enables hibernate' {
        Disable-PerformanceTweaks
        Should -Invoke powercfg -ParameterFilter { $args -contains '-h' -and $args -contains 'on' }
    }
}

Describe 'Enable-SecurityHardening' {
    BeforeAll { Set-CommonFeatureMocks }
    BeforeEach {
        $script:regWrites.Clear(); $script:regRemoves.Clear(); $script:keysCreated.Clear()
    }

    It 'disables SMBv1' {
        Enable-SecurityHardening
        Should -Invoke Set-SmbServerConfiguration -ParameterFilter { $EnableSMB1Protocol -eq $false }
    }

    It 'denies RDP, hardens AutoRun, disables the legacy TLS versions and blocks the Windows Script Host' {
        Enable-SecurityHardening

        ($script:regWrites | Where-Object { $_.Name -eq 'fDenyTSConnections' -and $_.Value -eq 1 }) | Should -Not -BeNullOrEmpty
        ($script:regWrites | Where-Object { $_.Name -eq 'NoDriveTypeAutoRun' -and $_.Value -eq 255 }) | Should -Not -BeNullOrEmpty
        @($script:regWrites | Where-Object { $_.Name -eq 'DisabledByDefault' -and $_.Value -eq 1 }) | Should -Not -BeNullOrEmpty
        ($script:regWrites | Where-Object { $_.Path -like '*Windows Script Host*' -and $_.Name -eq 'Enabled' -and $_.Value -eq 0 }) | Should -Not -BeNullOrEmpty
    }

    It 'blocks the SMB and NetBIOS ports through the firewall' {
        Enable-SecurityHardening
        Should -Invoke netsh -ParameterFilter { $args -contains 'localport=445' }
        Should -Invoke netsh -ParameterFilter { $args -contains 'localport=139' }
    }

    It 'writes nothing under -WhatIf' {
        Enable-SecurityHardening -WhatIf
        Should -Invoke Set-ItemProperty -Times 0
        Should -Invoke Set-SmbServerConfiguration -Times 0
        Should -Invoke netsh -Times 0
    }

    It 'writes only values its registry-target provider declares' {
        Enable-SecurityHardening
        Get-UndeclaredWrites -Targets @(Get-SecurityHardeningRegistryTargets) | Should -BeNullOrEmpty
    }
}

Describe 'Disable-SecurityHardening' {
    BeforeAll { Set-CommonFeatureMocks }
    BeforeEach {
        $script:regWrites.Clear(); $script:regRemoves.Clear(); $script:keysCreated.Clear()
    }

    It 're-enables RDP, restores the AutoRun default and re-enables the Windows Script Host' {
        Disable-SecurityHardening

        ($script:regWrites | Where-Object { $_.Name -eq 'fDenyTSConnections' -and $_.Value -eq 0 }) | Should -Not -BeNullOrEmpty
        ($script:regWrites | Where-Object { $_.Name -eq 'NoDriveTypeAutoRun' -and $_.Value -eq 91 }) | Should -Not -BeNullOrEmpty
        ($script:regWrites | Where-Object { $_.Path -like '*Windows Script Host*' -and $_.Name -eq 'Enabled' -and $_.Value -eq 1 }) | Should -Not -BeNullOrEmpty
    }
}

Describe 'Disable-ExtendedAIPurge' {
    BeforeAll { Set-CommonFeatureMocks }
    BeforeEach {
        $script:regWrites.Clear(); $script:regRemoves.Clear(); $script:keysCreated.Clear()
    }

    It 'writes the user-and-machine AI policies to both hives' {
        Disable-ExtendedAIPurge

        @($script:regWrites | Where-Object { $_.Path -eq 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' -and $_.Name -eq 'DisableClickToDo' }) | Should -Not -BeNullOrEmpty
        @($script:regWrites | Where-Object { $_.Path -eq 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI' -and $_.Name -eq 'DisableClickToDo' }) | Should -Not -BeNullOrEmpty
        ($script:regWrites | Where-Object { $_.Name -eq 'AllowRecallEnablement' -and $_.Value -eq 0 }) | Should -Not -BeNullOrEmpty
        ($script:regWrites | Where-Object { $_.Name -eq 'TurnOffWindowsCopilot' -and $_.Value -eq 1 }) | Should -Not -BeNullOrEmpty
    }

    It 'writes the Paint AI policy values at the Paint policy key' {
        Disable-ExtendedAIPurge

        foreach ($name in 'DisableCocreator', 'DisableGenerativeFill', 'DisableImageCreator') {
            ($script:regWrites | Where-Object { $_.Path -like '*\Policies\Paint' -and $_.Name -eq $name }) | Should -Not -BeNullOrEmpty
        }
    }

    It 'disables each sluggishness telemetry task that is present and not already disabled' {
        Disable-ExtendedAIPurge
        Should -Invoke Disable-ScheduledTask -Times 4 -Exactly
    }

    It 'leaves the tasks alone when they are already disabled' {
        Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Disabled' } }
        Disable-ExtendedAIPurge
        Should -Invoke Disable-ScheduledTask -Times 0
    }

    It 'removes the Recall optional component only when it is present and enabled' {
        Disable-ExtendedAIPurge
        Should -Invoke Disable-WindowsOptionalFeature -ParameterFilter { $FeatureName -eq 'Recall' }
    }

    It 'does not remove the Recall component when the feature is absent' {
        Mock Get-WindowsOptionalFeature { [pscustomobject]@{ State = 'Disabled' } }
        Disable-ExtendedAIPurge
        Should -Invoke Disable-WindowsOptionalFeature -ParameterFilter { $FeatureName -eq 'Recall' } -Times 0
    }

    It 'writes nothing under -WhatIf' {
        Disable-ExtendedAIPurge -WhatIf
        Should -Invoke Set-ItemProperty -Times 0
        Should -Invoke Disable-ScheduledTask -Times 0
        Should -Invoke Disable-WindowsOptionalFeature -Times 0
    }

    It 'writes only values its registry-target provider declares' {
        Disable-ExtendedAIPurge
        Get-UndeclaredWrites -Targets @(Get-ExtendedAIPurgeRegistryTargets) | Should -BeNullOrEmpty
    }
}

Describe 'Enable-ExtendedAIPurgeRevert' {
    BeforeAll { Set-CommonFeatureMocks }
    BeforeEach {
        $script:regWrites.Clear(); $script:regRemoves.Clear(); $script:keysCreated.Clear()
    }

    It 'restores Phone Link when its key exists and clears the cloud clipboard opt-in' {
        Mock Test-Path { $true }
        Enable-ExtendedAIPurgeRevert

        ($script:regWrites | Where-Object { $_.Name -eq 'PhoneLinkEnabled' -and $_.Value -eq 1 }) | Should -Not -BeNullOrEmpty
        @($script:regRemoves | Where-Object { $_.Name -eq 'EnableCloudClipboard' }) | Should -Not -BeNullOrEmpty
    }
}
