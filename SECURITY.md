# Security Policy for Winnow

Winnow is a modular Windows 11 optimization and debloating toolkit. Because Winnow modifies Windows system configurations, security and OS stability are paramount.

---

## Supported Versions

| Version | Supported | Status |
|---|---|---|
| `4.3.x` | Yes | Active production release for Windows 11 (24H2, 25H2). Current Winnow line. Carries the 4.2 security-hardening cycle, plus a working `-VerifyWatchdog` health check (it reported every watchdog as not installed in 4.2.x) and the first release whose rollback and watchdog paths were exercised end to end in Windows Sandbox |
| `4.2.x` | No | Superseded by 4.3. 4.2.1 through 4.2.3 introduced the security-hardening cycle (watchdog ACL/integrity anchor, standalone elevate-first extraction, winget argument isolation, reliable user-hive unload), but `-VerifyWatchdog` could not find the watchdog task |
| `4.0.x` - `4.1.x` | No | Superseded by 4.2. Predate the watchdog and standalone privilege-escalation fixes |
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

### 7. Standalone Extraction Runs Elevated
- The single-file `Winnow-Standalone.ps1` checks for administrator rights before it unpacks anything. If not elevated it relaunches itself through UAC and only then extracts, into a fresh directory whose ACL is locked to Administrators and SYSTEM with inheritance disabled. Earlier builds extracted as the standard user and self-elevated afterward, so the elevated run dot-sourced scripts from a directory the standard user still controlled. That local privilege-escalation path is closed.

### 8. Update Watchdog Integrity
- The optional update watchdog runs its payload as SYSTEM on a scheduled trigger. Its directory under `%ProgramData%\Winnow` carries a protected ACL (SYSTEM and Administrators full control, users read and execute, inheritance off) re-applied on every install, and the payload's SHA256 is recorded in an administrator-only `HKLM\SOFTWARE\Winnow\Watchdog` key. The payload verifies that hash before it enforces anything and fails closed if the check does not match, so a tampered payload does not run. Integrity failures and corrected drift are written to the Windows event log (source `Winnow`) for auditing. `-VerifyWatchdog` reports health read-only.

### 9. Argument Isolation for External Tools
- The software installer passes each winget package id as a discrete argument rather than interpolating it into a single command line, so a crafted id cannot inject extra flags. The generated `autounattend.xml` XML-escapes every user-supplied value, including the embedded config path, so a legal path containing `&`, `<`, or `>` cannot break the unattend file.

### 10. Reliable Offline Hive Handling
- Per-user and Sysprep runs that mount another profile's registry hive force a garbage collection to release lingering .NET registry handles before `reg unload`, and retry once. Earlier builds could leave the hive mounted and only warn, which risked locking the profile.
