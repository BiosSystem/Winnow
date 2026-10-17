#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for ConvertTo-ParameterList.
.DESCRIPTION
    powershell.exe -File binds "-Undo A,B" to a [string[]] parameter as the one
    value "A,B", so -Undo and -SoftwareList split their values before use. The
    last test reproduces that binding in a child process, which is the reason
    the helper exists.
#>

BeforeAll {
    $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
    . (Join-Path $script:repoRoot 'Scripts\Helpers\ConvertTo-ParameterList.ps1')
}

Describe 'ConvertTo-ParameterList' {
    It 'splits a single comma-separated value into separate items' {
        $result = @(ConvertTo-ParameterList 'DisableTelemetry,DisableCopilot')
        $result.Count | Should -Be 2
        $result[0] | Should -Be 'DisableTelemetry'
        $result[1] | Should -Be 'DisableCopilot'
    }

    It 'passes an already separated array through unchanged' {
        $result = @(ConvertTo-ParameterList @('DisableTelemetry', 'DisableCopilot'))
        $result | Should -Be @('DisableTelemetry', 'DisableCopilot')
    }

    It 'handles a mix of separated and comma-joined entries in order' {
        $result = @(ConvertTo-ParameterList @('A,B', 'C'))
        $result | Should -Be @('A', 'B', 'C')
    }

    It 'trims whitespace and drops empty entries' {
        $result = @(ConvertTo-ParameterList ' A , ,B ,')
        $result | Should -Be @('A', 'B')
    }

    It 'returns nothing for null or empty input' {
        @(ConvertTo-ParameterList $null).Count | Should -Be 0
        @(ConvertTo-ParameterList @()).Count | Should -Be 0
        @(ConvertTo-ParameterList '').Count | Should -Be 0
    }

    It 'keeps a single value as one item' {
        @(ConvertTo-ParameterList 'DisableTelemetry') | Should -Be @('DisableTelemetry')
    }

    It 'recovers the separate values that powershell.exe -File fuses into one' {
        $probe = Join-Path $TestDrive 'bind-probe.ps1'
        Set-Content -LiteralPath $probe -Encoding utf8 -Value @(
            'param([string[]]$Undo)'
            ('. "{0}"' -f (Join-Path $script:repoRoot 'Scripts\Helpers\ConvertTo-ParameterList.ps1'))
            'Write-Output ("raw={0}" -f @($Undo).Count)'
            'Write-Output ("split={0}" -f @(ConvertTo-ParameterList $Undo).Count)'
        )

        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probe -Undo 'DisableTelemetry,DisableCopilot'

        $output | Should -Contain 'raw=1' -Because '-File binds the comma list as one value'
        $output | Should -Contain 'split=2'
    }
}
