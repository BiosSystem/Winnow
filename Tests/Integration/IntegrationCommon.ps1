# Shared helpers for the Winnow integration suite.
#
# Unit tests exercise functions in isolation. These tests run Winnow.ps1 as a
# real process, which is the only way to cover startup guards, parameter
# binding, config loading, and exit codes together.

function Get-WinnowRepoRoot {
    return (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
}

function Test-IsElevated {
    return ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

<#
    .SYNOPSIS
    Runs Winnow.ps1 as a child process and captures its result.

    .DESCRIPTION
    stdin is redirected and closed so the run can never block on a prompt. A
    test that hangs is worse than one that fails, so every invocation is bounded
    by TimeoutSeconds and reports TimedOut rather than stalling the suite.

    .PARAMETER Arguments
    Arguments passed through to Winnow.ps1.

    .PARAMETER TimeoutSeconds
    How long to wait before killing the process. Defaults to 120.
#>
function Invoke-WinnowProcess {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,
        [int]$TimeoutSeconds = 120
    )

    $entryScript = Join-Path (Get-WinnowRepoRoot) 'Winnow.ps1'

    $quoted = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $entryScript))
    foreach ($argument in $Arguments) {
        $quoted += if ($argument -match '[\s"]') { '"{0}"' -f ($argument -replace '"', '\"') } else { $argument }
    }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'powershell.exe'
    $psi.Arguments = ($quoted -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true
    $psi.UseShellExecute = $false

    $process = [System.Diagnostics.Process]::Start($psi)
    $process.StandardInput.Close()

    # Read stdout before waiting so a large amount of output cannot fill the
    # pipe buffer and deadlock the child.
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()

    $exited = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $exited) {
        try { $process.Kill() } catch { }
        return [PSCustomObject]@{
            ExitCode = $null
            Stdout = $stdout
            Stderr = $stderr
            TimedOut = $true
        }
    }

    return [PSCustomObject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdout
        Stderr = $stderr
        TimedOut = $false
    }
}

<#
    .SYNOPSIS
    Reads the current values of every SetValue operation in a .reg file.

    .DESCRIPTION
    Returns a map of "path\name" to its current value, or $null where the value
    is absent. Comparing two of these across a run is how the dry-run tests
    prove that nothing was written: the assertion targets the exact values the
    feature would have changed rather than a general sweep of the registry.
#>
function Get-RegFileValueSnapshot {
    param(
        [Parameter(Mandatory)]
        [string]$RegFilePath
    )

    $snapshot = @{}
    foreach ($operation in @(Get-RegFileOperations -regFilePath $RegFilePath)) {
        if ($operation.OperationType -ne 'SetValue') { continue }

        $psPath = $operation.KeyPath `
            -replace '^HKEY_LOCAL_MACHINE', 'HKLM:' `
            -replace '^HKEY_CURRENT_USER', 'HKCU:' `
            -replace '^HKEY_CLASSES_ROOT', 'HKCR:' `
            -replace '^HKEY_USERS', 'HKU:'

        # Only the hives with a default PSDrive are readable here; anything else
        # is skipped rather than guessed at.
        if ($psPath -notmatch '^(HKLM|HKCU):') { continue }

        # A .reg default value (@) has an empty name, which Get-ItemProperty
        # cannot address by name.
        if ([string]::IsNullOrEmpty($operation.ValueName)) { continue }

        $key = '{0}\{1}' -f $psPath, $operation.ValueName
        $current = $null
        try {
            $item = Get-ItemProperty -LiteralPath $psPath -Name $operation.ValueName -ErrorAction Stop
            $current = $item.$($operation.ValueName)
        }
        catch {
            $current = $null
        }

        $snapshot[$key] = $current
    }

    return $snapshot
}

function Compare-RegValueSnapshot {
    param(
        [Parameter(Mandatory)][hashtable]$Before,
        [Parameter(Mandatory)][hashtable]$After
    )

    $changed = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $Before.Keys) {
        $old = $Before[$key]
        $new = $After[$key]
        if ("$old" -ne "$new") {
            $changed.Add(('{0}: [{1}] -> [{2}]' -f $key, $old, $new))
        }
    }

    return @($changed)
}

<#
    Puts every value a .reg file sets back to what a Get-RegFileValueSnapshot of
    that file recorded: values that were absent are removed, the rest are written
    back with the type the .reg file declares. Mutating tests share one Sandbox
    registry, so a test that leaves an apply in place (no backup, or rollback
    disabled on purpose) must not change what the next test starts from.
#>
function Restore-RegFileValueSnapshot {
    param(
        [Parameter(Mandatory)][string]$RegFilePath,
        [Parameter(Mandatory)][hashtable]$Snapshot
    )

    foreach ($operation in @(Get-RegFileOperations -regFilePath $RegFilePath)) {
        if ($operation.OperationType -ne 'SetValue') { continue }

        $psPath = $operation.KeyPath `
            -replace '^HKEY_LOCAL_MACHINE', 'HKLM:' `
            -replace '^HKEY_CURRENT_USER', 'HKCU:'
        if ($psPath -notmatch '^(HKLM|HKCU):') { continue }
        if ([string]::IsNullOrEmpty($operation.ValueName)) { continue }

        $key = '{0}\{1}' -f $psPath, $operation.ValueName
        if (-not $Snapshot.ContainsKey($key)) { continue }

        $original = $Snapshot[$key]
        if ($null -eq $original) {
            Remove-ItemProperty -LiteralPath $psPath -Name $operation.ValueName -ErrorAction SilentlyContinue
            continue
        }

        $type = switch ([string]$operation.ValueType) {
            'DWord' { 'DWord' }
            'QWord' { 'QWord' }
            'Binary' { 'Binary' }
            'Hex2' { 'ExpandString' }
            'Hex7' { 'MultiString' }
            default { 'String' }
        }
        if (-not (Test-Path -LiteralPath $psPath)) {
            New-Item -Path $psPath -Force | Out-Null
        }
        Set-ItemProperty -LiteralPath $psPath -Name $operation.ValueName -Value $original -Type $type -Force
    }
}
