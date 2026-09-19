<#
.SYNOPSIS
    Compiles the Winnow launcher (Winnow.cs) into Winnow.exe.

.DESCRIPTION
    The launcher is the .exe entry point winget requires. It is compiled from
    source at build/release time with the C# compiler that ships in the .NET
    Framework, so no compiler needs installing on the build machine and no
    prebuilt binary is committed.

    The release workflow can call this and drop the resulting Winnow.exe into
    the release zip so the winget manifest's RelativeFilePath (Winnow.exe)
    resolves. It is not part of the default build; it is opt-in for the winget
    distribution path.

.PARAMETER OutputPath
    Where Winnow.exe is written. Defaults to next to this script.
#>
[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'Winnow.exe')
)

$ErrorActionPreference = 'Stop'

$source = Join-Path $PSScriptRoot 'Winnow.cs'
if (-not (Test-Path -LiteralPath $source)) { throw "Launcher source not found at $source" }

$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $csc)) {
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
}
if (-not (Test-Path -LiteralPath $csc)) {
    throw "The .NET Framework C# compiler (csc.exe) was not found. It ships with the .NET Framework 4.x on Windows."
}

Write-Host "Compiling $source -> $OutputPath"
& $csc /nologo /target:exe /platform:anycpu /optimize+ "/out:$OutputPath" $source
if ($LASTEXITCODE -ne 0) { throw "csc.exe failed with exit code $LASTEXITCODE" }

if (-not (Test-Path -LiteralPath $OutputPath)) { throw 'Compilation reported success but Winnow.exe was not produced.' }
Write-Host "Built $OutputPath"
