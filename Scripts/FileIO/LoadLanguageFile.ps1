# Loads the localized text catalogue from Config/Languages.
#
# Function names match upstream Raphire/Win11Debloat PR 764 so the two can be
# reconciled later without renaming. The file name follows Winnow's own
# convention. Feature and category text is keyed by FeatureId and by the English
# category name, both of which are stable identifiers already used elsewhere.

<#
    .SYNOPSIS
    Resolves a language code to an available Config/Languages folder.

    .DESCRIPTION
    Prefers an exact match, then any folder sharing the language prefix so that
    es-MX resolves to es-ES, then en-US.

    .OUTPUTS
    System.String. The folder name to load.
#>
function Resolve-LanguageFolder {
    param(
        [Parameter(Mandatory)]
        [string]$LanguageCode,
        [string]$LanguagesPath = $script:LanguagesPath
    )

    if ([string]::IsNullOrWhiteSpace($LanguagesPath)) {
        return 'en-US'
    }

    $exactPath = Join-Path $LanguagesPath $LanguageCode
    if (Test-Path -LiteralPath $exactPath -PathType Container) {
        return $LanguageCode
    }

    $languagePrefix = ($LanguageCode -split '-')[0]
    if (-not [string]::IsNullOrWhiteSpace($languagePrefix)) {
        $prefixMatch = Get-ChildItem -Path $LanguagesPath -Directory -Filter "$languagePrefix-*" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($prefixMatch) {
            return $prefixMatch.Name
        }
    }

    return 'en-US'
}

<#
    .SYNOPSIS
    Loads the catalogue files for one language folder.

    .OUTPUTS
    PSCustomObject with LanguageCode, Features and Categories, or $null when a
    file is missing or unparsable.
#>
function Import-LanguageContent {
    param(
        [Parameter(Mandatory)]
        [string]$LanguageFolder,
        [string]$LanguagesPath = $script:LanguagesPath
    )

    $folderPath = Join-Path $LanguagesPath $LanguageFolder
    $features = LoadJsonFile -filePath (Join-Path $folderPath 'Features.json') -optionalFile
    $categories = LoadJsonFile -filePath (Join-Path $folderPath 'Categories.json') -optionalFile
    # Optional: a language may translate features without covering the GUI.
    $chrome = LoadJsonFile -filePath (Join-Path $folderPath 'Chrome.json') -optionalFile

    if (-not $features -or -not $categories) {
        return $null
    }

    return [PSCustomObject]@{
        LanguageCode = $LanguageFolder
        Features = $features.Features
        # Optional: text for the UiGroups dropdowns, keyed by GroupId.
        UiGroups = if ($features.PSObject.Properties['UiGroups']) { $features.UiGroups } else { $null }
        Categories = $categories.Categories
        Chrome = if ($chrome) { $chrome.Chrome } else { $null }
        Fallback = $null
    }
}

<#
    .SYNOPSIS
    Loads the active language catalogue, falling back to en-US.

    .DESCRIPTION
    A language other than en-US also carries the en-US catalogue on its Fallback
    property, so a single missing string resolves without the whole language
    being rejected.

    .OUTPUTS
    PSCustomObject, or $null when even en-US cannot be loaded.
#>
function Import-LanguageFile {
    param(
        [string]$LanguageCode = ([System.Globalization.CultureInfo]::CurrentUICulture.Name),
        [string]$LanguagesPath = $script:LanguagesPath
    )

    $resolvedFolder = Resolve-LanguageFolder -LanguageCode $LanguageCode -LanguagesPath $LanguagesPath
    $content = Import-LanguageContent -LanguageFolder $resolvedFolder -LanguagesPath $LanguagesPath

    if (-not $content -and $resolvedFolder -ne 'en-US') {
        Write-Warning "Failed to load language '$resolvedFolder', falling back to en-US."
        $content = Import-LanguageContent -LanguageFolder 'en-US' -LanguagesPath $LanguagesPath
    }

    if (-not $content) {
        # Not fatal. Callers fall back to the English text in Features.json.
        Write-Warning 'Unable to load any language catalogue. Using the text in Features.json.'
        return $null
    }

    if ($content.LanguageCode -ne 'en-US') {
        $content.Fallback = Import-LanguageContent -LanguageFolder 'en-US' -LanguagesPath $LanguagesPath
    }

    return $content
}

<#
    .SYNOPSIS
    Returns one localized string for a feature.

    .DESCRIPTION
    Resolution order is the active language, then its en-US fallback, then the
    value already carried in Features.json. The last step means a feature added
    without a catalogue entry still shows English rather than an empty control.

    .PARAMETER FeatureId
    The feature to look up.

    .PARAMETER Key
    Label, ToolTip, ApplyText, UndoLabel or ApplyUndoText.

    .OUTPUTS
    System.String, or $null when no source defines the key.
#>
function Get-WinnowFeatureText {
    param(
        [Parameter(Mandatory)]
        [string]$FeatureId,
        [Parameter(Mandatory)]
        [ValidateSet('Label', 'ToolTip', 'ApplyText', 'UndoLabel', 'ApplyUndoText')]
        [string]$Key
    )

    foreach ($catalogue in @($script:Language, $script:Language.Fallback)) {
        if (-not $catalogue -or -not $catalogue.Features) { continue }

        $entry = $catalogue.Features.PSObject.Properties[$FeatureId]
        if (-not $entry) { continue }

        $value = $entry.Value.PSObject.Properties[$Key]
        if ($value -and -not [string]::IsNullOrWhiteSpace([string]$value.Value)) {
            return [string]$value.Value
        }
    }

    # Features.json remains the last resort so a missing catalogue is not fatal.
    if ($script:Features -and $script:Features.ContainsKey($FeatureId)) {
        $fallback = $script:Features[$FeatureId].$Key
        if (-not [string]::IsNullOrWhiteSpace([string]$fallback)) {
            return [string]$fallback
        }
    }

    return $null
}

<#
    .SYNOPSIS
    Replaces the text on every loaded feature with its localized value.

    .DESCRIPTION
    Consumers read $feature.Label, $feature.ApplyText and the rest directly, in
    the CLI, the GUI and the XAML bindings alike. Overlaying the values once
    here localizes all of them without touching each call site, and without a
    call site being missed.

    Category is deliberately not overlaid. It is both a display string and the
    key features are grouped by, so translating it in place would break
    grouping. The GUI resolves it for display through Get-WinnowCategoryText.

    .OUTPUTS
    System.Int32. The number of strings replaced, for logging and tests.
#>
function Update-FeatureTextFromLanguage {
    if (-not $script:Features -or $script:Features.Count -eq 0) {
        return 0
    }

    $replaced = 0
    foreach ($featureId in @($script:Features.Keys)) {
        $feature = $script:Features[$featureId]

        foreach ($key in @('Label', 'ToolTip', 'ApplyText', 'UndoLabel', 'ApplyUndoText')) {
            $current = [string]$feature.$key
            if ([string]::IsNullOrWhiteSpace($current)) { continue }

            $localized = Get-WinnowFeatureText -FeatureId $featureId -Key $key
            if ([string]::IsNullOrWhiteSpace($localized) -or $localized -eq $current) { continue }

            $feature.$key = $localized
            $replaced++
        }
    }

    return $replaced
}

<#
    .SYNOPSIS
    Reads a XAML schema and returns it with its literal text translated.

    .DESCRIPTION
    Substitution happens on the markup before it is parsed, rather than by
    walking the loaded window. A logical tree does not contain text that lives
    inside a Style or a template, so a tree walk reaches only part of the
    markup: MainWindow alone carries 113 literal strings but exposes 99 as
    logical tree nodes.

    Chrome entries are keyed by their English text, so reordering markup cannot
    break them and an untranslated string resolves to itself. Values are read
    XML-decoded and written back XML-encoded, so a translation containing an
    ampersand or an angle bracket cannot corrupt the markup.

    Only Content, Text, Header, ToolTip and Title are considered, and a value
    that opens with a brace is left alone because it is a binding or a resource
    reference rather than text.

    .PARAMETER Path
    The schema file to read.

    .OUTPUTS
    System.String. The markup, translated where a translation exists.
#>
function Get-LocalizedXaml {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $markup = Get-Content -LiteralPath $Path -Raw

    $chrome = $null
    foreach ($catalogue in @($script:Language, $script:Language.Fallback)) {
        if ($catalogue -and $catalogue.Chrome) { $chrome = $catalogue.Chrome; break }
    }

    if (-not $chrome) {
        return $markup
    }

    $evaluator = {
        param($match)

        $attribute = $match.Groups['attr'].Value
        $raw = $match.Groups['value'].Value

        # Bindings and resource references are not text.
        if ($raw -match '^\s*\{') { return $match.Value }

        $decoded = [System.Net.WebUtility]::HtmlDecode($raw)
        $entry = $chrome.PSObject.Properties[$decoded]
        if (-not $entry) { return $match.Value }

        $translated = [string]$entry.Value
        if ([string]::IsNullOrWhiteSpace($translated) -or $translated -eq $decoded) {
            return $match.Value
        }

        # Encode before it goes back into markup, and escape the double quote
        # that would otherwise close the attribute.
        $encoded = [System.Security.SecurityElement]::Escape($translated)
        return ('{0}="{1}"' -f $attribute, $encoded)
    }

    $pattern = '(?<attr>\b(?:Content|Text|Header|ToolTip|Title))="(?<value>[^"]*)"'
    return [regex]::Replace($markup, $pattern, $evaluator)
}

function Get-WinnowGroupText {
    <#
        .SYNOPSIS
        Returns the localized text of a UiGroups dropdown: its label, its
        tooltip, or one of its option labels.

        .DESCRIPTION
        Group text lives in an optional UiGroups section of each language's
        Features.json, keyed by GroupId. Option labels are keyed by their
        English text, so reordering the options in Features.json cannot
        attach a translation to the wrong one. Falls back to en-US, then to
        the English text passed in from Features.json.

        .PARAMETER Text
        The English text from Features.json: the group's Label or ToolTip,
        or for Key Value the option's Label.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$GroupId,
        [Parameter(Mandatory)]
        [ValidateSet('Label', 'ToolTip', 'Value')]
        [string]$Key,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    foreach ($catalogue in @($script:Language, $script:Language.Fallback)) {
        if (-not $catalogue -or -not $catalogue.UiGroups) { continue }

        $group = $catalogue.UiGroups.PSObject.Properties[$GroupId]
        if (-not $group) { continue }

        $entry = if ($Key -eq 'Value') {
            if ($group.Value.PSObject.Properties['Values']) { $group.Value.Values.PSObject.Properties[$Text] }
        }
        else {
            $group.Value.PSObject.Properties[$Key]
        }

        if ($entry -and -not [string]::IsNullOrWhiteSpace([string]$entry.Value)) {
            return [string]$entry.Value
        }
    }

    return $Text
}

function Get-WinnowChromeText {
    <#
        .SYNOPSIS
        Returns the localized form of a UI string that is set from code
        rather than from XAML markup.

        .DESCRIPTION
        Chrome entries are keyed by their English text, the same catalogue
        Get-LocalizedXaml uses for markup. Text a script assigns at run time
        never passes through the markup substitution, so it is looked up here.
        Falls back to the en-US catalogue, then to the text itself.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $Text
    }

    foreach ($catalogue in @($script:Language, $script:Language.Fallback)) {
        if (-not $catalogue -or -not $catalogue.Chrome) { continue }

        $entry = $catalogue.Chrome.PSObject.Properties[$Text]
        if ($entry -and -not [string]::IsNullOrWhiteSpace([string]$entry.Value)) {
            return [string]$entry.Value
        }
    }

    return $Text
}

<#
    .SYNOPSIS
    Returns the localized display name for a feature category.

    .OUTPUTS
    System.String. The English category name when no translation exists, so an
    untranslated category still groups correctly.
#>
function Get-WinnowCategoryText {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Category
    )

    if ([string]::IsNullOrWhiteSpace($Category)) {
        return $Category
    }

    foreach ($catalogue in @($script:Language, $script:Language.Fallback)) {
        if (-not $catalogue -or -not $catalogue.Categories) { continue }

        $entry = $catalogue.Categories.PSObject.Properties[$Category]
        if ($entry -and -not [string]::IsNullOrWhiteSpace([string]$entry.Value)) {
            return [string]$entry.Value
        }
    }

    return $Category
}
