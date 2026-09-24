<#
.SYNOPSIS
    Runs the full integration suite, mutating tests included, in Windows Sandbox
    and prints the result.

.DESCRIPTION
    The committed Winnow-Tests.wsb has to carry absolute HostFolder paths, so it
    only works on a machine where the repository sits at exactly that path. This
    script writes an equivalent .wsb for wherever this clone lives, starts
    Windows Sandbox with it, waits for the harness inside the sandbox
    (Start-SandboxRun.ps1) to finish, and prints integration-summary.json.

    The repository is mapped read-only and only Tests\Integration\Sandbox\results
    is writable, exactly as in Winnow-Tests.wsb. Everything the mutating tests
    change happens inside the disposable sandbox.

    Only one sandbox can run at a time, and a sandbox started while the previous
    one's VM is still shutting down can boot without its mapped folders, in which
    case the harness never runs. So this refuses to start while a sandbox window
    is open, and waits for a closing VM to exit before launching.

.PARAMETER TimeoutMinutes
    How long to wait for the suite to finish once the harness has started.

.PARAMETER CloseWhenDone
    Close the sandbox once the results are in. By default it is left open so its
    console can still be read; close it before running this again.

.OUTPUTS
    Exit code 0 when every test passed, 1 when any test failed, 2 when the
    harness did not start or did not finish in time.

.EXAMPLE
    .\Tests\Integration\Sandbox\Invoke-SandboxRun.ps1 -CloseWhenDone
#>
[CmdletBinding()]
param(
    [int]$TimeoutMinutes = 30,
    [switch]$CloseWhenDone
)

$ErrorActionPreference = 'Stop'

$sandboxExe = Join-Path $env:WINDIR 'System32\WindowsSandbox.exe'
if (-not (Test-Path -LiteralPath $sandboxExe)) {
    throw 'Windows Sandbox is not enabled. Enable the Containers-DisposableClientVM optional feature and restart; see Tests\Integration\README.md.'
}

$sandboxDir = $PSScriptRoot
$repoRoot = (Resolve-Path (Join-Path $sandboxDir '..\..\..')).Path
$resultsDir = Join-Path $sandboxDir 'results'
if (-not (Test-Path -LiteralPath $resultsDir)) {
    New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null
}

$windowProcesses = @('WindowsSandboxRemoteSession', 'WindowsSandboxServer')
if (@(Get-Process -Name $windowProcesses -ErrorAction SilentlyContinue).Count -gt 0) {
    throw 'A Windows Sandbox is already running. Close it, then run this again.'
}

# A VM that is still shutting down has no window left, only its memory process.
$teardownDeadline = (Get-Date).AddMinutes(10)
if (@(Get-Process -Name 'vmmemWindowsSandbox' -ErrorAction SilentlyContinue).Count -gt 0) {
    Write-Host 'Waiting for the previous sandbox to finish shutting down...'
    while ((Get-Date) -lt $teardownDeadline -and @(Get-Process -Name 'vmmemWindowsSandbox' -ErrorAction SilentlyContinue).Count -gt 0) {
        Start-Sleep -Seconds 5
    }
    Start-Sleep -Seconds 30
}

$escape = { param($text) [System.Security.SecurityElement]::Escape($text) }
$wsb = @"
<Configuration>
  <MappedFolders>
    <MappedFolder>
      <HostFolder>$(& $escape $repoRoot)</HostFolder>
      <SandboxFolder>C:\Winnow</SandboxFolder>
      <ReadOnly>true</ReadOnly>
    </MappedFolder>
    <MappedFolder>
      <HostFolder>$(& $escape $resultsDir)</HostFolder>
      <SandboxFolder>C:\Winnow-Results</SandboxFolder>
      <ReadOnly>false</ReadOnly>
    </MappedFolder>
  </MappedFolders>
  <LogonCommand>
    <Command>powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Winnow\Tests\Integration\Sandbox\Start-SandboxRun.ps1</Command>
  </LogonCommand>
  <MemoryInMB>4096</MemoryInMB>
  <Networking>Enable</Networking>
</Configuration>
"@
$wsbPath = Join-Path $env:TEMP ('Winnow-Tests-{0}.wsb' -f [guid]::NewGuid().ToString('N'))
Set-Content -LiteralPath $wsbPath -Value $wsb -Encoding UTF8

$summaryPath = Join-Path $resultsDir 'integration-summary.json'
$transcriptPath = Join-Path $resultsDir 'sandbox-transcript.log'
$bootstrapPath = Join-Path $resultsDir 'bootstrap-error.json'

function Test-WrittenSince {
    param([string]$Path, [datetime]$Since)
    (Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path).LastWriteTime -gt $Since)
}

try {
    $launch = Get-Date
    Write-Host "Starting Windows Sandbox for $repoRoot"
    Start-Process -FilePath $sandboxExe -ArgumentList ('"{0}"' -f $wsbPath)

    # The harness writes its transcript within seconds of the sandbox logging on.
    $startDeadline = (Get-Date).AddMinutes(6)
    while ((Get-Date) -lt $startDeadline -and -not (Test-WrittenSince -Path $transcriptPath -Since $launch)) {
        Start-Sleep -Seconds 10
    }
    if (-not (Test-WrittenSince -Path $transcriptPath -Since $launch)) {
        Write-Host 'The test harness did not start inside the sandbox. Check the sandbox window.' -ForegroundColor Red
        exit 2
    }
    Write-Host 'Harness started. Running the suite...'

    $finishDeadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $finishDeadline -and -not (Test-WrittenSince -Path $summaryPath -Since $launch)) {
        Start-Sleep -Seconds 15
    }
    if (-not (Test-WrittenSince -Path $summaryPath -Since $launch)) {
        Write-Host "No results after $TimeoutMinutes minutes. The transcript is at $transcriptPath." -ForegroundColor Red
        exit 2
    }
    Start-Sleep -Seconds 2

    $summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
    Write-Host ''
    if ($summary.PSObject.Properties['BootstrapError']) {
        Write-Host "The harness failed before the suite ran: $($summary.BootstrapError)" -ForegroundColor Red
        exit 2
    }

    $color = if ([int]$summary.Failed -eq 0) { 'Green' } else { 'Red' }
    Write-Host ("Integration suite: {0} passed, {1} failed, {2} skipped, {3} total." -f
        $summary.Passed, $summary.Failed, $summary.Skipped, $summary.Total) -ForegroundColor $color
    foreach ($failure in @($summary.Failures)) {
        Write-Host "  FAILED: $($failure.Name)" -ForegroundColor Red
        Write-Host "          $(($failure.Message -split "`n")[0])"
    }
    foreach ($block in @($summary.BlockFailures)) {
        Write-Host "  SETUP FAILED: $($block.Name): $($block.Message)" -ForegroundColor Red
    }
    if (Test-WrittenSince -Path $bootstrapPath -Since $launch) {
        Write-Host "  The harness also reported an error after the suite: see $bootstrapPath" -ForegroundColor Yellow
    }
    Write-Host "Results: $resultsDir"

    if ([int]$summary.Failed -eq 0) { exit 0 } else { exit 1 }
}
finally {
    Remove-Item -LiteralPath $wsbPath -Force -ErrorAction SilentlyContinue
    if ($CloseWhenDone) {
        Get-Process -Name $windowProcesses -ErrorAction SilentlyContinue | Stop-Process -Force
    }
}
