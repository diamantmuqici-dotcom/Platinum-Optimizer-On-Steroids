# Implementation report — v2.0.0 CMD engine (complete UI removal)

Date: 2026-10-12 · Branch: `arena/e3ce8ca9-platinum-optimizer-on-steroids` · Base: `71ecf2a0`

This report states exactly what was changed, how it was verified in this
workspace, and what still requires verification on real Windows hardware.
It does not claim FPS, latency, or thermal improvements.

## 1. Mission

Remove the graphical interface completely and transform Platinum Optimizer
On Steroids into a fully automatic, administrator-launched, command-line
Windows gaming optimization engine with truthful logging, verified changes,
mandatory backups, and a tested recovery path.

## 2. What was removed

- `src/ui/MainWindow.xaml` — the entire WPF interface (deleted from the repository).
- The 1,242-line WPF wiring previously in `src/PlatinumOptimizer.ps1`
  (window loading, page navigation, buttons, dialogs, timers, UI-only
  functions) — the entry point is now a console dispatcher.
- The GUI launch path inside the single-file release (the payload no longer
  embeds XAML and the launcher no longer needs `-STA` WPF threading).
- The old GUI-driven "Platinum On Steroids" auto flow
  (`Invoke-POAutoGamingOptimize`), including its defective blind TCP block
  (`netsh int tcp set global ecncapability=disabled / timestamps=disabled /
  rss=enabled / autotuninglevel=normal` executed unconditionally, without
  reading current values, without verification, and without backup). The
  replacement Network module reads state first, changes only documented
  deviations, verifies every write, and records restore data.

## 3. What was preserved

- `PlatinumOptimizer.Core.psm1` — detection snapshot, registry state
  round-trip, checksum-verified backup ledger, restore dispatch, JSONL log,
  DNS state/eligibility, temp preview, benchmark snapshots.
- `PlatinumOptimizer.Power.psm1` — the idempotent `Platinum On Steroids`
  plan lifecycle (create-from-High-Performance or reuse by GUID, preset
  validation against the documented GUID catalog, verified writes via
  `powercfg /qh`, activation, previous-plan restore).
- `PlatinumOptimizer.Audio.psm1` / `PlatinumOptimizer.Display.psm1` — kept
  so v1.x backups with audio/display ledger sections remain restorable, and
  for read-only display/color-capability assessment in the new pipeline.
- All data catalogs (`src/data/*.json`), the legacy V9.3 archive, and the
  developer tools.

## 4. What was added

### 4.1 Launchers (CMD is the whole UI)

- `PlatinumOptimizer.bat` (rebuilt single-file release): pure-ASCII batch
  section that checks for Windows PowerShell (exit 3), detects elevation via
  `net session`, self-elevates through the standard UAC mechanism
  (`Start-Process -Verb RunAs`; declined elevation exits 4 without changes),
  supports paths with spaces (`%~dp0`/`%~f0`), passes arguments, always ends
  with "Press any key to exit..." (`pause >nul`), and propagates the engine
  exit code. The batch section now starts with `@echo off` and cmd exits via
  `exit /b` before the payload marker, so cmd never parses the payload text.
- `Platinum+Optimizer.V9.3.FREE.cmd`: compatibility launcher for the
  repository layout with the same elevation, pause, and exit-code behavior.
- The engine script itself also self-elevates once when started directly
  (`-NoElevate` disables that), so no entry point can silently skip UAC.

### 4.2 `PlatinumOptimizer.Engine.psm1` — automatic pipeline

- Console writer with `[INFO]/[PASS]/[WARN]/[SKIP]/[FAIL]` prefixes and
  colors, mirrored into a per-run timestamped `run.log` under
  `%ProgramData%\PlatinumOptimizer\logs\Run_<ts>_<mode>\` (per-user
  fallback), plus a structured `report.json` per run. Previous logs are
  never overwritten.
- Pipeline: preflight → detection → restore point (time-bounded job,
  supplemental) → backup-first power stage → gaming registry stage → GPU/
  display assessment → network stage → storage/startup/background
  assessment → final verification pass → report with counters
  (applied / already optimized / skipped / failed / unverified), reboot
  recommendation, next steps, and honest notes.
- Pure, testable decision functions: `Select-POAutoPowerPreset`
  (desktop→Gaming, laptop on AC→Laptop preset, battery/unknown→skip),
  `Get-POReportSummary`, `Select-PORestoreBackup` (refuses INVALID
  backups, honors explicit ids, picks newest valid with changes).
- `--restore` mode: lists backups from every known root, validates the
  manifest, restores only recorded sections through the guarded Core
  handlers, verifies, and reports.
- `--benchmark` mode: read-only counter sampling with optional ICMP to an
  explicitly chosen target; snapshots are saved and labeled; no change.

### 4.3 `PlatinumOptimizer.Network.psm1` — assess-first TCP/adapter module

- Reads active TCP state via `Get-NetTCPSetting` (language-neutral
  enums) with a documented `netsh int tcp show global` parser fallback.
- Policy: only deviations from documented Windows client defaults are
  corrected — autotuning below `normal` (disabled/restricted/highly
  restricted) is restored to `normal`; RSS is enabled only when disabled on
  a multi-logical-processor system. ECN, timestamps, RSC, congestion
  provider, RTO, and retransmission settings are reported, never flipped.
- Adapter power management: only connected physical **wired** adapters, only
  when not on battery; previous values captured, change verified by
  re-reading, restore handler included. Wi-Fi power saving is never touched.
- DNS: resolver-cache flush only. No DNS server, identity, speed/duplex, or
  firewall change; no network reset. The report explains that ping depends
  on ISP/routing/servers.
- Ledger: new backup sections `network-tcp` and `network-adapter-power`
  with dedicated before-state files and restore handlers wired into
  `Restore-POBackup`.

### 4.4 `PlatinumOptimizer.Gaming.psm1`

- Exactly four HKCU registry targets (Game Mode enable ×2, Game DVR/App
  capture disable ×2), all inside the existing Core backup/restore
  allowlist; each write is capture-before → write → verify-by-re-read →
  rollback-on-failure; capture settings are flagged as needing sign-out/
  reboot to fully apply.
- Read-only assessments: HAGS (`HwSchMode`) with a Settings recommendation,
  pending-reboot indicators (CBS, Windows Update, pending file renames),
  background-process visibility (never terminates anything), startup
  inventory (never disables anything).

### 4.5 Core hardening for v2.0

- Backup root moved to `%ProgramData%\PlatinumOptimizer\Backups` for
  elevated runs, with `%LOCALAPPDATA%` fallback and a search-root list so
  v1.x backups remain discoverable and restorable; restore/export/delete
  guards accept any known root.
- `Add-POBackupFile` — writes additional before-state files into a backup
  and registers them in the manifest checksum inventory (previously
  impossible without invalidating `Test-POBackup`).
- `Update-POBackupChangeStatus -ChangeId` — targeted ledger status updates
  so per-value registry changes do not overwrite each other's status.
- Manifest `applicationVersion` bumped to 2.0.0.

## 5. Verification performed in this workspace (Linux, no Windows runtime)

- `python3 tools/ps_syntax_sanity.py` — all PowerShell sources pass the
  structural scan (strings, here-strings, comments, bracket balance).
- `python3 tools/build_single_file.py` + `--check` — release rebuilt and
  every embedded file verified byte-exact against the repository sources.
- `python3 tools/audit_legacy.py` — legacy V9.3 archive inventory unchanged
  and still non-executing.
- Repository grep: no remaining XAML file, no WPF/WinForms reference in any
  execution path.

## 6. NOT verified here (requires real Windows 10/11)

- Windows PowerShell 5.1 execution of `tests/Run-Tests.ps1` (the harness is
  written for Windows PowerShell; this workspace has no `powershell.exe`).
- The UAC elevation round-trip, `powercfg` plan create/activate/restore,
  `Get-NetTCPSetting`/`netsh` reads and writes, registry writes,
  `Checkpoint-Computer`, CIM/WMI coverage, and live backup/restore.
- Console rendering on legacy code pages.

These are tracked in `docs/KNOWN-LIMITATIONS.md`. The engine is written so
that every one of these operations is individually guarded (read → act →
verify → rollback/report), and untestable-here paths degrade to `[SKIP]`
with a reason instead of guessing.

## 7. Idempotency and safety summary

- Repeated runs: the Platinum plan is reused by GUID; registry/TCP/adapter
  values already at target report "already optimized" and are not rewritten;
  backups and logs are timestamped per run; no duplicate plans, tasks,
  services, or background processes are ever created.
- Never touched: Defender, Firewall, Windows Update, UAC, services (any),
  BCD, page file, memory compression, DNS servers, GPU registry keys,
  display modes, color/saturation values, processes, personal files,
  existing backups, and unrelated power plans.
