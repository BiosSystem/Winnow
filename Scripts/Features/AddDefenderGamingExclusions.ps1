function Get-DefenderGamingExclusionPaths {
    # Single source of truth for the game-library paths, so the add and remove operations always
    # act on exactly the same set and cannot drift apart.
    return @(
        "C:\Program Files (x86)\Steam\steamapps\common",
        "C:\Program Files\Epic Games",
        "C:\Program Files (x86)\GOG Galaxy\Games",
        "D:\SteamLibrary\steamapps\common",
        "E:\SteamLibrary\steamapps\common"
    )
}

function Invoke-AddDefenderGamingExclusions {
    param (
        [switch]$WhatIf
    )

    Write-Host "`n[*] Adding Windows Defender Gaming Exclusions..." -ForegroundColor Cyan

    $gamePaths = @(Get-DefenderGamingExclusionPaths)

    if ($WhatIf) {
        Write-Host "  [WhatIf] Would add the following paths to Windows Defender exclusions:" -ForegroundColor Yellow
        foreach ($path in $gamePaths) {
            if (Test-Path $path) {
                Write-Host "  - $path (Detected)" -ForegroundColor DarkGray
            } else {
                Write-Host "  - $path (Not found)" -ForegroundColor DarkGray
            }
        }
        return
    }

    try {
        $added = 0
        foreach ($path in $gamePaths) {
            if (Test-Path $path) {
                Add-MpPreference -ExclusionPath $path -ErrorAction SilentlyContinue
                Write-Host "  [+] Excluded $path" -ForegroundColor Green
                $added++
            }
        }

        if ($added -eq 0) {
            Write-Host "  [-] No default gaming directories found to exclude." -ForegroundColor DarkGray
        } else {
            Write-Host "  [+] Windows Defender Gaming Exclusions applied." -ForegroundColor Green
        }
    }
    catch {
        Write-Host "  [ERROR] Failed to add Defender exclusions: $_" -ForegroundColor Red
    }
}

function Invoke-RemoveDefenderGamingExclusions {
    param (
        [switch]$WhatIf
    )

    Write-Host "`n[*] Removing Windows Defender Gaming Exclusions..." -ForegroundColor Cyan

    # Clear every path the add step could have excluded, whether or not the directory still exists:
    # the exclusion can outlive the folder, and Remove-MpPreference is a no-op for one that is absent.
    $gamePaths = @(Get-DefenderGamingExclusionPaths)

    if ($WhatIf) {
        Write-Host "  [WhatIf] Would remove the following paths from Windows Defender exclusions:" -ForegroundColor Yellow
        foreach ($path in $gamePaths) {
            Write-Host "  - $path" -ForegroundColor DarkGray
        }
        return
    }

    try {
        foreach ($path in $gamePaths) {
            Remove-MpPreference -ExclusionPath $path -ErrorAction SilentlyContinue
            Write-Host "  [-] Cleared exclusion for $path" -ForegroundColor Green
        }
        Write-Host "  [+] Windows Defender Gaming Exclusions removed." -ForegroundColor Green
    }
    catch {
        Write-Host "  [ERROR] Failed to remove Defender exclusions: $_" -ForegroundColor Red
    }
}
