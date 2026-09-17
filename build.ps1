param (
    [string]$SourceFolder = "$PSScriptRoot",
    [string]$OutputFile = "$PSScriptRoot\Winnow-Standalone.ps1"
)

Write-Host "Building Winnow Standalone..." -ForegroundColor Cyan

# 1. Zip the required files
$TempZip = "$env:TEMP\Winnow_Build.zip"
if (Test-Path $TempZip) { Remove-Item $TempZip -Force }

$IncludeItems = @(
    "Assets",
    "Config",
    "Regfiles",
    "Schemas",
    "Scripts",
    "Winnow.ps1",
    "Run.bat"
)

Write-Host "Compressing files..."
$ItemsToZip = $IncludeItems | ForEach-Object { Join-Path $SourceFolder $_ }
Compress-Archive -Path $ItemsToZip -DestinationPath $TempZip -Force

# 2. Convert Zip to Base64
Write-Host "Converting to Base64..."
$Bytes = [System.IO.File]::ReadAllBytes($TempZip)
$Base64String = [System.Convert]::ToBase64String($Bytes)

# 3. Create the Standalone Script Wrapper
Write-Host "Generating Standalone Wrapper..."

$WrapperCode = @"
<#
.SYNOPSIS
    Winnow Standalone Executable
.DESCRIPTION
    This script extracts the Winnow payload to a temporary directory and executes it.
#>

`$VerbosePreference = 'SilentlyContinue'

function Format-StandaloneArg {
    param([AllowEmptyString()][string]`$Value)

    `$escaped = `$Value -replace '(\\*)"', '`$1`$1\"'
    `$escaped = `$escaped -replace '(\\+)$', '`$1`$1'
    return '"' + `$escaped + '"'
}

function Test-StandaloneAdmin {
    return ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Set-StandaloneSecureDirectoryAcl {
    # Lock the extraction directory to Administrators and SYSTEM before any payload
    # lands in it. Winnow dot-sources roughly a hundred files from here while running
    # elevated; without this a standard user could swap one of those files after
    # extraction and have it execute with the elevated process's rights. Inheritance
    # is turned off so the user's writable %TEMP% ACL does not carry in.
    param([string]`$Path)

    `$acl = New-Object System.Security.AccessControl.DirectorySecurity
    `$acl.SetAccessRuleProtection(`$true, `$false)
    `$full = [System.Security.AccessControl.FileSystemRights]::FullControl
    `$inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    `$noProp = [System.Security.AccessControl.PropagationFlags]::None
    `$allow = [System.Security.AccessControl.AccessControlType]::Allow
    `$system = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-18'
    `$admins = New-Object System.Security.Principal.SecurityIdentifier 'S-1-5-32-544'
    `$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(`$system, `$full, `$inherit, `$noProp, `$allow)))
    `$acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(`$admins, `$full, `$inherit, `$noProp, `$allow)))
    Set-Acl -LiteralPath `$Path -AclObject `$acl
}

# Payload (Base64 Zip)
`$processExitCode = 1
`$Payload = "$Base64String"

# Elevate before extracting. If a non-elevated process extracted the payload and
# then Winnow relaunched itself elevated, the elevated run would read its scripts
# from a directory the standard user still controls, which is a local privilege
# escalation. Elevating first means extraction and every dot-sourced file live in
# an admin-only directory for the whole run.
if (-not (Test-StandaloneAdmin)) {
    `$selfPath = `$PSCommandPath
    if ([string]::IsNullOrEmpty(`$selfPath)) { `$selfPath = `$MyInvocation.MyCommand.Definition }

    `$relaunchArgs = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Format-StandaloneArg `$selfPath))
    foreach (`$argument in `$args) {
        `$relaunchArgs += (Format-StandaloneArg ([string]`$argument))
    }

    try {
        `$elevated = Start-Process -FilePath "powershell.exe" -ArgumentList `$relaunchArgs -Verb RunAs -Wait -PassThru -ErrorAction Stop
        `$processExitCode = `$elevated.ExitCode
    }
    catch {
        Write-Error "Winnow needs administrator rights, and elevation was cancelled or failed: `$_"
        `$processExitCode = 1
    }
    exit `$processExitCode
}

# Elevated from here. A full GUID gives a non-guessable directory name, and the
# locked ACL closes the tamper window for the rest of the run.
`$ExtractPath = Join-Path `$env:TEMP "Winnow_Run_`$([Guid]::NewGuid().ToString('N'))"

try {
    New-Item -ItemType Directory -Path `$ExtractPath -Force | Out-Null
    Set-StandaloneSecureDirectoryAcl -Path `$ExtractPath

    `$ZipPath = Join-Path `$ExtractPath "payload.zip"
    `$Bytes = [System.Convert]::FromBase64String(`$Payload)
    [System.IO.File]::WriteAllBytes(`$ZipPath, `$Bytes)

    Expand-Archive -Path `$ZipPath -DestinationPath `$ExtractPath -Force

    `$ScriptPath = Join-Path `$ExtractPath "Winnow.ps1"
    if (Test-Path `$ScriptPath) {
        `$ArgsList = @("-ExecutionPolicy", "Bypass", "-NoProfile", "-File", (Format-StandaloneArg `$ScriptPath))
        foreach (`$argument in `$args) {
            `$ArgsList += (Format-StandaloneArg ([string]`$argument))
        }
        Write-Host "Launching Winnow..." -ForegroundColor Cyan
        `$process = Start-Process -FilePath "powershell.exe" -ArgumentList `$ArgsList -NoNewWindow -Wait -PassThru
        `$processExitCode = `$process.ExitCode
    } else {
        Write-Error "Failed to locate Winnow.ps1 in extracted payload."
    }
} catch {
    Write-Error "An error occurred while launching Winnow: `$_"
} finally {
    if (Test-Path `$ExtractPath) {
        Remove-Item `$ExtractPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

exit `$processExitCode
"@

# 4. Save to Output File
[System.IO.File]::WriteAllText($OutputFile, $WrapperCode)
Remove-Item $TempZip -Force

Write-Host "Build complete! Standalone script saved to: $OutputFile" -ForegroundColor Green
