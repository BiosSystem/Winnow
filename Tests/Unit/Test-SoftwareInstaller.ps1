#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Unit tests for the winget install argument builder.
.DESCRIPTION
    The package id must be passed to winget as a discrete argument so a crafted id cannot inject
    extra winget flags. These assert the id stays a single element regardless of its content.
#>

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $repoRoot 'Scripts\Features\SoftwareInstaller.ps1')
}

Describe 'Get-WingetInstallArguments' {

    It 'places the package id as one discrete argument right after --id' {
        $result = Get-WingetInstallArguments -PackageId '7zip.7zip'
        $idIndex = [array]::IndexOf($result, '--id')
        $idIndex | Should -BeGreaterThan -1
        $result[$idIndex + 1] | Should -Be '7zip.7zip'
    }

    It 'keeps a crafted id with quotes and flags as a single element (no injection)' {
        $malicious = 'Evil.Id" --uninstall "Something'
        $result = Get-WingetInstallArguments -PackageId $malicious
        $result | Should -Contain $malicious
        # The crafted text must not appear split into separate winget flags.
        @($result | Where-Object { $_ -eq '--uninstall' }).Count | Should -Be 0
        $idIndex = [array]::IndexOf($result, '--id')
        $result[$idIndex + 1] | Should -Be $malicious
    }

    It 'includes the expected fixed flags' {
        $result = Get-WingetInstallArguments -PackageId 'x'
        $result | Should -Contain 'install'
        $result | Should -Contain '-e'
        $result | Should -Contain '--silent'
        $result | Should -Contain '--accept-package-agreements'
        $result | Should -Contain '--accept-source-agreements'
    }
}
