# Enables a Windows optional feature and pipes its output to the console.
# Returns $true on success (or under -WhatIf), $false when DISM failed.
function EnableWindowsFeature {
    param (
        [string]$FeatureName
    )

    return (Set-WindowsOptionalFeatureState -FeatureName $FeatureName -Enable $true)
}

# Disables a Windows optional feature and pipes its output to the console.
# Returns $true on success (or under -WhatIf), $false when DISM failed.
function DisableWindowsFeature {
    param (
        [string]$FeatureName
    )

    return (Set-WindowsOptionalFeatureState -FeatureName $FeatureName -Enable $false)
}

function Set-WindowsOptionalFeatureState {
    param (
        [Parameter(Mandatory)]
        [string]$FeatureName,
        [bool]$Enable
    )

    $verb = if ($Enable) { 'Enable' } else { 'Disable' }

    if ($script:Params.ContainsKey("WhatIf")) {
        Write-Host "[WhatIf] $verb Windows feature: $FeatureName" -ForegroundColor Cyan
        Write-Host ""
        return $true
    }

    # -ErrorAction Stop inside the runner: a DISM error used to be printed and
    # then ignored, so the feature reported success.
    try {
        $result = Invoke-NonBlocking -ScriptBlock {
            param($name, $enable)
            try {
                $output = if ($enable) {
                    Enable-WindowsOptionalFeature -Online -FeatureName $name -All -NoRestart -ErrorAction Stop
                }
                else {
                    Disable-WindowsOptionalFeature -Online -FeatureName $name -NoRestart -ErrorAction Stop
                }
                return [PSCustomObject]@{ Success = $true; Output = @($output); Error = $null }
            }
            catch {
                return [PSCustomObject]@{ Success = $false; Output = @(); Error = $_.Exception.Message }
            }
        } -ArgumentList @($FeatureName, $Enable)
    }
    catch {
        $result = [PSCustomObject]@{ Success = $false; Output = @(); Error = $_.Exception.Message }
    }

    if ($null -eq $result) {
        $result = [PSCustomObject]@{ Success = $false; Output = @(); Error = 'no result was returned' }
    }

    $dismResult = @($result.Output) | Where-Object { $_ -is [Microsoft.Dism.Commands.ImageObject] }
    if ($dismResult) {
        Write-Host ($dismResult | Out-String).Trim()
    }

    if (-not $result.Success) {
        Write-Host "Failed to $($verb.ToLowerInvariant()) Windows feature $($FeatureName): $($result.Error)" -ForegroundColor Red
        return $false
    }

    return $true
}

function Test-WindowsOptionalFeatureEnabled {
    param (
        [Parameter(Mandatory)]
        [string]$FeatureName
    )

    try {
        $feature = Get-WindowsOptionalFeature -Online -FeatureName $FeatureName -ErrorAction Stop
    }
    catch {
        return $false
    }

    return ($feature.State -eq 'Enabled')
}
