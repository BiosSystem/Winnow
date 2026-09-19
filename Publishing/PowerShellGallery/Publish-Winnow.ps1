<#
.SYNOPSIS
    Prepares and optionally publishes the Winnow standalone script to the
    PowerShell Gallery.

.DESCRIPTION
    Winnow's modular Winnow.ps1 dot-sources roughly a hundred files from the
    repository tree, so it cannot be installed as a single-file gallery script.
    The standalone build (build.ps1) embeds the whole tree as a base64 zip and
    is self-contained, so that is the artifact published to the gallery.

    This script:
      1. Reads the version from Winnow.ps1 (the WINNOW_VERSION constant).
      2. Builds the standalone into the output folder.
      3. Injects a PSScriptInfo block (with the fixed script GUID) so the file
         satisfies Test-ScriptFileInfo.
      4. Validates the result.
      5. Publishes with Publish-Script only when -ApiKey is supplied.

    Without -ApiKey it stops after validation, so you can inspect the gallery
    ready file before spending an API key. The API key is never stored or
    echoed; pass your own PowerShell Gallery key at publish time.

.PARAMETER ApiKey
    Your PowerShell Gallery API key. When omitted, the script builds and
    validates only and does not publish.

.PARAMETER OutputDirectory
    Where the gallery-ready standalone is written. Defaults to a temp folder.

.EXAMPLE
    .\Publish-Winnow.ps1
    Builds and validates the gallery script without publishing.

.EXAMPLE
    .\Publish-Winnow.ps1 -ApiKey $env:PSGALLERY_KEY
    Builds, validates, and publishes to the PowerShell Gallery.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ApiKey,
    [string]$OutputDirectory = (Join-Path ([System.IO.Path]::GetTempPath()) 'Winnow-PSGallery')
)

$ErrorActionPreference = 'Stop'

# Fixed identity for the gallery script. Do not regenerate: the gallery keys a
# script by this GUID across versions.
$ScriptGuid = '0e5a6893-36f8-46da-b8b8-0d9500d7a492'

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
$mainScript = Join-Path $repoRoot 'Winnow.ps1'
$buildScript = Join-Path $repoRoot 'build.ps1'

if (-not (Test-Path $mainScript)) { throw "Winnow.ps1 not found at $mainScript" }
if (-not (Test-Path $buildScript)) { throw "build.ps1 not found at $buildScript" }

# 1. Version from the WINNOW_VERSION constant, so the gallery version cannot
# drift from the app version.
$versionMatch = Select-String -Path $mainScript -Pattern "WINNOW_VERSION'\s*-Value\s*'([0-9]+\.[0-9]+\.[0-9]+)'" | Select-Object -First 1
if (-not $versionMatch) { throw "Could not read WINNOW_VERSION from $mainScript" }
$version = $versionMatch.Matches[0].Groups[1].Value
Write-Host "Winnow version: $version"

if (-not (Test-Path $OutputDirectory)) { New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null }
$galleryScript = Join-Path $OutputDirectory 'Winnow.ps1'

# 2. Build the standalone into a temporary file, then wrap it.
$builtStandalone = Join-Path $OutputDirectory 'Winnow-Standalone.build.ps1'
Write-Host 'Building standalone...'
& $buildScript -OutputFile $builtStandalone | Out-Null
if (-not (Test-Path $builtStandalone)) { throw 'build.ps1 did not produce the standalone artifact' }

$body = Get-Content -LiteralPath $builtStandalone -Raw

# 3. Inject the PSScriptInfo block if the built file does not already carry one.
if ($body -notmatch '(?m)^\s*<#PSScriptInfo') {
    $psScriptInfo = @"
<#PSScriptInfo

.VERSION $version
.GUID $ScriptGuid
.AUTHOR BiosSystem
.COMPANYNAME BiosSystem
.COPYRIGHT Copyright (c) BiosSystem
.TAGS Windows Windows11 Debloat Privacy Telemetry Copilot Recall PSEdition_Desktop
.LICENSEURI https://github.com/BiosSystem/Winnow/blob/master/LICENSE
.PROJECTURI https://github.com/BiosSystem/Winnow
.ICONURI
.EXTERNALMODULEDEPENDENCIES
.REQUIREDSCRIPTS
.EXTERNALSCRIPTDEPENDENCIES
.RELEASENOTES
See https://github.com/BiosSystem/Winnow/releases

#>

<#
.DESCRIPTION
Windows 11 debloat, telemetry, and privacy hardening toolkit (self-contained standalone build).
#>

"@
    $body = $psScriptInfo + $body
}

Set-Content -LiteralPath $galleryScript -Value $body -Encoding UTF8
Write-Host "Gallery script written to: $galleryScript"

# 4. Validate.
Write-Host 'Validating with Test-ScriptFileInfo...'
$info = Test-ScriptFileInfo -Path $galleryScript
Write-Host "  Name:    $($info.Name)"
Write-Host "  Version: $($info.Version)"
Write-Host "  GUID:    $($info.Guid)"
Write-Host "  Author:  $($info.Author)"

# 5. Publish only when a key is supplied.
if (-not $ApiKey) {
    Write-Host ''
    Write-Host 'No -ApiKey supplied. Built and validated only; nothing was published.' -ForegroundColor Yellow
    Write-Host 'Re-run with -ApiKey <your PowerShell Gallery key> to publish.'
    return
}

if ($PSCmdlet.ShouldProcess('PowerShell Gallery', "Publish Winnow $version")) {
    Write-Host 'Publishing to the PowerShell Gallery...'
    Publish-Script -Path $galleryScript -NuGetApiKey $ApiKey
    Write-Host "Published Winnow $version to the PowerShell Gallery." -ForegroundColor Green
}
