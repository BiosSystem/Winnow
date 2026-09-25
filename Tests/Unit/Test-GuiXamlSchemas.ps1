#Requires -Modules Pester
<#
.SYNOPSIS
    Loads every WPF schema the GUI uses and asserts it constructs.
.DESCRIPTION
    Winnow builds its windows at run time with XamlReader.Load over the files in
    Schemas. A malformed element, a bad attribute, or a type that does not exist
    throws only when that window is opened, which no automated test did. This
    loads each schema the same way the app does and fails if any does not build.

    XamlReader needs a single-threaded-apartment thread. The unit suite runs
    under pwsh, which is multi-threaded by default, so each load runs in its own
    STA runspace. That also isolates the WPF assemblies from the test host.
#>

BeforeAll {
    $script:schemasDir = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')) 'Schemas'

    function Test-XamlLoads {
        param([string]$Path)

        $runspace = [runspacefactory]::CreateRunspace()
        $runspace.ApartmentState = 'STA'
        $runspace.ThreadOptions = 'ReuseThread'
        $runspace.Open()
        try {
            $shell = [powershell]::Create()
            $shell.Runspace = $runspace
            [void]$shell.AddScript({
                    param($xamlPath)
                    try {
                        Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
                        $markup = Get-Content -LiteralPath $xamlPath -Raw
                        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($markup))
                        try {
                            $object = [System.Windows.Markup.XamlReader]::Load($reader)
                        }
                        finally {
                            $reader.Dispose()
                        }
                        if ($null -eq $object) { return 'XamlReader.Load returned nothing' }
                        return 'OK'
                    }
                    catch {
                        return $_.Exception.Message
                    }
                }).AddArgument($Path)
            $result = $shell.Invoke()
            $shell.Dispose()
            return $result[0]
        }
        finally {
            $runspace.Dispose()
        }
    }
}

Describe 'GUI XAML schemas' {

    It 'has schema files to load' {
        @(Get-ChildItem -LiteralPath $script:schemasDir -Filter '*.xaml').Count | Should -BeGreaterThan 0
    }

    It 'loads <Name> through XamlReader' -TestCases @(
        Get-ChildItem -LiteralPath (Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..\..')) 'Schemas') -Filter '*.xaml' |
            ForEach-Object { @{ Name = $_.Name; Path = $_.FullName } }
    ) {
        param($Name, $Path)
        Test-XamlLoads -Path $Path | Should -Be 'OK'
    }
}
