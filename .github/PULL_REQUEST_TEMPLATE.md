## What changed

<!-- State what changed and why. If this fixes a bug, describe the broken behaviour. -->

## Testing

<!-- What did you run, and what did you not? Do not claim something works if it was only reasoned about. -->

- [ ] `.\Tests\Invoke-StaticValidation.ps1 -RequirePSScriptAnalyzer`
- [ ] Pester unit suites under `Tests\Unit`
- [ ] Rebuilt the standalone artifact with `.\build.ps1` (required if `Assets`, `Config`, `Regfiles`, `Schemas`, `Scripts`, or `Winnow.ps1` changed)
- [ ] Mutating integration tests in Windows Sandbox (only if the change touches an apply/rollback path)

## Notes

<!-- PRs target `dev`, not `master`. Add a CHANGELOG entry for user-facing changes. -->
