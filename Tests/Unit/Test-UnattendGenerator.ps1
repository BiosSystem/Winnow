#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
.SYNOPSIS
    Unit tests for the unattend.xml generator, focused on XML-escaping user input.
.DESCRIPTION
    ComputerName, LocalAdminName, and the embedded Winnow config path are all user supplied and go
    into the generated autounattend.xml. Any of them can legally contain & < or >, which must be
    XML-escaped or Windows Setup silently rejects the file.
#>

BeforeAll {
    $repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    . (Join-Path $repoRoot 'Scripts\Features\UnattendGenerator.ps1')

    function New-UnattendXml {
        param([hashtable]$Parameters)
        $out = Join-Path $TestDrive ('unattend-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.xml')
        Generate-UnattendXML @Parameters -OutputPath $out -Confirm:$false 6>$null | Out-Null
        return $out
    }
}

Describe 'Generate-UnattendXML' {

    It 'produces valid XML when the config path contains XML special characters' {
        $path = New-UnattendXml -Parameters @{ WinnowConfigPath = 'C:\Games & Config\<win>.json' }
        { [xml](Get-Content -LiteralPath $path -Raw) } | Should -Not -Throw
    }

    It 'escapes the embedded config path' {
        $path = New-UnattendXml -Parameters @{ WinnowConfigPath = 'C:\A & B\c.json' }
        $raw = Get-Content -LiteralPath $path -Raw
        $raw | Should -Match 'A &amp; B'
        $raw | Should -Not -Match 'A & B'
    }

    It 'produces valid XML when the computer name and admin name contain special characters' {
        $path = New-UnattendXml -Parameters @{ ComputerName = 'PC&1'; LocalAdminName = 'Ad<min>' }
        { [xml](Get-Content -LiteralPath $path -Raw) } | Should -Not -Throw
    }

    It 'produces valid XML for the default (no optional inputs)' {
        $path = New-UnattendXml -Parameters @{}
        { [xml](Get-Content -LiteralPath $path -Raw) } | Should -Not -Throw
    }
}
