# Execution Architecture

Winnow is a modular, extensible PowerShell 5.1 engine. The core orchestrator reads JSON feature definitions at runtime, dispatches work to self-contained module scripts, captures system state before and after execution, and verifies compliance through a desired-state engine.

## Pre-Execution Safety Gate

Before any module executes, Winnow validates the runtime environment:

1. **PowerShell version guard** - Halts if the host is not Windows PowerShell 5.1. PowerShell 7 cannot reliably invoke Appx removal cmdlets or system restore APIs.
2. **Administrator elevation** - Checks `[Security.Principal.WindowsPrincipal]` and restarts under `Start-Process powershell -Verb RunAs` if elevation is absent. UAC arguments are quoted using Win32-safe escaping. The standalone build elevates *before* it unpacks its payload, then extracts to a fresh directory locked to Administrators and SYSTEM (inheritance off). This closes a local privilege-escalation path: if a non-elevated process extracted first and Winnow then self-elevated, the elevated run would be reading its scripts from a directory the standard user could still overwrite between extraction and execution.
3. **Mark-of-the-Web handling** - Unblocks only marked PowerShell source files when Group Policy overrides the execution policy. Executable and data files are not unblocked.
4. **Domain-join warning** - Detects domain-joined systems and warns that Group Policy may override applied registry changes after the next policy refresh.
5. **Path and asset validation** - Confirms that all required directories (`Assets`, `Config`, `Regfiles`, `Schemas`, `Scripts`) are present before loading any module.
6. **Registry backup** - Captures a timestamped JSON snapshot of all scheduled modification targets to `Backups\Winnow-RegistryBackup-<timestamp>.json` unless `-SkipRegistryBackup` is explicitly specified. This snapshot is what automatic rollback restores from.
7. **System restore point** - Creates a system restore point before executing any of the four high-impact custom modules: gaming optimization, extended AI purge, security hardening, or telemetry firewall.

## Feature Definition: Config/Features.json

All tweaks are defined declaratively in `Config/Features.json`. The schema allows contributors to add new features without modifying the core engine:

- `Categories` - logical groupings shown in the GUI (Privacy, Gaming, AI, System, etc.)
- `UiGroups` - radio or dropdown groups for mutually exclusive options (e.g., taskbar search style)
- `Features` - individual feature definitions containing:
  - `Label` and `ToolTip` for the GUI
  - `Category` for placement
  - `InvokeFeature` and `UndoFeature` pointing to the apply and revert function names
  - `VerifyFeature` pointing to the verification adapter function name
  - `Reg` array of registry operations (path, name, type, value, target state)
  - `Appx` array of package names to remove
  - `Service` array of service names and startup types to configure
  - `ScheduledTask` array of task paths to disable

## Core Apply Engine

`Scripts/Features/InvokeChanges.ps1` dispatches each enabled feature through `Invoke-WinnowFeature`. The engine:

1. Reads the feature definition from the in-memory parsed JSON.
2. Calls `ShouldProcess` before every registry write, Appx removal, or service change, enabling full `-WhatIf` dry-run support.
3. Applies registry values via `Set-ItemProperty` with explicit type casting.
4. Removes Appx packages via `Remove-AppxPackage` (current user) and `Remove-AppxProvisionedPackage` (provisioned image).
5. Configures services via `Set-Service -StartupType` and `Stop-Service`.
6. Disables scheduled tasks via `Disable-ScheduledTask`.
7. Increments per-operation success and failure counters for the run summary.

No Windows binary files are deleted. No Windows service registrations are removed from the service control manager database. All changes are reversible through the rollback mechanism.

## Custom Modules

Four Winnow-owned modules extend beyond the upstream feature set and are invoked through a unified routing layer:

| Module | Script | Key Operations |
|---|---|---|
| Gaming Mode | `GamingMode.ps1` | High Performance power plan, Nagle Algorithm disable, HAGS registry enable, GameDVR off, Sticky Keys off, startup delay zero, automatic maintenance disable |
| Competitive Esports | `CompetitiveGaming.ps1` | Ultimate Performance power plan, 0.5ms GlobalTimerResolutionRequests, BCD useplatformtick and disabledynamictick, MMCSS NetworkThrottlingIndex 0xFFFFFFFF and SystemResponsiveness 0, MMCSS Games GPU Priority 8 and Priority 6, CPU core parking ValueMax 0 |
| Extended AI Purge | `ExtendedAIPurge.ps1` | Recall suppression, Click To Do disable, AI service startup prevention, Edge AI feature disables, Paint and Notepad AI removes |
| Security Hardening | `SecurityHardening.ps1` | SMBv1 disable, TLS 1.0 and 1.1 disable, AutoRun and Windows Script Host restriction, BitLocker auto-encryption prevention |
| Telemetry Firewall | `BlockTelemetryFirewall.ps1` and `TelemetryScheduledTasks.ps1` | Outbound Windows Firewall rules blocking Microsoft telemetry endpoints, full disable of telemetry and diagnostic scheduled tasks |

## Desired-State Verification Engine

`Scripts/Features/DesiredStateVerification.ps1` implements the compliance verification layer. At verification time:

1. For each requested feature, the engine reads the current system state.
2. Registry values are read back via `Get-ItemPropertyValue` and compared to the expected target value.
3. Appx package presence is checked via `Get-AppxPackage` and `Get-AppxProvisionedPackage`.
4. Custom module state is verified through metadata-driven adapter functions referenced by `VerifyFeature` in the JSON definition.
5. Each feature is marked `Compliant`, `NonCompliant`, `Unsupported`, or `Failed`.
6. The engine exits with code `0` if all verified features are compliant, or code `2` if any feature is noncompliant, unsupported, or produced a verification failure.

Verification can be triggered three ways:

```powershell
# Inline after apply
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Winnow.ps1 -DisableTelemetry -DisableCopilot -Verify -Silent

# Standalone compliance audit against a profile
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Winnow.ps1 -VerifyProfile .\Config\DefaultSettings.json -Silent

# Parameter-driven verification of specific features
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Winnow.ps1 -Verify -DisableRecall -DisableGameDVR -Silent
```

## Rollback Protocols

### Automatic Rollback

When the apply phase fails, Winnow restores the backup taken before the run. The backup is captured in phase 1, before anything is written, so the material needed to recover already exists at the moment of failure.

A registry import failure triggers the restore, whether it was counted through `$script:RegistryImportFailures` or thrown as an exception. An app removal failure does not: a registry backup cannot reinstall a removed Appx package, so restoring there would claim a recovery that did not happen. Undo work is skipped after a rollback.

Exit code `3` means the run failed and was rolled back cleanly. Exit code `4` means the rollback itself failed, and the run summary names the backup file so recovery can be finished by hand.

Pass `-NoAutoRollback` to leave the failed state in place.

### Manual Registry Rollback

Backups are JSON, not `.reg` exports, and are restored through the engine rather than `reg import`:

```powershell
. .\Scripts\Features\RestoreRegistryBackup.ps1
$backup = Load-RegistryBackupFromFile -FilePath '.\Backups\Winnow-RegistryBackup-<timestamp>.json'
Restore-RegistryBackupState -Backup $backup
```

### Feature Undo

Revert individual features by id:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Winnow.ps1 -CLI -Silent -Undo DisableTelemetry
```

Undo covers the 89 of 114 features that declare a `RegistryUndoKey` or have a case in `Invoke-FeatureUndo`. The rest are rejected rather than silently doing nothing.

### System Restore Rollback

For changes applied through the four high-impact custom modules, the System Restore point created before execution provides a full OS-level rollback path accessible through `rstrui.exe` or the Settings app.

### Appx Package Restore

Removed Appx packages can be reinstalled from the Microsoft Store. Provisioned packages can be restored using `Add-AppxProvisionedPackage` with the appropriate cabinet file from a Windows installation image.

## WhatIf Mode

Pass `-DryRun` to engage WhatIf mode across all apply operations:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Winnow.ps1 -DisableTelemetry -DisableCopilot -DryRun
```

All registry writes, Appx removals, and service configuration calls will log what they would do without modifying the system. The run summary at completion shows the full list of planned operations.
