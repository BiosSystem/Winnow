#Requires -Modules Pester
<#
.SYNOPSIS
    Guards the agreement between Winnow.ps1, the Get.ps1 launcher, and the
    feature and control-parameter tables.
.DESCRIPTION
    Get.ps1 downloads Winnow and starts Winnow.ps1 with the parameters it was
    given, but it can only forward what its own param block declares. Nineteen
    Winnow.ps1 parameters were once missing from it, so the launcher rejected
    them as unknown.

    Every Winnow.ps1 parameter must also be accounted for: a Features.json
    FeatureId, a control parameter, or a switch Winnow.ps1 handles itself.
    Invoke-AllChanges skips keys it does not recognise, so an orphaned switch
    would be accepted and then silently do nothing.
#>

BeforeAll {
    $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path

    function Get-ParamTypeMap {
        param([string]$RelativePath)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:repoRoot $RelativePath), [ref]$null, [ref]$null)
        $map = @{}
        foreach ($parameter in $ast.ParamBlock.Parameters) {
            $map[$parameter.Name.VariablePath.UserPath] = $parameter.StaticType.FullName
        }
        return [PSCustomObject]@{ Ast = $ast; Types = $map }
    }

    $script:entry = Get-ParamTypeMap 'Winnow.ps1'
    $script:launcher = Get-ParamTypeMap 'Scripts\Get.ps1'

    $script:featureIds = @((Get-Content (Join-Path $script:repoRoot 'Config\Features.json') -Raw | ConvertFrom-Json).Features.FeatureId)

    $initAst = [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $script:repoRoot 'Scripts\Helpers\Initialize-Environment.ps1'), [ref]$null, [ref]$null)
    $assignment = $initAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
            $node.Left.Extent.Text -eq '$script:ControlParams'
        }, $true)
    $script:controlParams = @($assignment.Right.FindAll({
                param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst]
            }, $true) | ForEach-Object { $_.Value })

    # Switches Winnow.ps1 handles itself, outside Features.json and the control
    # list: the extended modules, the standalone modes, and their arguments.
    $script:directlyHandled = @(
        'EnablePerformanceTweaks', 'DisableWindowsAds', 'EnableCompetitiveGaming',
        'DisableMemoryIntegrity', 'DisableSettingsAds', 'DisableWidgetsDeep',
        'VerifyWatchdog', 'InstallSoftware', 'SoftwareList', 'GenerateUnattend',
        'UnattendOutPath', 'EnableUpdateWatchdog', 'AddDefenderGamingExclusions',
        'RemoveDefenderGamingExclusions'
    )

    # Launcher-only switches: -Dev picks the branch to download; -Verbose and
    # -WhatIf are common parameters of Winnow.ps1, explicit in the launcher.
    $script:launcherOnly = @('Dev', 'Verbose', 'WhatIf')
}

Describe 'Launcher parameter parity' {
    It 'declares every Winnow.ps1 parameter in Get.ps1' {
        $missing = @($script:entry.Types.Keys | Where-Object { -not $script:launcher.Types.ContainsKey($_) } | Sort-Object)
        $missing | Should -BeNullOrEmpty -Because "Get.ps1 cannot forward: $($missing -join ', ')"
    }

    It 'gives each shared parameter the same type in both scripts' {
        $mismatched = @($script:entry.Types.Keys | Where-Object {
                $script:launcher.Types.ContainsKey($_) -and $script:launcher.Types[$_] -ne $script:entry.Types[$_]
            } | ForEach-Object { '{0} (Winnow {1}, Get {2})' -f $_, $script:entry.Types[$_], $script:launcher.Types[$_] })
        $mismatched | Should -BeNullOrEmpty -Because ($mismatched -join '; ')
    }

    It 'adds no parameter to Get.ps1 beyond its own launcher switches' {
        $extra = @($script:launcher.Types.Keys | Where-Object {
                -not $script:entry.Types.ContainsKey($_) -and $_ -notin $script:launcherOnly
            } | Sort-Object)
        $extra | Should -BeNullOrEmpty -Because "Winnow.ps1 does not accept: $($extra -join ', ')"
    }
}

Describe 'Winnow.ps1 parameter accounting' {
    It 'accounts for every parameter as a feature, a control parameter, or a directly handled switch' {
        $unaccounted = @($script:entry.Types.Keys | Where-Object {
                $_ -notin $script:featureIds -and $_ -notin $script:controlParams -and $_ -notin $script:directlyHandled
            } | Sort-Object)
        $unaccounted | Should -BeNullOrEmpty -Because "orphaned parameters would be accepted and ignored: $($unaccounted -join ', ')"
    }

    It 'lists only real parameters as directly handled' {
        $stale = @($script:directlyHandled | Where-Object { -not $script:entry.Types.ContainsKey($_) })
        $stale | Should -BeNullOrEmpty -Because "no longer Winnow.ps1 parameters: $($stale -join ', ')"
    }

    It 'actually reads every directly handled switch in Winnow.ps1' {
        # The allow-list must not hide an orphan: each name has to be used
        # somewhere after the param block.
        $bodyText = $script:entry.Ast.Extent.Text.Substring($script:entry.Ast.ParamBlock.Extent.EndOffset - $script:entry.Ast.Extent.StartOffset)
        $unused = @($script:directlyHandled | Where-Object { $bodyText -notmatch ('\b{0}\b' -f [regex]::Escape($_)) })
        $unused | Should -BeNullOrEmpty -Because "declared but never read by Winnow.ps1: $($unused -join ', ')"
    }
}
