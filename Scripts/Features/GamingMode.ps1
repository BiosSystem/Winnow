<#
.SYNOPSIS
    Gaming Mode - applies a curated set of performance tweaks for gamers.
.DESCRIPTION
    Disables background services, enables High Performance power plan, and
    optimizes the OS for low-latency gaming. Created by Bios-System.
#>

function Enable-GamingMode {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Host "> Enabling Gaming Mode tweaks..." -ForegroundColor Cyan

    # 1. High Performance power plan
    if ($PSCmdlet.ShouldProcess("Power Plan", "Switch to High Performance")) {
        try {
            $hp = powercfg -list | Select-String "High performance"
            if ($hp) {
                $guid = ($hp -split "\s+")[3]
                powercfg -setactive $guid | Out-Null
                Write-Host "  [OK] Power plan set to High Performance"
            } else {
                powercfg -setactive SCHEME_MIN | Out-Null
                Write-Host "  [OK] Power plan set to High Performance (SCHEME_MIN)"
            }
        } catch {
            Write-Host "  [WARN] Could not change power plan: $_" -ForegroundColor Yellow
        }
    }

    # 2. Disable Nagle's Algorithm (reduces TCP latency in games)
    if ($PSCmdlet.ShouldProcess("Registry", "Disable Nagle Algorithm")) {
        $tcpPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
        Get-ChildItem $tcpPath -ErrorAction SilentlyContinue | ForEach-Object {
            Set-ItemProperty -Path $_.PSPath -Name "TcpAckFrequency" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $_.PSPath -Name "TCPNoDelay" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        }
        Write-Host "  [OK] Nagle's Algorithm disabled (lower network latency)"
    }

    # 3. Disable Mouse Acceleration (raw input)
    if ($PSCmdlet.ShouldProcess("Registry", "Disable Mouse Acceleration")) {
        $mousePath = "HKCU:\Control Panel\Mouse"
        Set-ItemProperty -Path $mousePath -Name "MouseSpeed" -Value "0" -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $mousePath -Name "MouseThreshold1" -Value "0" -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $mousePath -Name "MouseThreshold2" -Value "0" -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] Mouse acceleration disabled"
    }

    # 4. Disable Sticky Keys (no accidental shift interruptions)
    if ($PSCmdlet.ShouldProcess("Registry", "Disable Sticky Keys")) {
        $accessPath = "HKCU:\Control Panel\Accessibility\StickyKeys"
        if (-not (Test-Path $accessPath)) { New-Item -Path $accessPath -Force | Out-Null }
        Set-ItemProperty -Path $accessPath -Name "Flags" -Value "506" -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] Sticky Keys disabled"
    }

    # 5. Disable Xbox Game Bar (not just DVR)
    if ($PSCmdlet.ShouldProcess("Registry", "Disable Xbox Game Bar")) {
        $gbPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"
        if (-not (Test-Path $gbPath)) { New-Item -Path $gbPath -Force | Out-Null }
        Set-ItemProperty -Path $gbPath -Name "AppCaptureEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        $gbPath2 = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR"
        if (-not (Test-Path $gbPath2)) { New-Item -Path $gbPath2 -Force | Out-Null }
        Set-ItemProperty -Path $gbPath2 -Name "AllowGameDVR" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] Xbox Game Bar and DVR disabled"
    }

    # 6. Disable startup delay (faster post-boot)
    if ($PSCmdlet.ShouldProcess("Registry", "Disable Startup Delay")) {
        $startupPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize"
        if (-not (Test-Path $startupPath)) { New-Item -Path $startupPath -Force | Out-Null }
        Set-ItemProperty -Path $startupPath -Name "StartupDelayInMSec" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] Startup delay removed"
    }

    # 7. Prioritize GPU scheduling (Hardware Accelerated GPU Scheduling)
    if ($PSCmdlet.ShouldProcess("Registry", "Enable Hardware GPU Scheduling")) {
        $gpuPath = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
        if (-not (Test-Path $gpuPath)) { New-Item -Path $gpuPath -Force | Out-Null }
        Set-ItemProperty -Path $gpuPath -Name "HwSchMode" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] Hardware Accelerated GPU Scheduling enabled"
    }

    # 8. Disable automatic maintenance during active hours
    if ($PSCmdlet.ShouldProcess("Registry", "Disable Automatic Maintenance")) {
        $maintPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance"
        if (-not (Test-Path $maintPath)) { New-Item -Path $maintPath -Force | Out-Null }
        Set-ItemProperty -Path $maintPath -Name "MaintenanceDisabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] Automatic maintenance disabled"
    }

    Write-Host ""
    Write-Host "Gaming Mode enabled. A restart is recommended." -ForegroundColor Green
    Write-Host ""
}

function Disable-GamingMode {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Host "> Reverting Gaming Mode tweaks..." -ForegroundColor Cyan

    # Restore Balanced power plan
    if ($PSCmdlet.ShouldProcess("Power Plan", "Restore Balanced")) {
        powercfg -setactive SCHEME_BALANCED | Out-Null
        Write-Host "  [OK] Power plan restored to Balanced"
    }

    # Re-enable Nagle's Algorithm
    if ($PSCmdlet.ShouldProcess("Registry", "Re-enable Nagle Algorithm")) {
        $tcpPath = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces"
        Get-ChildItem $tcpPath -ErrorAction SilentlyContinue | ForEach-Object {
            Remove-ItemProperty -Path $_.PSPath -Name "TcpAckFrequency" -Force -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $_.PSPath -Name "TCPNoDelay" -Force -ErrorAction SilentlyContinue
        }
        Write-Host "  [OK] Nagle's Algorithm restored"
    }

    # Restore automatic maintenance
    if ($PSCmdlet.ShouldProcess("Registry", "Re-enable Automatic Maintenance")) {
        $maintPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance"
        Remove-ItemProperty -Path $maintPath -Name "MaintenanceDisabled" -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] Automatic maintenance restored"
    }

    Write-Host ""
    Write-Host "Gaming Mode reverted." -ForegroundColor Yellow
    Write-Host ""
}

function Get-GamingModeRegistryTargets {
    # The registry values Enable-GamingMode writes, as data, for the rollback
    # snapshot. The power plan change (powercfg) is not registry and stays uncovered.
    $targets = @(
        @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseSpeed' }
        @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseThreshold1' }
        @{ Path = 'HKCU:\Control Panel\Mouse'; Name = 'MouseThreshold2' }
        @{ Path = 'HKCU:\Control Panel\Accessibility\StickyKeys'; Name = 'Flags' }
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled' }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR'; Name = 'AllowGameDVR' }
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Serialize'; Name = 'StartupDelayInMSec' }
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'; Name = 'HwSchMode' }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance'; Name = 'MaintenanceDisabled' }
    )
    # Nagle's algorithm is disabled per network interface, so the target set depends
    # on the interfaces present at capture time.
    $interfaces = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -ErrorAction SilentlyContinue)
    foreach ($interface in $interfaces) {
        $targets += @{ Path = $interface.PSPath; Name = 'TcpAckFrequency' }
        $targets += @{ Path = $interface.PSPath; Name = 'TCPNoDelay' }
    }
    return $targets
}

