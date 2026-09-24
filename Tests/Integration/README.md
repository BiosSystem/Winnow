# Winnow integration tests

Unit tests exercise functions in isolation. These run `Winnow.ps1` as a real
process, which is the only way to cover startup guards, parameter binding,
config loading, and exit codes together.

That difference is not theoretical. The first thing this suite found was that
the administrator guard did not stop anything: `Ensure-Admin.ps1` is dot-sourced,
`exit` inside a dot-sourced script does not terminate the caller, and a
non-elevated run walked straight into the apply pipeline. Three releases of unit
tests and static validation never caught it, because none of them ran the script.

## Risk tags

Every `Describe` block carries one tag, chosen by what it can do to the machine:

| Tag | What it does | Safe to run on |
|---|---|---|
| `ReadOnly` | Exercises `-Verify`, which reads state and exits before applying anything | Anywhere, including your workstation |
| `DryRun` | Asserts `-DryRun` writes nothing. A regression in the dry-run guard *would* write here | An ephemeral machine: CI runner or Sandbox |
| `Mutating` | Deliberately applies changes | Windows Sandbox only |

Nothing beyond `ReadOnly` runs unless you ask for it.

## Running them

Read-only checks, safe on a workstation:

```powershell
.\Tests\Integration\Invoke-IntegrationTests.ps1
```

Run this from a normal, non-elevated PowerShell as well as from an elevated one.
One test, `refuses to verify without elevation`, only runs unelevated, and the
CI runner and Windows Sandbox are both elevated, so a workstation run is the only
place it executes. Unelevated, Winnow stops at its admin check without a UAC
prompt, because the test runs it with input redirected.

Adding the dry-run checks, on a machine you can throw away:

```powershell
.\Tests\Integration\Invoke-IntegrationTests.ps1 -Ephemeral
```

The full suite runs in Windows Sandbox. The simplest way is the launcher, from a
normal (non-elevated) PowerShell at the repository root:

```powershell
.\Tests\Integration\Sandbox\Invoke-SandboxRun.ps1 -CloseWhenDone
```

It writes a sandbox configuration for wherever this clone lives, starts Windows
Sandbox, waits for the suite inside it to finish, prints the result, and exits
`0` when everything passed, `1` when a test failed, and `2` when the run did not
start or finish. The repository is mapped read-only and only `Sandbox\results`
is writable, so the mutating tests can only change the disposable sandbox.

`Sandbox\Winnow-Tests.wsb` does the same by hand: open it to start a run. Its
two `HostFolder` paths are absolute, so edit them to point at your clone first.

**Windows Sandbox has to be enabled first.** It ships with Windows 11 Pro and
Enterprise but is off by default. From an elevated PowerShell:

```powershell
Enable-WindowsOptionalFeature -Online -FeatureName Containers-DisposableClientVM -All
```

That needs a reboot. Check whether it is already on with
`Test-Path C:\Windows\System32\WindowsSandbox.exe`.

Results land in `Sandbox\results` on the host: `integration-results.xml` (NUnit),
`integration-summary.json` (counts, the name and message of every failed test,
and `BlockFailures` for any `BeforeAll`/`AfterAll` that failed, which is where the
cause lives when tests report that they did not run), and `sandbox-transcript.log`.
If the bootstrap itself fails before the suite writes its summary, the error goes
into the summary; if it fails afterwards, it goes into `bootstrap-error.json` so
the per-test results are not overwritten. Nothing else survives the sandbox
closing, console output included.

Only one sandbox can run at a time. After closing one, wait until the
`vmmemWindowsSandbox` process has exited before starting the next: a sandbox
started while the previous VM is still tearing down can boot without its mapped
folders, and the run then never starts or writes anything.

Requires Pester 5.7.1 or later. Winnow refuses to run without elevation, so an
unelevated session will skip most cases and say so.

## What is covered

**`VerifyContract.Tests.ps1`** - `ReadOnly`. Exit-code contract for `-Verify` and
profile parsing. Every case is deterministic on any machine: whether a real tweak
is currently applied depends on how the host is configured, so none of these
assert on one. The cases that are machine-independent are an exempt-only profile
(`NotApplicable` must never fail a run), an unknown feature, an empty profile, a
missing profile path, and an app id that cannot exist.

**`DryRunSafety.Tests.ps1`** - `DryRun`. Proves `-DryRun` reaches the apply
pipeline and still changes nothing. The assertion targets the exact values the
selected feature would write, read out of its `.reg` file, rather than sweeping
the registry broadly.

**`ApplyRoundTrip.Tests.ps1`** - `Mutating`. Applies a registry-backed feature and
checks both the verification verdict and the individual values underneath it, so
a partially applied `.reg` file cannot pass as compliant.

**`RollbackContract.Tests.ps1`** - `Mutating`. The executable specification for
Track 1 automatic rollback. Rollback does not exist yet, so the whole block skips
itself until `InvokeChanges.ps1` references `Restore-RegistryBackupState`. When
Track 1 wires that up, these activate on their own.

**`ModuleRegistryRollback.Tests.ps1`** - `Mutating`. Scope B of full-module rollback
against the real registry. Captures a module's declared registry targets, drifts a
representative subset that mixes HKCU and HKLM and string and DWord types, restores from
the snapshot, and asserts each target is back to exactly what was captured, type included,
plus that a value the module created where none existed is removed rather than left behind.

**`WatchdogEnforcement.Tests.ps1`** - `Mutating`. Installs the real update watchdog and
checks the mutations that only happen live: the SYSTEM task is registered, the payload
directory is locked to SYSTEM and Administrators, the recorded hash makes the integrity
check pass, a drifted machine policy is re-asserted against the real registry while an
already-correct value is left untouched, and a tampered payload fails the check closed.
Everything it installs is removed in teardown.

They also pin the two open decisions in section 9 of the plan. The load-bearing
one is that an app-removal failure must **not** trigger rollback: a registry
restore cannot bring back an uninstalled Appx package, so rolling back there
would report a recovery that did not happen while the apps stay gone. If the
failure policy changes, these assertions are what has to change with it.

## File naming

Pester 5 only discovers files matching `*.Tests.ps1` when given a directory, so
these are named that way rather than following the `Test-*.ps1` convention used
in `Tests/Unit`, which CI invokes by explicit path. The runner fails when it
discovers nothing, because an empty suite otherwise reports success.

## Known gaps

**Undo used to be untestable, and is no longer.** Scenario 2 of Track 3 needed an
apply/undo round trip, but undo was reachable only from the GUI: `Winnow.ps1`
initialised `$script:UndoParams` empty and only `Show-MainWindow.ps1` ever
populated it. `Invoke-UndoFeatures` and the per-feature `RegistryUndoKey`
metadata existed, but nothing on the command line could select a feature for
undo, so unattended deployments could apply changes and never revert them.

The `-Undo` parameter closes that. It accepts the 89 of 114 features that declare
a `RegistryUndoKey` or have a case in `Invoke-FeatureUndo`, and rejects the rest
rather than reporting success while doing nothing.

**CI runs more than the plan expected.** Section 5.2 assumed CI would be limited
to non-mutating cases because Windows Sandbox is unavailable on hosted runners.
In practice the `windows-2025` runner is build 26100 and runs elevated, so it
clears both the Windows version gate and the administrator guard, and the
`ReadOnly` and `DryRun` tags both run there. Sandbox is still needed for
`Mutating`, because Server 2025 has no Start menu `start2.bin` and a limited Appx
stack.
