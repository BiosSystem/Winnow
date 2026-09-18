## [v4.2.3] - 2026-09-18
### Artifacts
- **Release Package**: Winnow-v4.2.3.zip
- **Standalone**: Winnow-Standalone.ps1
- Both built and published by the release workflow on tag push. Checksums are on the release page.
### Added
- `-RemoveDefenderGamingExclusions` reverses `-AddDefenderGamingExclusions`; both share one path list so they cannot drift.
### Security
- Pass the winget package id to the software installer as a discrete argument instead of interpolating it into one command line, removing an argument-injection surface (defense-in-depth; no untrusted caller today).
### Note
- Both changes were found during a comprehensive security-surface code audit that also produced the 4.2.1 and 4.2.2 fixes.

## [v4.2.2] - 2026-09-18
### Artifacts
- **Release Package**: Winnow-v4.2.2.zip
- **Standalone**: Winnow-Standalone.ps1
- Both built and published by the release workflow on tag push. Checksums are on the release page.
### Fixed
- Escape the embedded config path in the generated `autounattend.xml`; a legal path with `&`, `<`, or `>` previously produced a malformed unattend file Windows Setup silently rejects. Found during a full security-surface code audit.

## [v4.2.1] - 2026-09-18
### Artifacts
- **Release Package**: Winnow-v4.2.1.zip
- **Standalone**: Winnow-Standalone.ps1
- Both built and published by the release workflow on tag push. Checksums are on the release page.
### Fixed
- Unload the target user's registry hive reliably: force a GC to release the .NET RegistryKey handles the apply/verify/restore work opened into the mounted hive, and retry, so `reg unload` no longer fails and leaves the hive mounted (could lock the profile) on `-Sysprep`/`-User` runs.
- The PowerShell registry writer now applies `qword`, `hex(2)` (REG_EXPAND_SZ), and `hex(7)` (REG_MULTI_SZ) values instead of throwing; the parser and verifier already handled all three, so the writer was the only part out of step.
### Added
- Sandbox-only mutating integration tests for Scope B module registry rollback and the update watchdog (real install, ACL lockdown, integrity, policy re-assertion, tamper detection).
### Known limitation
- The mutating end-to-end paths are unit-tested and read-path-verified but have not yet been run in Windows Sandbox.

## [v4.2.0] - 2026-09-17
### Artifacts
- **Release Package**: Winnow-v4.2.0.zip
- **Standalone**: Winnow-Standalone.ps1
- Both built and published by the release workflow on tag push. Checksums are on the release page.
### Added
- Full-module rollback Scope B: a failed apply now also reverts the imperative registry writes of the SecurityHardening, ExtendedAIPurge, and GamingMode modules, each value captured with its type before apply and restored (or removed) on rollback. One-way ops (Recall removal) and the powercfg change stay reported as not restored.
- `-VerifyWatchdog` prints a read-only watchdog health report (task registered, payload integrity, directory lockdown, last run), exit 0 healthy / 2 degraded.
- The watchdog mirrors integrity failures (event 2000) and corrected drift (event 1000) to the Windows event log.
- Sourced tool-by-tool comparison in `COMPARISON.md`, linked from the README and the wiki.
### Changed
- The update watchdog now re-asserts the whole machine-wide privacy policy floor (Copilot, Recall, Windows AI, generative fill, cross-device clipboard, ink workspace, OneDrive sync, dmwappushservice, CEIP tasks), not just AllowTelemetry and DiagTrack, correcting only what drifted.
- The telemetry block sinkholes every domain in HOSTS (IP-rotation-proof) as the primary layer, with firewall rules kept as an additive second layer.
### Security
- Hardened the update watchdog against tampering: its directory is locked to SYSTEM and Administrators (re-applied every run) and its payload is hash-checked against an admin-only registry key before it enforces, failing closed on mismatch. Closes the path where a non-admin could replace a script a SYSTEM task runs.
- Closed a local privilege-escalation path in the standalone build: it now elevates before it unpacks and extracts to a directory locked to Administrators and SYSTEM, so the elevated run no longer reads its scripts from a user-writable location.
### Known limitation
- The mutating end-to-end paths (rollback capture-apply-fail-restore, and a live watchdog run against a real Windows update as SYSTEM) are unit-tested with mocks and verified read-only on real hardware, but have not yet been exercised in Windows Sandbox.

## [v4.1.0] - 2026-09-13
### Artifacts
- **Release Package**: Winnow-v4.1.0.zip
- **Standalone**: Winnow-Standalone.ps1
- Both built and published by the release workflow on tag push. Checksums are on the release page.
### Added
- Full-module rollback (Scope A): a failed apply now also reverts service start types, Winnow's telemetry firewall rules and HOSTS block, disabled scheduled tasks, and the SMB1 optional feature, alongside the registry backup. One-way ops (Recall/Appx/Edge removal) and imperative registry writes are reported as not restored, not faked.
- `Test-ConfigConsistency`: import configurations are validated for structure and scope/user consistency before anything is applied, in both the CLI and GUI import paths.
### Known limitation
- The mutating end-to-end rollback path (registry + module) is unit-tested with mocks but has not been run in Windows Sandbox on real hardware.

## [v4.0.1] - 2026-09-13
### Artifacts
- **Release Package**: Winnow-v4.0.1.zip
- **Standalone**: Winnow-Standalone.ps1
- Both built and published by the release workflow on tag push. Checksums are on the release page.
### Fixed
- The three app-list JSON loaders now read UTF-8, not the OS ANSI codepage (latent on ASCII `Apps.json`, guards against a future accented app name).
### Changed
- README banner and header refresh (branding/docs only).
### Note
- Sync release: 4.0.0 was tagged before the banner cleanup and the loader fix merged, so this brings the published artifact in line with `master`. No functional change from 4.0.0 beyond the encoding fix.

## [v4.0.0] - 2026-09-11
### Artifacts
- **Release Package**: Winnow-v4.0.0.zip
- **Standalone**: Winnow-Standalone.ps1
- Both built and published by the release workflow on tag push. Checksums are on the release page.
### Changed
- Renamed the project from WinSwift to Winnow: repository, `Winnow.ps1` entry point, `Winnow-Standalone.ps1`, the `WINNOW_VERSION` constant, the GUI branding (title bar, About dialog, ASCII header), the installer one-liner, and all documentation. The old `BiosSystem/WinSwift` repository URL redirects to the new one.
- Rebrand only; the 3.5.0 feature behaviour is unchanged. Releases at v3.5.0 and earlier were published as WinSwift and keep their original asset names.

## [v3.5.0] - 2026-09-09
### Artifacts
- **Release Package**: WinSwift-v3.5.0.zip
- **Standalone**: WinSwift-Standalone.ps1
- Both built and published by the release workflow on tag push. Checksums are on the release page.
### Added
- Localization framework with per-language catalogues under `Config/Languages` and per-key fallback to en-US, plus a Spanish (es-ES) translation of the feature text and the GUI chrome.
- Preset library under `Config/Presets`, validated before a run so a bad profile fails fast instead of applying nothing.
- Recall optional-component removal during the extended AI purge, and real registry actions behind `DisableSearchHistory` and `DisableSearchHighlights`.
### Fixed
- Runs reported success when app removals or features failed; failures are now counted and surfaced everywhere, and the exit code reflects them.
- `-WhatIf` made real changes for the watchdog and Defender steps; `-ForceRemoveEdge` was a dead switch; the app-removal scope and Ctrl+F broke under a translated UI. All fixed.
- The Update Watchdog now triggers on Windows Update install events and re-applies telemetry settings instead of only warning.
- Edge force-remove handles the 24H2/25H2 exit-532 block and verifies removal; Copilot removal no longer depends on WinGet.
- Eight features and all undo files threw in `-Sysprep`/`-User` mode; the resolver now falls back to the root file and the missing HKCU Sysprep variants were added.
### Known limitation
- The hardware-dependent paths (rollback, Edge 532, Recall removal, the watchdog event trigger, an offline-hive Sysprep pass) have not been run on a real 24H2/25H2 machine, and the es-ES layout has not had a visual pass.

## [v3.4.0] - 2026-09-06
### Artifacts
- **Release Package**: WinSwift-v3.4.0.zip
- **Standalone**: WinSwift-Standalone.ps1
- Both built and published by the release workflow on tag push. Checksums are on the release page.
### Added
- Automatic rollback of registry changes when the apply phase fails, restoring the snapshot taken before the run. Exit code 3 for a clean rollback, 4 when the rollback itself fails.
- `-Undo` to revert features from the command line. Undo was previously reachable only from the GUI, so unattended deployments could apply changes but never revert them.
- `-NoAutoRollback` to leave a failed run in place for inspection.
- Verification coverage for every feature, up from 102 of 112, through the AppxAbsence, StartLayout and EdgeRemoved adapters.
- Integration test suite that runs WinSwift as a real process, plus a Windows Sandbox harness for the destructive cases.
### Fixed
- The administrator guard printed its warning and then continued into the apply pipeline, because `exit` inside a dot-sourced script does not terminate the caller.
- The 24H2 DISM fallback passed a wildcard to `/PackageName`, which rejects wildcards, so it had never removed anything.
- Run summaries were never written. The export was guarded on a variable nothing assigned, which also left the GUI report button with nothing to open.
### Known limitation
- The rollback path has not been executed end to end. It is covered by source-level assertions in CI and by Sandbox tests that have not been run.

## 2026-08-20 - v3.2.0 release blocked by handoff audit

The package checksum is correct, but release integrity is not. `Config/Apps.json` cannot be parsed,
and `InvokeChanges.ps1` defines the same six functions twice. The archive matches source exactly,
so regenerating it without repairing source would reproduce both defects. Keep v3.2.0 on hold.

## [v3.2.0] - 2026-08-19
### Artifacts
- **Release Package**: WinSwift_v3.2.0.zip
- **SHA256**: 82AA1FB35BF980182A8587AC288366BA2D65A03D396A408BE65725F4A63E32C9
### Added
- Track 2 Guardrails: Hardcoded a mandatory System Restore execution in InvokeChanges.ps1 prior to bulk app removal.
- Fallback DISM uninstaller injected into RemoveApps.ps1 for resilient packages like Dev Home, new Teams, and Copilot Provider.
- CBS Registry backups triggered before feature modifications.

## [v3.1.0] - 2026-08-19
### Added
- Track 1 AI Purge: Deep disables for Paint Co-Creator AI, Windows Studio Effects AI telemetry, Auto SR (Super Resolution) analytics, Live Captions, and Voice Access.
- Start Menu Overrides: Injected BingSearchEnabled lock into Disable_Bing_Cortana_In_Search.reg.
- Appx Targets: Mapped Microsoft.Windows.AI.Copilot.Provider for complete removal alongside existing Copilot components.
- Cloud Nag Suppression: Silenced Windows Backup cloud sync nags and Smart App Control telemetry.

# Project History

## Origins
WinSwift is a private, rebranded fork of the widely successful open-source project `Raphire/Win11Debloat`. The original project provided a powerful PowerShell script with an extensive GUI built in WPF to customize and debloat Windows 11.

## Evolution
We cloned the repository to create a bespoke internal version that is easier to maintain and strictly aligns with our organizational needs. 

### Key Milestones:
1. **Initial Fork & Rebranding**: The project was cloned to the `classic` branch. All scripts, variables, and documentation referencing "Win11Debloat" were rebranded to "WinSwift". Original developer credits were maintained.
2. **Structural Split**: Separated core monolithic scripts into granular PowerShell components (`Features/`, `AppRemoval/`, `GUI/`).
3. **Data Localization**: Extracted massive hardcoded parameter arrays (apps, telemetry services) into standard JSON configuration files (`Apps.json`, `Features.json`).
4. **24H2/25H2 Adaptation (July 2026)**: Added deep blocks for modern Microsoft Copilot+, Windows Recall, and generative AI features injected into standard system apps.
5. **Modernization Audit (August 2026)**: Cross-referenced community bug reports to ensure debloat practices don't break Component-Based Servicing or Windows Updates, and formalized structural system restore logic.
2. **Build System Integration**: Added a `build.ps1` script to dynamically merge the modularized `Scripts/` and `Schemas/` folders into a single, portable `WinSwift-Standalone.ps1` executable.
3. **UI Redesign**: Re-engineered the Graphical User Interface to be denser and more responsive. The 3-column category layout was reduced to 2 columns to limit vertical scrolling, and padding/margins were trimmed. High-contrast theming was applied to dropdowns to fix readability issues.
4. **Code Organization**: Abstracted extensive UAC elevation logic and path initialization out of the primary entry script and into dedicated helper scripts (`Ensure-Admin.ps1` and `Initialize-Environment.ps1`).

## Future Roadmap
- Implementation of a CI/CD pipeline via GitHub Actions to automate the bundling of `WinSwift-Standalone.ps1` on every push to `master`.
- Integration with external telemetry and dashboard services for remote execution monitoring.




