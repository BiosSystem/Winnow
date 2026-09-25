#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for GUI helpers that operate on live WPF controls.
.DESCRIPTION
    ConvertTo-NormalizedCheckboxState, Set-TriStatePresetCheckBoxState, and
    Test-ComboBoxContainsMatch take real CheckBox and ComboBox objects, so they
    cannot be exercised with a plain data stand-in. Each scenario builds the
    control, calls the function, and returns the resulting state.

    WPF construction needs a single-threaded apartment; the unit suite runs
    under pwsh, which is multi-threaded, so every scenario runs in its own STA
    runspace. The runspace shares this process, so the returned hashtable holds
    real values, not serialized copies.
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

    # Runs against MainWindow-AppSelection.ps1 loaded inside the STA runspace.
    $script:appSelectionScenario = {
        param($repoRoot, $case)
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
        . (Join-Path $repoRoot 'Scripts\GUI\MainWindow-AppSelection.ps1')

        switch ($case) {
            'normalize-indeterminate' {
                $cb = New-Object System.Windows.Controls.CheckBox
                $cb.IsThreeState = $true
                $cb | Add-Member -NotePropertyName WasIndeterminateBeforeClick -NotePropertyValue $true -Force
                $cb.IsChecked = $false
                $result = ConvertTo-NormalizedCheckboxState -CheckBox $cb
                return @{ Result = $result; IsChecked = $cb.IsChecked; StillFlagged = $cb.WasIndeterminateBeforeClick }
            }
            'normalize-checked' {
                $cb = New-Object System.Windows.Controls.CheckBox
                $cb.IsChecked = $true
                return @{ Result = (ConvertTo-NormalizedCheckboxState -CheckBox $cb) }
            }
            'normalize-unchecked' {
                $cb = New-Object System.Windows.Controls.CheckBox
                $cb.IsChecked = $false
                return @{ Result = (ConvertTo-NormalizedCheckboxState -CheckBox $cb) }
            }
            default {
                # tri-state: case is "Total,Selected"
                $parts = $case -split ','
                $cb = New-Object System.Windows.Controls.CheckBox
                $cb.IsThreeState = $true
                Set-TriStatePresetCheckBoxState -CheckBox $cb -Total ([int]$parts[0]) -Selected ([int]$parts[1])
                return @{ IsChecked = $cb.IsChecked; IsNull = ($null -eq $cb.IsChecked); IsEnabled = $cb.IsEnabled }
            }
        }
    }

    $script:comboScenario = {
        param($repoRoot, $searchText)
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
        . (Join-Path $repoRoot 'Scripts\GUI\MainWindow-TweaksBuilder.ps1')

        $combo = New-Object System.Windows.Controls.ComboBox
        $item = New-Object System.Windows.Controls.ComboBoxItem
        $item.Content = 'Show search box'
        [void]$combo.Items.Add($item)
        [void]$combo.Items.Add('Hide taskbar')
        return @{ Match = (Test-ComboBoxContainsMatch -ComboBox $combo -SearchText $searchText) }
    }
}

Describe 'ConvertTo-NormalizedCheckboxState' {
    It 'treats a checkbox that was indeterminate before the click as checked' {
        $r = Invoke-InStaRunspace -Script $script:appSelectionScenario -ArgumentList @($script:repoRoot, 'normalize-indeterminate')
        $r.Result | Should -BeTrue
        $r.IsChecked | Should -BeTrue
        $r.StillFlagged | Should -BeFalse -Because 'the one-shot flag is cleared'
    }

    It 'reports a checked box as checked and an unchecked box as unchecked' {
        (Invoke-InStaRunspace -Script $script:appSelectionScenario -ArgumentList @($script:repoRoot, 'normalize-checked')).Result | Should -BeTrue
        (Invoke-InStaRunspace -Script $script:appSelectionScenario -ArgumentList @($script:repoRoot, 'normalize-unchecked')).Result | Should -BeFalse
    }
}

Describe 'Set-TriStatePresetCheckBoxState' {
    It 'disables and unchecks the box when nothing is available' {
        $r = Invoke-InStaRunspace -Script $script:appSelectionScenario -ArgumentList @($script:repoRoot, '0,0')
        $r.IsEnabled | Should -BeFalse
        $r.IsChecked | Should -BeFalse
    }

    It 'unchecks when none selected, checks when all selected' {
        $none = Invoke-InStaRunspace -Script $script:appSelectionScenario -ArgumentList @($script:repoRoot, '3,0')
        $none.IsEnabled | Should -BeTrue
        $none.IsChecked | Should -BeFalse

        $all = Invoke-InStaRunspace -Script $script:appSelectionScenario -ArgumentList @($script:repoRoot, '3,3')
        $all.IsChecked | Should -BeTrue
    }

    It 'goes indeterminate on a partial selection' {
        $r = Invoke-InStaRunspace -Script $script:appSelectionScenario -ArgumentList @($script:repoRoot, '3,1')
        $r.IsNull | Should -BeTrue
        $r.IsEnabled | Should -BeTrue
    }
}

Describe 'Test-ComboBoxContainsMatch' {
    It 'finds a match in a ComboBoxItem and in a plain string item' {
        (Invoke-InStaRunspace -Script $script:comboScenario -ArgumentList @($script:repoRoot, 'search')).Match | Should -BeTrue
        (Invoke-InStaRunspace -Script $script:comboScenario -ArgumentList @($script:repoRoot, 'taskbar')).Match | Should -BeTrue
    }

    It 'returns false when no item contains the search text' {
        (Invoke-InStaRunspace -Script $script:comboScenario -ArgumentList @($script:repoRoot, 'nonexistent')).Match | Should -BeFalse
    }
}
