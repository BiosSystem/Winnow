<#
.SYNOPSIS
    Runs the Winnow integration suite with a tag filter chosen by risk.

.DESCRIPTION
    Integration tests run Winnow.ps1 as a real process, so they are gated by
    what they can do to the machine running them:

      ReadOnly   The -Verify path. Reads state and exits before applying
                 anything, so it cannot write even if the engine regresses.
                 Safe anywhere. This is the default.

      DryRun     Asserts that -DryRun writes nothing. A regression in the
                 dry-run guard would write to this host, so it needs an
                 ephemeral machine: a CI runner or Windows Sandbox.

      Mutating   Deliberately applies changes. Windows Sandbox only.

    Nothing beyond ReadOnly runs unless you ask for it.

.PARAMETER Ephemeral
    Adds the DryRun tag. Use on CI runners and inside Sandbox.

.PARAMETER Mutating
    Adds the Mutating tag. Implies -Ephemeral. Windows Sandbox only.

.PARAMETER PassThru
    Returns the Pester result object instead of exiting.

.PARAMETER ResultPath
    Directory to write a NUnit XML result file and a JSON summary to. Use this
    when the run happens somewhere the console output cannot be read afterwards,
    such as inside Windows Sandbox, which discards everything on close.

.EXAMPLE
    .\Invoke-IntegrationTests.ps1
    Read-only checks. Safe on a workstation.

.EXAMPLE
    .\Invoke-IntegrationTests.ps1 -Mutating
    The full suite. Only do this in Windows Sandbox.
#>
[CmdletBinding()]
param(
    [switch]$Ephemeral,
    [switch]$Mutating,
    [switch]$PassThru,
    [string]$ResultPath
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [version]'5.0.0' })) {
    throw 'The integration suite requires Pester 5. Install it with: Install-Module Pester -MinimumVersion 5.7.1 -Force -SkipPublisherCheck -Scope CurrentUser'
}

Import-Module Pester -MinimumVersion 5.7.1 -ErrorAction Stop

$tags = @('ReadOnly')
if ($Ephemeral -or $Mutating) { $tags += 'DryRun' }
if ($Mutating) { $tags += 'Mutating' }

$isElevated = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host ''
Write-Host 'Winnow integration suite' -ForegroundColor Cyan
Write-Host ("  tags     : {0}" -f ($tags -join ', '))
Write-Host ("  elevated : {0}" -f $isElevated)
if (-not $isElevated) {
    Write-Host '  Winnow refuses to run without elevation, so most cases will skip.' -ForegroundColor Yellow
}
if ($Mutating) {
    Write-Host '  MUTATING: this will change the registry of this machine.' -ForegroundColor Red
}
Write-Host ''

$configuration = New-PesterConfiguration
$configuration.Run.Path = $PSScriptRoot
$configuration.Filter.Tag = $tags
$configuration.Output.Verbosity = 'Detailed'
$configuration.Run.PassThru = $true

if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
    if (-not (Test-Path -LiteralPath $ResultPath)) {
        New-Item -ItemType Directory -Path $ResultPath -Force | Out-Null
    }
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputPath = Join-Path $ResultPath 'integration-results.xml'
    Write-Host ("  results  : {0}" -f $ResultPath)
}

$result = $null
try {
    $result = Invoke-Pester -Configuration $configuration
}
catch {
    # Discovery problems surface here, for example when no file matches
    # *.Tests.ps1. Left unhandled these produce an empty result that reads as a
    # pass, so they have to be turned into a hard failure.
    Write-Error ("The integration suite could not run: {0}" -f $_.Exception.Message)
    if ($PassThru) { return $null }
    exit 1
}

# A suite that discovered nothing is a failure, not a pass. Without this a
# rename or a bad filter silently reports success.
if ($null -eq $result -or $result.TotalCount -eq 0) {
    Write-Error ("No integration tests were discovered for tag(s): {0}. Test files must be named *.Tests.ps1." -f ($tags -join ', '))
    if ($PassThru) { return $result }
    exit 1
}

Write-Host ''
Write-Host ("Integration suite: {0} passed, {1} failed, {2} skipped, {3} total." -f
    $result.PassedCount, $result.FailedCount, $result.SkippedCount, $result.TotalCount)

if (-not [string]::IsNullOrWhiteSpace($ResultPath)) {
    # A readable summary alongside the XML, including the name and message of
    # every failure, so a Sandbox run can be diagnosed after the window is gone.
    $failures = @($result.Tests | Where-Object { $_.Result -eq 'Failed' } | ForEach-Object {
        $message = (@($_.ErrorRecord) | ForEach-Object { $_.Exception.Message }) -join "`n"
        if ([string]::IsNullOrWhiteSpace($message)) {
            # A test that never ran because a BeforeAll above it failed carries no
            # error of its own; the cause is recorded under BlockFailures.
            $message = 'Did not run: a setup block above it failed. See BlockFailures.'
        }
        [ordered]@{
            Name = $_.ExpandedPath
            Message = $message
        }
    })

    # Failed BeforeAll/AfterAll blocks. Without these, a broken setup shows up
    # only as a list of tests that did not run, with the actual error in the
    # transcript.
    $blockFailures = @($result.FailedBlocks | ForEach-Object {
        [ordered]@{
            Name = $_.ExpandedPath
            Message = (@($_.ErrorRecord) | ForEach-Object { $_.Exception.Message }) -join "`n"
        }
    })

    [ordered]@{
        RanAt = (Get-Date).ToString('o')
        ComputerName = $env:COMPUTERNAME
        Tags = $tags
        Elevated = $isElevated
        Passed = $result.PassedCount
        Failed = $result.FailedCount
        Skipped = $result.SkippedCount
        Total = $result.TotalCount
        Failures = $failures
        BlockFailures = $blockFailures
    } | ConvertTo-Json -Depth 6 | Out-File -FilePath (Join-Path $ResultPath 'integration-summary.json') -Encoding UTF8 -Force

    Write-Host ("Results written to {0}" -f $ResultPath)
}

if ($PassThru) {
    return $result
}

if ($result.FailedCount -gt 0) {
    # Failing tests are a normal outcome, reported through the exit code. This
    # script runs under Stop, so Write-Error here would throw into the caller
    # (the Sandbox bootstrap) and read as the harness itself breaking.
    Write-Host ("{0} integration test(s) failed." -f $result.FailedCount) -ForegroundColor Red
    exit 1
}

exit 0
