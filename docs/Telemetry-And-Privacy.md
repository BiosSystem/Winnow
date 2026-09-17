# 🕵️ Telemetry & Privacy Hardening

Winnow uses a "Defense in Depth" approach to telemetry blocking.

## Service & Registry Disablement
We disable `DiagTrack` (Connected User Experiences and Telemetry) and `dmwappushservice`. 
Targeted ads and App Launch tracking are disabled via `HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo`.

## Dual-Layer Endpoint Blocking
Winnow blocks the telemetry and AI-inference endpoints in two layers:

1. **HOSTS sinkhole (primary).** Every known telemetry domain is pointed at `0.0.0.0` in the hosts file. This is IP-independent, so it keeps working when the endpoint rotates to a new CDN address, which the endpoints do constantly. Examples: `vortex.data.microsoft.com`, `telemetry.microsoft.com`, `settings-win.data.microsoft.com`, `copilot.microsoft.com`.
2. **Firewall rules (additive).** Winnow also resolves each domain at apply time and adds outbound Windows Defender Firewall block rules for those addresses, which catches traffic that reaches a hardcoded IP without a name lookup. These rules go stale as the addresses rotate, so they back up the HOSTS layer rather than being the main block.

Even if the telemetry service starts, name resolution is sinkholed and the current addresses are dropped at the network layer. A single marked block in the hosts file (`# Winnow-TelemetryBlock-Start/End`) keeps the change contained and reversible.

## The Update Watchdog
With the `-EnableUpdateWatchdog` switch, Winnow registers a lightweight Scheduled Task (`\Winnow\Winnow_UpdateWatchdog`) that runs as SYSTEM. It triggers on the Windows Update install events (Event ID `19` and `43` from `Microsoft-Windows-WindowsUpdateClient`), with a daily fallback if the event trigger cannot be created. When it fires it re-asserts the privacy policy floor Windows Update and the in-box re-provisioning most often reset: the `AllowTelemetry` policy, the Copilot, Recall, and Windows AI policies, generative fill, cross-device clipboard, ink workspace, and OneDrive sync policies, the `DiagTrack` and `dmwappushservice` services, and the CEIP telemetry scheduled tasks. It touches only what has drifted and logs what it corrected to `%ProgramData%\Winnow\watchdog.log`. The floor is limited to machine-wide (`HKLM`) policy keys, because a SYSTEM task has no user context and must not guess a hive.

### Tamper resistance
The task runs as SYSTEM, so the script it executes is a privileged target. Winnow hardens it two ways:

* **Locked directory.** `%ProgramData%\Winnow` is given a protected ACL (inheritance off) that grants Full Control only to SYSTEM and Administrators; standard users get read and execute. A SYSTEM task that ran a script from a directory a non-admin could write to would be a local privilege-escalation path, and this closes it. The watchdog re-applies this ACL on every run, so a directory that was loosened after install is tightened again before anything inside it is trusted.
* **Self-integrity check.** At install the payload's SHA256 is recorded under `HKLM\SOFTWARE\Winnow\Watchdog` (writable only by an admin or SYSTEM). Before enforcing, the payload re-hashes itself and refuses to run if the hash does not match, so a swapped-out payload cannot make the SYSTEM task apply an attacker's settings. Missing or unreadable state fails closed. If the check fails it logs a security warning and does nothing; re-running Winnow reinstalls a clean payload.

Because a fail-closed control is silent when it refuses to act, `Winnow.ps1 -VerifyWatchdog` prints a read-only health report: whether the task is registered, whether the payload still matches its recorded hash, whether the directory is still locked down, and when it last ran. It exits `0` when healthy and `2` when degraded or not installed, so it drops into a scheduled check or a monitoring script.

The watchdog also mirrors its security-relevant lines to the Windows event log (source `Winnow`, in the `Application` log), registered by the installer: an integrity failure is written as an Error (event ID `2000`) and a corrected drift as a Warning (event ID `1000`). This makes a tamper attempt or a reset auditable centrally and collectable by a SIEM, not only readable in a local text file that the same local attacker could edit. If the source cannot be registered the payload falls back to the text log alone.
