# Changelog

Document all notable Winnow changes in this file. Releases before 4.0.0 were published under the project's former name, WinSwift.

Follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The update watchdog now mirrors its security-relevant lines to the Windows event log (source `Winnow`, `Application` log, registered at install): an integrity failure as an Error (event ID `2000`) and a corrected drift as a Warning (event ID `1000`). A tamper attempt against a SYSTEM control is now auditable and SIEM-collectable, not only in a local text file the same attacker could edit. Falls back to the text log if the source cannot be registered.
- `-VerifyWatchdog` prints a read-only health report for the update watchdog: whether the task is registered, whether the payload still matches the hash recorded at install, whether the payload directory is still locked down, and when it last ran. Exits `0` when healthy and `2` when degraded or not installed, so a fail-closed watchdog that quietly refused to run is now visible to a scheduled check or monitoring script.

### Changed

- Reworked the update watchdog so it re-asserts the whole privacy policy floor instead of only the `AllowTelemetry` policy and the `DiagTrack` service. It now also re-applies the Copilot, Recall, Windows AI, generative fill, cross-device clipboard, ink workspace, and OneDrive sync policies, the `dmwappushservice` service, and the CEIP telemetry scheduled tasks, touching only the ones that have drifted. The floor is limited to machine-wide `HKLM` policy keys because a SYSTEM task has no user context.

### Security

- Closed a local privilege-escalation path in the standalone build. It extracted its payload to a per-user `%TEMP%` directory and ran Winnow from there before Winnow self-elevated, so the elevated run read its roughly hundred dot-sourced scripts from a directory the standard user could still overwrite between extraction and execution. The standalone now elevates first and extracts to a fresh directory locked to Administrators and SYSTEM (inheritance off, named with a full GUID). `Tests/Unit/Test-StandaloneWrapper.ps1` builds the artifact and asserts the elevate-before-extract ordering and the locked-directory ACL.
- Hardened the watchdog against tampering, since its scheduled task runs the payload as SYSTEM. `%ProgramData%\Winnow` now gets a protected ACL (SYSTEM and Administrators Full Control, standard users read and execute, inheritance off), re-applied on every run, which closes the local privilege-escalation path where a non-admin could replace a script a SYSTEM task executes. The payload's SHA256 is recorded under an admin-only `HKLM` key at install and re-checked before each run; a payload that does not match refuses to enforce and logs a warning, and missing or unreadable state fails closed. The payload ships as `Scripts/Watchdog/WatchdogPayload.ps1` with unit coverage for the ACL, the integrity check, and the drift-only enforcement. The end-to-end path against a real Windows update is still only exercisable in a live environment.

## [4.1.0] - 2026-09-13

### Added

- Full-module rollback (Scope A). Automatic rollback now also reverts the reversible non-registry state that module features change - service start types, Winnow's telemetry firewall rules and HOSTS block, disabled scheduled tasks, and the SMB1 optional feature - captured before the apply and restored on failure alongside the registry backup. One-way operations (Recall component removal, app removal, Edge removal) and the modules' imperative registry writes are reported as not restored rather than silently left in place.
- Reject structurally inconsistent import configurations before applying them (`Test-ConfigConsistency`), wired into both the CLI and GUI import paths.

## [4.0.1] - 2026-09-13

### Fixed

- Read the three app-list JSON loaders (`LoadAppPresetsFromJson`, `LoadAppsDetailsFromJson`, `LoadAppsFromFile`) as UTF-8 instead of the OS ANSI codepage, matching the main JSON loader. Latent today because `Apps.json` is ASCII, but it prevents an accented app name from being corrupted later.

### Changed

- Replaced the generic hero image with an SVG wordmark banner and refreshed the README header (tests and Windows 11 badges, differentiators-first intro, no marketing filler). Documentation and branding only.

This patch brings the released artifact in line with `master`; 4.0.0 was tagged before these two changes merged. No behaviour change from 4.0.0 beyond the encoding fix above.

## [4.0.0] - 2026-09-11

### Changed

- Renamed the project from WinSwift to Winnow. The repository, the entry script (`Winnow.ps1`), the standalone build (`Winnow-Standalone.ps1`), the `WINNOW_VERSION` constant, the GUI title bar and About dialog, the installer one-liner, and all documentation now use the new name. The old `BiosSystem/WinSwift` repository URL redirects to `BiosSystem/Winnow`, and the release assets are now `Winnow-Standalone.ps1` and `Winnow-v4.0.0.zip`.
- Rebrand only. No feature behaviour changed; the 3.5.0 functionality carries over unchanged. The major version reflects that the repository, entry-point, and asset names moved, which is a breaking change for anything referencing the old paths.

## [3.5.0] - 2026-09-09

### Added

- Localization framework. Feature text, categories, and the GUI chrome are read from per-language catalogues under `Config/Languages`, with per-key fallback to en-US and then to `Features.json`.
- Spanish (es-ES) translation, including the window chrome, with correct accents.
- Preset library under `Config/Presets`. A preset names a set of switches and is validated before the run starts: an unknown switch, a duplicate, or two values from one mutually exclusive group is rejected rather than silently applying nothing.
- `DisableSearchHistory` and `DisableSearchHighlights` are now wired to real registry changes; both switches previously did nothing.
- The extended AI purge removes the Recall optional component where present, instead of only setting the disable policies.

### Changed

- The Update Watchdog (`-EnableUpdateWatchdog`) now triggers on the Windows Update install events and re-applies the telemetry settings an update most often resets, instead of running a daily check that only warned. It re-asserts the `AllowTelemetry` policy and the `DiagTrack` service.
- Copilot is removed through the Appx/DISM path rather than WinGet, so the app-list removal works when WinGet is broken or absent.
- The extended gaming, ads, software-install, and watchdog modules run only after a clean apply, and a restore point is forced before the competitive-gaming module.
- Registry backups are read as UTF-8 so accented profile paths round-trip.

### Fixed

- A run reported success when app removals or features failed. App-removal failures are now counted and surfaced in the CLI, the GUI completion screen, the run summary, and the exit code; unverifiable removals are flagged rather than assumed to have worked. A skipped rollback or any surviving failure now exits non-zero.
- `-WhatIf` made real changes for the watchdog and Defender-exclusion steps, which were gated on `-DryRun` only.
- `-ForceRemoveEdge` was declared but never invoked; the switch now runs the force-remove.
- The Edge force-remove treated the 24H2/25H2 uninstaller block (exit code 532) as a generic warning and could report success while Edge stayed installed. It now reports the block explicitly and verifies Edge is gone before claiming success.
- The app-removal scope selection and the Ctrl+F shortcut were dropped under a translated UI because they matched on English text that localization rewrites.
- Eight features threw in `-Sysprep`/`-User` mode, and every undo file failed there, because the resolver only looked under `Regfiles\Sysprep`. It now falls back to the root file, and the four HKCU tweaks that were missing a Sysprep variant now ship one.
- Corrected stale documentation: undo counts, the watchdog description, and the upstream-parity claims in `UPSTREAM.md`.

### Known limitations

- The hardware-dependent paths have not been executed on a real 24H2/25H2 machine: automatic rollback, the Edge exit-532 handling, Recall component removal, the watchdog event trigger, and a Sysprep pass against an offline hive. They are covered by source-level assertions, unit tests, and the resolver checks in CI.
- The es-ES layout has not had a visual pass; Spanish strings run longer than English, so some controls may need width adjustment.

## [3.4.0] - 2026-09-06

### Added

- Roll back registry changes automatically when the apply phase fails, restoring the backup taken before the run.
- Add `-NoAutoRollback` to keep a failed run in place for inspection.
- Add `-Undo` to select features for undo from the command line. Undo was previously reachable only from the GUI, so unattended deployments could apply changes but never revert them.
- Return exit code `3` when an apply failed and was rolled back, and `4` when the rollback itself failed.
- Record rollback outcome, reason, and backup path in the run summary.
- Add the `AppxAbsence`, `StartLayout`, and `EdgeRemoved` verification adapters, giving all 114 features a verification story.
- Add the `NotApplicable` verification status for entries that carry no persistent desired state.
- Add an integration test suite that runs WinSwift as a real process, tagged by what it can change on the host.
- Add a Windows Sandbox harness for the mutating tests that writes results back to the host.

### Changed

- Route verification through the adapter declared in `Features.json` instead of a hardcoded feature list.
- Skip undo work after a failed apply.
- Pass exact provisioned package names to the 24H2 DISM fallback.
- Advance the upstream reconciliation baseline to `6012b02`.

### Fixed

- Stop a non-elevated run from continuing past the administrator guard. `exit` inside a dot-sourced script does not terminate the caller, so every exit in the guard was inert and the run proceeded into the apply pipeline.
- Catch apply-phase exceptions so rollback is reachable. A missing `.reg` file threw and escaped the run entirely.
- Write the run summary at all. Its export was guarded on `$script:RunStartTime`, which nothing ever assigned.
- Accept empty collections in `Export-RunSummary`, which rejected apply-only and undo-only runs.
- Remove a duplicate 24H2 DISM fallback that re-ran the same removal without error handling.
- Harden `ForceRemoveEdge` with a `WhatIf` guard, exit-code checking, and per-path cleanup reporting.

## [3.3.0] - 2026-08-23

### Added

- Add desired-state verification with registry read-back and installed plus provisioned Appx checks.
- Add `-Verify` and `-VerifyProfile` for unattended compliance checks.
- Return exit code `2` for noncompliant, unsupported, or failed verification.
- Add metadata-driven verification adapters for gaming mode, extended AI purge, security hardening, and telemetry firewall state.
- Add static PowerShell parsing, duplicate-function detection, JSON validation, and PSScriptAnalyzer enforcement.
- Add Pester coverage for verification, custom feature routing, and startup safety contracts.
- Add `UPSTREAM.md` and `CREDITS.md` for upstream reconciliation and attribution.

### Changed

- Require Windows PowerShell 5.1 before loading Appx and system restore code.
- Quote UAC elevation arguments with Win32-safe escaping.
- Limit Mark-of-the-Web handling to marked PowerShell source files when Group Policy overrides execution policy.
- Warn on domain-joined systems and return nonzero exit codes for missing runtime files.
- Route verified custom modules through the unified feature execution engine.
- Expose every configured feature through a direct command-line parameter.
- Require a system restore point before gaming, extended AI purge, security hardening, or telemetry firewall changes.
- Direct single-file quick-start installations to the standalone release asset.
- Propagate the modular process exit code through the standalone wrapper.
- Quote bootstrap launcher arguments safely and propagate the child process exit code.
- Run unit and static validation on pushes to `master` and `dev`.

### Fixed

- Remove an undefined extended AI purge expression.
- Initialize runtime parameters before the update check.
- Repair the malformed WPF fallback warning.
- Replace a Windows PowerShell 5.1-incompatible update banner.
- Keep registry backup progress counts consistent when `-SkipRegistryBackup` is used.
- Correct malformed application JSON and invalid software-installer interpolation found during release stabilization.
- Remove duplicate feature function declarations that bypassed parser-only validation.

## [3.2.0] - 2026-08-14

### Added

- Add system restore enforcement before bulk app removal.
- Add Component-Based Servicing registry backup support.
- Add a DISM fallback for resistant Appx packages.
- Add explicit system-wide Copilot policy blocks.
- Add Windows 11 architecture discovery documentation.

### Changed

- Validate 144 application records and the complete standalone payload before publication.
- Remove 460 lines of duplicated function declarations from `Scripts/Features/InvokeChanges.ps1`.

### Fixed

- Correct the malformed Copilot `AppId` array in `Config/Apps.json`.
- Fix invalid variable interpolation in `Scripts/Features/SoftwareInstaller.ps1`.

## [3.1.0] - 2026-07-25

### Added

- Add Windows 11 24H2 and 25H2 AI controls for Photos, Clipboard, Microsoft 365, Outlook, and Narrator.
- Add telemetry service and scheduled-task controls.
- Add Advertising ID and voice activation controls.
- Add Windows Update driver and feature-update policies.
- Add Pester tests for feature metadata, applications, and registry files.
- Add JSON run summaries and unattended Windows setup generation.

### Changed

- Expand telemetry firewall and HOSTS fallback coverage.
- Modernize the modular feature architecture and release validation workflow.

## [3.0.0] - 2026-07-16

### Added

- Add the Windows Update watchdog scheduled task.
- Add telemetry firewall and HOSTS endpoint blocking.
- Add Defender gaming exclusions for common game libraries.

## [2.4.0] - 2026-07-11

### Added

- Add `autounattend.xml` generation with configurable output paths.

## [2.3.0] - 2026-07-11

### Added

- Add Winget software installation for a curated application list.
- Add reusable JSON preset profiles.
- Add dry-run execution through `-DryRun`.

## [2.2.0] - 2026-07-11

### Added

- Add competitive gaming mode with power, timer, scheduler, and optional Memory Integrity controls.
- Add Settings advertising suppression.
- Add deep Widgets removal and policy enforcement.
- Add automatic release update checks.

## [2.1.0] - 2026-07-11

### Added

- Add gaming and performance profiles.
- Add security hardening and extended AI purge modules.
- Add Windows advertising suppression.

### Fixed

- Replace the incompatible pipeline quick-run command with file-based execution.

## [2.0.0] - 2026-07-11

### Added

- Add the standalone source bundler.
- Add the AI and Copilot purge module.
- Add the WinSwift version constant and branch release model.
- Add project documentation, security policy, and contribution guidelines.

### Changed

- Rebrand the Win11Debloat fork as WinSwift while preserving upstream attribution.
- Modularize administrator checks and environment initialization.
- Redesign the WPF interface around a responsive two-column layout.

## [1.0.0] - 2026-07-04

### Added

- Create the WinSwift fork from [Raphire/Win11Debloat](https://github.com/Raphire/Win11Debloat).

[3.3.0]: https://github.com/BiosSystem/WinSwift/compare/v3.2.0...v3.3.0
[3.2.0]: https://github.com/BiosSystem/WinSwift/compare/v3.1.0...v3.2.0
[3.1.0]: https://github.com/BiosSystem/WinSwift/compare/v3.0.0...v3.1.0
[3.0.0]: https://github.com/BiosSystem/WinSwift/compare/v2.4.0...v3.0.0
[2.4.0]: https://github.com/BiosSystem/WinSwift/compare/v2.3.0...v2.4.0
[2.3.0]: https://github.com/BiosSystem/WinSwift/compare/v2.2.0...v2.3.0
[2.2.0]: https://github.com/BiosSystem/WinSwift/compare/v2.1.0...v2.2.0
[2.1.0]: https://github.com/BiosSystem/WinSwift/compare/v2.0.0...v2.1.0
[2.0.0]: https://github.com/BiosSystem/WinSwift/compare/v1.0.0...v2.0.0
[1.0.0]: https://github.com/BiosSystem/WinSwift/releases/tag/v1.0.0
