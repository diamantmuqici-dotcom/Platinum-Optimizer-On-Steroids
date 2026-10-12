# Known limitations and validation status (v2.0 CMD engine)

## Environment validation

- The development workspace is Linux. Windows PowerShell 5.1, `powercfg.exe`, `netsh.exe`, CIM Windows providers, UAC, `Checkpoint-Computer`, and Windows 10/11 are not available here.
- The console engine and Windows-specific core therefore cannot be launched or integration-tested in this environment. No Windows 10/11 result is claimed. Run `tests/Run-Tests.ps1` on Windows PowerShell 5.1, then complete the manual checklist below before release.
- Structural gates that DO run here: `tools/ps_syntax_sanity.py`, `tools/build_single_file.py --check` (byte-exact embedded payload), and `tools/audit_legacy.py`.
- The legacy V9.3 batch source was read completely, archived as inert text, statically inventoried, and is not executed by any launcher.

## Detection gaps are explicit

- The OS gate identifies the Windows 10/11 family and reports the build, but does not verify update health, ESU/LTSC enrollment, domain policy, or organizational servicing status; the servicing lifecycle is reported Unknown.
- Generic CIM/WMI does not consistently expose hybrid P/E-core topology, processor generation, NUMA details, memory channels, memory compression, reliable GPU VRAM/shared memory, per-display HDR/color depth, NVMe health, temperatures, or thermal throttling. The engine prints Unknown/Not exposed and never infers settings from model text.
- Generic counters can be absent or localized. Missing samples remain unavailable; absent values are never translated to zero.
- `netsh int tcp show global` labels are localized on non-English Windows; the engine therefore prefers `Get-NetTCPSetting` (language-neutral enums) and treats an unrecognizable netsh output as "unavailable" (documented skip), never as a default.
- GPU usage, FPS, frame time, 1% lows, game-server route latency, and thermals are not collected. No game process is injected or inspected. `--benchmark` samples only documented Windows counters and optional user-chosen ICMP.

## Feature boundaries (v2.0)

- **Automatic scope:** the default run changes only: (1) the `Platinum On Steroids` power plan and its activation, (2) four allowlisted HKCU gaming registry values, (3) TCP autotuning/RSS **only when below documented Windows defaults**, (4) wired-adapter "allow computer to turn off device" **only when not on battery**, and (5) a DNS cache flush. Everything else is assessed and reported read-only.
- **Power plan:** created from the High Performance scheme via `powercfg /duplicatescheme` or reused by GUID. Policy-restricted platforms may reject creation; the failure is reported and the previous plan stays active. Boost policy and core-parking settings exist only where the platform exposes them; elsewhere they are skipped (NOT_SUPPORTED), never forced — on some AMD/Intel generations core parking remains under Windows' internal control. The plan's effect on frame pacing is not measured by this application.
- **Gaming settings:** Game DVR/App-capture registry changes may require sign-out or reboot to fully apply; the report flags this. The Xbox Game Bar app, Defender, Firewall, Windows Update, services, scheduled tasks, startup entries, and processes are never disabled, stopped, or terminated.
- **Network:** ECN, TCP timestamps, RSC, congestion provider, and offload features are deliberately report-only — their benefit is hardware/driver/workload dependent. DNS servers, speed/duplex, network identity, and firewall are never changed; no `netsh reset` is ever run. Ping depends on ISP, routing, congestion, server location, and the game server; no latency improvement is promised.
- **Display/GPU:** refresh rate and resolution are never changed automatically (an unsupported rate can blank the screen); the engine reports the highest enumerated refresh at the current resolution as a recommendation. Vendor saturation/vibrance has no documented write API here, so color changes remain manual guidance; third-party color software (e.g., PlexusX) is never touched. Gamma profiles from v1.x are still restorable from old backups but are not applied by the automatic run. DDC/CI is probed read-only.
- **Storage/memory:** temp-file inventory is reported but never auto-deleted (deletion is irreversible); the page file, memory compression, SysMain, and Windows Search are untouched.
- **Restore** can only undo operations recorded by Platinum Optimizer (validated manifest, checksums, allowlists). It cannot recover unrecorded user changes or a whole Windows installation. A System Restore point, when creation succeeded, is supplemental.
- Backup ZIP exports (v1.x feature) are unencrypted and may contain local system metadata.

## Launcher boundaries

- Elevation uses the standard Windows UAC prompt (`Start-Process -Verb RunAs`). Declining elevation exits with code 4 and changes nothing. The elevated instance runs in its own console window; the original window closes after a short notice.
- Argument passing through the BAT uses `%*`; documented arguments are simple flags (`--restore`, `--benchmark`, `--target <host>`, `-Scan`, `-SelfTest`). Arguments containing quotes or spaces are not supported by the launcher.
- `PlatinumOptimizer.bat` expands embedded sources into `%LOCALAPPDATA%\PlatinumOptimizer\runtime\<build-id>` once per build; deleting that folder is the documented recovery for a corrupted expansion. The batch section is pure ASCII so any cmd code page can parse it.
- No scheduled task, service, startup entry, or background process is created. The optimizer is a foreground process that exits when finished.

## Manual Windows release checklist

1. Run `tests\Run-Tests.ps1` (or `PlatinumOptimizer.bat -SelfTest`) in a standard-user and an elevated session; all assertions must pass.
2. Double-click `PlatinumOptimizer.bat` on a clean Windows 10 and a clean Windows 11 build: confirm the UAC prompt appears, the elevated console runs automatically with no menu, and the report matches the actual system state.
3. Decline the UAC prompt: confirm exit code 4, the explanatory message, and that nothing changed.
4. On a disposable PC/VM: verify the `Platinum On Steroids` plan is created, activated (active GUID re-read), and that a **second run reuses the same GUID** without creating a duplicate and reports "already optimized" for unchanged settings.
5. Verify `%ProgramData%\PlatinumOptimizer\Backups\Backup_*` exists with a valid manifest, that `run.log` and `report.json` exist per run, and that previous runs' logs are not overwritten.
6. Run `--restore`: confirm the previous power plan is reactivated, the four registry values return to their captured state, TCP/adapter changes revert, and the Platinum plan itself is not deleted.
7. Test a laptop on battery (plan change must skip with a reason) and on AC (Laptop preset applies).
8. Test a machine with autotuning `normal` (no TCP change) and one with autotuning disabled (corrected to normal and verified). Confirm ECN/timestamps/RSC are never modified.
9. Tamper with a backup snapshot file and confirm restore refuses it (checksum validation).
10. Confirm Defender, Firewall, Windows Update, services, startup entries, and running processes are unchanged after a full run.
11. Verify `-Scan` and `--benchmark` run without elevation and change nothing; `--benchmark --target <reachable host>` records ICMP honestly.
12. Check console rendering on a legacy OEM code page (e.g., 437/850) and on Windows Terminal.
