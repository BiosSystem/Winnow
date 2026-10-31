#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for the download launcher (Scripts/Get.ps1) and the user data folder.
.DESCRIPTION
    Get.ps1 downloads Winnow and runs it elevated. It must only run a release
    archive that matches the SHA-256 GitHub published for it, and the elevated
    step must unpack and run from a folder a standard user cannot change.

    The launcher's functions are loaded from the file's syntax tree, so nothing
    is downloaded and no elevation prompt appears. The bootstrap is run for real
    against a small archive with a stand-in Winnow.ps1; it sets an
    Administrators/SYSTEM-only ACL, so those cases need an elevated session and
    are skipped otherwise (CI runs elevated).
#>

BeforeDiscovery {
    $script:isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

BeforeAll {
    $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
    $launcherPath = Join-Path $script:repoRoot 'Scripts\Get.ps1'
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($launcherPath, [ref]$null, [ref]$null)
    foreach ($name in 'Format-LauncherArg', 'Get-WinnowReleaseArchive', 'New-WinnowBootstrapScript') {
        $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
        if (-not $definition) { throw "Get.ps1 no longer defines $name" }
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    . (Join-Path $script:repoRoot 'Scripts\Helpers\Initialize-UserData.ps1')

    # Builds an archive whose Winnow.ps1 records the arguments it was started with.
    function New-StandInArchive {
        param([string]$Path, [string]$RecordPath, [string]$NestedFolder = '')

        $source = Join-Path $TestDrive ("src-" + [guid]::NewGuid().ToString('N'))
        $appDir = if ($NestedFolder) { Join-Path $source $NestedFolder } else { $source }
        $null = New-Item -ItemType Directory -Path $appDir -Force
        $recordLiteral = "'" + $RecordPath.Replace("'", "''") + "'"
        Set-Content -LiteralPath (Join-Path $appDir 'Winnow.ps1') -Encoding UTF8 -Value @"
`$lines = @(`$PSScriptRoot) + @(`$args)
Set-Content -LiteralPath $recordLiteral -Value `$lines -Encoding UTF8
exit 7
"@
        Compress-Archive -Path (Join-Path $source '*') -DestinationPath $Path -Force
        return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    }

    function Invoke-Bootstrap {
        param([string]$ScriptText)

        $scriptFile = Join-Path $TestDrive ("bootstrap-" + [guid]::NewGuid().ToString('N') + '.ps1')
        Set-Content -LiteralPath $scriptFile -Value $ScriptText -Encoding UTF8
        $outFile = "$scriptFile.out"
        $errFile = "$scriptFile.err"
        $process = Start-Process powershell.exe -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', "`"$scriptFile`"") -Wait -PassThru -NoNewWindow -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $output = @(Get-Content -LiteralPath $outFile, $errFile -ErrorAction SilentlyContinue) -join ' | '
        return [PSCustomObject]@{ ExitCode = $process.ExitCode; Output = $output }
    }
}

Describe 'Release archive selection' {
    It 'uses the release zip asset and its published SHA-256' {
        $digest = 'ab' * 32
        $release = [PSCustomObject]@{
            tag_name = 'v9.9.9'
            assets = @(
                [PSCustomObject]@{ name = 'Winnow-Standalone.ps1'; browser_download_url = 'https://example.invalid/s.ps1'; digest = 'sha256:' + ('cd' * 32) }
                [PSCustomObject]@{ name = 'Winnow-v9.9.9.zip'; browser_download_url = 'https://example.invalid/w.zip'; digest = "sha256:$digest" }
            )
        }

        $archive = Get-WinnowReleaseArchive -Release $release
        $archive.Uri | Should -Be 'https://example.invalid/w.zip'
        $archive.Sha256 | Should -Be $digest.ToUpperInvariant()
    }

    It 'refuses a release whose zip has no digest' {
        $release = [PSCustomObject]@{
            tag_name = 'v9.9.9'
            assets = @([PSCustomObject]@{ name = 'Winnow-v9.9.9.zip'; browser_download_url = 'https://example.invalid/w.zip'; digest = $null })
        }

        { Get-WinnowReleaseArchive -Release $release } | Should -Throw '*no SHA-256 digest*'
    }

    It 'refuses a release without the zip asset' {
        $release = [PSCustomObject]@{ tag_name = 'v9.9.9'; assets = @() }

        { Get-WinnowReleaseArchive -Release $release } | Should -Throw '*has no Winnow-v*.zip asset*'
    }
}

Describe 'Elevated bootstrap script' {
    It 'unpacks under %SystemRoot%\Temp and locks the folder to Administrators and SYSTEM by default' {
        $text = New-WinnowBootstrapScript -ArchivePath 'C:\x.zip' -ArchiveSha256 ('A' * 64)

        $text | Should -Match "Join-Path \(Join-Path \`$env:SystemRoot 'Temp'\)"
        $text | Should -Match 'SetAccessRuleProtection\(\$true, \$false\)'
        $text | Should -Match "'S-1-5-18', 'S-1-5-32-544'"
        { [scriptblock]::Create($text) } | Should -Not -Throw
    }

    It 'keeps a hostile argument a single quoted literal in the script' {
        $text = New-WinnowBootstrapScript -ArchivePath "C:\it's.zip" -ArchiveSha256 ('A' * 64) -WinnowArguments @('-User', "x'; Remove-Item C:\ -WhatIf; '")

        $text | Should -Match ([regex]::Escape("'x''; Remove-Item C:\ -WhatIf; '''"))
        $text | Should -Match ([regex]::Escape("'C:\it''s.zip'"))
        { [scriptblock]::Create($text) } | Should -Not -Throw
    }

    It 'runs Winnow.ps1 from a protected copy with the arguments intact' -Skip:(-not $script:isElevated) {
        $record = Join-Path $TestDrive 'record-ok.txt'
        $archive = Join-Path $TestDrive 'ok.zip'
        $hash = New-StandInArchive -Path $archive -RecordPath $record
        $runRoot = Join-Path $TestDrive 'runs-ok'
        $null = New-Item -ItemType Directory -Path $runRoot

        $arguments = @('-Silent', '-User', (Format-LauncherArg 'Jane Doe'), '-Apps', (Format-LauncherArg 'A,B "C"'))
        $result = Invoke-Bootstrap (New-WinnowBootstrapScript -ArchivePath $archive -ArchiveSha256 $hash -WinnowArguments $arguments -RunRoot $runRoot)

        $result.ExitCode | Should -Be 7 -Because $result.Output
        $lines = @(Get-Content -LiteralPath $record -Encoding UTF8)
        $lines[0] | Should -BeLike "$runRoot\Winnow-*\app"
        $lines[1..5] | Should -Be @('-Silent', '-User', 'Jane Doe', '-Apps', 'A,B "C"')
        @(Get-ChildItem -LiteralPath $runRoot).Count | Should -Be 0 -Because 'the run folder is removed afterwards'
    }

    It 'does not start Winnow when the archive no longer matches the verified hash' -Skip:(-not $script:isElevated) {
        $record = Join-Path $TestDrive 'record-bad.txt'
        $archive = Join-Path $TestDrive 'bad.zip'
        $null = New-StandInArchive -Path $archive -RecordPath $record
        $runRoot = Join-Path $TestDrive 'runs-bad'
        $null = New-Item -ItemType Directory -Path $runRoot

        $result = Invoke-Bootstrap (New-WinnowBootstrapScript -ArchivePath $archive -ArchiveSha256 ('0' * 64) -RunRoot $runRoot)

        $result.ExitCode | Should -Not -Be 7
        $result.Output | Should -BeLike '*changed after it was verified*'
        Test-Path -LiteralPath $record | Should -BeFalse
        @(Get-ChildItem -LiteralPath $runRoot).Count | Should -Be 0
    }

    It 'finds Winnow.ps1 inside the single folder of a branch archive' -Skip:(-not $script:isElevated) {
        $record = Join-Path $TestDrive 'record-dev.txt'
        $archive = Join-Path $TestDrive 'dev.zip'
        $hash = New-StandInArchive -Path $archive -RecordPath $record -NestedFolder 'Winnow-master'
        $runRoot = Join-Path $TestDrive 'runs-dev'
        $null = New-Item -ItemType Directory -Path $runRoot

        $result = Invoke-Bootstrap (New-WinnowBootstrapScript -ArchivePath $archive -ArchiveSha256 $hash -RunRoot $runRoot)

        $result.ExitCode | Should -Be 7 -Because $result.Output
        @(Get-Content -LiteralPath $record -Encoding UTF8)[0] | Should -BeLike '*\app\Winnow-master'
    }
}

Describe 'Standalone build' {
    It 'extracts into %SystemRoot%\Temp, where a standard user cannot replace the locked folder' {
        $buildScript = Get-Content -LiteralPath (Join-Path $script:repoRoot 'build.ps1') -Raw

        # build.ps1 holds the wrapper as a here-string, so its variables are backtick-escaped.
        $buildScript | Should -Match ([regex]::Escape('`$ExtractPath = Join-Path (Join-Path `$env:SystemRoot ''Temp'')'))
        $buildScript | Should -Not -Match ([regex]::Escape('`$ExtractPath = Join-Path `$env:TEMP'))
    }
}

Describe 'User data folder' {
    It 'creates the Logs and Config folders' {
        $userData = Join-Path $TestDrive 'ud-create'

        Initialize-WinnowUserData -UserDataPath $userData

        Test-Path -LiteralPath (Join-Path $userData 'Logs') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $userData 'Config') | Should -BeTrue
    }

    It 'copies saved settings and backups from an earlier location without overwriting' {
        $legacy = Join-Path $TestDrive 'legacy'
        $null = New-Item -ItemType Directory -Path (Join-Path $legacy 'Config'), (Join-Path $legacy 'Backups') -Force
        Set-Content -LiteralPath (Join-Path $legacy 'Config\LastUsedSettings.json') -Value 'legacy settings'
        Set-Content -LiteralPath (Join-Path $legacy 'Backups\Winnow-RegistryBackup-1.json') -Value 'old one'
        Set-Content -LiteralPath (Join-Path $legacy 'Backups\Winnow-RegistryBackup-2.json') -Value 'old two'

        $userData = Join-Path $TestDrive 'ud-migrate'
        $null = New-Item -ItemType Directory -Path (Join-Path $userData 'Backups') -Force
        Set-Content -LiteralPath (Join-Path $userData 'Backups\Winnow-RegistryBackup-2.json') -Value 'new two'

        Initialize-WinnowUserData -UserDataPath $userData -LegacyPaths @($legacy, (Join-Path $TestDrive 'missing'))

        Get-Content -LiteralPath (Join-Path $userData 'Config\LastUsedSettings.json') | Should -Be 'legacy settings'
        Get-Content -LiteralPath (Join-Path $userData 'Backups\Winnow-RegistryBackup-1.json') | Should -Be 'old one'
        Get-Content -LiteralPath (Join-Path $userData 'Backups\Winnow-RegistryBackup-2.json') | Should -Be 'new two'
        Test-Path -LiteralPath (Join-Path $legacy 'Backups\Winnow-RegistryBackup-1.json') | Should -BeTrue -Because 'the old copy stays'
    }

    It 'keeps existing saved settings' {
        $legacy = Join-Path $TestDrive 'legacy-keep'
        $null = New-Item -ItemType Directory -Path (Join-Path $legacy 'Config') -Force
        Set-Content -LiteralPath (Join-Path $legacy 'Config\LastUsedSettings.json') -Value 'legacy'
        $userData = Join-Path $TestDrive 'ud-keep'
        $null = New-Item -ItemType Directory -Path (Join-Path $userData 'Config') -Force
        Set-Content -LiteralPath (Join-Path $userData 'Config\LastUsedSettings.json') -Value 'current'

        Initialize-WinnowUserData -UserDataPath $userData -LegacyPaths @($legacy)

        Get-Content -LiteralPath (Join-Path $userData 'Config\LastUsedSettings.json') | Should -Be 'current'
    }

    It 'puts user data under LOCALAPPDATA and keeps it next to the script without one' {
        # Evaluated from the syntax tree: dot-sourcing Initialize-Environment draws
        # the console banner, which fails without a console (CI).
        $initAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:repoRoot 'Scripts\Helpers\Initialize-Environment.ps1'), [ref]$null, [ref]$null)
        $assignment = $initAst.Find({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -eq '$script:UserDataPath' }, $true)
        $assignment | Should -Not -BeNullOrEmpty
        $resolve = [scriptblock]::Create('param($rootDir) ' + $assignment.Right.Extent.Text)

        $saved = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = 'C:\Users\Someone\AppData\Local'
            & $resolve 'C:\Winnow' | Should -Be 'C:\Users\Someone\AppData\Local\Winnow'
            $env:LOCALAPPDATA = $null
            & $resolve 'C:\Winnow' | Should -Be 'C:\Winnow'
        }
        finally {
            $env:LOCALAPPDATA = $saved
        }

        $initText = $initAst.Extent.Text
        $initText | Should -Match ([regex]::Escape('$script:RegistryBackupsPath = Join-Path $script:UserDataPath ''Backups'''))
        $initText | Should -Match ([regex]::Escape('$script:SavedSettingsFilePath = Join-Path (Join-Path $script:UserDataPath ''Config'') ''LastUsedSettings.json'''))
        $initText | Should -Match ([regex]::Escape('$logsPath = Join-Path $script:UserDataPath ''Logs'''))
    }
}
