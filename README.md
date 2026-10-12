# Platinum Optimizer

**A read-only-first, reversible Windows gaming optimizer.** It detects the PC before recommending actions, previews changes, backs up state, verifies supported operations, and can restore changes recorded by the application. It does not claim an FPS gain without a real measurement.

**Version 1.1 adds three integrated modules and a single-file release:**

- **Power plan:** creates, validates, configures, activates, and restores a dedicated **Platinum On Steroids** power plan with validated presets (Gaming, Competitive, Balanced, Laptop), core-parking/processor setting readout, Quick CPU detection, and one-click restore of the previous plan.
- **Audio & Headphones:** verified device/endpoint inventory plus presets whose only automatic change is fully readable, verifiable, and restorable; everything else is honest detection plus manual steps in supported Windows UI.
- **Display & Colors:** per-display gamma and refresh profiles computed absolutely from a captured original (no accumulation, no tint, no GPU registry writes), with DDC/CI and HDR capability detection and vendor color-control guidance.
- **`PlatinumOptimizer.bat`:** the whole application (engine, modules, data, UI, tests) embedded into one self-expanding BAT that needs only built-in Windows PowerShell 5.1.

> **V9.3 migration:** The original 2,841-line command file is archived as non-executable plain text under `legacy/`. The original `.cmd` filename is now a compatibility frontend. It does **not** execute the V9.3 command list. See [`docs/legacy-v9.3-audit.md`](docs/legacy-v9.3-audit.md) and the line-level [`CSV inventory`](docs/legacy-v9.3-tweak-inventory.csv).

## Requirements

- Windows 10 or Windows 11 desktop edition. The app identifies the Windows family/build but does not verify Windows 10 ESU/LTSC enrollment, update health, or organizational servicing status; its lifecycle field remains Unknown.
- Windows PowerShell 5.1 with WPF (built into supported Windows desktop editions).
- Administrator rights are **not** required to open the UI, detect hardware, run read-only diagnostics, inspect the library, or preview a profile. Elevation is requested only when the user explicitly chooses to apply a system plan or restore a system change.
- No Python, third-party package, telemetry service, or network account is required by the Windows application.

## Run

**Single-file release:** double-click `PlatinumOptimizer.bat`. It is a cmd/PowerShell polyglot: the batch section launches built-in Windows PowerShell, which reads the BAT itself, expands the embedded sources byte-exact into `%LOCALAPPDATA%\PlatinumOptimizer\runtime\<build-id>` (once per build), and starts the UI. Nothing is downloaded, and no separate scripts, Python, or third-party tools are required. Optional flags: `PlatinumOptimizer.bat -Scan` (JSON system snapshot) and `-SelfTest` (test harness).

**From the repository:** double-click `Platinum+Optimizer.V9.3.FREE.cmd`, or launch directly:

```powershell
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File .\src\PlatinumOptimizer.ps1
```

Regenerate the single-file release after source changes with `python tools\build_single_file.py` (developer tool only; the checked-in BAT is the release artifact).

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

### Platinum On Steroids power plan

- Detects the active plan, enumerates existing plans, and detects whether `Platinum On Steroids` already exists; an existing plan is inspected and validated instead of duplicated.
- Creation uses `powercfg /duplicatescheme` from the documented High Performance scheme, renames the copy exactly `Platinum On Steroids`, verifies it in the scheme list, and exports a `.pow` copy. Existing plans are never deleted automatically; deletion of the Platinum plan itself is a separate explicit action that is blocked while it is active.
- Presets (Gaming, Competitive, Balanced, Laptop) are validated configurations inside the one plan. Every value targets a Microsoft-documented subgroup/setting GUID from `src/data/power-settings.json`; each write is re-read with `powercfg /qh` and compared. Settings the platform does not expose (boost policy, core parking on some systems) are skipped as NOT_SUPPORTED, never forced. AC and DC are configured separately; sleep is never silently disabled (explicit 20–60 minute sleep timeouts); laptops get a capped processor ceiling and passive cooling on battery.
- Activation happens only after explicit confirmation and is verified by re-reading the active scheme GUID. The plan active before the change is recorded in the app's state and in the backup ledger; **Restore Previous Power Plan** reactivates it (re-importing the `.pow` export if it disappeared) without deleting the Platinum plan.
- The Power page reads the active plan's processor settings (min/max state, cooling policy, boost policy, core-parking min/max cores and utility distribution where Windows exposes them) and detects Quick CPU if installed; Quick CPU is never downloaded or launched.

### Audio & Headphones

- Inventory uses Windows-reported sources only: `Win32_SoundDevice`, PnP `AudioEndpoint` devices, the Audiosrv service state, and PnP-id-based connection-type inference (USB / Bluetooth / HDAudio / GPU display audio), always labeled as inferred. Fields Windows does not expose (default endpoint, sample rate, enhancements state, spatial state, latency) are shown as Unknown or pointed to their supported UI.
- The only automatic change in any preset is the documented communications-activity value (`HKCU\Software\Microsoft\Multimedia\Audio\UserDuckingPreference`), captured before the first change, written, read back, and restorable. No microphone is disabled, no default device is moved, and no codec/driver/third-party audio software is installed. Preset cards explain exactly what changes and why, plus game-native guidance (CS2 HRTF, Fortnite headphone mode, Bluetooth codec limits) and manual steps in `mmsys.cpl`/Settings.

### Display & Colors

- Inventory enumerates active displays with `EnumDisplayDevices`/`EnumDisplaySettings`: current mode, every enumerated mode at the current resolution, highest available refresh, adapter/vendor, monitor PnP identity, Windows Color Management ICC association, HDR status (reported as Unknown where the API does not expose it), and a read-only DDC/CI capability probe (`dxva2` capabilities query; never writes VCP values).
- Profiles apply bounded gamma ramps through the documented `Get/SetDeviceGammaRamp` API and optional refresh-rate changes through `ChangeDisplaySettingsEx` with a `CDS_TEST` preflight and post-change verification. Anti color-corruption is enforced by design: ramps are computed **absolutely** from the identity curve (no accumulation across applies), the same curve is used on all three channels (no green/red/blue tint is possible), gamma is clamped to 0.85–1.15, the original ramp and mode are captured before the first change per display, targeting is per selected display, and no GPU registry value is ever written. If the driver refuses or does not keep the ramp (typical under HDR), the change is reported as failed — never as success.
- GPU-vendor saturation/vibrance controls have no documented write API here, so they are surfaced as manual instructions with conservative defaults, and the UI states that global ramp changes affect the desktop, not a single game.

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
power/      prior active plan GUID and .pow export; Platinum On Steroids state when applicable
network/    DNS state for detected adapters (only a selected adapter is changed)
audio/      captured communications-behavior value (only when an audio preset was applied)
display/    captured display mode and gamma ramp (only when a display profile was applied)
system/     local hardware and Windows snapshot
manifest.json  change ledger, timestamps, warnings, checksums, restore history
```

The ledger now supports the `power` (built-in plan switch and `platinum-power-plan`), `network`, `registry`, `audio`, and `display` sections. Restore Center restores exactly those sections it recorded; the Platinum plan itself is never deleted during restore, and audio/display restores work without elevation because they touch only user-session state.

Restore Center validates SHA-256 checksums and restores **only sections recorded as changed by Platinum Optimizer**. Diagnostic snapshots of BCD/services/registry do not cause those sections to be written during restore. Backup export is an unencrypted ZIP and may contain local machine/network metadata; keep it private. A backup of state that the app did not change is not a full Windows image or a substitute for a separately maintained system backup.

## Benchmark honesty

The app can sample Windows CPU/memory/disk counters and optionally run ICMP tests. It can compare before/after numbers, with missing counters shown as unavailable. These are short system observations, not controlled gameplay benchmarks; conditions/noise can differ. It does **not** inject into games or fabricate FPS, frame-time, ping-to-game-server, DPC/ISR latency, thermal, or performance scores. “Gaming score” remains **NOT SCORED** unless a legitimate standardized in-game benchmark source is actually collected.

## Local data and privacy

Backups, custom game entries, benchmark snapshots, and JSON Lines logs stay in `%LOCALAPPDATA%\PlatinumOptimizer`. The app has no telemetry, remote command execution, update channel, credential collection, or background service. Optional ping tests send only the user-selected ICMP requests. Game discovery reads local manifests/package/installer metadata; it does not read game memory or modify games.

## Repository layout

```text
PlatinumOptimizer.bat                  Single-file release (embedded app, self-expanding)
Platinum+Optimizer.V9.3.FREE.cmd       Safe compatibility launcher for the repo layout
legacy/                                Original V9.3 source, archived as plain text
src/PlatinumOptimizer.ps1              WPF application entry point and UI wiring
src/core/PlatinumOptimizer.Core.psm1   Detection, plans, backup, apply, verify, rollback, diagnostics
src/core/PlatinumOptimizer.Power.psm1  Platinum On Steroids plan lifecycle and CPU power readout
src/core/PlatinumOptimizer.Audio.psm1  Audio inventory and reversible audio presets
src/core/PlatinumOptimizer.Display.psm1 Display inventory, bounded gamma/refresh profiles
src/data/                              Profiles, tweaks, games, services, power presets, audio presets, display profiles
src/ui/MainWindow.xaml                 Platinum dark/platinum WPF interface
tests/                                 Windows PowerShell test harness (pure logic + Windows integration)
tools/build_single_file.py             Builds and verifies PlatinumOptimizer.bat (developer tool)
tools/ps_syntax_sanity.py              Structural PowerShell scan for the Linux workspace
tools/ps_tree_sitter_check.py          Tree-sitter PowerShell parse gate (developer tool)
tools/audit_legacy.py                  Non-executing legacy audit extractor
docs/                                  Audit, references, limitations, implementation report
```

## Tests / build status

There is no compiler/package build step; this is a PowerShell/WPF application. `tests/Run-Tests.ps1` covers JSON/catalog integrity, Windows/profile compatibility decisions, safe plan selection, dry-run semantics, DNS validation, backup path/checksum safety, registry snapshot round-trip, and — new in 1.1 — Platinum power-preset validation against the documented GUID catalog, `powercfg /list` and `/qh` output parsers, audio preset/connection-inference rules, display gamma math (identity, clamping, channel equality, no accumulation), refresh selection, ledger acceptance of audio/display sections, and byte-exact integrity of the single-file release. `python tools/audit_legacy.py` checks the archived source inventory; `python tools/build_single_file.py --check` re-verifies the release BAT; `python tools/ps_syntax_sanity.py` and `tools/ps_tree_sitter_check.py` are Linux-side structural gates.

This repository workspace is Linux-based and does not include Windows PowerShell or a Windows 10/11 runtime. Therefore the source audit and portable data checks can run here, but a Windows GUI launch, Windows 10/11 integration test, UAC flow, WMI coverage, and live backup/restore test must be verified on actual Windows before release. See [`docs/KNOWN-LIMITATIONS.md`](docs/KNOWN-LIMITATIONS.md).

## Technical references

See [`docs/REFERENCES.md`](docs/REFERENCES.md) for the Microsoft documentation behind powercfg, DNS, WMI/CIM, Game Mode, and Graphics Settings.
