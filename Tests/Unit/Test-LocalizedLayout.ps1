#Requires -Modules Pester
<#
.SYNOPSIS
    Fails when a translated window cuts off any visible text.
.DESCRIPTION
    Translations are often longer than English, and a fixed-width control that
    fits the English label can clip the translated one. Two such bugs shipped
    for Spanish: the home screen Custom Setup button, and the app selection
    footer pushing its checkbox off the window.

    For every shipped language and every window (each tab of the main window),
    the window is built the way the app builds it - localized markup, shared
    styles, theme resources - then laid out headless and checked. A visible
    TextBlock fails if its text is wider than the block, if wrapped text needs
    more height than it got, or if the block extends past any enclosing element
    up to the window (content inside a scroll area is exempt). Layout and text
    measurement run on the same machine, so the check does not depend on the
    fonts of any particular one.

    The Tweaks tab is built by the real Build-DynamicTweaks after the same
    language overlay Winnow.ps1 applies at startup, so its labels and category
    headers are checked too - both for clipping and for actually showing the
    translated text. The app list and message bodies, filled in later at run
    time, are not covered.

    WPF needs an STA thread and the unit suite runs under pwsh (MTA), so each
    language runs in its own STA runspace.
#>

BeforeDiscovery {
    $repo = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
    $script:languages = @(Get-ChildItem (Join-Path $repo 'Config\Languages') -Directory |
            Where-Object { Test-Path (Join-Path $_.FullName 'Chrome.json') } |
            ForEach-Object { @{ Language = $_.Name } })
}

BeforeAll {
    $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path

    $script:layoutScenario = {
        param($repo, $lang)
        $ErrorActionPreference = 'Stop'
        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

        $script:LanguagesPath = Join-Path $repo 'Config\Languages'
        $script:SharedStylesSchema = Join-Path $repo 'Schemas\SharedStyles.xaml'
        . (Join-Path $repo 'Scripts\FileIO\LoadJsonFile.ps1')
        . (Join-Path $repo 'Scripts\FileIO\LoadLanguageFile.ps1')
        . (Join-Path $repo 'Scripts\GUI\SetWindowThemeResources.ps1')
        $script:Language = Import-LanguageFile -LanguageCode $lang -LanguagesPath $script:LanguagesPath
        $culture = [System.Globalization.CultureInfo]::GetCultureInfo($lang)

        function Get-VisualDescendants($node) {
            $count = [System.Windows.Media.VisualTreeHelper]::GetChildrenCount($node)
            for ($i = 0; $i -lt $count; $i++) {
                $child = [System.Windows.Media.VisualTreeHelper]::GetChild($node, $i)
                $child
                Get-VisualDescendants $child
            }
        }

        function Test-IsShown($element) {
            $current = $element
            while ($current) {
                if ($current -is [System.Windows.UIElement] -and $current.Visibility -ne 'Visible') { return $false }
                $current = [System.Windows.Media.VisualTreeHelper]::GetParent($current)
            }
            return $true
        }

        function Get-ClippedText($root, [string]$where) {
            foreach ($tb in @(Get-VisualDescendants $root | Where-Object { $_ -is [System.Windows.Controls.TextBlock] })) {
                if ([string]::IsNullOrWhiteSpace($tb.Text) -or $tb.ActualWidth -le 0) { continue }
                if (-not (Test-IsShown $tb)) { continue }

                $typeface = [System.Windows.Media.Typeface]::new($tb.FontFamily, $tb.FontStyle, $tb.FontWeight, $tb.FontStretch)
                $ft = [System.Windows.Media.FormattedText]::new($tb.Text, $culture, $tb.FlowDirection, $typeface, $tb.FontSize, [System.Windows.Media.Brushes]::Black, 1.0)
                if ($tb.TextWrapping -eq 'NoWrap') {
                    if ($ft.WidthIncludingTrailingWhitespace -gt ($tb.ActualWidth + 1)) {
                        '{0}: "{1}" needs {2:N0}px, has {3:N0}px' -f $where, $tb.Text, $ft.Width, $tb.ActualWidth
                        continue
                    }
                }
                else {
                    # +1: the layout rounds to whole pixels, so a line that just
                    # fits can measure a fraction over and wrap in FormattedText.
                    $ft.MaxTextWidth = [Math]::Max(1, $tb.ActualWidth + 1)
                    if ($ft.Height -gt ($tb.ActualHeight + 1)) {
                        '{0}: "{1}" needs {2:N0}px of height, has {3:N0}px' -f $where, $tb.Text, $ft.Height, $tb.ActualHeight
                        continue
                    }
                }

                $ancestor = [System.Windows.Media.VisualTreeHelper]::GetParent($tb)
                while ($ancestor) {
                    if ($ancestor -is [System.Windows.Controls.ScrollContentPresenter]) { break }
                    if ($ancestor -is [System.Windows.FrameworkElement] -and $ancestor.ActualWidth -gt 0) {
                        $bounds = $tb.TransformToAncestor($ancestor).TransformBounds([System.Windows.Rect]::new(0, 0, $tb.ActualWidth, $tb.ActualHeight))
                        if ($bounds.Left -lt -1 -or $bounds.Right -gt ($ancestor.ActualWidth + 1)) {
                            '{0}: "{1}" spans {2:N0}..{3:N0}px inside a {4} {5:N0}px wide' -f $where, $tb.Text, $bounds.Left, $bounds.Right, $ancestor.GetType().Name, $ancestor.ActualWidth
                            break
                        }
                    }
                    $ancestor = [System.Windows.Media.VisualTreeHelper]::GetParent($ancestor)
                }
            }
        }

        function Get-Window([string]$name) {
            $xaml = Get-LocalizedXaml -Path (Join-Path $repo "Schemas\$name.xaml")
            $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
            try { $window = [System.Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
            SetWindowThemeResources -window $window -usesDarkMode $false
            return $window
        }

        function Invoke-Layout($root, [double]$width, [double]$heightLimit) {
            $root.Measure([System.Windows.Size]::new($width, $heightLimit))
            $height = if ([double]::IsInfinity($heightLimit)) { [Math]::Max(50, [Math]::Ceiling($root.DesiredSize.Height)) } else { $heightLimit }
            $root.Arrange([System.Windows.Rect]::new(0, 0, $width, $height))
            $root.UpdateLayout()
        }

        $problems = [System.Collections.Generic.List[string]]::new()
        $checked = 0

        # Main window: each tab at the initial window size. The Tweaks tab is
        # filled by the real builder after the same startup steps Winnow.ps1
        # runs: load Features.json, then overlay the active language.
        $main = Get-Window 'MainWindow'
        $script:FeaturesFilePath = Join-Path $repo 'Config\Features.json'
        . (Join-Path $repo 'Scripts\GUI\MainWindow-TweaksBuilder.ps1')
        $featuresData = LoadJsonFile -filePath $script:FeaturesFilePath -expectedVersion '1.0'
        $script:Features = @{}
        foreach ($feature in $featuresData.Features) { $script:Features[$feature.FeatureId] = $feature }
        $null = Update-FeatureTextFromLanguage
        $script:ModernStandbySupported = $true
        Build-DynamicTweaks -Window $main -WinVersion 26100

        # The tab must show the translated text, not just fit it.
        $tweakControls = 0
        foreach ($controlName in @($script:UiControlMappings.Keys)) {
            $mapping = $script:UiControlMappings[$controlName]
            $control = $main.FindName($controlName)
            if ($mapping.Type -ne 'feature' -or $control -isnot [System.Windows.Controls.CheckBox]) { continue }
            $tweakControls++
            $expected = [string]$script:Features[$mapping.FeatureId].Label
            if ([string]$control.Content -ne $expected) {
                $problems.Add(('Tweaks: {0} shows "{1}", expected "{2}"' -f $mapping.FeatureId, $control.Content, $expected))
            }
        }
        if ($tweakControls -eq 0) { $problems.Add('Tweaks: the builder produced no feature checkboxes') }

        # Dropdown groups: the label, the "No Change" option and each option.
        $groupControls = 0
        $noChange = Get-WinnowChromeText -Text 'No Change'
        foreach ($controlName in @($script:UiControlMappings.Keys)) {
            $mapping = $script:UiControlMappings[$controlName]
            $combo = $main.FindName($controlName)
            if ($mapping.Type -ne 'group' -or $combo -isnot [System.Windows.Controls.ComboBox]) { continue }
            $groupControls++
            $groupId = $controlName -replace '^Group_(.+)Combo$', '$1'
            $source = @($featuresData.UiGroups | Where-Object { $_.GroupId -eq $groupId })[0]

            # The builder registers the label's border, not the label itself.
            $label = $main.FindName("${controlName}_LabelBorder").Child
            $expectedLabel = Get-WinnowGroupText -GroupId $groupId -Key Label -Text $source.Label
            if ($label.Text -ne $expectedLabel) {
                $problems.Add(('Tweaks: group {0} label shows "{1}", expected "{2}"' -f $groupId, $label.Text, $expectedLabel))
            }
            if ([string]$combo.Items[0].Content -ne $noChange) {
                $problems.Add(('Tweaks: group {0} first option shows "{1}", expected "{2}"' -f $groupId, $combo.Items[0].Content, $noChange))
            }
            for ($i = 0; $i -lt $mapping.Values.Count; $i++) {
                $expected = Get-WinnowGroupText -GroupId $groupId -Key Value -Text $mapping.Values[$i].Label
                if ([string]$combo.Items[$i + 1].Content -ne $expected) {
                    $problems.Add(('Tweaks: group {0} option {1} shows "{2}", expected "{3}"' -f $groupId, ($i + 1), $combo.Items[$i + 1].Content, $expected))
                }
            }
        }
        if ($groupControls -eq 0) { $problems.Add('Tweaks: the builder produced no dropdown groups') }
        foreach ($categoryName in @($script:CategoryCardMap.Keys)) {
            $header = $script:CategoryCardMap[$categoryName].Children[0].Children[1]
            $expected = Get-WinnowCategoryText -Category $categoryName
            if ($header.Text -ne $expected) {
                $problems.Add(('Tweaks: category "{0}" shows "{1}", expected "{2}"' -f $categoryName, $header.Text, $expected))
            }
        }

        $tabs = $main.FindName('MainTabControl')
        for ($index = 0; $index -lt $tabs.Items.Count; $index++) {
            $tabs.SelectedIndex = $index
            Invoke-Layout $main.Content 1400 860
            foreach ($p in @(Get-ClippedText $main.Content "MainWindow/$($tabs.Items[$index].Name)")) { $problems.Add($p) }
            $checked++
        }

        # Dialogs at their declared width, height sized to content.
        foreach ($name in 'AboutWindow', 'AppSelectionWindow', 'ApplyChangesWindow', 'ImportExportConfigWindow', 'MessageBox', 'RestoreBackupWindow') {
            $window = Get-Window $name
            $width = if ($window.Width -gt 0 -and -not [double]::IsNaN($window.Width)) { $window.Width } else { 500 }
            $heightLimit = if ($window.SizeToContent -match 'Height' -or [double]::IsNaN($window.Height)) { [double]::PositiveInfinity } else { $window.Height }
            Invoke-Layout $window.Content $width $heightLimit
            foreach ($p in @(Get-ClippedText $window.Content $name)) { $problems.Add($p) }
            $checked++
        }

        return @{ Problems = @($problems); Checked = $checked }
    }

    function Invoke-InStaRunspace {
        param([Parameter(Mandatory)][scriptblock]$Script, [object[]]$ArgumentList = @())
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
}

Describe 'Localized window layout' {
    It 'finds at least one shipped language' {
        @(Get-ChildItem (Join-Path $script:repoRoot 'Config\Languages') -Directory |
                Where-Object { Test-Path (Join-Path $_.FullName 'Chrome.json') }).Count | Should -BeGreaterThan 1
    }

    It 'lays out <Language> with no clipped or untranslated text' -ForEach $script:languages {
        $result = Invoke-InStaRunspace -Script $script:layoutScenario -ArgumentList @($script:repoRoot, $Language)

        $result.Checked | Should -Be 10 -Because 'four main window tabs and six dialogs are laid out'
        $result.Problems | Should -BeNullOrEmpty -Because ($result.Problems -join "`n")
    }
}
