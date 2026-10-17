#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for the language catalogue loader and text resolution.
#>

Describe 'Winnow localization' {

    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
        . (Join-Path $repoRoot 'Scripts\FileIO\LoadJsonFile.ps1')
        . (Join-Path $repoRoot 'Scripts\FileIO\LoadLanguageFile.ps1')
        $script:realLanguagesPath = Join-Path $repoRoot 'Config\Languages'
    }

    BeforeEach {
        # A two-language fixture: es-ES translates only some keys, so fallback
        # to en-US can be observed per key rather than per language.
        $script:LanguagesPath = Join-Path $TestDrive 'Languages'
        foreach ($code in 'en-US', 'es-ES') {
            New-Item -ItemType Directory -Path (Join-Path $script:LanguagesPath $code) -Force | Out-Null
        }

        @{
            Version = '1'
            Features = @{
                DisableTelemetry = @{ Label = 'Disable telemetry'; ApplyText = 'Disabling telemetry'; ToolTip = 'English tip' }
                OnlyInEnglish = @{ Label = 'Only in English' }
            }
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:LanguagesPath 'en-US\Features.json') -Encoding utf8

        @{ Version = '1'; Categories = @{ 'AI' = 'AI'; 'Gaming' = 'Gaming' } } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:LanguagesPath 'en-US\Categories.json') -Encoding utf8

        @{
            Version = '1'
            Features = @{
                DisableTelemetry = @{ Label = 'Desactivar telemetria'; ApplyText = 'Desactivando telemetria' }
            }
        } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:LanguagesPath 'es-ES\Features.json') -Encoding utf8

        @{ Version = '1'; Categories = @{ 'Gaming' = 'Juegos' } } |
            ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:LanguagesPath 'es-ES\Categories.json') -Encoding utf8

        $script:Features = @{
            DisableTelemetry = [PSCustomObject]@{ FeatureId = 'DisableTelemetry'; Label = 'json label'; ApplyText = 'json apply' }
            NotInAnyCatalogue = [PSCustomObject]@{ FeatureId = 'NotInAnyCatalogue'; Label = 'json only'; ApplyText = 'json only apply' }
        }
        $script:Language = $null
    }

    Context 'folder resolution' {
        It 'prefers an exact match' {
            Resolve-LanguageFolder -LanguageCode 'es-ES' | Should -Be 'es-ES'
        }

        It 'falls back to another region sharing the language' {
            Resolve-LanguageFolder -LanguageCode 'es-MX' | Should -Be 'es-ES'
        }

        It 'falls back to en-US for an unknown language' {
            Resolve-LanguageFolder -LanguageCode 'ja-JP' | Should -Be 'en-US'
        }
    }

    Context 'catalogue loading' {
        It 'loads the requested language and attaches the en-US fallback' {
            $content = Import-LanguageFile -LanguageCode 'es-ES'

            $content.LanguageCode | Should -Be 'es-ES'
            $content.Fallback | Should -Not -BeNullOrEmpty
            $content.Fallback.LanguageCode | Should -Be 'en-US'
        }

        It 'does not attach a fallback to en-US itself' {
            (Import-LanguageFile -LanguageCode 'en-US').Fallback | Should -BeNullOrEmpty
        }

        It 'returns null rather than throwing when no catalogue exists' {
            $script:LanguagesPath = Join-Path $TestDrive 'Missing'
            Import-LanguageFile -LanguageCode 'en-US' -WarningAction SilentlyContinue | Should -BeNullOrEmpty
        }
    }

    Context 'text resolution' {
        It 'returns the translated string when one exists' {
            $script:Language = Import-LanguageFile -LanguageCode 'es-ES'

            Get-WinnowFeatureText -FeatureId 'DisableTelemetry' -Key 'Label' | Should -Be 'Desactivar telemetria'
        }

        It 'falls back to en-US for a key the language does not translate' {
            $script:Language = Import-LanguageFile -LanguageCode 'es-ES'

            Get-WinnowFeatureText -FeatureId 'DisableTelemetry' -Key 'ToolTip' | Should -Be 'English tip'
        }

        It 'falls back to Features.json for a feature in no catalogue' {
            $script:Language = Import-LanguageFile -LanguageCode 'es-ES'

            Get-WinnowFeatureText -FeatureId 'NotInAnyCatalogue' -Key 'Label' | Should -Be 'json only'
        }

        It 'resolves from Features.json when no catalogue loaded at all' {
            $script:Language = $null

            Get-WinnowFeatureText -FeatureId 'DisableTelemetry' -Key 'Label' | Should -Be 'json label'
        }

        It 'returns the English category name when untranslated' {
            $script:Language = Import-LanguageFile -LanguageCode 'es-ES'

            Get-WinnowCategoryText -Category 'Gaming' | Should -Be 'Juegos'
            Get-WinnowCategoryText -Category 'AI' | Should -Be 'AI'
            Get-WinnowCategoryText -Category 'Unknown Category' | Should -Be 'Unknown Category'
        }
    }

    Context 'overlay onto loaded features' {
        It 'replaces feature text in place and reports the count' {
            $script:Language = Import-LanguageFile -LanguageCode 'es-ES'

            $replaced = Update-FeatureTextFromLanguage

            $replaced | Should -Be 2
            $script:Features['DisableTelemetry'].Label | Should -Be 'Desactivar telemetria'
            $script:Features['DisableTelemetry'].ApplyText | Should -Be 'Desactivando telemetria'
        }

        It 'leaves features with no translation untouched' {
            $script:Language = Import-LanguageFile -LanguageCode 'es-ES'

            $null = Update-FeatureTextFromLanguage

            $script:Features['NotInAnyCatalogue'].Label | Should -Be 'json only'
        }

        It 'changes nothing when no catalogue is loaded' {
            $script:Language = $null

            Update-FeatureTextFromLanguage | Should -Be 0
            $script:Features['DisableTelemetry'].Label | Should -Be 'json label'
        }
    }

    Context 'XAML chrome substitution' {

        BeforeEach {
            $script:Language = [PSCustomObject]@{
                LanguageCode = 'xx-XX'
                Chrome = [PSCustomObject]@{
                    'Apply changes' = 'Aplicar cambios'
                    'Risky & <bad>' = 'Peligro & <malo>'
                }
                Features = $null
                Categories = $null
                Fallback = $null
            }
            $script:sample = Join-Path $TestDrive 'sample.xaml'
        }

        It 'substitutes a translated attribute' {
            '<Window><Button Content="Apply changes" /></Window>' |
                Set-Content -LiteralPath $script:sample -Encoding utf8

            Get-LocalizedXaml -Path $script:sample | Should -Match 'Content="Aplicar cambios"'
        }

        It 'leaves untranslated text alone' {
            '<Window><Button Content="Not in catalogue" /></Window>' |
                Set-Content -LiteralPath $script:sample -Encoding utf8

            Get-LocalizedXaml -Path $script:sample | Should -Match 'Content="Not in catalogue"'
        }

        It 'does not touch bindings' {
            '<Window><Button Content="{Binding Apply}" /></Window>' |
                Set-Content -LiteralPath $script:sample -Encoding utf8

            Get-LocalizedXaml -Path $script:sample | Should -BeLike '*{Binding Apply}*'
        }

        It 'XML-encodes a translation containing markup characters' {
            '<Window><Button Content="Risky &amp; &lt;bad&gt;" /></Window>' |
                Set-Content -LiteralPath $script:sample -Encoding utf8

            $result = Get-LocalizedXaml -Path $script:sample
            $result | Should -BeLike '*Peligro &amp; &lt;malo&gt;*'
            $result | Should -Not -BeLike '*Peligro & <malo>*'
        }

        It 'returns the markup unchanged when no catalogue is loaded' {
            $script:Language = $null
            '<Window><Button Content="Apply changes" /></Window>' |
                Set-Content -LiteralPath $script:sample -Encoding utf8

            Get-LocalizedXaml -Path $script:sample | Should -BeLike '*Content="Apply changes"*'
        }
    }

    Context 'non-ASCII encoding' {

        It 'reads a UTF-8 file with no BOM without mangling accents' {
            # Windows PowerShell 5.1 falls back to the ANSI codepage for a
            # UTF-8 file with no BOM, which double-encodes accented text.
            # LoadJsonFile passes -Encoding UTF8 to prevent that.
            $expected = 'Configuraci' + [char]0xF3 + 'n telemetr' + [char]0xED + 'a a' + [char]0xF1 + 'o'
            $path = Join-Path $TestDrive 'accents.json'
            $json = '{ "Version": "1", "Categories": { "k": "' + $expected + '" } }'
            [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding $false))

            (LoadJsonFile -filePath $path).Categories.k | Should -Be $expected
        }

        It 'reads a UTF-8 file with a BOM without mangling accents' {
            $expected = 'Men' + [char]0xFA + ' Inicio y b' + [char]0xFA + 'squeda'
            $path = Join-Path $TestDrive 'accents-bom.json'
            $json = '{ "Version": "1", "Categories": { "k": "' + $expected + '" } }'
            [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding $true))

            (LoadJsonFile -filePath $path).Categories.k | Should -Be $expected
        }

        It 'keeps accents through the shipped es-ES catalogue' {
            $script:LanguagesPath = $script:realLanguagesPath
            $script:Features = @{}
            $script:Language = Import-LanguageFile -LanguageCode 'es-ES'

            Get-WinnowCategoryText -Category 'Start Menu & Search' |
                Should -Be ('Men' + [char]0xFA + ' Inicio y b' + [char]0xFA + 'squeda')
            Get-WinnowFeatureText -FeatureId 'DisableTelemetry' -Key 'Label' |
                Should -BeLike ('*telemetr' + [char]0xED + 'a*')
        }

        It 'carries accents into substituted markup' {
            $script:LanguagesPath = $script:realLanguagesPath
            $script:Language = Import-LanguageFile -LanguageCode 'es-ES'
            $schemasPath = Join-Path (Split-Path (Split-Path $script:realLanguagesPath -Parent) -Parent) 'Schemas'

            $markup = Get-LocalizedXaml -Path (Join-Path $schemasPath 'MainWindow.xaml')

            $markup | Should -BeLike ('*Configuraci' + [char]0xF3 + 'n*')
            $markup | Should -BeLike ('*' + [char]0xBF + '*')
        }
    }
    Context 'the shipped es-ES translation' {

        BeforeEach {
            $script:LanguagesPath = $script:realLanguagesPath
            $script:Features = @{}
            foreach ($f in (Get-Content (Join-Path (Split-Path $script:realLanguagesPath -Parent) 'Features.json') -Raw | ConvertFrom-Json).Features) {
                $script:Features[$f.FeatureId] = $f
            }
            $script:Language = Import-LanguageFile -LanguageCode 'es-ES'
        }

        It 'loads with an en-US fallback attached' {
            $script:Language.LanguageCode | Should -Be 'es-ES'
            $script:Language.Fallback.LanguageCode | Should -Be 'en-US'
        }

        It 'translates a feature that has an entry' {
            Get-WinnowFeatureText -FeatureId 'DisableCopilot' -Key 'Label' |
                Should -Be 'Desactivar Microsoft Copilot'
        }

        It 'falls back per key, not per feature' {
            # The shipped catalogue is complete, so take one key out to check
            # that a missing key falls back on its own.
            $null = $script:Language.Features.DisableTelemetry.PSObject.Properties.Remove('ToolTip')

            Get-WinnowFeatureText -FeatureId 'DisableTelemetry' -Key 'Label' |
                Should -BeLike ('Desactivar telemetr' + [char]0xED + 'a*')
            Get-WinnowFeatureText -FeatureId 'DisableTelemetry' -Key 'ToolTip' |
                Should -BeLike 'This setting disables telemetry*'
        }

        It 'falls back entirely for a feature the catalogue does not cover' {
            $null = $script:Language.Features.PSObject.Properties.Remove('DisableWidgets')

            Get-WinnowFeatureText -FeatureId 'DisableWidgets' -Key 'Label' |
                Should -Be 'Disable widgets on the taskbar & lock screen'
        }

        It 'translates every category' {
            Get-WinnowCategoryText -Category 'Gaming' | Should -Be 'Juegos'
            Get-WinnowCategoryText -Category 'Privacy & Suggested Content' |
                Should -Be 'Privacidad y contenido sugerido'
        }

        It 'translates text set from code through the Chrome catalogue' {
            Get-WinnowChromeText -Text 'All users' | Should -Be 'Todos los usuarios'
            Get-WinnowChromeText -Text 'Not in any catalogue' | Should -Be 'Not in any catalogue'
        }

        It 'falls back to en-US, then to the text itself, for code-set strings' {
            $null = $script:Language.Chrome.PSObject.Properties.Remove('All users')
            Get-WinnowChromeText -Text 'All users' | Should -Be 'All users'

            $script:Language = $null
            Get-WinnowChromeText -Text 'All users' | Should -Be 'All users'
        }

        It 'resolves other Spanish regions to es-ES' {
            Resolve-LanguageFolder -LanguageCode 'es-MX' | Should -Be 'es-ES'
            Resolve-LanguageFolder -LanguageCode 'es-AR' | Should -Be 'es-ES'
        }

        It 'overlays Spanish onto the real feature table' {
            $replaced = Update-FeatureTextFromLanguage

            $replaced | Should -BeGreaterThan 0
            $script:Features['DisableCopilot'].Label | Should -Be 'Desactivar Microsoft Copilot'
            $script:Features['DisableWidgets'].Label | Should -Be 'Desactivar los widgets en la barra de tareas y la pantalla de bloqueo'
        }

        It 'defines no key that en-US does not' {
            # A stale key would silently never be used.
            foreach ($file in 'Chrome', 'Features', 'Categories') {
                $section = @{ Chrome = 'Chrome'; Features = 'Features'; Categories = 'Categories' }[$file]
                $en = (LoadJsonFile -filePath (Join-Path $script:realLanguagesPath "en-US\$file.json")).$section
                $es = (LoadJsonFile -filePath (Join-Path $script:realLanguagesPath "es-ES\$file.json")).$section

                $unknown = @($es.PSObject.Properties.Name | Where-Object { -not $en.PSObject.Properties[$_] })
                $unknown | Should -BeNullOrEmpty -Because "es-ES $file.json has keys absent from en-US: $($unknown -join ', ')"
            }
        }

        It 'leaves every schema parsable after substitution' -Skip:([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
            # XamlReader needs STA. Pester may run MTA, in which case the
            # string-level assertions above still cover substitution.
            Add-Type -AssemblyName PresentationFramework
            $schemasPath = Join-Path (Split-Path (Split-Path $script:realLanguagesPath -Parent) -Parent) 'Schemas'

            foreach ($schema in Get-ChildItem $schemasPath -Filter *.xaml) {
                $markup = Get-LocalizedXaml -Path $schema.FullName
                { 
                    $r = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($markup))
                    try { $null = [Windows.Markup.XamlReader]::Load($r) } finally { $r.Close() }
                } | Should -Not -Throw -Because "$($schema.Name) must still parse in Spanish"
            }
        }
    }
    Context 'the shipped en-US catalogue' {
        It 'covers every feature in Features.json' {
            $catalogue = LoadJsonFile -filePath (Join-Path $script:realLanguagesPath 'en-US\Features.json')
            $features = (Get-Content (Join-Path (Split-Path $script:realLanguagesPath -Parent) 'Features.json') -Raw | ConvertFrom-Json).Features

            $missing = @($features | Where-Object {
                -not $catalogue.Features.PSObject.Properties[$_.FeatureId]
            } | ForEach-Object { $_.FeatureId })

            $missing | Should -BeNullOrEmpty -Because "features absent from the en-US catalogue: $($missing -join ', ')"
        }

        It 'matches the English text in Features.json exactly' {
            $catalogue = LoadJsonFile -filePath (Join-Path $script:realLanguagesPath 'en-US\Features.json')
            $features = (Get-Content (Join-Path (Split-Path $script:realLanguagesPath -Parent) 'Features.json') -Raw | ConvertFrom-Json).Features

            $drift = [System.Collections.Generic.List[string]]::new()
            foreach ($feature in $features) {
                $entry = $catalogue.Features.PSObject.Properties[$feature.FeatureId]
                if (-not $entry) { continue }

                foreach ($key in 'Label', 'ToolTip', 'ApplyText', 'UndoLabel', 'ApplyUndoText') {
                    $source = [string]$feature.$key
                    if ([string]::IsNullOrWhiteSpace($source)) { continue }

                    $translated = $entry.Value.PSObject.Properties[$key]
                    if (-not $translated -or [string]$translated.Value -ne $source) {
                        $drift.Add("$($feature.FeatureId).$key")
                    }
                }
            }

            $drift | Should -BeNullOrEmpty -Because "en-US catalogue has drifted from Features.json: $($drift -join ', ')"
        }

        It 'covers every category' {
            $catalogue = LoadJsonFile -filePath (Join-Path $script:realLanguagesPath 'en-US\Categories.json')
            $features = (Get-Content (Join-Path (Split-Path $script:realLanguagesPath -Parent) 'Features.json') -Raw | ConvertFrom-Json).Features

            $categories = @($features | ForEach-Object { $_.Category } | Where-Object { $_ } | Select-Object -Unique)
            $missing = @($categories | Where-Object { -not $catalogue.Categories.PSObject.Properties[$_] })

            $missing | Should -BeNullOrEmpty -Because "categories absent from the en-US catalogue: $($missing -join ', ')"
        }

        It 'covers every translatable string in the schemas' {
            # Guards against a new XAML string being added without a catalogue
            # entry. Glyph character references and bindings are not text.
            $catalogue = LoadJsonFile -filePath (Join-Path $script:realLanguagesPath 'en-US\Chrome.json')
            $schemasPath = Join-Path (Split-Path (Split-Path $script:realLanguagesPath -Parent) -Parent) 'Schemas'

            $missing = [System.Collections.Generic.List[string]]::new()
            foreach ($schema in Get-ChildItem $schemasPath -Filter *.xaml) {
                $markup = Get-Content -LiteralPath $schema.FullName -Raw
                foreach ($match in [regex]::Matches($markup, '(?:Content|Text|Header|ToolTip|Title)="([^"]*)"')) {
                    $raw = $match.Groups[1].Value
                    if ($raw.Length -lt 2) { continue }
                    if ($raw -match '^\s*\{') { continue }
                    if ($raw -match '^(&#x?[0-9A-Fa-f]+;\s*)+$') { continue }

                    $decoded = [System.Net.WebUtility]::HtmlDecode($raw)
                    if ($decoded -match '^[\W\d_]+$') { continue }

                    if (-not $catalogue.Chrome.PSObject.Properties[$decoded]) {
                        $missing.Add("$($schema.Name): $decoded")
                    }
                }
            }

            $missing | Should -BeNullOrEmpty -Because "schema strings absent from Chrome.json: $($missing -join '; ')"
        }
    }
}
