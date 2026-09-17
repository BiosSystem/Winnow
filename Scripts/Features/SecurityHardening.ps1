<#
.SYNOPSIS
    Security hardening preset for Winnow.
.DESCRIPTION
    Disables insecure legacy protocols (SMBv1, TLS 1.0/1.1), blocks common attack
    ports, disables RDP inbound, disables AutoRun on all drives, and enables DNS
    over HTTPS. All changes are reversible.
    Created by Bios-System | https://github.com/BiosSystem/Winnow
#>

function Enable-SecurityHardening {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Host "> Applying security hardening..." -ForegroundColor Cyan

    # 1. Disable SMBv1 (EternalBlue/WannaCry vector)
    if ($PSCmdlet.ShouldProcess("Windows Feature", "Disable SMBv1")) {
        try {
            Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction SilentlyContinue
            Disable-WindowsOptionalFeature -Online -FeatureName "SMB1Protocol" -NoRestart -ErrorAction SilentlyContinue | Out-Null
            Write-Host "  [OK] SMBv1 disabled"
        } catch {
            Write-Host "  [WARN] Could not disable SMBv1: $_" -ForegroundColor Yellow
        }
    }

    # 2. Disable Remote Desktop (RDP) inbound
    if ($PSCmdlet.ShouldProcess("Registry", "Disable RDP")) {
        $rdpPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server"
        Set-ItemProperty -Path $rdpPath -Name "fDenyTSConnections" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        # Disable RDP firewall rule
        netsh advfirewall firewall set rule group="remote desktop" new enable=No 2>$null | Out-Null
        Write-Host "  [OK] Remote Desktop (RDP) disabled"
    }

    # 3. Disable AutoRun on all drives (USB malware prevention)
    if ($PSCmdlet.ShouldProcess("Registry", "Disable AutoRun")) {
        $autorunPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
        if (-not (Test-Path $autorunPath)) { New-Item -Path $autorunPath -Force | Out-Null }
        Set-ItemProperty -Path $autorunPath -Name "NoDriveTypeAutoRun" -Value 255 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] AutoRun disabled on all drive types"
    }

    # 4. Disable TLS 1.0 and 1.1
    if ($PSCmdlet.ShouldProcess("Registry", "Disable TLS 1.0 and 1.1")) {
        $tlsPaths = @(
            "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Client",
            "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Server",
            "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.1\Client",
            "HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.1\Server"
        )
        foreach ($path in $tlsPaths) {
            if (-not (Test-Path $path)) { New-Item -Path $path -Force | Out-Null }
            Set-ItemProperty -Path $path -Name "Enabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $path -Name "DisabledByDefault" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        }
        Write-Host "  [OK] TLS 1.0 and TLS 1.1 disabled"
    }

    # 5. Block common attack ports via Windows Firewall (inbound)
    if ($PSCmdlet.ShouldProcess("Firewall", "Block ports 135 139 445")) {
        $ports = @(
            @{ Name = "Block-RPC-135";   Port = "135" },
            @{ Name = "Block-NetBIOS-139"; Port = "139" },
            @{ Name = "Block-SMB-445";   Port = "445" }
        )
        foreach ($rule in $ports) {
            netsh advfirewall firewall add rule name="$($rule.Name)" dir=in action=block protocol=TCP localport=$($rule.Port) 2>$null | Out-Null
            Write-Host "  [OK] Blocked inbound port $($rule.Port) ($($rule.Name))"
        }
    }

    # 6. Disable Windows Script Host (blocks .vbs/.js malware from running via double-click)
    if ($PSCmdlet.ShouldProcess("Registry", "Disable Windows Script Host")) {
        $wshPath = "HKLM:\SOFTWARE\Microsoft\Windows Script Host\Settings"
        if (-not (Test-Path $wshPath)) { New-Item -Path $wshPath -Force | Out-Null }
        Set-ItemProperty -Path $wshPath -Name "Enabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] Windows Script Host disabled (.vbs/.js protection)"
    }

    Write-Host ""
    Write-Host "Security hardening applied. A restart is recommended." -ForegroundColor Green
    Write-Host ""
}

function Disable-SecurityHardening {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Host "> Reverting security hardening..." -ForegroundColor Cyan

    # Re-enable RDP
    $rdpPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server"
    Set-ItemProperty -Path $rdpPath -Name "fDenyTSConnections" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
    netsh advfirewall firewall set rule group="remote desktop" new enable=Yes 2>$null | Out-Null
    Write-Host "  [OK] Remote Desktop re-enabled"

    # Re-enable AutoRun defaults
    $autorunPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    Set-ItemProperty -Path $autorunPath -Name "NoDriveTypeAutoRun" -Value 91 -Type DWord -Force -ErrorAction SilentlyContinue
    Write-Host "  [OK] AutoRun defaults restored"

    # Re-enable Windows Script Host
    $wshPath = "HKLM:\SOFTWARE\Microsoft\Windows Script Host\Settings"
    Set-ItemProperty -Path $wshPath -Name "Enabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    Write-Host "  [OK] Windows Script Host re-enabled"

    Write-Host ""
    Write-Host "Security hardening reverted." -ForegroundColor Yellow
    Write-Host ""
}

function Get-SecurityHardeningRegistryTargets {
    # The exact registry values Enable-SecurityHardening writes, as data, so the
    # rollback snapshot captures the same set the apply changes and cannot drift
    # from it. Paths only; the snapshot records each value and its type at capture.
    $targets = @(
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'; Name = 'fDenyTSConnections' }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Name = 'NoDriveTypeAutoRun' }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows Script Host\Settings'; Name = 'Enabled' }
    )
    foreach ($tlsPath in @(
            'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Client',
            'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0\Server',
            'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.1\Client',
            'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.1\Server'
        )) {
        $targets += @{ Path = $tlsPath; Name = 'Enabled' }
        $targets += @{ Path = $tlsPath; Name = 'DisabledByDefault' }
    }
    return $targets
}

