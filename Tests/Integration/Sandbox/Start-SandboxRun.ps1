<#
.SYNOPSIS
    Bootstraps and runs the mutating integration suite inside Windows Sandbox.
.DESCRIPTION
    Launched by Winnow-Tests.wsb. Installs Pester, copies the repository out
    of the read-only mapped folder so the tests can write alongside it, runs the
    full suite, and writes the results to the mapped output folder.

    Everything inside the sandbox is destroyed when the window closes, console
    output included, so the results folder is the only thing that survives. A
    transcript goes there too, which is what makes a failed bootstrap
    diagnosable after the fact.
#>
$ErrorActionPreference = 'Stop'

$resultRoot = 'C:\Winnow-Results'
$transcript = $null

if (Test-Path -LiteralPath $resultRoot) {
    $transcript = Join-Path $resultRoot 'sandbox-transcript.log'
    try { Start-Transcript -Path $transcript -Force | Out-Null } catch { }
}

Write-Host 'Winnow integration suite, Windows Sandbox' -ForegroundColor Cyan
Write-Host ''

$exitCode = 1
$runStart = Get-Date
try {
    if (-not (Test-Path -LiteralPath $resultRoot)) {
        throw "The results folder is not mapped at $resultRoot. Check the second MappedFolder in Winnow-Tests.wsb, and that its HostFolder exists on the host."
    }

    $source = 'C:\Winnow'
    $working = 'C:\Winnow-Run'

    if (-not (Test-Path -LiteralPath $source)) {
        throw "The repository is not mapped at $source. Check HostFolder in Winnow-Tests.wsb."
    }

    # The mapped folder is read-only by design. Tests need a writable tree, and
    # a copy also guarantees the host working tree cannot be touched.
    Write-Host 'Copying repository to a writable location...'
    Copy-Item -LiteralPath $source -Destination $working -Recurse -Force

    Write-Host 'Installing Pester 5.7.1...'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    Install-Module Pester -RequiredVersion 5.7.1 -Force -SkipPublisherCheck -Scope CurrentUser

    Write-Host ''
    Write-Host 'Running the full suite, including mutating tests...' -ForegroundColor Yellow
    Write-Host ''

    # The suite reports failing tests through its exit code, not by throwing, so a
    # normal test failure is judged here rather than landing in the catch below.
    & "$working\Tests\Integration\Invoke-IntegrationTests.ps1" -Mutating -ResultPath $resultRoot
    $exitCode = $LASTEXITCODE

    Write-Host ''
    if ($exitCode -eq 0) {
        Write-Host 'Integration suite passed.' -ForegroundColor Green
    }
    else {
        Write-Host "Integration suite failed with exit code $exitCode." -ForegroundColor Red
    }
}
catch {
    Write-Host ''
    Write-Host "Sandbox run failed before the suite completed: $($_.Exception.Message)" -ForegroundColor Red

    # Record it in the results folder as well, so a bootstrap failure is not
    # invisible once the window is gone. Never replace a summary the suite wrote
    # during this run: that file holds the per-test results the run exists for.
    if (Test-Path -LiteralPath $resultRoot) {
        $summaryPath = Join-Path $resultRoot 'integration-summary.json'
        $suiteWroteSummary = (Test-Path -LiteralPath $summaryPath) -and
            ((Get-Item -LiteralPath $summaryPath).LastWriteTime -ge $runStart)
        $bootstrapPath = if ($suiteWroteSummary) { Join-Path $resultRoot 'bootstrap-error.json' } else { $summaryPath }

        [ordered]@{
            RanAt = (Get-Date).ToString('o')
            BootstrapError = $_.Exception.Message
            ScriptStackTrace = $_.ScriptStackTrace
        } | ConvertTo-Json -Depth 4 |
            Out-File -FilePath $bootstrapPath -Encoding UTF8 -Force
    }
}
finally {
    if ($transcript) { try { Stop-Transcript | Out-Null } catch { } }

    Write-Host ''
    Write-Host "Results were written to the host folder mapped at $resultRoot."
    Write-Host 'Everything else in this sandbox is discarded when you close the window.'
    Write-Host 'Press Enter to close.'
    [void](Read-Host)
}
