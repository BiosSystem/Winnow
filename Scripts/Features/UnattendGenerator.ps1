<#
.SYNOPSIS
    Unattended XML generator for offline OOBE bypass and Winnow integration.
.DESCRIPTION
    Generates an autounattend.xml file that skips the Microsoft Account
    requirement, disables OOBE telemetry prompts, and optionally pre-seeds
    Winnow to run on first boot with a saved configuration.
    Created by Bios-System | https://github.com/BiosSystem/Winnow
#>

function Generate-UnattendXML {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$OutputPath = "C:\autounattend.xml",

        # If provided, embed a Winnow first-boot run command using this config path
        [string]$WinnowConfigPath = "",

        # Local admin account to create (leave empty to skip)
        [string]$LocalAdminName = "",

        # Computer name to set (leave empty for random)
        [string]$ComputerName = ""
    )

    Write-Host "> Generating autounattend.xml for offline OOBE bypass..." -ForegroundColor Cyan

    $computerNameXml = if (-not [string]::IsNullOrWhiteSpace($ComputerName)) {
        "            <ComputerName>$([System.Security.SecurityElement]::Escape($ComputerName))</ComputerName>"
    } else { "" }

    $localAdminXml = if (-not [string]::IsNullOrWhiteSpace($LocalAdminName)) {
        @"
            <UserAccounts>
                <LocalAccounts>
                    <LocalAccount wcm:action="add">
                        <Name>$([System.Security.SecurityElement]::Escape($LocalAdminName))</Name>
                        <Group>Administrators</Group>
                        <DisplayName>$([System.Security.SecurityElement]::Escape($LocalAdminName))</DisplayName>
                    </LocalAccount>
                </LocalAccounts>
            </UserAccounts>
"@
    } else { "" }

    $winSwiftFirstBoot = if (-not [string]::IsNullOrWhiteSpace($WinnowConfigPath)) {
        # Escape the path for XML like the other user-supplied values, so a legal path containing
        # &, < or > does not produce an autounattend.xml that Windows Setup silently rejects.
        $escapedConfigPath = [System.Security.SecurityElement]::Escape($WinnowConfigPath)
        @"
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>powershell.exe -NonInteractive -ExecutionPolicy Bypass -File "C:\Winnow\Winnow-Standalone.ps1" -Config "$escapedConfigPath"</Path>
                    <Description>Apply Winnow configuration on first boot</Description>
                </RunSynchronousCommand>
"@
    } else { "" }

    $xmlContent = @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <SetupUILanguage>
                <UILanguage>en-US</UILanguage>
            </SetupUILanguage>
            <InputLocale>en-US</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UserLocale>en-US</UserLocale>
        </component>
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <UserData>
                <AcceptEula>true</AcceptEula>
            </UserData>
        </component>
    </settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
$computerNameXml
        </component>
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE /v BypassNRO /t REG_DWORD /d 1 /f</Path>
                    <Description>Bypass Microsoft Account requirement in OOBE</Description>
                </RunSynchronousCommand>
$winSwiftFirstBoot
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <ProtectYourPC>3</ProtectYourPC>
                <NetworkLocation>Home</NetworkLocation>
                <SkipMachineOOBE>true</SkipMachineOOBE>
                <SkipUserOOBE>true</SkipUserOOBE>
            </OOBE>
$localAdminXml
        </component>
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <InputLocale>en-US</InputLocale>
            <SystemLocale>en-US</SystemLocale>
            <UILanguage>en-US</UILanguage>
            <UserLocale>en-US</UserLocale>
        </component>
    </settings>
</unattend>
"@

    if ($PSCmdlet.ShouldProcess($OutputPath, "Create autounattend.xml file")) {
        try {
            $xmlContent | Out-File -FilePath $OutputPath -Encoding UTF8 -Force
            Write-Host "  [OK] Generated autounattend.xml at: $OutputPath" -ForegroundColor Green
            Write-Host "  To use: Place this file at the root of your Windows 11 installation USB." -ForegroundColor Yellow
            if (-not [string]::IsNullOrWhiteSpace($WinnowConfigPath)) {
                Write-Host "  Winnow first-boot run is embedded. Place Winnow-Standalone.ps1 at C:\Winnow\ before running setup." -ForegroundColor DarkGray
            }
        } catch {
            Write-Host "  [WARN] Failed to generate XML: $_" -ForegroundColor Yellow
        }
    }

    Write-Host ""
}

function Show-UnattendGeneratorPrompt {
    [CmdletBinding()]
    param()

    Write-Host ""
    Write-Host "=== Winnow Unattend XML Generator ===" -ForegroundColor Cyan
    Write-Host "Generates an autounattend.xml for automated Windows 11 setup." -ForegroundColor DarkGray
    Write-Host ""

    $outputPath = Read-Host "Output path [default: C:\autounattend.xml]"
    if ([string]::IsNullOrWhiteSpace($outputPath)) { $outputPath = "C:\autounattend.xml" }

    $configPath = Read-Host "Winnow config path to embed for first-boot (leave blank to skip)"
    $adminName  = Read-Host "Local admin account name to create (leave blank to skip)"
    $pcName     = Read-Host "Computer name (leave blank for random)"

    Generate-UnattendXML -OutputPath $outputPath `
        -WinnowConfigPath $configPath `
        -LocalAdminName $adminName `
        -ComputerName $pcName
}
