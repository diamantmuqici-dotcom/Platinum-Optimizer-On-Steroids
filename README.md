# Platinum Optimizer On Steroids

**An automatic, foreground-only Windows gaming optimizer with a CMD interface.** The old WPF dashboard and category-selection flow have been removed. The default run detects the system, creates and verifies a recovery backup, configures the supported Platinum power plan, verifies its active state, writes a timestamped report, and waits for a key before closing.

The optimizer is intentionally conservative: it does not promise FPS or ping improvements, and it does not apply undocumented registry recipes or blanket service/network tweaks.

## Requirements

- Windows 10 or Windows 11.
- Built-in Windows PowerShell 5.1 and `powercfg.exe`.
- Administrator privileges for automatic optimization and recovery. Read-only scan and benchmark modes do not require elevation.
- No Python, third-party downloads, telemetry service, network account, or persistent background service is used by the Windows application.

## Run

1. Right-click **`PlatinumOptimizer.bat`** and choose **Run as administrator**. You can also double-click it; the launcher will request elevation through the normal Windows UAC confirmation.
2. Approve the Windows UAC prompt. This is the standard Windows security mechanism. If approval is declined, the optimizer exits without applying changes.
3. Automatic mode starts without asking you to choose categories. The visible CMD/PowerShell console shows each detected operation and its actual result, then waits for a key before closing.

The compatibility launcher **`Platinum+Optimizer.V9.3.FREE.cmd`** delegates to the same CMD-only application. The old V9.3 tweak list is archived as non-executable text under `legacy/`; it is never run.

### Optional command-line modes

```cmd
PlatinumOptimizer.bat --scan
PlatinumOptimizer.bat --benchmark
PlatinumOptimizer.bat --restore
PlatinumOptimizer.bat --self-test
```

- `--scan` captures a read-only system assessment.
- `--benchmark` captures a short Windows resource sample; it does not launch a game or report FPS/frame-time results.
- `--restore` restores the newest valid backup with recorded changes that have not already been restored. Completed sections are not selected repeatedly; after recovery, another run can step back to an earlier run. Before restoring, it requires a fresh verified export of the active power scheme and, when present, the Platinum scheme/settings.
- `--self-test` runs the PowerShell test harness without changing system settings.

For a specific backup path, open an elevated Command Prompt and run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\src\PlatinumOptimizer.ps1" -Mode Restore -BackupPath "C:\path\to\backup"
```

The engine validates the backup manifest and checksums before restoring. It restores only supported changes recorded in that backup. It does not delete unrelated power plans.

## What automatic mode detects

Where Windows exposes the data, the report includes:

- Windows edition, family, version, build, and architecture; administrator status; and pending-reboot indicators.
- Device model/form factor and power source; CPU model, reported architecture, core/thread counts, clocks and cache; GPU model/driver; installed memory; system volume and storage-device inventory.
- Active and available power plans, supported processor power settings and core-parking visibility.
- Connected network adapters, inferred Ethernet/Wi-Fi type, status, link speed, DNS-state readability, and a read-only `netsh interface tcp show global` snapshot.
- Display mode/refresh information where the display APIs report it, audio controller/endpoints, relevant gaming registry values, Windows security posture, aggregate CPU/memory/disk counters, and read-only startup/service inventory counts.

Unknown or unavailable hardware fields stay **Unknown**. Generic Windows inventory does not reliably report every hybrid-core topology, GPU temperature/utilization, HDR state, game FPS, frame times, DPC/ISR latency, or monitor color capability.

## Automatic power-plan configuration

The engine creates or reuses a Windows power scheme named exactly **Platinum On Steroids**, then activates it only after Windows verifies its GUID.

- If it must be created, the plan is copied from the currently active scheme, preserving the existing Windows/OEM policy as its baseline. Balanced is the fallback if the active scheme cannot be read.
- Repeated runs reuse the existing scheme; they do not create duplicate Platinum plans.
- The automatic desktop/AC configuration changes only documented processor minimum/maximum state and AC cooling policy when the setting is exposed and its read-back verifies. Minimum state remains low for idle efficiency; the maximum is not forced beyond 100 percent.
- On positively identified laptops, the battery-side maximum processor state is capped at 85 percent. This conservative cap can reduce performance on battery; other battery, sleep, display, USB, and OEM behavior is retained from the active plan.
- Core parking, boost mode, PCIe ASPM, USB suspend, sleep/display timers, processor affinity, voltage, firmware, and overclock settings are not force-tuned. Unsupported settings are skipped and reported.
- A failed or unverifiable operation is not reported as successful. A transaction failure attempts to restore the original power settings; a newly created plan is removed only when the optimizer can verify that it is the exact new plan and is not active.

These settings affect Windows power policy, not game rendering or network routing. A power plan may change power draw, fan behavior, and responsiveness, but **no FPS, frame-time, temperature, or latency improvement is guaranteed**.

## Changes deliberately left read-only

These categories are assessed and documented, but the default run does not change them because the correct value depends on the user's preference, driver, device, workload, or a supported control interface:

- Game Mode, Game Bar, DVR/background capture, and recording preferences.
- TCP congestion control, ECN, timestamps, receive-window autotuning, DNS, adapter offloads, RSC/RSS, duplex, and adapter power management.
- GPU vendor controls, monitor saturation/colors, ICC profiles, resolution, refresh rate, and graphics scheduling.
- Startup entries, services, scheduled tasks, background processes, temporary files, page-file policy, memory compression, and Windows security features.

No DNS server is forced, no connection is reset, no process is killed, no service is disabled, and Defender, Firewall, Windows Update, UAC, Secure Boot, Memory Integrity, and recovery protections are not modified. Ping depends on the ISP, route, congestion, server location, and the game server.

Display and audio modules are retained as read-only diagnostics/recovery components; they do not launch a dashboard or pop-up window. Automatic color adjustment is not attempted because a reliable vendor-supported write interface is not available in this project.

## Backups, reports, and recovery

All application data stays local under:

```text
%LOCALAPPDATA%\PlatinumOptimizer\
  Backups\   timestamped, checksummed configuration backups
  logs\      one human-readable log per run
  reports\   one structured JSON report per run
  power\     optimizer state for the Platinum plan
```

Before a power-plan change, the engine validates its configuration backup. It records the prior active plan GUID and exports that plan; if a Platinum plan already exists, it also exports that scheme and records the documented processor settings before changing them. A critical backup or checksum failure stops the workflow before power settings are changed.

Windows System Restore is supplemental. After the verified application backup is in place, the optimizer attempts to create a restore point only when the built-in command is available; it does not enable System Protection. If Windows blocks or cannot verify the restore point, the run reports that fact and relies on the explicit application backup.

Run **`PlatinumOptimizer.bat --restore`** to restore the newest valid, not-yet-restored recorded change. Recovery reactivates the previous plan and, when a Platinum plan existed before the run, restores only AC/DC setting sides recorded as attempted by the optimizer and still matching its recorded target. Values already at baseline are left alone; a later conflicting value blocks the overwrite. A Platinum plan newly created by a successful run is retained but is no longer active after restoration; unrelated plans are never deleted.

The report distinguishes attempted changes, verified changes, values already at target, skipped operations, failures, and operations that could not be verified. Logs and reports contain local OS/hardware/adapter metadata but never collect passwords, authentication tokens, or personal document contents.

## Repository layout

```text
PlatinumOptimizer.bat                  Primary CMD launcher
Platinum+Optimizer.V9.3.FREE.cmd       Compatibility launcher for old shortcuts
src/Launcher.ps1                       UAC/elevation and mode handoff
src/PlatinumOptimizer.ps1              CMD-oriented application entry point
src/core/PlatinumOptimizer.Automatic.psm1  Automatic pipeline, logging, reports
src/core/PlatinumOptimizer.Core.psm1       Detection, backups, recovery, diagnostics
src/core/PlatinumOptimizer.Power.psm1      Verified powercfg configuration/recovery
src/core/PlatinumOptimizer.Audio.psm1      Read-only audio inventory and safe legacy recovery
src/core/PlatinumOptimizer.Display.psm1    Read-only display diagnostics and recovery
src/data/                              Power settings and diagnostic catalogs
legacy/                                Non-executable V9.3 archive
```

## Development and tests

On Windows, run the repository harness with built-in Windows PowerShell 5.1:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```

On any host with Python 3, run the static/contract checks:

```bash
python tools/ps_syntax_sanity.py
python -m unittest discover -s tests -p 'test_*.py'
```

The Windows-specific `powercfg`, registry, UAC, System Restore, network-adapter, display, and audio integrations must be verified on Windows 10/11 hardware. This repository checkout is tested in a non-Windows environment; it cannot honestly claim a live Windows end-to-end run here.

## Legacy safety audit

The original V9.3 command file is preserved as `legacy/Platinum+Optimizer.V9.3.FREE.cmd.disabled.txt` for audit only. See [`docs/legacy-v9.3-audit.md`](docs/legacy-v9.3-audit.md) and [`docs/legacy-v9.3-tweak-inventory.csv`](docs/legacy-v9.3-tweak-inventory.csv). The compatibility launcher does not execute it.
