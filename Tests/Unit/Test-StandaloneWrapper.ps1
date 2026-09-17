#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    $script:buildOutput = Join-Path ([System.IO.Path]::GetTempPath()) ("Winnow-Standalone-test_" + [Guid]::NewGuid().ToString('N') + '.ps1')
    & (Join-Path $repoRoot 'build.ps1') -OutputFile $script:buildOutput | Out-Null
    $script:wrapper = Get-Content -LiteralPath $script:buildOutput -Raw
}

AfterAll {
    if ($script:buildOutput -and (Test-Path -LiteralPath $script:buildOutput)) {
        Remove-Item -LiteralPath $script:buildOutput -Force -ErrorAction SilentlyContinue
    }
}

Describe 'Winnow standalone wrapper' {
    It 'parses without errors' {
        $parseErrors = $null
        $tokens = $null
        [System.Management.Automation.Language.Parser]::ParseFile($script:buildOutput, [ref]$tokens, [ref]$parseErrors) | Out-Null
        @($parseErrors).Count | Should -Be 0
    }

    It 'checks for admin rights and elevates through RunAs' {
        $script:wrapper | Should -Match 'Test-StandaloneAdmin'
        $script:wrapper | Should -Match '-Verb RunAs'
    }

    It 'elevates before it extracts the payload' {
        # The whole point of the fix: the admin gate must come before extraction,
        # or an elevated run would still read its scripts from a user-writable dir.
        $guardIndex = $script:wrapper.IndexOf('if (-not (Test-StandaloneAdmin))')
        $extractIndex = $script:wrapper.IndexOf('Expand-Archive')
        $guardIndex | Should -BeGreaterThan -1
        $extractIndex | Should -BeGreaterThan -1
        $guardIndex | Should -BeLessThan $extractIndex
    }

    It 'locks the extraction directory to administrators and system' {
        $script:wrapper | Should -Match 'SetAccessRuleProtection'
        $script:wrapper | Should -Match 'Set-StandaloneSecureDirectoryAcl'
        # S-1-5-18 SYSTEM and S-1-5-32-544 Administrators, and no Users SID.
        $script:wrapper | Should -Match 'S-1-5-18'
        $script:wrapper | Should -Match 'S-1-5-32-544'
    }

    It 'names the extraction directory with a full guid' {
        $script:wrapper | Should -Match "ToString\('N'\)"
        $script:wrapper | Should -Not -Match "Substring\(0,\s*8\)"
    }
}
