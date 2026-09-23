#Requires -Modules Pester

Describe 'Registry files' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
        $script:regFiles = @(Get-ChildItem -Path (Join-Path $repoRoot 'Regfiles') -Filter '*.reg' -Recurse)
        $script:validHives = @(
            'HKEY_LOCAL_MACHINE',
            'HKEY_CURRENT_USER',
            'HKEY_CLASSES_ROOT',
            'HKEY_USERS',
            'HKEY_CURRENT_CONFIG'
        )
    }

    It 'finds registry files' {
        $script:regFiles.Count | Should -BeGreaterThan 0
    }

    It 'validates every registry file' {
        $failures = [System.Collections.Generic.List[string]]::new()

        foreach ($regFile in $script:regFiles) {
            $content = Get-Content -LiteralPath $regFile.FullName -Raw
            $lines = @(Get-Content -LiteralPath $regFile.FullName)

            if ([string]::IsNullOrWhiteSpace($content)) {
                $failures.Add("$($regFile.FullName): file is empty")
                continue
            }
            if ($lines.Count -eq 0 -or $lines[0].Trim() -ne 'Windows Registry Editor Version 5.00') {
                $failures.Add("$($regFile.FullName): invalid registry header")
            }
            if ($content -notmatch '(?m)^\[-?[^\]]+\]') {
                $failures.Add("$($regFile.FullName): no registry key section")
            }

            foreach ($keyLine in @($lines | Where-Object { $_ -match '^\[' })) {
                $stripped = $keyLine -replace '^\[-?', '' -replace '\]$', ''
                $hive = ($stripped -split '\\')[0]
                if ($script:validHives -notcontains $hive) {
                    $failures.Add("$($regFile.FullName): invalid hive '$hive'")
                }
            }
        }

        $failures | Should -BeNullOrEmpty -Because ($failures -join [Environment]::NewLine)
    }

    It 'ships a Sysprep variant for every root reg file that writes HKEY_CURRENT_USER' {
        # In Sysprep/User mode HKCU keys must target the offline Default hive
        # (hkey_users\default), so any tweak that writes HKEY_CURRENT_USER needs a
        # Sysprep variant. Without one the resolver falls back to the root file and
        # writes the live admin hive instead of the target user's.
        $root = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
        $regfilesRoot = Join-Path $root 'Regfiles'
        $missing = [System.Collections.Generic.List[string]]::new()

        foreach ($regFile in @(Get-ChildItem -Path $regfilesRoot -Filter '*.reg')) {
            $content = Get-Content -LiteralPath $regFile.FullName -Raw
            if ($content -match '(?im)^\[-?HKEY_CURRENT_USER\\') {
                $sysprepPath = Join-Path (Join-Path $regfilesRoot 'Sysprep') $regFile.Name
                if (-not (Test-Path -LiteralPath $sysprepPath)) {
                    $missing.Add($regFile.Name)
                }
            }
        }

        $missing | Should -BeNullOrEmpty -Because ('these HKCU reg files need a Regfiles\Sysprep variant: ' + ($missing -join ', '))
    }

    Context 'backup file encoding' {

        BeforeAll {
            $root = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
            . (Join-Path $root 'Scripts\FileIO\SaveToFile.ps1')
            $script:restoreSource = Get-Content (Join-Path $root 'Scripts\Features\RestoreRegistryBackup.ps1') -Raw
        }

        It 'reads backups as UTF8 rather than the ANSI codepage' {
            # Registry data can hold non-ASCII, an accented profile path for one.
            # SaveToFile writes a BOM so Winnow's own backups would read either
            # way, but a backup produced elsewhere has none.
            $script:restoreSource | Should -Match 'Get-Content -LiteralPath \$FilePath -Raw -Encoding UTF8'
        }

        It 'round-trips a non-ASCII registry value through a BOM-less backup' {
            $accented = 'C:\Users\Jos' + [char]0xE9 + '\AppData\Se' + [char]0xF1 + 'or'
            $path = Join-Path $TestDrive 'nobom.json'
            $json = @{ Version = '1'; RegistryKeys = @($accented) } | ConvertTo-Json -Depth 5
            [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding $false))

            $read = (Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json).RegistryKeys[0]

            $read | Should -Be $accented
        }

        It 'leaves the reg file reader alone, since those are UTF-16LE' {
            # Regedit writes .reg as UTF-16LE with a BOM. Get-Content detects it.
            # Forcing UTF8 there would corrupt every registry file in the repo.
            $root = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
            $regReader = Get-Content (Join-Path $root 'Scripts\Helpers\Get-RegFileOperations.ps1') -Raw
            $regReader | Should -Not -Match 'Get-Content.*-Encoding UTF8'

            $sample = Get-ChildItem (Join-Path $root 'Regfiles') -Filter *.reg | Select-Object -First 1
            $bytes = [System.IO.File]::ReadAllBytes($sample.FullName)
            "$($bytes[0]) $($bytes[1])" | Should -Be '255 254' -Because 'reg files are UTF-16LE with a BOM'
        }
    }
}

Describe 'Reg operation to value kind' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
        . (Join-Path $repoRoot 'Scripts\Helpers\ApplyRegistryRegFile.ps1')
    }

    It 'maps a DWord, preserving a high-bit value through the sign wrap' {
        $result = Convert-RegOperationToValueKind -Operation ([PSCustomObject]@{ ValueName = 'X'; ValueType = 'DWord'; ValueData = [uint32]'0xFFFFFFFF'; KeyPath = 'HKLM:\Test' })
        $result.Kind | Should -Be ([Microsoft.Win32.RegistryValueKind]::DWord)
        $result.Value | Should -Be (-1)
    }

    It 'maps a QWord, preserving a high-bit value' {
        $result = Convert-RegOperationToValueKind -Operation ([PSCustomObject]@{ ValueName = 'X'; ValueType = 'QWord'; ValueData = [uint64]18446744073709551615; KeyPath = 'HKLM:\Test' })
        $result.Kind | Should -Be ([Microsoft.Win32.RegistryValueKind]::QWord)
        $result.Value | Should -Be (-1)
    }

    It 'maps hex(2) to an expandable string' {
        $result = Convert-RegOperationToValueKind -Operation ([PSCustomObject]@{ ValueName = 'X'; ValueType = 'Hex2'; ValueData = '%SystemRoot%\test'; KeyPath = 'HKLM:\Test' })
        $result.Kind | Should -Be ([Microsoft.Win32.RegistryValueKind]::ExpandString)
        $result.Value | Should -Be '%SystemRoot%\test'
    }

    It 'maps hex(7) to a multi-string' {
        $result = Convert-RegOperationToValueKind -Operation ([PSCustomObject]@{ ValueName = 'X'; ValueType = 'Hex7'; ValueData = @('one', 'two'); KeyPath = 'HKLM:\Test' })
        $result.Kind | Should -Be ([Microsoft.Win32.RegistryValueKind]::MultiString)
        @($result.Value).Count | Should -Be 2
        $result.Value[0] | Should -Be 'one'
    }

    It 'maps a String and Binary' {
        (Convert-RegOperationToValueKind -Operation ([PSCustomObject]@{ ValueName = 'X'; ValueType = 'String'; ValueData = 'hi'; KeyPath = 'HKLM:\Test' })).Kind | Should -Be ([Microsoft.Win32.RegistryValueKind]::String)
        (Convert-RegOperationToValueKind -Operation ([PSCustomObject]@{ ValueName = 'X'; ValueType = 'Binary'; ValueData = [byte[]](1, 2, 3); KeyPath = 'HKLM:\Test' })).Kind | Should -Be ([Microsoft.Win32.RegistryValueKind]::Binary)
    }

    It 'throws on a genuinely unsupported type' {
        { Convert-RegOperationToValueKind -Operation ([PSCustomObject]@{ ValueName = 'X'; ValueType = 'Nonsense'; ValueData = 1; KeyPath = 'HKLM:\Test' }) } | Should -Throw
    }
}

Describe 'Registry fallback writer result' {
    BeforeAll {
        $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
        . (Join-Path $repoRoot 'Scripts\Helpers\ApplyRegistryRegFile.ps1')
        # Get-RegFileOperations lives in another helper; a stub lets it be mocked.
        function Get-RegFileOperations { param($regFilePath) }
    }

    BeforeEach {
        $script:Params = @{}
        Mock Get-RegFileOperations { @([PSCustomObject]@{ OperationType = 'SetValue' }, [PSCustomObject]@{ OperationType = 'SetValue' }) }
        Mock Write-RegistryOperationAccessDeniedWarning { }
        Mock Write-Warning { }
        Mock Write-Host { }
    }

    It 'does not report success when a write was skipped because access was denied' {
        $script:writeCalls = 0
        Mock Invoke-RegistryOperation {
            $script:writeCalls++
            if ($script:writeCalls -eq 2) { throw [System.UnauthorizedAccessException]::new('denied') }
        }

        Invoke-RegistryOperationsFromRegFile -RegFilePath 'x.reg'
        Write-RegistryFallbackResult

        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -like '*1 setting(s) skipped*' }
        Should -Invoke Write-Host -Times 0 -Exactly -ParameterFilter { $Object -like '*completed successfully*' }
    }

    It 'reports success when every write applied' {
        Mock Invoke-RegistryOperation { }

        Invoke-RegistryOperationsFromRegFile -RegFilePath 'x.reg'
        Write-RegistryFallbackResult

        Should -Invoke Write-Host -Times 1 -Exactly -ParameterFilter { $Object -like '*completed successfully*' }
    }
}
