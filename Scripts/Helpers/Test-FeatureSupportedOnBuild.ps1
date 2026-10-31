<#
    .SYNOPSIS
        Checks a feature's MinVersion and MaxVersion against a Windows build number.

    .DESCRIPTION
        MinVersion and MaxVersion in Features.json are Windows build numbers. A
        feature without limits, or a build that could not be read, counts as
        supported.
#>
function Test-FeatureSupportedOnBuild {
    param(
        $Feature,
        $Build
    )

    $buildNumber = 0
    if ($null -eq $Feature -or -not [int]::TryParse([string]$Build, [ref]$buildNumber)) { return $true }
    if ($Feature.MinVersion -and $buildNumber -lt [int]$Feature.MinVersion) { return $false }
    if ($Feature.MaxVersion -and $buildNumber -gt [int]$Feature.MaxVersion) { return $false }
    return $true
}
