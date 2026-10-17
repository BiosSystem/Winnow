#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for the registry value comparison in Test-FeatureApplied.
.DESCRIPTION
    Test-FeatureApplied (GetCurrentTweakState.ps1) reads a feature's live
    registry state and compares it against the values from the feature's .reg
    file to decide whether the feature is already applied. The desired-state
    tests stub this function, so the comparison itself had no coverage.

    These tests drive the real function through its generic SetValue path, with
    the registry helpers mocked and a fake key that returns controlled data.
    The focus is Binary and MultiString values, which are ordered sequences: a
    byte or string list that matches only when reordered must not count as
    applied. A FeatureId outside the function's special-case switch is used so
    execution reaches the generic .reg comparison.
#>

BeforeAll {
    $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
    . (Join-Path $script:repoRoot 'Scripts\Features\GetCurrentTweakState.ps1')

    # Helpers Test-FeatureApplied calls on its generic path. Stubbed so Mock has
    # a command to replace; the real implementations live in other files.
    function Get-RegFileOperations { param($regFilePath) }
    function Split-RegistryPath { param($path) }
    function Get-RegistryRootKey { param($hiveName) }
    function Get-ExpectedRegistryValueKind { param($Operation) }

    # Builds a fake registry key that returns one value of a given kind, and
    # records that it was closed.
    function New-FakeRegistryKey {
        param([string]$Name, $Data, [Microsoft.Win32.RegistryValueKind]$Kind)
        $key = [PSCustomObject]@{ Closed = $false }
        $key | Add-Member -NotePropertyName _name -NotePropertyValue $Name -Force
        $key | Add-Member -NotePropertyName _data -NotePropertyValue $Data -Force
        $key | Add-Member -NotePropertyName _kind -NotePropertyValue $Kind -Force
        $key | Add-Member -MemberType ScriptMethod -Name GetValueNames -Value { @($this._name) }
        $key | Add-Member -MemberType ScriptMethod -Name GetValueKind -Value { param($n) $this._kind }
        $key | Add-Member -MemberType ScriptMethod -Name GetValue -Value { param($n, $default, $options) $this._data }
        $key | Add-Member -MemberType ScriptMethod -Name Close -Value { $this.Closed = $true }
        return $key
    }

    function Invoke-RegistryFeatureCheck {
        param(
            [string]$ValueName,
            $ActualData,
            $ExpectedData,
            [Microsoft.Win32.RegistryValueKind]$Kind
        )
        $script:Features = @{ RegistryFeature = [PSCustomObject]@{ RegistryKey = 'Example.reg' } }
        $script:RegfilesPath = $TestDrive

        $key = New-FakeRegistryKey -Name $ValueName -Data $ActualData -Kind $Kind
        $root = [PSCustomObject]@{}
        $root | Add-Member -MemberType ScriptMethod -Name OpenSubKey -Value { param($path, $writable) $script:fakeKey }
        $script:fakeKey = $key

        Mock Test-Path { $true }
        Mock Get-RegFileOperations { @([PSCustomObject]@{ OperationType = 'SetValue'; KeyPath = 'HKEY_CURRENT_USER\Software\Example'; ValueName = $ValueName; ValueType = 'Binary'; ValueData = $ExpectedData }) }
        Mock Split-RegistryPath { @{ Hive = 'HKEY_CURRENT_USER'; SubKey = 'Software\Example' } }
        Mock Get-RegistryRootKey { $root }
        Mock Get-ExpectedRegistryValueKind { $Kind }

        $result = Test-FeatureApplied -FeatureId 'RegistryFeature'
        return [PSCustomObject]@{ Result = $result; Closed = $key.Closed }
    }
}

Describe 'Test-FeatureApplied binary registry comparison' {
    It 'compares binary data in order: <Case>' -ForEach @(
        @{ Case = 'identical bytes'; Actual = @(1, 2, 3); Expected = @(1, 2, 3); Result = $true }
        @{ Case = 'same bytes reordered'; Actual = @(1, 2, 3); Expected = @(3, 2, 1); Result = $false }
        @{ Case = 'different length'; Actual = @(1, 2, 3); Expected = @(1, 2); Result = $false }
        @{ Case = 'single byte that matches'; Actual = @(1); Expected = 1; Result = $true }
        @{ Case = 'single zero byte that matches'; Actual = @(0); Expected = 0; Result = $true }
        @{ Case = 'longer value against one expected byte'; Actual = @(1, 2); Expected = 1; Result = $false }
        @{ Case = 'empty on both sides'; Actual = @(); Expected = $null; Result = $true }
    ) {
        $r = Invoke-RegistryFeatureCheck -ValueName 'Mask' -ActualData ([byte[]]$Actual) -ExpectedData $Expected -Kind ([Microsoft.Win32.RegistryValueKind]::Binary)
        $r.Result | Should -Be $Result
        $r.Closed | Should -BeTrue
    }
}

Describe 'Test-FeatureApplied multi-string registry comparison' {
    It 'compares multi-string data in order: <Case>' -ForEach @(
        @{ Case = 'identical strings'; Actual = @('one', 'two'); Expected = @('one', 'two'); Result = $true }
        @{ Case = 'same strings reordered'; Actual = @('one', 'two'); Expected = @('two', 'one'); Result = $false }
        @{ Case = 'different length'; Actual = @('one', 'two'); Expected = 'one'; Result = $false }
        @{ Case = 'single string that matches'; Actual = @('one'); Expected = 'one'; Result = $true }
        @{ Case = 'strings sharing a prefix'; Actual = @('other'); Expected = 'one'; Result = $false }
        @{ Case = 'empty on both sides'; Actual = @(); Expected = $null; Result = $true }
    ) {
        $r = Invoke-RegistryFeatureCheck -ValueName 'Items' -ActualData ([string[]]$Actual) -ExpectedData $Expected -Kind ([Microsoft.Win32.RegistryValueKind]::MultiString)
        $r.Result | Should -Be $Result
        $r.Closed | Should -BeTrue
    }
}
