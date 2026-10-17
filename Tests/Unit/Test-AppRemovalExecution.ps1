#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for the app-removal execution paths in RemoveApps.ps1 and
    ForceRemoveEdge.ps1.
.DESCRIPTION
    These functions uninstall Store apps via winget and the Appx cmdlets, fall
    back to DISM on 24H2, schedule RunOnce winget tasks, and force-remove Edge.
    Only the Windows Sandbox mutating suite ever ran them end to end; the unit
    suite covered the metadata and the verification adapters but never the
    removal bodies themselves.

    Every OS-touching command is mocked, and winget and DISM are shadowed by
    no-op functions so the native tools can never run even if a mock were
    missing. ForceRemoveEdge writes directly to HKLM and the file system before
    any exit-code logic, so only its WhatIf/DryRun short circuit is exercised
    here; the rest stays in the Sandbox suite.

    The focus is the logic that is easy to get wrong and expensive to debug on a
    real machine: the winget-vs-Appx dispatch, the Edge deferral, the
    post-removal verification counters, and the Base64 encoding that keeps a
    hostile app id from breaking out of the scheduled RunOnce command.
#>

BeforeAll {
    $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
    . (Join-Path $script:repoRoot 'Scripts\AppRemoval\RemoveApps.ps1')
    . (Join-Path $script:repoRoot 'Scripts\AppRemoval\ForceRemoveEdge.ps1')

    # External helpers RemoveApps.ps1 calls but does not define. Stubbed so Mock
    # has a command to replace and the real dependencies stay out of the suite.
    function GetTargetUserForAppRemoval { 'AllUsers' }
    function Invoke-NonBlocking { param([scriptblock]$ScriptBlock, [object[]]$ArgumentList = @(), [int]$TimeoutSeconds = 0) }
    function GetInstalledAppsViaWinget { param([int]$TimeOut, [switch]$NonBlocking) }
    function Test-AppInWingetList { param([string]$appId, [object[]]$InstalledList) $false }
    function GetUserName { 'TestUser' }
    function Show-MessageBox { param($Message, $Title, $Button, $Icon) 'No' }
    function Invoke-WithTargetUserHive { param([string]$TargetUserName, [scriptblock]$ScriptBlock, $ArgumentObject, [switch]$PassHiveContext) }
    function Invoke-RegistryOperation { param($Operation, $RegFilePath) }

    # Shadow the native tools so a missed mock cannot reach the real machine.
    function winget { }
    function DISM { }

    function Reset-AppRemovalState {
        $script:Params = @{}
        $script:WingetInstalled = $true
        $script:CancelRequested = $false
        $script:ApplySubStepCallback = $null
        $script:GuiWindow = $null
        $script:AppRemovalFailures = 0
        $script:AppRemovalFailedApps = @()
        $script:AppRemovalRemovedApps = @()
        $script:AppRemovalVerificationUnavailable = $false
        $script:AppRemovalDeferredApps = @()
        $script:AppRemovalMethodCache = $null
    }

    # What Remove-WinGetApp builds from a winget run that refused a user-scope package.
    $script:userScopeRefusal = [pscustomobject]@{
        Output   = @('The package installed for user scope cannot be uninstalled when running with administrator privileges.')
        ExitCode = -1978335107
    }
}

Describe 'Get-AppRemovalMethod' {
    BeforeAll {
        $script:appsJsonPath = Join-Path $TestDrive 'Apps.json'
        @{
            Apps = @(
                @{ AppId = 'Contoso.WinGetApp'; RemovalMethod = 'WinGet' }
                @{ AppId = 'Contoso.AppxApp'; RemovalMethod = 'Appx' }
                @{ AppId = 'Contoso.NoMethod' }
                @{ AppId = @('Contoso.Multi1', 'Contoso.Multi2'); RemovalMethod = 'WinGet' }
            )
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $script:appsJsonPath -Encoding UTF8
    }

    BeforeEach {
        Reset-AppRemovalState
        $script:AppsListFilePath = $script:appsJsonPath
    }

    It 'returns WinGet for a WinGet app and Appx for an Appx app' {
        Get-AppRemovalMethod 'Contoso.WinGetApp' | Should -Be 'WinGet'
        Get-AppRemovalMethod 'Contoso.AppxApp' | Should -Be 'Appx'
    }

    It 'defaults an app with no RemovalMethod, and an unknown id, to Appx' {
        Get-AppRemovalMethod 'Contoso.NoMethod' | Should -Be 'Appx'
        Get-AppRemovalMethod 'Contoso.DoesNotExist' | Should -Be 'Appx'
    }

    It 'maps every id when an app declares an array of ids' {
        Get-AppRemovalMethod 'Contoso.Multi1' | Should -Be 'WinGet'
        Get-AppRemovalMethod 'Contoso.Multi2' | Should -Be 'WinGet'
    }

    It 'defaults to Appx when the apps file is missing' {
        $script:AppsListFilePath = Join-Path $TestDrive 'Absent.json'
        Get-AppRemovalMethod 'Contoso.WinGetApp' | Should -Be 'Appx'
    }
}

Describe 'RemoveApps' {
    BeforeEach {
        Reset-AppRemovalState
        Mock Write-Host { }
        Mock GetTargetUserForAppRemoval { 'AllUsers' }
        Mock Remove-WinGetApp { }
        Mock Remove-AppxApp { }
        Mock Remove-EdgeApp { }
        Mock Request-EdgeForceRemove { }
        Mock GetInstalledAppsViaWinget { @([pscustomobject]@{ Id = 'x' }) }
        Mock Test-AppStillInstalled { $false }
        Mock Get-AppRemovalMethod {
            param($appId)
            if ($appId -eq 'Contoso.WinGetApp') { 'WinGet' } else { 'Appx' }
        }
    }

    It 'prints a preview and removes nothing under WhatIf' {
        $script:Params = @{ WhatIf = $true }
        RemoveApps @('Contoso.WinGetApp', 'Contoso.AppxApp')

        Should -Invoke Remove-WinGetApp -Times 0
        Should -Invoke Remove-AppxApp -Times 0
    }

    It 'routes each app to the method its metadata declares' {
        RemoveApps @('Contoso.WinGetApp', 'Contoso.AppxApp')

        Should -Invoke Remove-WinGetApp -Times 1 -ParameterFilter { $app -eq 'Contoso.WinGetApp' }
        Should -Invoke Remove-AppxApp -Times 1 -ParameterFilter { $app -eq 'Contoso.AppxApp' }
    }

    It 'defers Edge to the end and never routes it through the per-app loop' {
        RemoveApps @('Microsoft.Edge', 'Contoso.AppxApp')

        Should -Invoke Remove-EdgeApp -Times 1
        Should -Invoke Remove-WinGetApp -Times 0
    }

    It 'stops immediately when a cancel has been requested' {
        $script:CancelRequested = $true
        RemoveApps @('Contoso.WinGetApp')

        Should -Invoke Remove-WinGetApp -Times 0
    }

    It 'counts a winget removal that is still present as a failure' {
        Mock Test-AppStillInstalled { $true }
        RemoveApps @('Contoso.WinGetApp')

        $script:AppRemovalFailures | Should -Be 1
        $script:AppRemovalFailedApps | Should -Contain 'Contoso.WinGetApp'
    }

    It 'records a winget removal that is gone afterwards as removed' {
        Mock Test-AppStillInstalled { $false }
        RemoveApps @('Contoso.WinGetApp')

        $script:AppRemovalRemovedApps | Should -Contain 'Contoso.WinGetApp'
        $script:AppRemovalFailures | Should -Be 0
    }

    It 'flags verification as unavailable when the post-removal list cannot be read' {
        Mock GetInstalledAppsViaWinget { $null }
        RemoveApps @('Contoso.WinGetApp')

        $script:AppRemovalVerificationUnavailable | Should -BeTrue
    }

    It 'triggers the Edge force-remove path when Edge survives winget' {
        Mock Test-AppStillInstalled { $true }
        RemoveApps @('Microsoft.Edge')

        Should -Invoke Request-EdgeForceRemove -Times 1
    }
}

Describe 'Remove-WinGetApp' {
    BeforeEach {
        Reset-AppRemovalState
        Mock Write-Host { }
        Mock Invoke-NonBlocking { }
        Mock Set-RunOnceWingetTask { }
        Mock GetUserName { 'TestUser' }
    }

    It 'does nothing but warn when winget is unavailable' {
        $script:WingetInstalled = $false
        Remove-WinGetApp -app 'Contoso.App'

        Should -Invoke Invoke-NonBlocking -Times 0
        Should -Invoke Set-RunOnceWingetTask -Times 0
    }

    It 'schedules a RunOnce task for a targeted user before uninstalling' {
        $script:Params = @{ User = 'Alice' }
        Remove-WinGetApp -app 'Contoso.App'

        Should -Invoke Set-RunOnceWingetTask -Times 1 -ParameterFilter { $appId -eq 'Contoso.App' }
        Should -Invoke Invoke-NonBlocking -Times 1
    }

    It 'uninstalls without scheduling a task in the default machine scope' {
        Remove-WinGetApp -app 'Contoso.App'

        Should -Invoke Set-RunOnceWingetTask -Times 0
        Should -Invoke Invoke-NonBlocking -Times 1
    }
}

Describe 'Remove-EdgeApp' {
    BeforeEach {
        Reset-AppRemovalState
        Mock Write-Host { }
        Mock Invoke-NonBlocking { }
        Mock Set-RunOnceWingetTask { }
    }

    It 'does nothing but warn when winget is unavailable' {
        $script:WingetInstalled = $false
        Remove-EdgeApp -edgeAppsInList @('Microsoft.Edge')

        Should -Invoke Invoke-NonBlocking -Times 0
    }

    It 'schedules one Edge task for new users and runs winget for each Edge id' {
        $script:Params = @{ Sysprep = $true }
        Remove-EdgeApp -edgeAppsInList @('Microsoft.Edge', 'XPFFTQ037JWMHS')

        Should -Invoke Set-RunOnceWingetTask -Times 1 -ParameterFilter { $appId -eq 'Microsoft.Edge' }
        Should -Invoke Invoke-NonBlocking -Times 2
    }
}

Describe 'Remove-AppxApp' {
    BeforeEach {
        Reset-AppRemovalState
        Mock Write-Host { }
        Mock Invoke-NonBlocking { }
    }

    It 'dispatches an all-users removal through the background runner' {
        Remove-AppxApp -app 'Clipchamp.Clipchamp' -targetUser 'AllUsers'
        Should -Invoke Invoke-NonBlocking -Times 1
    }

    It 'passes the resolved user name into a specific-user removal' {
        Remove-AppxApp -app 'Clipchamp.Clipchamp' -targetUser 'Alice'
        Should -Invoke Invoke-NonBlocking -Times 1 -ParameterFilter { $ArgumentList -contains 'Alice' }
    }
}

Describe 'Set-RunOnceWingetTask' {
    BeforeEach {
        Reset-AppRemovalState
        Mock Write-Host { }
        $script:capturedOp = $null
        $script:capturedTarget = $null
        Mock Invoke-WithTargetUserHive {
            $script:capturedTarget = $TargetUserName
            $script:capturedOp = $ArgumentObject
        }
    }

    It 'schedules for the Default profile under Sysprep' {
        $script:Params = @{ Sysprep = $true }
        Set-RunOnceWingetTask -appId 'Microsoft.BingNews'

        $script:capturedTarget | Should -Be 'Default'
        $script:capturedOp.ValueName | Should -Be 'Uninstall_Microsoft.BingNews'
        $script:capturedOp.KeyPath | Should -BeLike '*\RunOnce'
    }

    It 'targets the named user outside Sysprep and sanitizes backslashes in the value name' {
        $script:Params = @{ User = 'Alice' }
        Set-RunOnceWingetTask -appId 'Vendor\App'

        $script:capturedTarget | Should -Be 'Alice'
        $script:capturedOp.ValueName | Should -Be 'Uninstall_Vendor_App'
    }

    It 'Base64-encodes the command so a hostile app id cannot break out of the shell' {
        $script:Params = @{ User = 'Alice' }
        Set-RunOnceWingetTask -appId 'Fake.App&calc'

        $prefix = 'powershell.exe -NoProfile -EncodedCommand '
        $script:capturedOp.ValueData | Should -BeLike "$prefix*"

        $encoded = $script:capturedOp.ValueData.Substring($prefix.Length)
        $encoded | Should -Match '^[A-Za-z0-9+/=]+$' -Because 'the metacharacter must be inside the Base64 blob, not in the raw command line'

        $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
        $decoded | Should -BeLike "*--id 'Fake.App&calc'*"
    }

    It 'doubles an embedded single quote so the id stays one quoted token' {
        $script:Params = @{ User = 'Alice' }
        Set-RunOnceWingetTask -appId "It's.App"

        $encoded = $script:capturedOp.ValueData -replace '^.*-EncodedCommand '
        $decoded = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($encoded))
        $decoded | Should -BeLike "*--id 'It''s.App'*"
    }
}

Describe 'Test-AppStillInstalled' {
    BeforeEach {
        Reset-AppRemovalState
        Mock Write-Host { }
    }

    It 'reports still-installed when the Appx package is present' {
        Mock Get-AppxPackage { [pscustomobject]@{ Name = 'Microsoft.BingNews' } }
        Mock Test-AppInWingetList { throw 'winget should not be consulted once Appx confirms it' }

        Test-AppStillInstalled -appId 'Microsoft.BingNews' -InstalledList @() | Should -BeTrue
    }

    It 'falls back to the winget list when the Appx query is empty' {
        Mock Get-AppxPackage { $null }
        Mock Test-AppInWingetList { $true }

        Test-AppStillInstalled -appId 'Contoso.App' -InstalledList @([pscustomobject]@{ Id = 'Contoso.App' }) | Should -BeTrue
    }

    It 'reports gone when neither Appx nor winget lists it' {
        Mock Get-AppxPackage { $null }
        Mock Test-AppInWingetList { $false }

        Test-AppStillInstalled -appId 'Contoso.App' -InstalledList @([pscustomobject]@{ Id = 'Other' }) | Should -BeFalse
    }
}

Describe 'Remove-EdgeAutostartValue' {
    BeforeEach {
        Reset-AppRemovalState
        Mock Write-Host { }
    }

    It 'treats a missing key as already clean and removes nothing' {
        Mock Get-ItemProperty { throw [System.Management.Automation.ItemNotFoundException]::new('missing') }
        Mock Remove-ItemProperty { }

        Remove-EdgeAutostartValue -Path 'HKCU:\Software\...\Run' -Name 'Microsoft Edge Update' | Should -BeTrue
        Should -Invoke Remove-ItemProperty -Times 0
    }

    It 'treats an existing key without the value as already clean' {
        Mock Get-ItemProperty { [pscustomobject]@{ SomethingElse = 1 } }
        Mock Remove-ItemProperty { }

        Remove-EdgeAutostartValue -Path 'HKCU:\Software\...\Run' -Name 'Microsoft Edge Update' | Should -BeTrue
        Should -Invoke Remove-ItemProperty -Times 0
    }

    It 'removes the value when it is present' {
        Mock Get-ItemProperty { [pscustomobject]@{ 'Microsoft Edge Update' = 'x' } }
        Mock Remove-ItemProperty { }

        Remove-EdgeAutostartValue -Path 'HKCU:\Software\...\Run' -Name 'Microsoft Edge Update' | Should -BeTrue
        Should -Invoke Remove-ItemProperty -Times 1
    }

    It 'reports failure when the value cannot be inspected' {
        Mock Get-ItemProperty { throw 'access denied' }

        Remove-EdgeAutostartValue -Path 'HKCU:\Software\...\Run' -Name 'Microsoft Edge Update' | Should -BeFalse
    }

    It 'reports failure when the value cannot be removed' {
        Mock Get-ItemProperty { [pscustomobject]@{ 'Microsoft Edge Update' = 'x' } }
        Mock Remove-ItemProperty { throw 'locked' }

        Remove-EdgeAutostartValue -Path 'HKCU:\Software\...\Run' -Name 'Microsoft Edge Update' | Should -BeFalse
    }
}

Describe 'ForceRemoveEdge' {
    BeforeEach {
        Reset-AppRemovalState
        Mock Write-Host { }
    }

    It 'short circuits to success under WhatIf without touching the machine' {
        $script:Params = @{ WhatIf = $true }
        ForceRemoveEdge | Should -BeTrue
    }

    It 'short circuits to success under DryRun' {
        $script:Params = @{ DryRun = $true }
        ForceRemoveEdge | Should -BeTrue
    }
}

Describe 'Test-WingetUserScopeBlocked' {
    It 'recognises the admin-context refusal by its exit code: <Case>' -ForEach @(
        @{ Case = 'decimal'; ExitCode = -1978335107 }
        @{ Case = 'hex string'; ExitCode = '0x8A15007D' }
        @{ Case = 'hex string with a leading zero'; ExitCode = '0x08A15007D' }
    ) {
        Test-WingetUserScopeBlocked -Result ([pscustomobject]@{ Output = @(); ExitCode = $ExitCode }) | Should -BeTrue
    }

    It 'falls back to the message when the exit code is not the specific one' {
        Test-WingetUserScopeBlocked -Result ([pscustomobject]@{
                Output   = @('Uninstalling...', 'The package installed for user scope cannot be uninstalled when running with administrator privileges.')
                ExitCode = 1
            }) | Should -BeTrue
    }

    It 'does not treat other failures, a success, or no result as a refusal' {
        Test-WingetUserScopeBlocked -Result ([pscustomobject]@{ Output = @('No installed package found'); ExitCode = -1978335212 }) | Should -BeFalse
        Test-WingetUserScopeBlocked -Result ([pscustomobject]@{ Output = @('Successfully uninstalled'); ExitCode = 0 }) | Should -BeFalse
        Test-WingetUserScopeBlocked -Result $null | Should -BeFalse
    }
}

Describe 'Remove-WinGetApp deferring a user-scope uninstall' {
    BeforeEach {
        Reset-AppRemovalState
        Mock Write-Host { }
        Mock Get-RunOnceWingetTargets { @('PC\Alice', 'Default') }
        Mock Set-RunOnceWingetTask { $true }
    }

    It 'schedules the uninstall for every target and records it as deferred' {
        Mock Invoke-NonBlocking { $script:userScopeRefusal }
        Remove-WinGetApp -app 'Contoso.App'

        Should -Invoke Set-RunOnceWingetTask -Times 1 -Exactly -ParameterFilter { $appId -eq 'Contoso.App' -and $TargetUserName -eq 'PC\Alice' }
        Should -Invoke Set-RunOnceWingetTask -Times 1 -Exactly -ParameterFilter { $appId -eq 'Contoso.App' -and $TargetUserName -eq 'Default' }
        $script:AppRemovalDeferredApps | Should -Be @('Contoso.App')
    }

    It 'schedules nothing and defers nothing when winget succeeds' {
        Mock Invoke-NonBlocking { [pscustomobject]@{ Output = @('Successfully uninstalled'); ExitCode = 0 } }
        Remove-WinGetApp -app 'Contoso.App'

        Should -Invoke Set-RunOnceWingetTask -Times 0
        @($script:AppRemovalDeferredApps).Count | Should -Be 0
    }

    It 'does not record a deferral when scheduling fails for any target' {
        Mock Invoke-NonBlocking { $script:userScopeRefusal }
        Mock Set-RunOnceWingetTask { $TargetUserName -ne 'Default' }
        Remove-WinGetApp -app 'Contoso.App'

        @($script:AppRemovalDeferredApps).Count | Should -Be 0 -Because 'a partly scheduled uninstall must still be reported by the post-removal check'
    }

    It 'does not record a deferral when there is no target to schedule for' {
        Mock Invoke-NonBlocking { $script:userScopeRefusal }
        Mock Get-RunOnceWingetTargets { @() }
        Remove-WinGetApp -app 'Contoso.App'

        @($script:AppRemovalDeferredApps).Count | Should -Be 0
    }

    It 'reuses the -User task scheduled before the uninstall instead of scheduling again' {
        $script:Params = @{ User = 'Alice' }
        Mock Invoke-NonBlocking { $script:userScopeRefusal }
        Remove-WinGetApp -app 'Contoso.App'

        Should -Invoke Set-RunOnceWingetTask -Times 1 -Exactly
        Should -Invoke Get-RunOnceWingetTargets -Times 0
        $script:AppRemovalDeferredApps | Should -Be @('Contoso.App')
    }
}

Describe 'Get-RunOnceWingetTargets' {
    BeforeEach {
        Reset-AppRemovalState
        Mock Write-Host { }
        Mock Write-Warning { }
    }

    It 'targets the Default profile under Sysprep' {
        $script:Params = @{ Sysprep = $true }
        Get-RunOnceWingetTargets | Should -Be @('Default')
    }

    It 'targets the -User account' {
        $script:Params = @{ User = 'Alice' }
        Get-RunOnceWingetTargets | Should -Be @('Alice')
    }

    It 'targets the signed-in user for CurrentUser' {
        Mock GetTargetUserForAppRemoval { 'CurrentUser' }
        Get-RunOnceWingetTargets | Should -Be @($env:USERNAME)
    }

    It 'targets the named user for a specific removal target' {
        Mock GetTargetUserForAppRemoval { 'Bob' }
        Mock Get-CimInstance { @() }
        Get-RunOnceWingetTargets | Should -Be @('Bob')
        Should -Invoke Get-CimInstance -Times 0
    }

    It 'targets every profile with a hive, plus Default, for AllUsers' {
        $mySid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $myName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        Mock GetTargetUserForAppRemoval { 'AllUsers' }
        Mock Get-CimInstance {
            @(
                [pscustomobject]@{ SID = $mySid; LocalPath = 'C:\Users\Me'; Special = $false }
                [pscustomobject]@{ SID = 'S-1-5-18'; LocalPath = 'C:\Windows\System32\config\systemprofile'; Special = $true }
                [pscustomobject]@{ SID = 'S-1-5-21-1-2-3-1500'; LocalPath = 'C:\Users\NoHive'; Special = $false }
                [pscustomobject]@{ SID = 'S-1-5-21-1-2-3-999999'; LocalPath = 'C:\Users\Orphan'; Special = $false }
            )
        }
        Mock Test-Path { $LiteralPath -notlike '*NoHive*' }

        $targets = @(Get-RunOnceWingetTargets)

        $targets | Should -Be @($myName, 'Default') -Because 'special profiles, profiles without a hive and unresolvable SIDs are skipped'
        Should -Invoke Write-Warning -Times 1 -Exactly
    }

    It 'returns no targets when profiles cannot be listed' {
        Mock GetTargetUserForAppRemoval { 'AllUsers' }
        Mock Get-CimInstance { throw 'WMI unavailable' }

        @(Get-RunOnceWingetTargets).Count | Should -Be 0
    }
}

Describe 'Set-RunOnceWingetTask result' {
    BeforeEach {
        Reset-AppRemovalState
        Mock Write-Host { }
    }

    It 'returns true and writes to the explicit target user' {
        $script:capturedTarget = $null
        Mock Invoke-WithTargetUserHive { $script:capturedTarget = $TargetUserName; 'noise' }

        Set-RunOnceWingetTask -appId 'Contoso.App' -TargetUserName 'PC\Alice' | Should -BeExactly $true
        $script:capturedTarget | Should -Be 'PC\Alice'
    }

    It 'returns false when the hive cannot be written' {
        Mock Invoke-WithTargetUserHive { throw 'hive locked' }
        Set-RunOnceWingetTask -appId 'Contoso.App' -TargetUserName 'PC\Alice' | Should -BeExactly $false
    }
}

Describe 'RemoveApps with a deferred uninstall' {
    BeforeEach {
        Reset-AppRemovalState
        Mock Write-Host { }
        Mock GetTargetUserForAppRemoval { 'AllUsers' }
        Mock Get-AppRemovalMethod { 'WinGet' }
        Mock Remove-WinGetApp { $script:AppRemovalDeferredApps = @($script:AppRemovalDeferredApps) + $app }
        Mock GetInstalledAppsViaWinget { @([pscustomobject]@{ Id = 'x' }) }
        Mock Test-AppStillInstalled { $true }
    }

    It 'does not report a deferred uninstall as a failure although the app is still present' {
        RemoveApps @('Contoso.App')

        $script:AppRemovalFailures | Should -Be 0
        @($script:AppRemovalFailedApps).Count | Should -Be 0
        $script:AppRemovalDeferredApps | Should -Be @('Contoso.App')
    }

    It 'does not flag verification as unavailable when only deferred apps were removed' {
        Mock GetInstalledAppsViaWinget { $null }
        RemoveApps @('Contoso.App')

        $script:AppRemovalVerificationUnavailable | Should -BeFalse
    }
}
