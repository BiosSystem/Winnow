<#
    .SYNOPSIS
        Reads a boolean deployment value from a configuration file.

    .DESCRIPTION
        Returns $true or $false for a JSON boolean, the text true or false (any
        case, surrounding spaces ignored) and the numbers 1 and 0. Anything else
        gives $null. A [bool] cast cannot be used: it turns any non-empty text,
        including "false", into $true.
#>
function ConvertTo-ConfigBoolean {
    param($Value)

    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string]) {
        $text = $Value.Trim()
        if ($text -ieq 'true') { return $true }
        if ($text -ieq 'false') { return $false }
        return $null
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [decimal] -or $Value -is [double]) {
        if ($Value -eq 1) { return $true }
        if ($Value -eq 0) { return $false }
    }
    return $null
}

<#
    .SYNOPSIS
        Reads one boolean deployment setting, warning when it is not a boolean.
#>
function Get-ConfigDeploymentFlag {
    param(
        [hashtable]$Lookup,
        [string]$Name
    )

    if (-not $Lookup.ContainsKey($Name)) { return $null }

    $flagValue = ConvertTo-ConfigBoolean $Lookup[$Name]
    if ($null -eq $flagValue) {
        Write-Warning "Ignoring deployment setting '$Name' in the config file: expected true or false, found '$($Lookup[$Name])'."
    }
    return $flagValue
}

function ImportConfigToParams {
    param (
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,
        [int]$CurrentBuild,
        [string]$ExpectedVersion = '1.0'
    )

    $resolvedConfigPath = $null
    try {
        $resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).Path
    }
    catch {
        throw "Unable to find config file at path: $ConfigPath"
    }

    if (-not (Test-Path -LiteralPath $resolvedConfigPath -PathType Leaf)) {
        throw "Provided config path is not a file: $resolvedConfigPath"
    }

    if ([System.IO.Path]::GetExtension($resolvedConfigPath) -ne '.json') {
        throw "Provided config file must be a .json file: $resolvedConfigPath"
    }

    $configJson = LoadJsonFile -filePath $resolvedConfigPath -expectedVersion $ExpectedVersion
    if ($null -eq $configJson) {
        throw "Failed to read config file: $resolvedConfigPath"
    }

    $consistencyError = Test-ConfigConsistency -Config $configJson
    if ($consistencyError) {
        throw "Invalid config file '$resolvedConfigPath': $consistencyError"
    }

    $importedItems = 0

    if ($configJson.Apps) {
        $appIds = @(
            $configJson.Apps | 
            Where-Object { $_ -is [string] } | 
            ForEach-Object { $_.Trim() } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        )
        
        if ($appIds.Count -gt 0) {
            AddParameter 'RemoveApps'
            AddParameter 'Apps' ($appIds -join ',')
            $importedItems++
        }
    }

    if ($configJson.Tweaks) {
        foreach ($setting in @($configJson.Tweaks)) {
            if (-not $setting -or -not $setting.Name -or $setting.Value -ne $true) {
                continue
            }

            $feature = $script:Features[$setting.Name]
            if (-not $feature) {
                continue
            }

            if (($feature.MinVersion -and $CurrentBuild -lt $feature.MinVersion) -or ($feature.MaxVersion -and $CurrentBuild -gt $feature.MaxVersion) -or ($feature.FeatureId -eq 'DisableModernStandbyNetworking' -and (-not $script:ModernStandbySupported))) {
                continue
            }

            AddParameter $setting.Name $true
            $importedItems++
        }
    }

    if ($configJson.Deployment) {
        $deploymentLookup = @{}
        foreach ($setting in @($configJson.Deployment)) {
            if ($setting -and $setting.Name) {
                $deploymentLookup[$setting.Name] = $setting.Value
            }
        }

        if ((Get-ConfigDeploymentFlag -Lookup $deploymentLookup -Name 'CreateRestorePoint') -eq $true) {
            AddParameter 'CreateRestorePoint'
            $importedItems++
        }

        if ((Get-ConfigDeploymentFlag -Lookup $deploymentLookup -Name 'RestartExplorer') -eq $false) {
            AddParameter 'SkipExplorerRestart'
            $importedItems++
        }

        if ($deploymentLookup.ContainsKey('UserSelectionIndex')) {
            switch ([int]$deploymentLookup['UserSelectionIndex']) {
                1 {
                    $otherUserName = if ($deploymentLookup.ContainsKey('OtherUsername')) { "$($deploymentLookup['OtherUsername'])".Trim() } else { '' }
                    if (-not [string]::IsNullOrWhiteSpace($otherUserName)) {
                        AddParameter 'User' $otherUserName
                        $importedItems++
                    }
                }
                2 {
                    AddParameter 'Sysprep'
                    $importedItems++
                }
            }
        }

        if ($deploymentLookup.ContainsKey('AppRemovalScopeIndex') -and $script:Params.ContainsKey('RemoveApps')) {
            switch ([int]$deploymentLookup['AppRemovalScopeIndex']) {
                0 {
                    AddParameter 'AppRemovalTarget' 'AllUsers'
                    $importedItems++
                }
                1 {
                    AddParameter 'AppRemovalTarget' 'CurrentUser'
                    $importedItems++
                }
                2 {
                    $targetUser = if ($deploymentLookup.ContainsKey('OtherUsername')) { "$($deploymentLookup['OtherUsername'])".Trim() } else { '' }
                    if (-not [string]::IsNullOrWhiteSpace($targetUser)) {
                        AddParameter 'AppRemovalTarget' $targetUser
                        $importedItems++
                    }
                }
            }
        }
    }

    if ($importedItems -eq 0) {
        throw "The config file contains no importable data: $resolvedConfigPath"
    }

    return $resolvedConfigPath
}
