# 📚 Winnow Developer Wiki

Welcome to the technical documentation for Winnow. These guides are meant for developers, sysadmins, and power users who want a transparent look at exactly how Winnow operates under the hood. 

We believe in open-source transparency - no "black box" registry hacking. Below you will find deep-dives into the exact mechanisms, services, and paths we modify.

## Technical Guides

1. [⚙️ Execution Architecture](Execution-Architecture.md)
   *Learn how the Winnow engine elevates privileges, parses `Features.json`, and safely applies changes using the `$WhatIf` dry-run system.*

2. [🧹 The AI Purge (24H2/25H2)](The-AI-Purge.md)
   *A breakdown of the registry keys and services targeted to neutralize Windows Recall, Copilot, and the WSAIFabricSvc.*

3. [🕵️ Telemetry & Privacy Hardening](Telemetry-And-Privacy.md)
   *Discover the exact domains blocked by our firewall rules and how the Update Watchdog scheduled task ensures your privacy survives Windows Updates.*

4. [🎮 Performance & Gaming Optimization](Performance-And-Gaming.md)
   *Understand MMCSS tuning (`NetworkThrottlingIndex`), 0.5ms Timer Resolutions, CPU core parking, and Windows Defender real-time exclusions.*

## How Winnow compares

Winnow treats a debloat run as a reversible, verifiable, update-surviving operation rather than a one-shot set of toggles. That is where it leads the alternatives: automatic rollback when an apply fails, `-Verify` state checks with exit codes for automation, and an update watchdog that re-asserts your privacy settings after Windows resets them. Where another tool is the better fit, such as WinUtil for an all-in-one suite or O&O ShutUp10++ for a gentler on-ramp, the comparison says so.

See [COMPARISON.md](../COMPARISON.md) for the sourced, tool-by-tool breakdown against Raphire/Win11Debloat, O&O ShutUp10++, Chris Titus WinUtil, custom ISOs, and Sophia Script, including Winnow's own limitations.

---
*Winnow - keep the grain, lose the bloat.*
