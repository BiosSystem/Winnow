#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $repoRoot 'Scripts\Features\UpdateWatchdog.ps1')
    . (Join-Path $repoRoot 'Scripts\Watchdog\WatchdogPayload.ps1')
}

Describe 'Winnow update watchdog directory hardening' {
    BeforeEach {
        $script:tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("WinnowWatchdogAcl_" + [Guid]::NewGuid().ToString('N'))
    }
    AfterEach {
        if ($script:tempDir -and (Test-Path -LiteralPath $script:tempDir)) {
            Remove-Item -LiteralPath $script:tempDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'protects the ACL from inheritance and grants standard users no more than read and execute' {
        Set-WinnowWatchdogDirectoryAcl -Path $script:tempDir

        $acl = Get-Acl -LiteralPath $script:tempDir
        $acl.AreAccessRulesProtected | Should -BeTrue

        $writeRights = [System.Security.AccessControl.FileSystemRights]::Write
        foreach ($rule in $acl.Access) {
            $sid = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
            if ($sid -in @('S-1-5-32-545', 'S-1-5-11', 'S-1-1-0')) {
                # Users, Authenticated Users, Everyone must not carry a write bit.
                ([int]$rule.FileSystemRights -band [int]$writeRights) | Should -Be 0
            }
        }
    }
}

Describe 'Winnow update watchdog integrity check' {
    BeforeEach {
        $script:tempPayload = Join-Path ([System.IO.Path]::GetTempPath()) ("WinnowPayload_" + [Guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $script:tempPayload -Value "# watchdog payload under test`nInvoke-WinnowWatchdog" -Force
        $script:testRegPath = 'HKCU:\Software\WinnowWatchdogTest'
        if (-not (Test-Path -LiteralPath $script:testRegPath)) {
            New-Item -Path $script:testRegPath -Force | Out-Null
        }
    }
    AfterEach {
        Remove-Item -LiteralPath $script:tempPayload -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $script:testRegPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'passes when the recorded hash matches the payload' {
        $hash = (Get-FileHash -LiteralPath $script:tempPayload -Algorithm SHA256).Hash
        Set-ItemProperty -LiteralPath $script:testRegPath -Name 'PayloadSha256' -Value $hash -Type String -Force

        Test-WinnowWatchdogIntegrity -PayloadPath $script:tempPayload -RegPath $script:testRegPath | Should -BeTrue
    }

    It 'fails when the payload was altered after the hash was recorded' {
        $hash = (Get-FileHash -LiteralPath $script:tempPayload -Algorithm SHA256).Hash
        Set-ItemProperty -LiteralPath $script:testRegPath -Name 'PayloadSha256' -Value $hash -Type String -Force
        Add-Content -LiteralPath $script:tempPayload -Value "`nStart-Process calc.exe"

        Test-WinnowWatchdogIntegrity -PayloadPath $script:tempPayload -RegPath $script:testRegPath | Should -BeFalse
    }

    It 'fails closed when no hash was ever recorded' {
        Test-WinnowWatchdogIntegrity -PayloadPath $script:tempPayload -RegPath $script:testRegPath | Should -BeFalse
    }

    It 'fails closed when the payload file is missing' {
        $hash = (Get-FileHash -LiteralPath $script:tempPayload -Algorithm SHA256).Hash
        Set-ItemProperty -LiteralPath $script:testRegPath -Name 'PayloadSha256' -Value $hash -Type String -Force
        Remove-Item -LiteralPath $script:tempPayload -Force

        Test-WinnowWatchdogIntegrity -PayloadPath $script:tempPayload -RegPath $script:testRegPath | Should -BeFalse
    }
}

Describe 'Winnow update watchdog desired-state floor' {
    It 'covers only machine-wide HKLM policy keys' {
        $state = Get-WinnowWatchdogDesiredState
        foreach ($entry in $state.Registry) {
            $entry.Path | Should -BeLike 'HKLM:\*'
        }
    }

    It 'includes the telemetry service and the core AI policies' {
        $state = Get-WinnowWatchdogDesiredState
        $state.Services | Should -Contain 'DiagTrack'
        $names = $state.Registry | ForEach-Object { $_.Name }
        $names | Should -Contain 'AllowTelemetry'
        $names | Should -Contain 'TurnOffWindowsCopilot'
        $names | Should -Contain 'DisableAIDataAnalysis'
    }
}

Describe 'Winnow update watchdog enforcement' {
    BeforeEach {
        Mock -CommandName Test-Path -MockWith { $true }
        Mock -CommandName New-Item -MockWith { }
        Mock -CommandName Set-ItemProperty -MockWith { }
        Mock -CommandName Set-Service -MockWith { }
        Mock -CommandName Stop-Service -MockWith { }
        Mock -CommandName Disable-ScheduledTask -MockWith { }
        Mock -CommandName Get-Service -MockWith { $null }
        Mock -CommandName Get-ScheduledTask -MockWith { $null }
        Mock -CommandName Write-WinnowWatchdogLog -MockWith { }
    }

    It 're-asserts a drifted registry value' {
        Mock -CommandName Get-ItemProperty -MockWith { [PSCustomObject]@{ AllowTelemetry = 1 } }
        $state = [PSCustomObject]@{
            Registry = @(@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry'; Value = 0 })
            Services = @()
            Tasks    = @()
        }

        $result = Invoke-WinnowWatchdogEnforcement -DesiredState $state

        Should -Invoke -CommandName Set-ItemProperty -Times 1 -Exactly
        $result | Should -Contain 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection\AllowTelemetry'
    }

    It 'leaves a correct registry value untouched' {
        Mock -CommandName Get-ItemProperty -MockWith { [PSCustomObject]@{ AllowTelemetry = 0 } }
        $state = [PSCustomObject]@{
            Registry = @(@{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection'; Name = 'AllowTelemetry'; Value = 0 })
            Services = @()
            Tasks    = @()
        }

        $result = Invoke-WinnowWatchdogEnforcement -DesiredState $state

        Should -Invoke -CommandName Set-ItemProperty -Times 0 -Exactly
        $result.Count | Should -Be 0
    }

    It 'disables a telemetry service that was re-enabled' {
        Mock -CommandName Get-ItemProperty -MockWith { $null }
        Mock -CommandName Get-Service -MockWith { [PSCustomObject]@{ StartType = 'Automatic' } }
        $state = [PSCustomObject]@{
            Registry = @()
            Services = @('DiagTrack')
            Tasks    = @()
        }

        $result = Invoke-WinnowWatchdogEnforcement -DesiredState $state

        Should -Invoke -CommandName Set-Service -Times 1 -Exactly
        $result | Should -Contain 'service:DiagTrack'
    }

    It 'disables a telemetry task that was re-enabled' {
        Mock -CommandName Get-ItemProperty -MockWith { $null }
        Mock -CommandName Get-ScheduledTask -MockWith { [PSCustomObject]@{ State = 'Ready' } }
        $state = [PSCustomObject]@{
            Registry = @()
            Services = @()
            Tasks    = @(@{ Path = '\Microsoft\Windows\Autochk\'; Name = 'Proxy' })
        }

        $result = Invoke-WinnowWatchdogEnforcement -DesiredState $state

        Should -Invoke -CommandName Disable-ScheduledTask -Times 1 -Exactly
        $result | Should -Contain 'task:Proxy'
    }
}

Describe 'Winnow update watchdog health' {
    It 'reports healthy when installed, intact, and locked down' {
        Mock -CommandName Get-ScheduledTask -MockWith { [PSCustomObject]@{ TaskName = 'Winnow_UpdateWatchdog' } }
        Mock -CommandName Get-ScheduledTaskInfo -MockWith { [PSCustomObject]@{ LastRunTime = (Get-Date); LastTaskResult = 0 } }
        Mock -CommandName Get-ItemProperty -MockWith { [PSCustomObject]@{ PayloadSha256 = 'ABC123'; SchemaVersion = 2; InstalledUtc = '2026-09-17T00:00:00.0000000Z' } }
        Mock -CommandName Test-Path -MockWith { $true }
        Mock -CommandName Get-FileHash -MockWith { [PSCustomObject]@{ Hash = 'ABC123' } }
        Mock -CommandName Get-Acl -MockWith { [PSCustomObject]@{ AreAccessRulesProtected = $true; Access = @() } }

        $health = Get-WinnowWatchdogHealth

        $health.Installed | Should -BeTrue
        $health.IntegrityOk | Should -BeTrue
        $health.AclLockedDown | Should -BeTrue
        $health.Healthy | Should -BeTrue
    }

    It 'reports degraded when the payload hash no longer matches' {
        Mock -CommandName Get-ScheduledTask -MockWith { [PSCustomObject]@{ TaskName = 'Winnow_UpdateWatchdog' } }
        Mock -CommandName Get-ScheduledTaskInfo -MockWith { [PSCustomObject]@{ LastRunTime = (Get-Date); LastTaskResult = 0 } }
        Mock -CommandName Get-ItemProperty -MockWith { [PSCustomObject]@{ PayloadSha256 = 'ABC123' } }
        Mock -CommandName Test-Path -MockWith { $true }
        Mock -CommandName Get-FileHash -MockWith { [PSCustomObject]@{ Hash = 'DIFFERENT' } }
        Mock -CommandName Get-Acl -MockWith { [PSCustomObject]@{ AreAccessRulesProtected = $true; Access = @() } }

        $health = Get-WinnowWatchdogHealth

        $health.IntegrityOk | Should -BeFalse
        $health.Healthy | Should -BeFalse
    }

    It 'reports not installed when the task is absent' {
        Mock -CommandName Get-ScheduledTask -MockWith { $null }
        Mock -CommandName Get-ItemProperty -MockWith { $null }
        Mock -CommandName Test-Path -MockWith { $false }

        $health = Get-WinnowWatchdogHealth

        $health.Installed | Should -BeFalse
        $health.Healthy | Should -BeFalse
    }
}
