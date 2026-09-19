<#
.SYNOPSIS
    Extended AI and Copilot+ purge for Windows 11 24H2/25H2.
.DESCRIPTION
    Targets new AI integrations added in the 24H2/25H2 update cycle that were
    not present in earlier Winnow AI purge routines: Phone Link deep disable,
    Sluggishness Telemetry tasks, Windows Ink AI suggestions, OneDrive silent
    sign-in suppression, and Copilot Actions permissions lockdown.
    Created by Bios-System | https://github.com/BiosSystem/Winnow
#>

function Disable-ExtendedAIPurge {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Host "> Running extended AI purge (24H2/25H2 targets)..." -ForegroundColor Cyan

    # 1. Phone Link - deep registry disable
    if ($PSCmdlet.ShouldProcess("Registry", "Disable Phone Link")) {
        $mobilityPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Mobility"
        if (-not (Test-Path $mobilityPath)) { New-Item -Path $mobilityPath -Force | Out-Null }
        Set-ItemProperty -Path $mobilityPath -Name "PhoneLinkEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $mobilityPath -Name "OptedIn" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] Phone Link disabled"
    }

    # 2. Disable Windows Ink Workspace AI suggestions
    if ($PSCmdlet.ShouldProcess("Registry", "Disable Windows Ink AI")) {
        $inkPath = "HKLM:\SOFTWARE\Policies\Microsoft\WindowsInkWorkspace"
        if (-not (Test-Path $inkPath)) { New-Item -Path $inkPath -Force | Out-Null }
        Set-ItemProperty -Path $inkPath -Name "AllowWindowsInkWorkspace" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] Windows Ink Workspace AI disabled"
    }

    # 3. Disable Sluggishness Telemetry (CloudExperienceHost scheduled tasks)
    if ($PSCmdlet.ShouldProcess("Scheduled Tasks", "Disable Sluggishness Telemetry")) {
        $slugTasks = @(
            @{ Path = "\Microsoft\Windows\CloudExperienceHost\"; Name = "CreateObjectTask" },
            @{ Path = "\Microsoft\Windows\Shell\"; Name = "FamilySafetyMonitor" },
            @{ Path = "\Microsoft\Windows\Shell\"; Name = "FamilySafetyRefreshTask" },
            @{ Path = "\Microsoft\Windows\Device Inventory\"; Name = "RunUpdateUserDeviceInventoryTask" }
        )
        foreach ($task in $slugTasks) {
            $taskObj = Get-ScheduledTask -TaskPath $task.Path -TaskName $task.Name -ErrorAction SilentlyContinue
            if ($taskObj -and $taskObj.State -ne 'Disabled') {
                try {
                    Disable-ScheduledTask -TaskPath $task.Path -TaskName $task.Name -ErrorAction Stop | Out-Null
                    Write-Host "  [OK] Disabled task: $($task.Path)$($task.Name)"
                } catch {
                    Write-Host "  [WARN] Could not disable $($task.Name): $_" -ForegroundColor Yellow
                }
            }
        }
    }

    # 4. Suppress OneDrive silent sign-in from Microsoft account
    if ($PSCmdlet.ShouldProcess("Registry", "Suppress OneDrive auto sign-in")) {
        $odPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive"
        if (-not (Test-Path $odPath)) { New-Item -Path $odPath -Force | Out-Null }
        Set-ItemProperty -Path $odPath -Name "DisableFileSyncNGSC" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        $od2Path = "HKCU:\Software\Microsoft\OneDrive"
        if (Test-Path $od2Path) {
            Set-ItemProperty -Path $od2Path -Name "DisablePersonalSync" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        }
        Write-Host "  [OK] OneDrive auto sign-in suppressed"
    }

    # 5. Disable clipboard cloud sync (cross-device clipboard history)
    if ($PSCmdlet.ShouldProcess("Registry", "Disable Cloud Clipboard Sync")) {
        $clipPath = "HKCU:\Software\Microsoft\Clipboard"
        if (-not (Test-Path $clipPath)) { New-Item -Path $clipPath -Force | Out-Null }
        Set-ItemProperty -Path $clipPath -Name "EnableCloudClipboard" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        $clipPolicy = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"
        if (-not (Test-Path $clipPolicy)) { New-Item -Path $clipPolicy -Force | Out-Null }
        Set-ItemProperty -Path $clipPolicy -Name "AllowCrossDeviceClipboard" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] Cloud clipboard sync disabled"
    }

    # 6. Disable Recall, Click to Do and the Settings agent (WindowsAI policies).
    # Per the WindowsAI policy CSP, DisableAIDataAnalysis and DisableClickToDo are
    # both machine and user scoped, so set them in HKLM and HKCU; AllowRecallEnablement
    # and DisableSettingsAgent are machine scoped only. Click to Do (screen analysis)
    # and the agentic Settings search are 24H2/25H2 additions not covered before.
    if ($PSCmdlet.ShouldProcess("Registry", "Disable Recall, Click to Do and Settings agent")) {
        $windowsAiKeys = @(
            "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI",
            "HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"
        )
        foreach ($aiKey in $windowsAiKeys) {
            if (-not (Test-Path $aiKey)) { New-Item -Path $aiKey -Force | Out-Null }
            Set-ItemProperty -Path $aiKey -Name "DisableAIDataAnalysis" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            Set-ItemProperty -Path $aiKey -Name "DisableClickToDo" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        }
        # Machine-scoped only.
        $recallPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI"
        Set-ItemProperty -Path $recallPath -Name "AllowRecallEnablement" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $recallPath -Name "DisableSettingsAgent" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] Recall snapshots, Click to Do and Settings agent disabled"
    }

    # 6b. Remove the Recall optional component where present. Since KB5041865
    # Recall is a removable Windows feature on Copilot+ builds; the policies above
    # leave it installed. Guarded so it no-ops on SKUs where the feature is absent,
    # and one-way: re-adding the component needs its payload and a restart.
    if ($PSCmdlet.ShouldProcess("Windows optional feature 'Recall'", "Remove component")) {
        try {
            $recallFeature = Get-WindowsOptionalFeature -Online -FeatureName 'Recall' -ErrorAction Stop
            if ($recallFeature -and $recallFeature.State -eq 'Enabled') {
                Disable-WindowsOptionalFeature -Online -FeatureName 'Recall' -Remove -NoRestart -ErrorAction Stop | Out-Null
                Write-Host "  [OK] Recall optional component removed (restart required to complete)"
            }
            else {
                Write-Host "  [SKIP] Recall optional component not present on this edition" -ForegroundColor DarkGray
            }
        }
        catch {
            Write-Host "  [WARN] Could not remove the Recall component: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # 7. Disable Photos app Generative Fill (24H2 AI image editing)
    if ($PSCmdlet.ShouldProcess("Registry", "Disable Photos Generative Fill")) {
        $photosPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Photos"
        if (-not (Test-Path $photosPath)) { New-Item -Path $photosPath -Force | Out-Null }
        Set-ItemProperty -Path $photosPath -Name "DisableGenerativeFill" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] Photos Generative Fill disabled"
    }

    # 8. Disable AI Suggested Clipboard Actions (AI reads clipboard to suggest tasks)
    if ($PSCmdlet.ShouldProcess("Registry", "Disable Suggested Clipboard Actions")) {
        $clipPath = "HKCU:\Software\Microsoft\Clipboard"
        if (-not (Test-Path $clipPath)) { New-Item -Path $clipPath -Force | Out-Null }
        Set-ItemProperty -Path $clipPath -Name "EnableSuggestedClipboardActions" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] AI Suggested Clipboard Actions disabled"
    }

    # 9. Block Microsoft 365 silent auto-install push (delivered via Windows Update post-24H2)
    if ($PSCmdlet.ShouldProcess("Registry", "Block M365 auto-install")) {
        $m365Path = "HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common"
        if (-not (Test-Path $m365Path)) { New-Item -Path $m365Path -Force | Out-Null }
        Set-ItemProperty -Path $m365Path -Name "PreventProductInstall" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] Microsoft 365 silent auto-install blocked"
    }

    # 10. Disable System-Wide Windows Copilot (Windows 11)
    if ($PSCmdlet.ShouldProcess("Registry", "Disable Windows Copilot")) {
        $copilotPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot"
        if (-not (Test-Path $copilotPath)) { New-Item -Path $copilotPath -Force | Out-Null }
        Set-ItemProperty -Path $copilotPath -Name "TurnOffWindowsCopilot" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] System-wide Windows Copilot disabled"
    }

    # 11. Disable Copilot in Outlook (new Outlook AI suggestions)
    if ($PSCmdlet.ShouldProcess("Registry", "Disable Outlook Copilot")) {
        $olPath = "HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\outlook\options\mail"
        if (-not (Test-Path $olPath)) { New-Item -Path $olPath -Force | Out-Null }
        Set-ItemProperty -Path $olPath -Name "DisableCopilot" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] Outlook Copilot AI suggestions disabled"
    }

    # 12. Disable Power Automate Desktop UIFlowService autostart
    if ($PSCmdlet.ShouldProcess("Registry", "Disable UIFlowService autostart")) {
        $uiflowKey = "HKLM:\SYSTEM\CurrentControlSet\Services\UIFlowService"
        if (Test-Path $uiflowKey) {
            Set-ItemProperty -Path $uiflowKey -Name "Start" -Value 4 -Type DWord -Force -ErrorAction SilentlyContinue
            Write-Host "  [OK] Power Automate Desktop UIFlowService set to disabled"
        } else {
            Write-Host "  [SKIP] UIFlowService not found (Power Automate Desktop not installed)" -ForegroundColor DarkGray
        }
    }

    # 13. Disable Narrator AI online voices (24H2 natural AI speech)
    if ($PSCmdlet.ShouldProcess("Registry", "Disable Narrator AI voices")) {
        $narrPath = "HKCU:\Software\Microsoft\Narrator\NoRoam"
        if (-not (Test-Path $narrPath)) { New-Item -Path $narrPath -Force | Out-Null }
        Set-ItemProperty -Path $narrPath -Name "OnlineVoicesEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] Narrator AI online voices disabled"
    }

    # 14. Disable the Paint AI features (Cocreator, generative fill, Image Creator).
    # These are the documented WindowsAI/Paint policies at the Paint policy key,
    # separate from the Photos generative-fill key handled in step 7.
    if ($PSCmdlet.ShouldProcess("Registry", "Disable Paint AI features")) {
        $paintPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint"
        if (-not (Test-Path $paintPath)) { New-Item -Path $paintPath -Force | Out-Null }
        Set-ItemProperty -Path $paintPath -Name "DisableCocreator" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $paintPath -Name "DisableGenerativeFill" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $paintPath -Name "DisableImageCreator" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Write-Host "  [OK] Paint AI features (Cocreator, generative fill, Image Creator) disabled"
    }

    Write-Host ""
    Write-Host "Extended AI purge complete." -ForegroundColor Green
    Write-Host ""
}

function Enable-ExtendedAIPurgeRevert {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    Write-Host "> Reverting extended AI purge..." -ForegroundColor Cyan

    # Re-enable Phone Link
    $mobilityPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Mobility"
    if (Test-Path $mobilityPath) {
        Set-ItemProperty -Path $mobilityPath -Name "PhoneLinkEnabled" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $mobilityPath -Name "OptedIn" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
    }

    # Re-enable Cloud Clipboard
    $clipPath = "HKCU:\Software\Microsoft\Clipboard"
    if (Test-Path $clipPath) {
        Remove-ItemProperty -Path $clipPath -Name "EnableCloudClipboard" -Force -ErrorAction SilentlyContinue
    }

    Write-Host "  [OK] Extended AI settings reverted (Phone Link and Cloud Clipboard restored)"
    Write-Host ""
}

function Get-ExtendedAIPurgeRegistryTargets {
    # The registry values Disable-ExtendedAIPurge writes, as data, for the rollback
    # snapshot. Scheduled tasks (Scope A) and the Recall component removal (one-way)
    # are handled elsewhere and are not listed here.
    @(
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Mobility'; Name = 'PhoneLinkEnabled' }
        @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Mobility'; Name = 'OptedIn' }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsInkWorkspace'; Name = 'AllowWindowsInkWorkspace' }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive'; Name = 'DisableFileSyncNGSC' }
        @{ Path = 'HKCU:\Software\Microsoft\OneDrive'; Name = 'DisablePersonalSync' }
        @{ Path = 'HKCU:\Software\Microsoft\Clipboard'; Name = 'EnableCloudClipboard' }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'; Name = 'AllowCrossDeviceClipboard' }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableAIDataAnalysis' }
        @{ Path = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableAIDataAnalysis' }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableClickToDo' }
        @{ Path = 'HKCU:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableClickToDo' }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'AllowRecallEnablement' }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsAI'; Name = 'DisableSettingsAgent' }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Photos'; Name = 'DisableGenerativeFill' }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint'; Name = 'DisableCocreator' }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint'; Name = 'DisableGenerativeFill' }
        @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Paint'; Name = 'DisableImageCreator' }
        @{ Path = 'HKCU:\Software\Microsoft\Clipboard'; Name = 'EnableSuggestedClipboardActions' }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Office\16.0\Common'; Name = 'PreventProductInstall' }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot' }
        @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\office\16.0\outlook\options\mail'; Name = 'DisableCopilot' }
        @{ Path = 'HKLM:\SYSTEM\CurrentControlSet\Services\UIFlowService'; Name = 'Start' }
        @{ Path = 'HKCU:\Software\Microsoft\Narrator\NoRoam'; Name = 'OnlineVoicesEnabled' }
    )
}


