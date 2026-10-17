#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for GUI helpers that look controls up on the main window.
.DESCRIPTION
    Get-PendingTweakActions, New-Overview, Build-TweakPresetControlMap and
    Update-AppPresetStates find their controls with Window.FindName, so they
    need a real window, not loose controls. Each scenario parses a small window
    with XamlReader (which registers every x:Name for FindName), sets up the
    script-scope tables the main window normally builds, drives the function,
    and returns plain data.

    WPF needs a single-threaded apartment and the unit suite runs under pwsh
    (MTA), so every scenario runs in its own STA runspace in this process.
#>

BeforeAll {
    $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path

    function Invoke-InStaRunspace {
        param(
            [Parameter(Mandatory)][scriptblock]$Script,
            [object[]]$ArgumentList = @()
        )
        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ApartmentState = 'STA'
        $runspace.ThreadOptions = 'ReuseThread'
        $runspace.Open()
        try {
            $shell = [powershell]::Create()
            $shell.Runspace = $runspace
            [void]$shell.AddScript($Script.ToString())
            foreach ($argument in $ArgumentList) { [void]$shell.AddArgument($argument) }
            $output = $shell.Invoke()
            if ($shell.HadErrors) {
                throw (($shell.Streams.Error | ForEach-Object { $_.ToString() }) -join '; ')
            }
            $shell.Dispose()
            return $output[-1]
        }
        finally {
            $runspace.Dispose()
        }
    }

    # Shared by every scenario: load the helpers, parse the window, and build
    # the control mapping and label tables the main window normally creates.
    $script:scenario = {
        param($repoRoot, $case)
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
        . (Join-Path $repoRoot 'Scripts\GUI\MainWindow-AppSelection.ps1')
        . (Join-Path $repoRoot 'Scripts\GUI\MainWindow-Deployment.ps1')

        $xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml">
  <StackPanel>
    <CheckBox x:Name="TweakA" />
    <CheckBox x:Name="TweakB" />
    <ComboBox x:Name="GroupC">
      <ComboBoxItem Content="No change" />
      <ComboBoxItem Content="Left" />
      <ComboBoxItem Content="Hidden" />
    </ComboBox>
    <CheckBox x:Name="HiddenD" Visibility="Collapsed" />
    <CheckBox x:Name="PresetDefaultApps" IsThreeState="True" />
    <CheckBox x:Name="PresetLastUsed" IsThreeState="True" />
    <StackPanel x:Name="AppsPanel" />
  </StackPanel>
</Window>
'@
        $window = [System.Windows.Markup.XamlReader]::Parse($xaml)

        $script:UiControlMappings = @{
            TweakA  = @{ Type = 'feature'; FeatureId = 'FeatureA' }
            TweakB  = @{ Type = 'feature'; FeatureId = 'FeatureB' }
            GroupC  = @{ Type = 'group'; Values = @(
                    @{ FeatureIds = @('GroupLeft') },
                    @{ FeatureIds = @('GroupHiddenOne', 'GroupHiddenTwo') }
                ) }
            HiddenD = @{ Type = 'feature'; FeatureId = 'FeatureD' }
            Missing = @{ Type = 'feature'; FeatureId = 'NotOnWindow' }
        }
        $script:FeatureLabelLookup = @{
            FeatureA = 'Label A'; FeatureB = 'Label B'; FeatureD = 'Label D'
            GroupLeft = 'Align left'; GroupHiddenOne = 'Hide one'; GroupHiddenTwo = 'Hide two'
        }

        $a = $window.FindName('TweakA'); $b = $window.FindName('TweakB'); $c = $window.FindName('GroupC')
        $apps = $window.FindName('AppsPanel')

        function New-AppBox([string[]]$Ids, [bool]$Default, [bool]$Checked) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb | Add-Member -NotePropertyName AppIds -NotePropertyValue $Ids -Force
            $cb | Add-Member -NotePropertyName SelectedByDefault -NotePropertyValue $Default -Force
            $cb.IsChecked = $Checked
            [void]$apps.Children.Add($cb)
        }

        switch ($case) {
            'no-mappings' {
                $script:UiControlMappings = $null
                return @{ Count = @(Get-PendingTweakActions -Window $window -ShowAppliedTweaksMode $false).Count }
            }
            'feature-changes' {
                # A: was off, now on -> Apply. B: was on, now off -> Undo. Hidden D unchanged.
                $a | Add-Member -NotePropertyName InitialState -NotePropertyValue $false -Force; $a.IsChecked = $true
                $b | Add-Member -NotePropertyName InitialState -NotePropertyValue $true -Force; $b.IsChecked = $false
                $c | Add-Member -NotePropertyName InitialIndex -NotePropertyValue 0 -Force; $c.SelectedIndex = 0
                $actions = @(Get-PendingTweakActions -Window $window -ShowAppliedTweaksMode $false)
                return @{ Lines = @($actions | ForEach-Object { '{0}:{1}:{2}' -f $_.Action, $_.FeatureId, $_.Label }) }
            }
            'applied-mode' {
                # The baseline is SystemState in applied mode, InitialState otherwise.
                $a | Add-Member -NotePropertyName InitialState -NotePropertyValue $false -Force
                $a | Add-Member -NotePropertyName SystemState -NotePropertyValue $true -Force
                $a.IsChecked = $true
                $normal = @(Get-PendingTweakActions -Window $window -ShowAppliedTweaksMode $false)
                $applied = @(Get-PendingTweakActions -Window $window -ShowAppliedTweaksMode $true)
                return @{ Normal = @($normal.Action); Applied = $applied.Count }
            }
            'group-select' {
                $c | Add-Member -NotePropertyName InitialIndex -NotePropertyValue 0 -Force
                $c.SelectedIndex = 2
                $actions = @(Get-PendingTweakActions -Window $window -ShowAppliedTweaksMode $false)
                return @{ Lines = @($actions | ForEach-Object { '{0}:{1}' -f $_.Action, $_.FeatureId }) }
            }
            'group-reset' {
                # Moving a group back to "No change" queues nothing: groups have no undo here.
                $c | Add-Member -NotePropertyName InitialIndex -NotePropertyValue 1 -Force
                $c.SelectedIndex = 0
                return @{ Count = @(Get-PendingTweakActions -Window $window -ShowAppliedTweaksMode $false).Count }
            }
            'overview' {
                New-AppBox @('App.One') $true $true
                New-AppBox @('App.Two') $false $true
                New-AppBox @('App.Three') $false $false
                $a | Add-Member -NotePropertyName InitialState -NotePropertyValue $false -Force; $a.IsChecked = $true
                $b | Add-Member -NotePropertyName InitialState -NotePropertyValue $true -Force; $b.IsChecked = $false
                return @{ Lines = @(New-Overview -Window $window -AppsPanel $apps -ShowCurrentlyAppliedTweaksCheckBox $null) }
            }
            'preset-map' {
                $settings = [pscustomobject]@{ Settings = @(
                        [pscustomobject]@{ Name = 'FeatureA'; Value = $true }
                        [pscustomobject]@{ Name = 'FeatureB'; Value = $false }
                        [pscustomobject]@{ Name = 'GroupHiddenTwo'; Value = $true }
                        [pscustomobject]@{ Name = 'FeatureD'; Value = $true }
                        [pscustomobject]@{ Name = 'CreateRestorePoint'; Value = $true }
                        [pscustomobject]@{ Name = 'NotOnWindow'; Value = $true }
                    ) }
                $map = Build-TweakPresetControlMap -Window $window -SettingsJson $settings
                $result = @{ Keys = @($map.Keys | Sort-Object) }
                foreach ($k in $map.Keys) { $result[$k] = '{0}={1}' -f $map[$k].ControlType, $map[$k].DesiredValue }
                return $result
            }
            'preset-map-empty' {
                return @{ Count = (Build-TweakPresetControlMap -Window $window -SettingsJson $null).Count }
            }
            'preset-states' {
                New-AppBox @('App.One') $true $true
                New-AppBox @('App.Two') $true $false
                New-AppBox @('App.Three') $false $true
                $jsonPreset = New-Object System.Windows.Controls.CheckBox
                $jsonPreset.IsThreeState = $true
                $jsonPreset | Add-Member -NotePropertyName PresetAppIds -NotePropertyValue @('App.Three') -Force
                $script:JsonPresetCheckboxes = @($jsonPreset)
                $script:SavedAppIds = @('App.One', 'App.Two')
                $script:MainWindow = $window

                Update-AppPresetStates -AppsPanel $apps

                $default = $window.FindName('PresetDefaultApps'); $last = $window.FindName('PresetLastUsed')
                return @{
                    DefaultIsNull = ($null -eq $default.IsChecked)
                    JsonChecked   = $jsonPreset.IsChecked
                    LastIsNull    = ($null -eq $last.IsChecked)
                    Updating      = $script:UpdatingPresets
                }
            }
        }
    }
}

Describe 'Get-PendingTweakActions' {
    It 'returns nothing when no control mappings exist' {
        (Invoke-InStaRunspace -Script $script:scenario -ArgumentList @($script:repoRoot, 'no-mappings')).Count | Should -Be 0
    }

    It 'queues an apply for a newly checked feature and an undo for a newly cleared one' {
        $r = Invoke-InStaRunspace -Script $script:scenario -ArgumentList @($script:repoRoot, 'feature-changes')
        @($r.Lines | Sort-Object) | Should -Be @('Apply:FeatureA:Label A', 'Undo:FeatureB:Label B')
    }

    It 'compares against the live system state in applied-tweaks mode' {
        $r = Invoke-InStaRunspace -Script $script:scenario -ArgumentList @($script:repoRoot, 'applied-mode')
        $r.Normal | Should -Be @('Apply') -Because 'against InitialState the box was turned on'
        $r.Applied | Should -Be 0 -Because 'the system already has it applied'
    }

    It 'applies every feature behind the selected group option' {
        $r = Invoke-InStaRunspace -Script $script:scenario -ArgumentList @($script:repoRoot, 'group-select')
        $r.Lines | Should -Be @('Apply:GroupHiddenOne', 'Apply:GroupHiddenTwo')
    }

    It 'queues nothing when a group is moved back to no change' {
        (Invoke-InStaRunspace -Script $script:scenario -ArgumentList @($script:repoRoot, 'group-reset')).Count | Should -Be 0
    }
}

Describe 'New-Overview' {
    It 'lists the app removal count, the applies, and the undos' {
        $r = Invoke-InStaRunspace -Script $script:scenario -ArgumentList @($script:repoRoot, 'overview')
        $r.Lines[0] | Should -Be 'Remove 2 application(s)'
        @($r.Lines | Select-Object -Skip 1 | Sort-Object) | Should -Be @('Label A', 'Undo: Label B')
    }
}

Describe 'Build-TweakPresetControlMap' {
    It 'maps enabled settings to their visible controls and skips the rest' {
        $r = Invoke-InStaRunspace -Script $script:scenario -ArgumentList @($script:repoRoot, 'preset-map')
        $r.Keys | Should -Be @('GroupC', 'TweakA') -Because 'disabled, hidden, restore-point and unknown settings are skipped'
        $r.TweakA | Should -Be 'CheckBox=True'
        $r.GroupC | Should -Be 'ComboBox=2' -Because 'GroupHiddenTwo belongs to the second group option'
    }

    It 'returns an empty map when there are no settings' {
        (Invoke-InStaRunspace -Script $script:scenario -ArgumentList @($script:repoRoot, 'preset-map-empty')).Count | Should -Be 0
    }
}

Describe 'Update-AppPresetStates' {
    It 'sets each preset box from how many of its apps are selected' {
        $r = Invoke-InStaRunspace -Script $script:scenario -ArgumentList @($script:repoRoot, 'preset-states')
        $r.DefaultIsNull | Should -BeTrue -Because 'one of two default apps is selected'
        $r.JsonChecked | Should -BeTrue -Because 'the only app in that preset is selected'
        $r.LastIsNull | Should -BeTrue -Because 'one of two last-used apps is selected'
        $r.Updating | Should -BeFalse -Because 'the re-entrancy flag is cleared afterwards'
    }
}
