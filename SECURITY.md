# Security Policy for Winnow

Winnow is a modular Windows 11 optimization and debloating toolkit. Because Winnow modifies Windows system configurations, security and OS stability are paramount.

---

## Supported Versions

| Version | Supported | Status |
|---|---|---|
| `4.0.x` | Yes | Active production release for Windows 11 (24H2, 25H2). Current Winnow line |
| `3.x` | No | Superseded by 4.0. Published under the former name, WinSwift; 3.3.x and earlier also carried the elevation-guard bug fixed in 3.4.0 |
| `< 3.0` | No | Legacy baseline |

---

## Reporting a Vulnerability

Report vulnerabilities securely through [GitHub Private Vulnerability Reporting](https://github.com/BiosSystem/Winnow/security/advisories/new). Do not open public GitHub issues.

---

## Security Principles & Hardening

### 1. Non-Destructive GPO / Policy Suppression
- Winnow uses Group Policy and registry configurations to disable telemetry, Copilot, Recall, and background services. It **never deletes system binaries** (`explorer.exe`, `SearchHost.exe`), ensuring cumulative Windows Updates and anti-cheat drivers (Vanguard, EAC, BattlEye, FACEIT) remain 100 percent operational.

### 2. UAC Elevation & Win32 Argument Quoting
- Re-elevation processes rigorously escape paths, script parameters, and user flags to prevent command injection via crafted folder names or CLI arguments.

### 3. Mark-of-the-Web Safety
- The orchestrator validates execution policy and unblocks only signed/validated PowerShell scripts without disabling system-wide execution restrictions.

### 4. Desired-State Verification
- Integrated `-Verify` and `-VerifyProfile` audit modes allow administrators to inspect system state and verify drift with exit code `2` before applying changes.

### 5. Elevation Enforcement
- The administrator check stops the run before any runtime module loads. Versions before 3.4.0 printed the warning but continued into the apply pipeline, because `exit` inside a dot-sourced script does not terminate the caller. A non-elevated run could reach registry imports and scheduled task changes and fail partway through, leaving a partially applied system.

### 6. Automatic Rollback
- A failed apply restores the registry backup taken before the run instead of leaving the system half-changed. Exit code `3` reports a clean rollback, `4` reports a rollback that itself failed and names the backup file for manual recovery.
