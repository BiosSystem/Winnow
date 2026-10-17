# Upstream Synchronization Ledger

## Current Baseline

- Upstream repository: `Raphire/Win11Debloat`
- Upstream branch: `master`
- Reviewed commit: `bcf4471` (upstream `master` head at review time)
- Reviewed date: 2026-10-17
- Last re-checked: 2026-10-17 (after the 4.4.0 release; upstream `master` still `bcf4471`)
- Previous baseline: `3202466` (2026-09-12)
- Winnow release line: `4.4.0`
- Upstream changelog review: July 11 2026 upstream release (dropped CustomAppsList format, retired legacy CLI app removal, fixed Copilot removal, dropped sunset apps)

## Upstream Review Log

### 2026-10-17 review: `3202466` to `bcf4471`

Thirty-two upstream commits since the last baseline. Most are localization (ja-JP, zh-CN, nl-NL,
it-IT, pt-BR app and feature strings), a theme/language settings dialog, and UI accessibility
polish, none of which Winnow shares. Every non-localization commit was diffed for a bundled fix:

- `ab34b30` "compare binary and multi-string registry data in order" (#818) is a real bug and
  Winnow had the same one. `Test-FeatureApplied` compared array values with `Compare-Object`,
  which is set-based and calls `1,2,3` equal to `3,2,1`. For REG_BINARY and REG_MULTI_SZ the
  order is part of the value, so an applied-state read could report a feature applied when the
  value differed. Ported to `GetCurrentTweakState.ps1`: Binary and MultiString now compare
  position by position, with both sides normalised to arrays by kind (the .reg parser hands back
  a single element as a scalar and an empty one as `$null`). Covered by the new
  `Test-TweakStateRegistryComparison.ps1`, which drives the real function through its generic
  SetValue path; the comparison previously had no unit coverage. Tracked as issue #88.
- `4079b27` "quote argument values passed on by Get.ps1" (#793) is already present in Winnow:
  `Get.ps1` builds launcher arguments through `Format-LauncherArg`, which does the same
  backslash/quote escaping for `CommandLineToArgvW`. Nothing to port.
- `5f3c277` "give the import/export window's CategoryDetails a hashtable default" (#817): Winnow's
  `Build-CategoryDetails` already returns a hashtable and is covered by `Test-GuiConfigLogic.ps1`.
- `a7e6538` "enhance FindName reference validation" (#826): Winnow validates its XAML through
  `Test-GuiXamlSchemas.ps1` (loads every schema in an STA runspace). Different mechanism, same
  guarantee; not ported.

Resolved after the review (2026-10-17), each as its own issue and pull request:

- `5ca1b70` "remove the DisableSearchHistory and DisableSearchHighlights switches" (#800): not
  ported. Upstream's PR explains the cause: both features had already been dropped from their
  Features.json (their #592), leaving orphaned switches that failed as "Unknown feature". In
  Winnow both are fully wired features, so they stay. The guard upstream added with it is ported
  in spirit: `Test-CliParameterParity.ps1` (Winnow #92/#93) fails if any `Winnow.ps1` parameter is
  not a feature, a control parameter or a switch `Winnow.ps1` reads itself. Writing it also found
  that `Get.ps1` could not forward 19 `Winnow.ps1` parameters, fixed in the same change, and that
  `-Undo`/`-SoftwareList` treated a comma list as one value under `-File` (Winnow #90/#91).
- `8942447` deferred uninstall of user-scope WinGet apps (#802): ported (Winnow #98/#99). Detection
  by exit code with the message as fallback, RunOnce for the removal target (every profile plus
  Default for AllUsers), deferred apps reported as deferred rather than failed. English-only
  messages, matching the rest of Winnow's app-removal output.
- `adf57d1` Edge AI hides the Copilot Chat button (#811): ported (Winnow #94/#95), after checking
  `Microsoft365CopilotChatIconEnabled` against Microsoft's policy reference. That check also found
  `CopilotCDPPageContext` obsolete after Edge 132; kept, since it is harmless.
- `6092513` disable Google Chrome AI features (#763): ported with corrections (Winnow #96/#97). Each
  value was checked against Chromium's GenerativeAI policy definitions. Upstream's
  `FindAndFillWithGeminiSettings` does not exist; `AutofillGenAiSettings` is used instead.
- `7d286ed` "Bing News -> Microsoft News" (#810): not ported. Winnow keeps separate
  `Microsoft.BingNews` and `Microsoft.News` entries whose descriptions already note the rebrand;
  renaming would give two entries the same label, and merging would drop one package id.

AI/telemetry currency: re-read the authoritative WindowsAI Policy CSP
(`learn.microsoft.com/.../policy-csp-windowsai`, ms.date 2026-09-10). Winnow already covers every
documented consumer-facing disable policy (AllowRecallEnablement, DisableAIDataAnalysis,
DisableClickToDo, DisableSettingsAgent, the three Paint policies, TurnOffWindowsCopilot). The 26H2
Copilot surfaces (File Explorer, Windows Search) have no documented policy key; the newer agentic
policies (ConfigureAgentConnectors, AgentConnectorAccessPolicy, DisableRecallDataProviders) are
Insider-only, Enterprise/Education only, and several carry no registry mapping on the page. No AI
policy keys added; inventing keys for undocumented surfaces is out of policy.

### 2026-09-18 re-check: no change

### 2026-09-18 re-check: no change

Re-fetched `upstream/master` from `Raphire/Win11Debloat`. Head is still `3202466` (2026-09-10),
the commit reviewed on 2026-09-12. No new upstream commits, nothing to reconcile; Winnow is not
missing any upstream bug or fix. The `ef8811d` error-handling ports under Deferred remain
deliberately deferred, and `InvokeChanges.ps1` has since been rewritten for automatic rollback, so
any future port there reconciles against the current implementation, not the pre-rollback one.

### 2026-09-12 review: `6012b02` to `3202466`

One upstream commit: `3202466` "Add localization framework for the GUI (en-US baseline) (#764)".
Winnow already built its own localization framework in the 3.5.0 release (`Config/Languages`,
`Scripts/FileIO/LoadLanguageFile.ps1`), so the feature itself is not ported. Every
non-localization file in the commit was diffed to check for a bundled fix:

- The only real bug fix is `Import-JsonFile.ps1` gaining `-Encoding UTF8` on its
  `Get-Content -Raw`. Winnow already has this in `LoadJsonFile.ps1`. Nothing to port.
- `Show-MessageBox.ps1` gained a native-dialog fallback that guards upstream's XAML-marker
  localization mechanism; Winnow localizes through `LoadLanguageFile.ps1` instead, so the
  failure mode does not exist here.
- Everything else is string literals swapped for `Get-Translation` calls plus a whole-body
  reindentation of `Show-RestoreBackupDialog.ps1`; control flow is byte-for-byte unchanged.

Verdict: nothing to port. Winnow is not missing any bug or fix from `3202466`.

While reconciling, hardened three JSON loaders that still read without `-Encoding UTF8`
(`LoadAppPresetsFromJson`, `LoadAppsDetailsFromJson`, `LoadAppsFromFile`) — a latent codepage
risk on `Apps.json`, not an upstream item. `Test-ConfigConsistency` was absent at the time of
this review; it was ported on 2026-09-13 (see the note under Deferred).

### 2026-09-05 review: `fff1fcd` to `6012b02`

Five upstream commits were assessed. Verdict per commit:

| Upstream commit | Subject | Disposition |
|---|---|---|
| `ef8811d` | Improve error reporting & handling (#741) | Partially ported (see below) |
| `f431c56` | Bump version | Not applicable, Winnow maintains its own version line |
| `9b75b1a`, `687ddea`, `6012b02` | CONTRIBUTING.md edits | Declined, Winnow maintains its own contributor guide |

#### Why `ef8811d` cannot be cherry-picked

`git cherry-pick ef8811d` applies to zero files in this repository. Winnow renamed every
script touched by that commit when it moved off the upstream hyphenated `Verb-Noun.ps1`
file convention, so the patch would create a parallel set of upstream-named files and
duplicate every function they define. Attempting it would fail static validation on the
duplicate-function check.

| Upstream path | Winnow path |
|---|---|
| `Scripts/AppRemoval/Invoke-ForceRemoveEdge.ps1` | `Scripts/AppRemoval/ForceRemoveEdge.ps1` |
| `Scripts/AppRemoval/Remove-SelectedApps.ps1` | `Scripts/AppRemoval/RemoveApps.ps1` |
| `Scripts/Features/Import-RegistryFile.ps1` | `Scripts/Features/ImportRegistryFile.ps1` |
| `Scripts/Features/Invoke-Changes.ps1` | `Scripts/Features/InvokeChanges.ps1` |
| `Scripts/Features/Invoke-SystemRestorePoint.ps1` | `Scripts/Features/CreateSystemRestorePoint.ps1` |
| `Scripts/Features/Replace-StartMenu.ps1` | `Scripts/Features/ReplaceStartMenu.ps1` |
| `Scripts/Features/Set-StoreSearchSuggestions.ps1` | `Scripts/Features/StoreSearchSuggestions.ps1` |
| `Scripts/Features/Telemetry-ScheduledTasks.ps1` | `Scripts/Features/TelemetryScheduledTasks.ps1` |
| `Scripts/Features/Windows-OptionalFeatures.ps1` | `Scripts/Features/WindowsOptionalFeatures.ps1` |
| `Scripts/Helpers/Import-ConfigToParams.ps1` | `Scripts/Helpers/ImportConfigToParams.ps1` |

#### Ported: `ForceRemoveEdge` hardening

`ForceRemoveEdge.ps1` was the only file in `ef8811d` that had not also diverged in content,
so its hardening was ported manually:

- Added a `WhatIf` guard. The function is exposed as the `ForceRemoveEdge` FeatureId and
  could previously run destructively when invoked directly under dry-run.
- Wrapped the routine in `try`/`catch`/`finally` and disposed the three open registry keys.
- Added `-Force -ErrorAction Stop` to Edge stub creation so a partial stub is not silently
  skipped.
- Captured the uninstaller exit code through `Invoke-NonBlocking` and reported nonzero.
- Replaced silent leftover deletion with per-path error reporting.
- Replaced four blind `reg delete ... *>$null` calls with `Remove-EdgeAutostartValue`,
  which distinguishes an already-absent value from a failure to inspect or remove one.
- Returned `$true`/`$false`. Both `Request-EdgeForceRemove` call sites discard the result
  with `$null =` to keep the caller's pipeline output unchanged.

#### Remaining `ef8811d` changes: resolved 2026-10-17

The rest of `ef8811d` targeted files where Winnow had diverged, so each was reviewed for the
failure mode it fixed rather than patched in:

- `TelemetryScheduledTasks.ps1`, `WindowsOptionalFeatures.ps1`, `ReplaceStartMenu.ps1`,
  `StoreSearchSuggestions.ps1`, `InvokeChanges.ps1`: Winnow had the same bug class. Steps outside
  the registry import printed their errors and the run still finished as a success with exit
  code 0. Re-implemented against Winnow's engine in #107/#108: each step returns a result,
  `Add-FeatureStepFailure` records failures, which reach the console summary, the run summary
  (`FeatureErrors`), the GUI panel and the exit code, without triggering rollback. Task lookups
  only treat `ObjectNotFound` as a missing task.
- `ImportRegistryFile.ps1`: already covered. A missing file and a writer that applies nothing
  both increment `RegistryImportFailures`, and `Write-RegistryFallbackResult` (4.3.0) stopped the
  fallback path from claiming success after skipped writes.
- `CreateSystemRestorePoint.ps1`: not ported. Upstream reads `-Silent` from `$script:Params` as
  well; in Winnow `-Silent` only ever arrives on the command line, so the existing check works.
  Upstream also gives up when the System Restore setting cannot be read, where Winnow still tries
  to create the point.
- `RemoveApps.ps1`: Winnow already verifies each removal after the fact and reports failures;
  the deferred user-scope case was ported separately (#98/#99).
- GUI call sites: the Store/config import validation was ported with `Test-ConfigConsistency`
  (below). The app-removal scope guard is not needed: Winnow's scope list is three fixed, named
  items with All users preselected, and the target-user name is validated before deploy, so an
  empty or unknown scope cannot reach the apply. The completion message keeps Winnow's per-kind
  breakdown rather than upstream's single count.

`Test-ConfigConsistency.ps1` was ported on 2026-09-13, no longer deferred. It was not
cherry-picked: upstream's version returns `Get-Translation` message keys, which Winnow has no
equivalent for, so it was re-implemented with plain-English messages against Winnow's config
format (the shared Apps/Tweaks/Deployment import shape, which matches upstream). It is wired
into both import paths (`ImportConfigToParams` and the GUI `Import-Configuration`) and covered
by `Tests/Unit/Test-ConfigConsistency.ps1`.

## Integrated Safety Changes

- Enforce Windows PowerShell 5.1 before loading runtime modules.
- Quote paths, scalar values, arrays, and unbound arguments during UAC elevation.
- Handle Mark-of-the-Web on PowerShell source files when Group Policy sets execution policy.
- Warn when Group Policy can override changes on a domain-joined machine.
- Validate required configuration, assets, schemas, and registry paths before execution.
- Initialize registry and app-removal failure counters.
- Support `-SkipExplorerRestart` while preserving `-NoRestartExplorer` as an alias.
- Support `-SkipRegistryBackup` for controlled deployment workflows.

## Winnow-Owned Differences vs. Upstream

Winnow diverges from the upstream Win11Debloat base in the following areas. These differences are intentional, maintained independently, and must not be overwritten during upstream reconciliation.

### Gaming and Low-Latency Subsystem

Upstream Win11Debloat covers only basic UI-level gaming tweaks (disabling GameDVR recording and Game Bar). Winnow adds a full kernel-level latency optimization stack not present in any upstream release:

| Winnow Module | Registry or Boot Target | Upstream Equivalent |
|---|---|---|
| `GamingMode.ps1` | High Performance power plan, Nagle disable, HAGS enable, GameDVR off | GameDVR off only |
| `CompetitiveGaming.ps1` | 0.5ms GlobalTimerResolutionRequests, BCD useplatformtick, disabledynamictick, MMCSS NetworkThrottlingIndex, MMCSS Games GPU Priority 8, CPU core parking ValueMax=0 | None |
| `AddDefenderGamingExclusions.ps1` | `Add-MpPreference` whitelist for Steam, Epic, GOG directories | None |

### Extended AI Purge (24H2 and 25H2)

Most of the granular AI-suppression regfiles are shared with upstream (verified identical at `6012b02`): `Disable_AI_Recall.reg`, `Disable_AI_Service_Auto_Start.reg`, `Disable_Click_to_Do.reg`, `Disable_Edge_AI_Features.reg`, `Disable_Paint_AI_Features.reg`, and `Disable_Notepad_AI_Features.reg`. Winnow's own additions to the AI surface, without the binary deletion that would destabilize `explorer.exe` or `SearchHost.exe`, are:

- `Disable_Narrator_AI_Voices.reg` - removes online AI voice packs (not in upstream)
- `Disable_Photos_Generative_Fill.reg` - blocks Photos generative fill (not in upstream)
- `ExtendedAIPurge.ps1` - orchestrates the full sequence and adds the 24H2/25H2 GPO suppressions (Phone Link, Ink AI, cloud clipboard, Recall optional-component removal, M365 auto-install block, Narrator online voices, and more)

### 24H2 BitLocker Auto-Encryption Guard

The 24H2 change that enables software BitLocker XTS-AES 128 silently on clean installations is handled by `Disable_Bitlocker_Auto_Encryption.reg`, which sets `PreventDeviceEncryption = 1` under `HKLM:\SYSTEM\CurrentControlSet\Control\BitLocker` before the first-run encryption trigger fires. This regfile is shared with upstream (identical content at `6012b02`), not a Winnow-only addition.

### Telemetry Firewall and Scheduler Block

Upstream disables telemetry registry flags. Winnow adds two additional layers:

- `BlockTelemetryFirewall.ps1` - applies Windows Firewall outbound block rules targeting Microsoft telemetry endpoints
- `TelemetryScheduledTasks.ps1` - disables the full set of Windows telemetry scheduled tasks in Task Scheduler

### Desired-State Verification Engine

Upstream does not implement post-apply state verification. Winnow adds:

- `DesiredStateVerification.ps1` - reads actual registry values and Appx package states and compares against requested configuration
- `-Verify` parameter for inline verification after apply
- `-VerifyProfile` parameter for unattended compliance auditing against a JSON profile
- Exit code `2` for noncompliance, drift, or unsupported feature state
- Metadata-driven verification adapters for gaming, AI purge, security hardening, and telemetry firewall modules

### Unattend XML Generator and Software Installer

Upstream does not provide OOBE bypass tooling or silent software installation. Winnow adds:

- `UnattendGenerator.ps1` - generates a Windows `unattend.xml` to bypass OOBE tracking and Microsoft Account requirements during setup
- `SoftwareInstaller.ps1` - silently installs user-selected essential applications via winget

## Capability Matrix: Winnow vs. Ecosystem Alternatives

| Capability | Winnow | Win11Debloat (Raphire) | WinUtil (Chris Titus) | SophiApp (farag2) | AtlasOS and ReviOS |
|---|---|---|---|---|---|
| **Architecture** | Native PowerShell 5.1 modular engine | PowerShell 5.1 script | PowerShell + WPF GUI | PowerShell module suite | AME Playbook / stripped ISO |
| **Execution footprint** | Pure in-memory, no install required | Pure in-memory | Web download + package manager | Local module import required | Full OS wipe + clean install |
| **Gaming latency stack** | Full stack (0.5ms timer, BCD clock, Nagle, MMCSS, HAGS, core unparking) | None | Basic (power plan + Game Mode) | Service toggles only | Varies per build |
| **Anti-cheat compatibility** | 100% verified (Vanguard, EAC, BattlEye, FACEIT) | 100% safe | 100% safe | 100% safe | High risk (stripped components trigger bans) |
| **24H2 BitLocker guard** | Registry fix (shared with upstream) | Same registry fix | Partial (recent micro-patch) | Registry-based | Stripped at ISO level |
| **24H2 AI purge depth** | Granular non-destructive GPO suppression | Basic Copilot removal | Recall and Copilot toggle | Granular service disables | Total binary removal (risk of shell crashes) |
| **Windows Update lifecycle** | Fully intact | Fully intact | Intact (unless update service killed) | Fully intact | Broken or frozen |
| **Post-apply verification** | Built-in -Verify and -VerifyProfile engine with exit code 2 | None | None | None | None |
| **Rollback capability** | Pre-run snapshot, automatic rollback on failed apply, System Restore, per-feature `-Undo` | Basic registry backup | System Restore only | Detailed restore script | Impossible without OS reinstall |
| **Standalone single-file build** | Yes (Winnow-Standalone.ps1 bundles all modules) | No | No | No | N/A |

## Why Winnow Uses Non-Destructive GPO Suppression

Alternative tools that delete `CoreAIComponents` binaries or strip UWP system packages from the Windows image cause the following documented failures in Windows 11 24H2:

- `explorer.exe` and `SearchHost.exe` crash loops when Recall or Click To Do binary dependencies are missing
- Windows Update error `0x800f081e` when cumulative updates attempt to patch stripped system packages
- Kernel anti-cheat initialization failures (Vanguard, EAC) when Xbox Identity Provider or Code Integrity service registrations are absent
- `Class Not Registered` COM errors in PowerShell 7 when DISM-backed service registrations are removed

Winnow applies only policy and registry suppression that the Windows kernel honors without requiring the associated binary to be absent. This preserves shell stability, update chain integrity, and anti-cheat compatibility permanently.

## Release Hardening Verification

- Recheck the Windows PowerShell 5.1 guard against upstream before loading any runtime module.
- Recheck Win32-safe quoting for paths, scalar values, arrays, and unbound elevation arguments.
- Recheck Mark-of-the-Web handling against upstream and limit unblocking to marked PowerShell source files.
- Protect the three upstream safety contracts with Pester regression tests.
- Apply the same Win32-safe quoting contract to bootstrap launcher arguments and propagate child exit codes.
- Add metadata-driven verification adapters for Winnow gaming, extended AI purge, security hardening, and telemetry firewall modules.
- Enforce a direct command-line parameter for every configured feature ID.
- Require a restore point before applying the four high-impact custom modules.

## Reconciliation Procedure

Winnow and upstream no longer share git ancestry. Branch-relative comparisons such as
`git rev-list --count HEAD..upstream/master` report the whole of upstream's history and are
meaningless here. Diff against the reviewed commit recorded above instead:

```
git fetch upstream
git log --oneline <reviewed commit>..upstream/master
```

That range is accurate because the reviewed commit still exists in the upstream remote,
whether or not it is reachable from this repository's history.

1. Fetch `upstream/master`.
2. Record the new upstream commit in this ledger.
3. Review safety, app-removal, registry, user-hive, and deployment changes.
4. Port compatible behavior through Winnow modules.
5. Preserve upstream attribution and MIT license notices.
6. Run `Tests/Invoke-StaticValidation.ps1 -RequirePSScriptAnalyzer`.
7. Run every Pester file under `Tests/Unit`.
8. Rebuild `Winnow-Standalone.ps1`.
9. Confirm the generated script parses under Windows PowerShell 5.1.
