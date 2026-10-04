# Platinum Optimizer

**A read-only-first, reversible Windows gaming optimizer.** It detects the PC before recommending actions, previews changes, backs up state, verifies supported operations, and can restore changes recorded by the application. It does not claim an FPS gain without a real measurement.

> **V9.3 migration:** The original 2,841-line command file is archived as non-executable plain text under `legacy/`. The original `.cmd` filename is now a compatibility frontend. It does **not** execute the V9.3 command list. See [`docs/legacy-v9.3-audit.md`](docs/legacy-v9.3-audit.md) and the line-level [`CSV inventory`](docs/legacy-v9.3-tweak-inventory.csv).

## Requirements

- Windows 10 or Windows 11 desktop edition. The app identifies the Windows family/build but does not verify Windows 10 ESU/LTSC enrollment, update health, or organizational servicing status; its lifecycle field remains Unknown.
- Windows PowerShell 5.1 with WPF (built into supported Windows desktop editions).
- Administrator rights are **not** required to open the UI, detect hardware, run read-only diagnostics, inspect the library, or preview a profile. Elevation is requested only when the user explicitly chooses to apply a system plan or restore a system change.
- No Python, third-party package, telemetry service, or network account is required by the Windows application.

## Run

Double-click `Platinum+Optimizer.V9.3.FREE.cmd`, or launch directly:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File .\src\PlatinumOptimizer.ps1
```

The batch file's `ExecutionPolicy Bypass` is visible in source and is used only to launch this checked-in local script. It downloads nothing, adds no persistence, and does not bypass Windows Defender Application Control or organizational policy. If local policy prevents script execution, use your organization's approved method rather than weakening system policy.

Useful diagnostic commands:

```powershell
# Read-only hardware/Windows snapshot as JSON
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\PlatinumOptimizer.ps1 -Scan

# Run the built-in PowerShell test harness on Windows PowerShell 5.1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1

# Regenerate the non-executing V9.3 source audit (Python 3 only for this developer tool)
python .\tools\audit_legacy.py
```

## What the app does

### Detection and diagnostics

- Windows family/build/edition and device power source/form factor.
- CPU model/vendor, reported architecture, core/thread count, clocks/cache and virtualization support.
- GPU name/vendor/driver and adapter-reported memory/display mode where Windows exposes them.
- Physical memory/module metadata, system-volume free space, disk inventory, motherboard/BIOS, and monitor identity when firmware reports it.
- Security status is observed only: Defender, Firewall, Memory Integrity, Secure Boot, TPM, and UAC. Unknown values remain unknown.
- Read-only service/dependency, startup, scheduled-task, AppX, BCD, driver, network, and game inventories; task impact and startup impact are not guessed.
- Optional local before/after system samples, ICMP tests, and explicit low-rate CPU/memory monitoring.

Generic WMI/CIM does not reliably report all hybrid-core topology, GPU shared memory/VRAM, monitor HDR/color depth, temperatures, mouse polling rate, per-driver DPC/ISR latency, or game FPS/frame times. The UI says **Unknown** or **Not measured** rather than guessing. DPC/ISR percentage is not described as latency.

### Profiles

- **Safe** — no automatic system change; opens supported Windows settings for manual review.
- **Balanced** — offers the already-installed Windows Balanced plan.
- **Gaming / Competitive** — can offer the already-installed High Performance plan after a preview. The system must be positively identified as non-portable, or as portable and on AC; battery, unknown power state, or unknown form factor blocks the change.
- **Maximum Performance** — offers an already-installed Ultimate Performance plan, or High Performance when Ultimate is absent; a separate heat/power confirmation is required.
- **Laptop Battery** — selects the existing Power Saver plan or falls back to Balanced; no high-performance change is applied.
- **Custom** — no selections are made for the user.

Profiles never disable services, Windows Update, Microsoft Store, Defender, Firewall, UAC, VBS/HVCI, Bluetooth, audio, USB, or recovery; never remove AppX packages; never set Realtime process priority; and never write BCD or undocumented GPU/CPU/Direct3D keys. A profile only switches to a plan already present in Windows. If the plan is unavailable or the device/build is unsupported, it is skipped.

### Supported changes

1. **Active power plan:** explicit preview → local backup → change existing plan → verify active GUID. On failure, the previous active plan is reactivated and verified. Restore Center can activate the original plan again. Switching an active plan does not require reboot.
2. **IPv4 DNS on one adapter:** explicit warning/confirmation → local adapter state backup → Windows `Set-DnsClientServerAddress` → verify. Limited to a connected physical adapter after both DHCP address assignment and automatic/DHCP DNS mode are confirmed; static, VPN, virtual, IPv6, and other adapters are left untouched. Unknown DNS mode is blocked. If apply or verification fails, DHCP DNS reset is attempted and verified.
3. **Old user TEMP files:** optional preview only; only current-user TEMP files older than seven days. Deletion is irreversible and has a separate confirmation. It is never part of a gaming profile. Windows logs, update internals, driver stores, shader caches, and browser/application caches are excluded.
4. **Windows Settings links:** Game Mode, capture, graphics, mouse, and startup choices remain under Windows' supported user interface.

## Backup and restore

Backups are created under `%LOCALAPPDATA%\PlatinumOptimizer\Backups\Backup_yyyy-MM-dd_HH-mm-ss\`. Each snapshot contains:

```text
registry/   selected Game Mode / Game DVR preference values (read-only snapshot)
bcd/        current boot-entry text (read-only; BCD is never changed)
services/   service state/start-mode inventory (read-only; services are never changed)
power/      prior active plan GUID and .pow export when available
network/    DNS state for detected adapters (only a selected adapter is changed)
system/     local hardware and Windows snapshot
manifest.json  change ledger, timestamps, warnings, checksums, restore history
```

Restore Center validates SHA-256 checksums and restores **only sections recorded as changed by Platinum Optimizer**. Diagnostic snapshots of BCD/services/registry do not cause those sections to be written during restore. Backup export is an unencrypted ZIP and may contain local machine/network metadata; keep it private. A backup of state that the app did not change is not a full Windows image or a substitute for a separately maintained system backup.

## Benchmark honesty

The app can sample Windows CPU/memory/disk counters and optionally run ICMP tests. It can compare before/after numbers, with missing counters shown as unavailable. These are short system observations, not controlled gameplay benchmarks; conditions/noise can differ. It does **not** inject into games or fabricate FPS, frame-time, ping-to-game-server, DPC/ISR latency, thermal, or performance scores. “Gaming score” remains **NOT SCORED** unless a legitimate standardized in-game benchmark source is actually collected.

## Local data and privacy

Backups, custom game entries, benchmark snapshots, and JSON Lines logs stay in `%LOCALAPPDATA%\PlatinumOptimizer`. The app has no telemetry, remote command execution, update channel, credential collection, or background service. Optional ping tests send only the user-selected ICMP requests. Game discovery reads local manifests/package/installer metadata; it does not read game memory or modify games.

## Repository layout

```text
Platinum+Optimizer.V9.3.FREE.cmd       Safe compatibility launcher
legacy/                                Original V9.3 source, archived as plain text
src/PlatinumOptimizer.ps1              WPF application entry point
src/core/PlatinumOptimizer.Core.psm1   Detection, plans, backup, apply, verify, rollback, diagnostics
src/data/                              Profiles, tweak definitions, games, service classifications
src/ui/MainWindow.xaml                 Platinum dark/platinum WPF interface
tests/                                 Windows PowerShell test harness
tools/audit_legacy.py                  Non-executing legacy audit extractor
docs/                                  Audit, references, support and migration documentation
```

## Tests / build status

There is no compiler/package build step; this is a PowerShell/WPF application. `tests/Run-Tests.ps1` covers JSON/catalog integrity, Windows/profile compatibility decisions, safe plan selection, dry-run semantics, DNS validation, backup path/checksum safety, and registry snapshot round-trip in a temporary test key. `python tools/audit_legacy.py` checks the archived source inventory and produces the audit CSV/summary.

This repository workspace is Linux-based and does not include Windows PowerShell or a Windows 10/11 runtime. Therefore the source audit and portable data checks can run here, but a Windows GUI launch, Windows 10/11 integration test, UAC flow, WMI coverage, and live backup/restore test must be verified on actual Windows before release. See [`docs/KNOWN-LIMITATIONS.md`](docs/KNOWN-LIMITATIONS.md).

## Technical references

See [`docs/REFERENCES.md`](docs/REFERENCES.md) for the Microsoft documentation behind powercfg, DNS, WMI/CIM, Game Mode, and Graphics Settings.
