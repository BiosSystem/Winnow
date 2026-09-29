#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for the app-selection panel helpers that operate on live WPF
    controls but not on a fully built window.
.DESCRIPTION
    Update-AppRemovalScopeDescription, Update-AppSelectionStatus,
    Update-AppsPanelRebuildSearchIndex, Update-SortArrows, Update-AppsPanelSort
    and Invoke-AppPreset take real panels, checkboxes, combo boxes and text
    blocks. Each scenario builds the controls, drives the function, and returns
    the resulting state.

    WPF construction needs a single-threaded apartment; the unit suite runs
    under pwsh (MTA), so every scenario runs in its own STA runspace. The
    runspace shares this process, so the returned values are real.

    Invoke-AppPreset delegates its checkbox summary to Update-AppPresetStates,
    which reaches into the main window via FindName. The scenario overrides that
    collaborator with a stub after dot-sourcing so the preset check/uncheck
    logic can be exercised without a built window; the window-bound helpers
    (Update-AppPresetStates, the scroll helpers) are covered by the Sandbox
    smoke run, not here.
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

    $script:scopeDescriptionScenario = {
        param($repoRoot, $itemContent)
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
        . (Join-Path $repoRoot 'Scripts\GUI\MainWindow-AppSelection.ps1')

        $combo = New-Object System.Windows.Controls.ComboBox
        foreach ($text in 'All users', 'Current user only', 'Target user only') {
            $item = New-Object System.Windows.Controls.ComboBoxItem
            $item.Content = $text
            [void]$combo.Items.Add($item)
            if ($text -eq $itemContent) { $combo.SelectedItem = $item }
        }
        $desc = New-Object System.Windows.Controls.TextBlock
        Update-AppRemovalScopeDescription -AppRemovalScopeCombo $combo -AppRemovalScopeDescription $desc
        return @{ Text = $desc.Text }
    }

    $script:selectionStatusScenario = {
        param($repoRoot, $checkedCount, $userComboIndex)
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
        . (Join-Path $repoRoot 'Scripts\GUI\MainWindow-AppSelection.ps1')

        $panel = New-Object System.Windows.Controls.StackPanel
        for ($i = 0; $i -lt 3; $i++) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.IsChecked = ($i -lt $checkedCount)
            [void]$panel.Children.Add($cb)
        }

        $status = New-Object System.Windows.Controls.TextBlock
        $scopeCombo = New-Object System.Windows.Controls.ComboBox
        $allUsers = New-Object System.Windows.Controls.ComboBoxItem
        $allUsers.Content = 'All users'
        [void]$scopeCombo.Items.Add($allUsers)
        $scopeCombo.SelectedItem = $allUsers
        $scopeCombo.IsEnabled = $false
        $scopeSection = New-Object System.Windows.Controls.Border
        $scopeSection.Visibility = 'Collapsed'
        $scopeDesc = New-Object System.Windows.Controls.TextBlock
        $userCombo = New-Object System.Windows.Controls.ComboBox
        foreach ($u in 'a', 'b', 'c') {
            $ui = New-Object System.Windows.Controls.ComboBoxItem
            $ui.Content = $u
            [void]$userCombo.Items.Add($ui)
        }
        $userCombo.SelectedIndex = $userComboIndex

        Update-AppSelectionStatus -AppsPanel $panel -AppSelectionStatus $status `
            -AppRemovalScopeCombo $scopeCombo -AppRemovalScopeSection $scopeSection `
            -AppRemovalScopeDescription $scopeDesc -UserSelectionCombo $userCombo

        return @{
            StatusText  = $status.Text
            Visibility  = $scopeSection.Visibility.ToString()
            ScopeEnabled = $scopeCombo.IsEnabled
        }
    }

    $script:searchIndexScenario = {
        param($repoRoot, $case)
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
        . (Join-Path $repoRoot 'Scripts\GUI\MainWindow-AppSelection.ps1')

        $panel = New-Object System.Windows.Controls.StackPanel
        # Two highlighted (match) checkboxes with a plain one between them, plus a
        # non-checkbox child that must be ignored.
        $match1 = New-Object System.Windows.Controls.CheckBox
        $match1.Background = [System.Windows.Media.Brushes]::Yellow
        $plain = New-Object System.Windows.Controls.CheckBox
        $plain.Background = [System.Windows.Media.Brushes]::Transparent
        $match2 = New-Object System.Windows.Controls.CheckBox
        $match2.Background = [System.Windows.Media.Brushes]::Yellow
        [void]$panel.Children.Add($match1)
        [void]$panel.Children.Add((New-Object System.Windows.Controls.TextBlock))
        [void]$panel.Children.Add($plain)
        [void]$panel.Children.Add($match2)

        $active = if ($case -eq 'active-second') { $match2 } else { $null }
        Update-AppsPanelRebuildSearchIndex -AppsPanel $panel -ActiveMatch $active

        return @{ MatchCount = $script:AppSearchMatches.Count; Index = $script:AppSearchMatchIndex }
    }

    $script:sortArrowsScenario = {
        param($repoRoot, $column, $ascending)
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
        . (Join-Path $repoRoot 'Scripts\GUI\MainWindow-AppSelection.ps1')

        function New-Arrow {
            $tb = New-Object System.Windows.Controls.TextBlock
            $tb.RenderTransform = New-Object System.Windows.Media.RotateTransform
            return $tb
        }
        $name = New-Arrow; $descr = New-Arrow; $appId = New-Arrow
        $script:SortColumn = $column
        $script:SortAscending = [bool]$ascending

        Update-SortArrows -SortArrowName $name -SortArrowDescription $descr -SortArrowAppId $appId
        return @{ Name = $name.Opacity; Description = $descr.Opacity; AppId = $appId.Opacity }
    }

    $script:sortScenario = {
        param($repoRoot, $ascending)
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
        . (Join-Path $repoRoot 'Scripts\GUI\MainWindow-AppSelection.ps1')

        $panel = New-Object System.Windows.Controls.StackPanel
        foreach ($n in 'Charlie', 'Alpha', 'Bravo') {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb | Add-Member -NotePropertyName AppName -NotePropertyValue $n -Force
            $cb | Add-Member -NotePropertyName AppDescription -NotePropertyValue $n -Force
            $cb | Add-Member -NotePropertyName AppIdDisplay -NotePropertyValue $n -Force
            [void]$panel.Children.Add($cb)
        }

        function New-PanelSortArrow {
            $tb = New-Object System.Windows.Controls.TextBlock
            $tb.RenderTransform = New-Object System.Windows.Media.RotateTransform
            return $tb
        }
        $script:SortColumn = 'Name'
        $script:SortAscending = [bool]$ascending
        $script:AppSearchMatches = @()
        $script:AppSearchMatchIndex = -1

        Update-AppsPanelSort -AppsPanel $panel -SortArrowName (New-PanelSortArrow) -SortArrowDescription (New-PanelSortArrow) -SortArrowAppId (New-PanelSortArrow)
        return @{ Order = (@($panel.Children) | ForEach-Object { $_.AppName }) -join ',' }
    }

    $script:presetScenario = {
        param($repoRoot, $mode)
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
        . (Join-Path $repoRoot 'Scripts\GUI\MainWindow-AppSelection.ps1')
        # Override the window-bound summary collaborator so only the preset
        # check/uncheck logic runs.
        function Update-AppPresetStates { param($AppsPanel) }

        $panel = New-Object System.Windows.Controls.StackPanel
        foreach ($spec in @(@{ Tag = 'x'; Pre = $false }, @{ Tag = 'y'; Pre = $true }, @{ Tag = 'x'; Pre = $false })) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Tag = $spec.Tag
            $cb.IsChecked = $spec.Pre
            [void]$panel.Children.Add($cb)
        }
        $filter = { param($c) $c.Tag -eq 'x' }

        if ($mode -eq 'exclusive') {
            Invoke-AppPreset -AppsPanel $panel -MatchFilter $filter -Check $true -Exclusive
        }
        else {
            Invoke-AppPreset -AppsPanel $panel -MatchFilter $filter -Check $true
        }

        $states = @($panel.Children | ForEach-Object { [bool]$_.IsChecked })
        return @{ First = $states[0]; Second = $states[1]; Third = $states[2] }
    }
}

Describe 'Update-AppRemovalScopeDescription' {
    It 'sets the all-users copy, mentioning the image, for the all-users scope' {
        $r = Invoke-InStaRunspace -Script $script:scopeDescriptionScenario -ArgumentList @($script:repoRoot, 'All users')
        $r.Text | Should -Match 'all users'
        $r.Text | Should -Match 'image'
    }

    It 'sets the current-user copy' {
        $r = Invoke-InStaRunspace -Script $script:scopeDescriptionScenario -ArgumentList @($script:repoRoot, 'Current user only')
        $r.Text | Should -Match 'current user'
    }

    It 'sets the target-user copy' {
        $r = Invoke-InStaRunspace -Script $script:scopeDescriptionScenario -ArgumentList @($script:repoRoot, 'Target user only')
        $r.Text | Should -Match 'target user'
    }
}

Describe 'Update-AppSelectionStatus' {
    It 'reports the count and reveals the scope section when apps are selected' {
        $r = Invoke-InStaRunspace -Script $script:selectionStatusScenario -ArgumentList @($script:repoRoot, 2, 0)
        $r.StatusText | Should -Be '2 app(s) selected for removal'
        $r.Visibility | Should -Be 'Visible'
        $r.ScopeEnabled | Should -BeTrue
    }

    It 'collapses the scope section when nothing is selected' {
        $r = Invoke-InStaRunspace -Script $script:selectionStatusScenario -ArgumentList @($script:repoRoot, 0, 0)
        $r.StatusText | Should -Be '0 app(s) selected for removal'
        $r.Visibility | Should -Be 'Collapsed'
    }

    It 'leaves the scope combo disabled while the target-user option is selected' {
        $r = Invoke-InStaRunspace -Script $script:selectionStatusScenario -ArgumentList @($script:repoRoot, 2, 2)
        $r.Visibility | Should -Be 'Visible'
        $r.ScopeEnabled | Should -BeFalse
    }
}

Describe 'Update-AppsPanelRebuildSearchIndex' {
    It 'indexes only the highlighted checkboxes and skips other children' {
        $r = Invoke-InStaRunspace -Script $script:searchIndexScenario -ArgumentList @($script:repoRoot, 'none')
        $r.MatchCount | Should -Be 2
        $r.Index | Should -Be 0
    }

    It 'points the active index at the supplied active match' {
        $r = Invoke-InStaRunspace -Script $script:searchIndexScenario -ArgumentList @($script:repoRoot, 'active-second')
        $r.MatchCount | Should -Be 2
        $r.Index | Should -Be 1
    }
}

Describe 'Update-SortArrows' {
    It 'lights the active column and dims the others' {
        $r = Invoke-InStaRunspace -Script $script:sortArrowsScenario -ArgumentList @($script:repoRoot, 'Name', $true)
        $r.Name | Should -Be 1.0
        $r.Description | Should -Be 0.3
        $r.AppId | Should -Be 0.3
    }
}

Describe 'Update-AppsPanelSort' {
    It 'reorders the panel ascending by the active column' {
        $r = Invoke-InStaRunspace -Script $script:sortScenario -ArgumentList @($script:repoRoot, $true)
        $r.Order | Should -Be 'Alpha,Bravo,Charlie'
    }

    It 'reorders the panel descending' {
        $r = Invoke-InStaRunspace -Script $script:sortScenario -ArgumentList @($script:repoRoot, $false)
        $r.Order | Should -Be 'Charlie,Bravo,Alpha'
    }
}

Describe 'Invoke-AppPreset' {
    It 'checks only the matching boxes and leaves the rest alone in additive mode' {
        $r = Invoke-InStaRunspace -Script $script:presetScenario -ArgumentList @($script:repoRoot, 'additive')
        $r.First | Should -BeTrue
        $r.Second | Should -BeTrue -Because 'an already-checked non-match is not touched in additive mode'
        $r.Third | Should -BeTrue
    }

    It 'checks matches and unchecks non-matches in exclusive mode' {
        $r = Invoke-InStaRunspace -Script $script:presetScenario -ArgumentList @($script:repoRoot, 'exclusive')
        $r.First | Should -BeTrue
        $r.Second | Should -BeFalse -Because 'a non-match is unchecked in exclusive mode'
        $r.Third | Should -BeTrue
    }
}
