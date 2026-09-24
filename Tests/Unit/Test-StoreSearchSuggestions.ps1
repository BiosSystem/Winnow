#Requires -Modules Pester
<#
.SYNOPSIS
    Unit tests for the Microsoft Store search suggestion toggle.
.DESCRIPTION
    Disabling suggestions puts an Everyone deny FullControl rule on the user's
    store.db; undoing it removes that rule and deletes the file. These run against
    a real temporary file so the ACL handling is exercised for real. takeown and
    icacls are mocked: they act on ownership, which is not what is under test.

    The undo test checks for the ACL warning as well as for the file being gone.
    In a temp folder the file can be deleted through the folder's own delete
    permission even when its deny rule was never removed, so the deletion alone
    would not show that the rule removal failed.
#>

BeforeAll {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..\..') | Select-Object -ExpandProperty Path
    . (Join-Path $repoRoot 'Scripts\Features\StoreSearchSuggestions.ps1')
}

Describe 'Store search suggestions' {

    BeforeEach {
        $script:Params = @{}
        $script:storeDb = Join-Path $TestDrive 'store.db'
        Set-Content -LiteralPath $script:storeDb -Value 'placeholder'
        Mock takeown { }
        Mock icacls { }
        Mock Write-Host { }
        Mock Write-Warning { }
    }

    AfterEach {
        # Leave nothing behind that the test runner cannot delete.
        if (Test-Path -LiteralPath $script:storeDb) {
            $acl = Get-Acl -Path $script:storeDb
            foreach ($rule in @($acl.Access | Where-Object { $_.AccessControlType -eq 'Deny' })) {
                [void]$acl.RemoveAccessRule($rule)
            }
            Set-Acl -Path $script:storeDb -AclObject $acl
            Remove-Item -LiteralPath $script:storeDb -Force
        }
    }

    It 'puts an Everyone deny rule on the database when disabling' {
        DisableStoreSearchSuggestions -StoreAppsDatabase $script:storeDb

        Test-StoreSearchSuggestionsDisabled -StoreAppsDatabase $script:storeDb | Should -BeTrue
    }

    It 'removes the deny rule and deletes the database when undoing' {
        DisableStoreSearchSuggestions -StoreAppsDatabase $script:storeDb

        EnableStoreSearchSuggestions -StoreAppsDatabase $script:storeDb

        Should -Invoke Write-Warning -Times 0 -Exactly -ParameterFilter { $Message -like '*normalize ACL*' }
        Test-Path -LiteralPath $script:storeDb | Should -BeFalse
    }
}
