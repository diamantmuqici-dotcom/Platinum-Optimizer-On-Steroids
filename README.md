# Platinum Optimizer On Steroids v2.0 — Automatic CMD Gaming Optimizer

**A fully automatic, command-line Windows gaming optimization engine.** No graphical dashboard, no WPF interface, no browser UI, and no interactive category-selection menu — the Command Prompt console is the entire user interface. Right-click the launcher, choose **Run as administrator**, accept the normal Windows UAC prompt, and the optimizer runs its complete verified workflow by itself and prints an honest final report.

It detects the PC before changing anything, creates a System Restore point when available plus a checksum-verified configuration backup, applies only documented and hardware-appropriate optimizations, verifies every write by reading it back, and can restore everything it recorded. It never claims an FPS or ping gain without a real measurement.

```
============================================================
        PLATINUM OPTIMIZER ON STEROIDS  v2.0.0
                AUTOMATIC MODE
============================================================

---- PREFLIGHT ----
[PASS] Administrator privileges confirmed.
[PASS] powercfg.exe is available.
---- SYSTEM DETECTION ----
[INFO] Windows: Microsoft Windows 11 Pro | Build 26100 | 64-bit | Supported: True
[INFO] CPU: ... | physical cores: 8 | logical: 16
[INFO] Network: Ethernet [Ethernet] link 1 Gbps duplex True
[INFO] 'Platinum On Steroids' plan: present (d6a1b3c2-...)
---- RECOVERY PREPARATION ----
[INFO] System Restore point created (supplemental recovery; ...).
---- POWER MANAGEMENT ----
[PASS] Configuration backup created and checksum-verified: C:\ProgramData\PlatinumOptimizer\Backups\Backup_...
[PASS] Power: Platinum On Steroids preset 'gaming' applied and verified ...
...
============================================================
                  OPTIMIZATION REPORT
============================================================

Changes applied and verified : N
Already optimized            : N
Skipped (with reason)        : N
Failed                       : N
Unverified (not success)     : N
Reboot recommended           : No

Backup : C:\ProgramData\PlatinumOptimizer\Backups\Backup_...
Log    : C:\ProgramData\PlatinumOptimizer\logs\Run_..._optimize

Recommended next steps:
  - ...
Press any key to exit...
```

Every status line reflects an actual operation and its verified outcome: `[INFO]` observation, `[PASS]` verified success or already-optimized state, `[WARN]` a gap or unverified result, `[SKIP]` a documented reason a change was not made, `[FAIL]` an operation that failed. Nothing is printed as successful before it has succeeded and been verified.

> **V9.3 → v2.0 history:** The original 2,841-line V9.3 command file is archived as non-executable plain text under `legacy/` (see [`docs/legacy-v9.3-audit.md`](docs/legacy-v9.3-audit.md)). The v1.x WPF dashboard was **removed completely** in v2.0 and replaced by this automatic CMD engine; the migration report is [`docs/IMPLEMENTATION-REPORT-V2.md`](docs/IMPLEMENTATION-REPORT-V2.md). The original `.cmd` filename remains as a compatibility launcher that runs the same engine — it never executes the V9.3 command list and never starts a GUI.

## Requirements

- Windows 10 or Windows 11 (desktop editions) with built-in Windows PowerShell 5.1.
- Administrator privileges for the automatic run — requested through the standard Windows UAC prompt. Read-only modes (`-Scan`, `--benchmark`) work without elevation.
- No Python, no third-party package, no download, no telemetry service, and no background process. The optimizer runs in the visible foreground and exits when its work is done.

## Run

**Primary launcher (single file):** right-click `PlatinumOptimizer.bat` → **Run as administrator** — or simply double-click it: the launcher detects whether it is elevated and, if not, re-launches itself through the normal Windows UAC prompt. If you decline elevation, it exits safely and changes nothing.

**From the repository layout:** double-click `Platinum+Optimizer.V9.3.FREE.cmd` (same elevation logic), or run:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File .\src\PlatinumOptimizer.ps1
```

### Modes

| Command | What it does | Elevation |
|---|---|---|
| `PlatinumOptimizer.bat` | **Default: fully automatic optimization run.** No menus, no category selection. | Yes (auto-elevates via UAC) |
| `PlatinumOptimizer.bat --restore [id]` | Restores the settings recorded in the latest valid backup (or the backup with the given id) and verifies the rollback. | Yes |
| `PlatinumOptimizer.bat --benchmark [--target host]` | Diagnostic mode: samples CPU/RAM/disk counters (and optional ICMP to an explicitly chosen host), saves a snapshot, changes nothing. | No |
| `PlatinumOptimizer.bat -Scan` | Read-only hardware/Windows snapshot as JSON. | No |
| `PlatinumOptimizer.bat -SelfTest` | Runs the built-in test harness. | No |

Regenerate the single-file release after source changes with `python tools\build_single_file.py` (developer tool; the checked-in BAT is the release artifact, verified byte-exact by `python tools\build_single_file.py --check`).

## What the automatic run does

Pipeline order (each stage prints its real result):

1. **Preflight** — Windows 10/11 detection, administrator check, `powercfg` availability. Unsupported hosts stop before any change.
2. **Detection** — Windows edition/build/architecture; CPU model, physical/logical cores; GPU(s) and driver versions; memory; system volume free space; form factor and power source (desktop vs laptop, AC vs battery); network adapters with Ethernet/Wi-Fi classification, link speed and duplex; active power plan and existing `Platinum On Steroids` plan; current gaming registry settings; core-parking exposure; Quick CPU presence (detected, never launched); HAGS state; pending-reboot indicators. Missing optional fields are reported as Unknown — they never crash the run.
3. **Recovery preparation** — a System Restore point is attempted when System Restore is enabled (time-bounded, supplemental), and a **checksum-verified configuration backup** is created *before* any change. If the backup fails, no system change is applied.
4. **Power management — `Platinum On Steroids` plan** — created from the documented High Performance scheme via `powercfg /duplicatescheme` or **reused by GUID if it already exists** (idempotent: repeated runs never duplicate plans). Preset values (Gaming on desktops, thermally capped Laptop preset on AC laptops) come exclusively from the Microsoft-documented GUID catalog in `src/data/power-settings.json`. Every write is re-read with `powercfg /qh` and compared; unsupported settings (boost policy, core parking on some platforms) are skipped as NOT_SUPPORTED, never forced. The plan is activated only after verification, and the previously active plan is recorded for one-command restore. Existing plans are never deleted. Sleep is never disabled; laptops on battery are never given a performance plan.
5. **CPU / core parking** — processor power settings are applied through the verified plan above; core-parking exposure and current values are read from the active scheme and reported. No registry hacks, no forced affinity, no idle-state disabling, no BIOS/firmware/voltage changes.
6. **Windows gaming settings** — Game Mode is enabled and background Game DVR/app capture is disabled through four HKCU registry values, each captured-before/written/verified-by-re-read, on failure rolled back immediately. The Xbox Game Bar app itself, Defender, Firewall, Windows Update, audio, networking, input, and accessibility components are **never** disabled. No service is modified or stopped; no process is terminated.
7. **GPU & display (read-only)** — per-display resolution/refresh, the highest enumerated refresh at the current resolution (reported as a recommendation when higher, never changed automatically: an unsupported rate can blank the screen), HDR/ICC status as reported, DDC/CI capability probe, and vendor color-control detection (NVIDIA/AMD/Intel surfaces are reported with their manual paths; no saturation/vibrance value is written because no documented write API exists, and third-party color software such as PlexusX is never touched). HAGS is assessed and recommended, not flipped (it needs a reboot and GPU/driver support).
8. **Network** — the module **reads the current TCP state first** (`Get-NetTCPSetting`, `netsh` fallback) and acts only on deviations from documented Windows defaults: receive-window autotuning below `normal` is restored to `normal`; RSS is enabled when disabled on a multi-core system. ECN, TCP timestamps, RSC, the congestion provider, and offload features are **assessed and reported, never blindly changed**. Connected wired adapters get "allow the computer to turn off this device" disabled (previous value captured, verified, restorable); Wi-Fi power saving is left alone; on battery nothing is changed. The DNS resolver cache is flushed. No DNS server, speed/duplex setting, network identity, or firewall rule is changed, and no network reset is run.
9. **Storage & background (read-only)** — free space warning below 10%, user TEMP inventory older than 7 days (reported, **not** auto-deleted — deletion is irreversible), startup entry count (review stays in Settings > Apps > Startup), largest background processes by working set (reported, never terminated). The page file, memory compression, SysMain, and Windows Search are untouched.
10. **Final verification pass** — active plan GUID, gaming registry values, and TCP state are re-read and compared; anything that cannot be confirmed is reported as **Unverified**, not as success.
11. **Report + logs** — console report (applied / already optimized / skipped / failed / unverified / reboot), recommended next steps, honest notes, `report.json` and a human-readable `run.log` in a per-run timestamped directory, plus the append-only JSONL log.

Independent optional failures never abort the whole run; critical failures (unsupported OS, no elevation, detection failure, backup failure) stop changes safely before they happen.

## Backup and recovery

Backups live under **`%ProgramData%\PlatinumOptimizer\Backups\Backup_<timestamp>\`** for elevated runs (older v1.x backups under `%LOCALAPPDATA%\PlatinumOptimizer\Backups\` are still found and restorable). Each snapshot contains:

```text
registry/   Game Mode / Game DVR values captured before any write
power/      prior active plan GUID + .pow export + Platinum plan state
network/    DNS state per adapter, TCP global before-state, adapter power before-state
system/     full hardware/Windows snapshot
services/, bcd/   read-only inventories (never modified)
audio/, display/  captured state when a v1.x audio/display change was recorded
manifest.json     change ledger with SHA-256 checksums and restore history
```

**Recovery:** `PlatinumOptimizer.bat --restore` validates the manifest (checksums, ids, path safety), then restores **only the sections this application recorded as changed**: the previous power plan (re-importing the `.pow` if needed), the captured registry values, TCP settings, adapter power management, and any v1.x audio/display/DNS changes. Malformed or unlisted values are refused. The `Platinum On Steroids` plan itself is never deleted during restore. A System Restore point, when one was created, is additional protection.

## Performance honesty

- No FPS, frame-time, latency, or ping improvement is promised or faked. Ping also depends on your ISP, routing, congestion, server location, and the game server itself.
- `--benchmark` records real CPU/RAM/disk counters and optional ICMP to a host **you** choose, with before/after comparison guidance; GPU usage and FPS are explicitly reported as *not measured* (no game injection, no fabricated scores).
- "Gaming score" does not exist in this application.

## Repository layout

```text
PlatinumOptimizer.bat                  Single-file release: auto-elevating CMD launcher + embedded engine
Platinum+Optimizer.V9.3.FREE.cmd       Compatibility launcher for the repository layout (same engine)
src/PlatinumOptimizer.ps1              Console engine entry point (no GUI code remains)
src/core/PlatinumOptimizer.Core.psm1   Detection, backup/restore ledger, registry round-trip, logging
src/core/PlatinumOptimizer.Power.psm1  Platinum On Steroids plan lifecycle and CPU power readout
src/core/PlatinumOptimizer.Network.psm1 Assess-first TCP/adapter optimization with verified restore
src/core/PlatinumOptimizer.Gaming.psm1 Game Mode / Game DVR changes, HAGS/startup/background assessment
src/core/PlatinumOptimizer.Engine.psm1 Console pipeline, run logs, report, restore/benchmark modes
src/core/PlatinumOptimizer.Audio.psm1  Audio inventory + reversible preset (v1.x backups remain restorable)
src/core/PlatinumOptimizer.Display.psm1 Display inventory, gamma/refresh math, color-control detection
src/data/                              Documented power-setting GUIDs and presets, catalogs
tests/Run-Tests.ps1                    Windows PowerShell test harness (pure logic + Windows integration)
tools/build_single_file.py             Builds and verifies PlatinumOptimizer.bat (developer tool)
tools/ps_syntax_sanity.py              Structural PowerShell scan for non-Windows workspaces
tools/ps_tree_sitter_check.py          Tree-sitter PowerShell parse gate (developer tool)
tools/audit_legacy.py                  Non-executing legacy V9.3 audit extractor
legacy/                                Original V9.3 source, archived as plain text
docs/                                  Audit, references, limitations, implementation reports
```

## Tests / build status

There is no compiler step; this is a Windows PowerShell application. `tests/Run-Tests.ps1` covers the launcher structure (elevation, exit codes, pause, embedded byte-exact payload, **no GUI file**), administrator/Windows gating, hardware detection with missing fields, backup creation/validation/checksum safety, `Add-POBackupFile` ledger integrity, power-plan preset validation against the documented GUID catalog, `powercfg` output parsers, automatic preset selection (desktop/laptop/battery/unknown), network safety rules (defaults untouched, only sub-default autotuning/RSS corrected, ECN/timestamps/RSC never flipped), gaming registry allowlist, report counter accuracy, restore-target selection (refuses INVALID backups), and repeated-execution idempotency rules.

`python tools/ps_syntax_sanity.py` and `python tools/build_single_file.py --check` run on any platform; `python tools/audit_legacy.py` re-verifies the archived V9.3 inventory. This repository workspace is Linux-based: the structural gates and byte-exact release verification run here, while the Windows PowerShell test harness, the UAC flow, WMI coverage, live powercfg/netsh/registry writes, and live backup/restore must be verified on actual Windows 10/11 hardware before release. See [`docs/KNOWN-LIMITATIONS.md`](docs/KNOWN-LIMITATIONS.md).

## Technical references

See [`docs/REFERENCES.md`](docs/REFERENCES.md) for the Microsoft documentation behind powercfg, processor power management, TCP networking, Game Mode/capture settings, and WMI/CIM.
