#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for the success/failure results of feature steps that run
    outside the registry import, and for how the feature engine records them.
.DESCRIPTION
    Scheduled tasks, Windows optional features, the start menu file and the
    Store database used to fail silently: errors were printed and the run still
    finished as a success with exit code 0. Each step now returns $true or
    $false, and Invoke-FeatureApply / Invoke-FeatureUndo record a failed step
    with Add-FeatureStepFailure.

    Invoke-NonBlocking is mocked to run the real scriptblock in-process, so the
    code that normally runs on the background runner is exercised too, against
    mocked task and DISM cmdlets. File steps run against files in TestDrive.
#>

BeforeAll {
    $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
    foreach ($file in 'TelemetryScheduledTasks', 'WindowsOptionalFeatures', 'ReplaceStartMenu', 'StoreSearchSuggestions', 'InvokeChanges') {
        . (Join-Path $script:repoRoot "Scripts\Features\$file.ps1")
    }

    # Helpers the engine calls but which live elsewhere.
    function Invoke-NonBlocking { param([scriptblock]$ScriptBlock, [object[]]$ArgumentList = @(), [int]$TimeoutSeconds = 0) }
    function ImportRegistryFile { param($message, $path) }
    function GetUserName { 'TestUser' }
    function GetUserDirectory { param($userName, $fileName, $exitIfPathNotFound) }

    function New-ObjectNotFoundError {
        [System.Management.Automation.ErrorRecord]::new(
            [System.Exception]::new('No MSFT_ScheduledTask objects found'),
            'CmdletizationQuery_NotFound', [System.Management.Automation.ErrorCategory]::ObjectNotFound, $null)
    }
}

Describe 'Telemetry scheduled task results' {
    BeforeEach {
        $script:Params = @{}
        $script:FeatureStepFailures = @()
        Mock Write-Host { }
        Mock Invoke-NonBlocking { & $ScriptBlock @ArgumentList }
        Mock Import-Module { }
        Mock Get-TelemetryScheduledTasks { @(@{ Path = '\Test\'; Name = 'TaskOne' }) }
    }

    It 'succeeds when it disables a running task' {
        Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Ready' } }
        Mock Disable-ScheduledTask { }

        Disable-TelemetryScheduledTasks | Should -BeExactly $true
        Should -Invoke Disable-ScheduledTask -Times 1 -Exactly
    }

    It 'succeeds without changes when the task is already disabled' {
        Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Disabled' } }
        Mock Disable-ScheduledTask { }

        Disable-TelemetryScheduledTasks | Should -BeExactly $true
        Should -Invoke Disable-ScheduledTask -Times 0
    }

    It 'treats a task that does not exist as done' {
        Mock Get-ScheduledTask { throw (New-ObjectNotFoundError) }
        Disable-TelemetryScheduledTasks | Should -BeExactly $true
    }

    It 'fails when the lookup fails for another reason instead of calling it not found' {
        Mock Get-ScheduledTask { throw [System.UnauthorizedAccessException]::new('Access is denied') }
        Disable-TelemetryScheduledTasks | Should -BeExactly $false
    }

    It 'fails when the task cannot be disabled' {
        Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Ready' } }
        Mock Disable-ScheduledTask { throw 'Access is denied' }
        Disable-TelemetryScheduledTasks | Should -BeExactly $false
    }

    It 'fails when the background runner returns nothing' {
        Mock Invoke-NonBlocking { $null }
        Disable-TelemetryScheduledTasks | Should -BeExactly $false
    }

    It 're-enables only a disabled task' {
        Mock Get-ScheduledTask { [pscustomobject]@{ State = 'Disabled' } }
        Mock Enable-ScheduledTask { }

        Enable-TelemetryScheduledTasks | Should -BeExactly $true
        Should -Invoke Enable-ScheduledTask -Times 1 -Exactly
    }

    It 'previews under WhatIf without touching any task' {
        $script:Params = @{ WhatIf = $true }
        Disable-TelemetryScheduledTasks | Should -BeExactly $true
        Should -Invoke Invoke-NonBlocking -Times 0
    }
}

Describe 'Windows optional feature results' {
    BeforeEach {
        $script:Params = @{}
        $script:FeatureStepFailures = @()
        Mock Write-Host { }
        Mock Invoke-NonBlocking { & $ScriptBlock @ArgumentList }
    }

    It 'succeeds when DISM enables the feature' {
        Mock Enable-WindowsOptionalFeature { }
        EnableWindowsFeature 'Containers-DisposableClientVM' | Should -BeExactly $true
    }

    It 'fails when DISM throws' {
        Mock Enable-WindowsOptionalFeature { throw 'The requested operation requires elevation' }
        EnableWindowsFeature 'Containers-DisposableClientVM' | Should -BeExactly $false
    }

    It 'fails when disabling throws' {
        Mock Disable-WindowsOptionalFeature { throw 'Feature name is unknown' }
        DisableWindowsFeature 'VirtualMachinePlatform' | Should -BeExactly $false
    }

    It 'previews under WhatIf without calling DISM' {
        $script:Params = @{ WhatIf = $true }
        Mock Enable-WindowsOptionalFeature { }
        EnableWindowsFeature 'Containers-DisposableClientVM' | Should -BeExactly $true
        Should -Invoke Enable-WindowsOptionalFeature -Times 0
    }
}

Describe 'Start menu replacement results' {
    BeforeEach {
        $script:Params = @{}
        $script:FeatureStepFailures = @()
        Mock Write-Host { }
        $script:template = Join-Path $TestDrive 'template.bin'
        Set-Content -LiteralPath $script:template -Value 'layout' -Encoding ascii
        $script:target = Join-Path $TestDrive ('Users\Someone\AppData\Local\LocalState\{0}\start2.bin' -f [guid]::NewGuid())
        New-Item -ItemType Directory -Path (Split-Path $script:target) -Force | Out-Null
    }

    It 'returns a single true and writes the template, even when no start2.bin existed' {
        $output = @(ReplaceStartMenu -startMenuBinFile $script:target -startMenuTemplate $script:template)

        $output.Count | Should -Be 1 -Because 'the created file object must not leak into the result'
        $output[0] | Should -BeExactly $true
        (Get-Content -LiteralPath $script:target -Raw).Trim() | Should -Be 'layout'
    }

    It 'fails for a missing template and for a template that is not a .bin file' {
        ReplaceStartMenu -startMenuBinFile $script:target -startMenuTemplate (Join-Path $TestDrive 'absent.bin') | Should -BeExactly $false

        $notBin = Join-Path $TestDrive 'template.txt'
        Set-Content -LiteralPath $notBin -Value 'x'
        ReplaceStartMenu -startMenuBinFile $script:target -startMenuTemplate $notBin | Should -BeExactly $false
    }

    It 'fails instead of reporting success when the copy fails' {
        Mock Copy-Item { throw 'The process cannot access the file' }
        ReplaceStartMenu -startMenuBinFile $script:target -startMenuTemplate $script:template | Should -BeExactly $false
        Should -Invoke Write-Host -Times 0 -ParameterFilter { $Object -like 'Replaced start menu*' }
    }
}

Describe 'Store search suggestion results' {
    BeforeEach {
        $script:Params = @{}
        $script:FeatureStepFailures = @()
        Mock Write-Host { }
        $script:storeDb = Join-Path $TestDrive ('Users\Someone\AppData\{0}\store.db' -f [guid]::NewGuid())
    }

    It 'returns a single true when the database is locked down' {
        $output = @(DisableStoreSearchSuggestions -StoreAppsDatabase $script:storeDb)
        $output.Count | Should -Be 1
        $output[0] | Should -BeExactly $true
        EnableStoreSearchSuggestions -StoreAppsDatabase $script:storeDb | Should -BeExactly $true
    }

    It 'fails instead of reporting success when the ACL cannot be set' {
        Mock Set-Acl { throw 'Attempted to perform an unauthorized operation' }
        DisableStoreSearchSuggestions -StoreAppsDatabase $script:storeDb | Should -BeExactly $false
    }

    It 'counts an undo with nothing to undo as success' {
        EnableStoreSearchSuggestions -StoreAppsDatabase (Join-Path $TestDrive 'absent\store.db') | Should -BeExactly $true
    }
}

Describe 'Feature engine recording of failed steps' {
    BeforeEach {
        $script:Params = @{}
        $script:FeatureStepFailures = @()
        Mock Write-Host { }
        $script:Features = @{
            DisableTelemetry                = [pscustomobject]@{ ApplyText = 'Disabling telemetry'; RegistryKey = 'Disable_Telemetry.reg' }
            EnableWindowsSubsystemForLinux  = [pscustomobject]@{ ApplyText = 'Enabling WSL'; RegistryKey = $null; ApplyUndoText = 'Disabling WSL' }
            ClearStart                      = [pscustomobject]@{ ApplyText = 'Clearing the start menu'; RegistryKey = $null }
            DisableStoreSearchSuggestions   = [pscustomobject]@{ ApplyText = 'Disabling Store suggestions'; RegistryKey = $null }
        }
        Mock ImportRegistryFile { }
    }

    It 'records nothing and outputs nothing when a step succeeds' {
        Mock Disable-TelemetryScheduledTasks { $true }
        $output = @(Invoke-FeatureApply -FeatureId 'DisableTelemetry')

        $output.Count | Should -Be 0 -Because 'a step result must not leak into the pipeline'
        @($script:FeatureStepFailures).Count | Should -Be 0
    }

    It 'records a failed telemetry task step against DisableTelemetry' {
        Mock Disable-TelemetryScheduledTasks { $false }
        Invoke-FeatureApply -FeatureId 'DisableTelemetry'

        @($script:FeatureStepFailures).Count | Should -Be 1
        $script:FeatureStepFailures[0].FeatureId | Should -Be 'DisableTelemetry'
    }

    It 'records each optional feature that fails, by name' {
        Mock EnableWindowsFeature { $FeatureName -ne 'VirtualMachinePlatform' }
        Invoke-FeatureApply -FeatureId 'EnableWindowsSubsystemForLinux'

        @($script:FeatureStepFailures).Count | Should -Be 1
        $script:FeatureStepFailures[0].Message | Should -Match 'VirtualMachinePlatform'
    }

    It 'records a start menu file that cannot be resolved instead of skipping silently' {
        Mock GetStartMenuBinPathForUser { $null }
        Invoke-FeatureApply -FeatureId 'ClearStart'

        $script:FeatureStepFailures[0].Message | Should -Match 'could not be resolved'
    }

    It 'records a Store database that cannot be resolved' {
        Mock GetStoreAppsDatabasePathForUser { $null }
        Invoke-FeatureApply -FeatureId 'DisableStoreSearchSuggestions'

        $script:FeatureStepFailures[0].FeatureId | Should -Be 'DisableStoreSearchSuggestions'
    }

    It 'records a failed step during undo' {
        Mock Enable-TelemetryScheduledTasks { $false }
        Invoke-FeatureUndo -FeatureId 'DisableTelemetry'

        $script:FeatureStepFailures[0].FeatureId | Should -Be 'DisableTelemetry'
    }

    It 'keeps every recorded failure as its own entry' {
        Add-FeatureStepFailure -FeatureId 'A' -Message 'first'
        Add-FeatureStepFailure -FeatureId 'B' -Message 'second'

        @($script:FeatureStepFailures).Count | Should -Be 2
        @($script:FeatureStepFailures | ForEach-Object { $_.FeatureId }) | Should -Be @('A', 'B')
    }
}
