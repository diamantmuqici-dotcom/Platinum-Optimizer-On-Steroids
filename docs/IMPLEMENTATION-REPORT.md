# Implementation report — CMD-only automatic optimizer

Date: 2026-10-12 · Application version: 2.0.0

## Delivered

- Replaced the WPF/XAML dashboard entry point with a console-only PowerShell engine and a small CMD launcher. The old compatibility `.cmd` now delegates to the new launcher; the archived V9.3 command list remains non-executable text.
- Added Windows UAC handoff for automatic/recovery modes, validated command-line modes (`--scan`, `--benchmark`, `--restore`, `--self-test`), safe repository-relative paths, visible foreground execution, meaningful exit codes, and a final keypress wait. Elevation is checked from the Windows security token rather than `net session` (which can fail when the Server service is disabled), and the launcher elevates Windows PowerShell with a quoted script path instead of trying to execute the `.bat` through `Start-Process`.
- Added a console assessment covering Windows/hardware, power schemes/processor settings, adapters/TCP state, display/audio, gaming settings, security, storage, reboot indicators, and aggregate resource counters. Optional data remains unknown when Windows does not expose it.
- Reworked the power workflow so its checksum-verified application backup is created **before** any system change, including the optional System Restore point. The previous active plan must export successfully. An existing Platinum scheme is also exported and its documented processor values are captured for rollback.
- The automatic plan is cloned from the active plan (Balanced fallback), reused by exact name, configured only with conservative documented processor values, and activated only after GUID read-back. Core parking, boost, network, capture, display, services, startup, storage, security, and undocumented registry settings remain unchanged.
- Added per-run human-readable logs and structured JSON reports with truthful applied/restored/already-optimized/skipped/failed/unverified results. `--restore` records its source backup, validates the selected manifest and checksums, captures and verifies a fresh pre-restore snapshot for the affected sections, requires non-empty exports of the active and existing Platinum power schemes, and restores only recorded supported changes. Existing-plan recovery uses the persisted per-side write history, restores only attempted sides still at the optimizer target, skips sides already at their baseline, and blocks on newer conflicting values. Successfully restored sections are not repeatedly selected; another `--restore` can step back to an earlier eligible run.
- Removed the graphical dashboard and the obsolete self-expanding BAT builder/runtime payload. The primary `.bat` is now a normal ASCII CMD launcher.

## Verification performed in this workspace

This workspace is not Windows. PowerShell system changes, UAC, System Restore, `powercfg`, WMI/CIM hardware inventory, and Windows recovery cannot be executed here.

| Check | Result |
|---|---|
| PowerShell structural sanity scan | Passed for launcher, engine, all PowerShell modules, and Windows test harness |
| Tree-sitter PowerShell grammar check | Passed; parser noted documented grammar quirks in existing Core/test constructs |
| JSON catalogs parse | Passed; all 7 data catalogs parsed |
| Python CLI/repository contract tests | Passed; 13 tests |
| Windows PowerShell test harness (`tests/Run-Tests.ps1`) | Authored but not executed; Windows PowerShell is unavailable here |
| Live Windows integration | Not performed; no Windows host, UAC, `powercfg`, WMI/CIM, or Windows APIs are available |

## Important scope and honesty

- The application does not claim a particular FPS, frame-time, thermal, ping, or latency gain.
- The automatic writer currently changes only the Platinum power scheme's supported processor settings and activation state. Network, display, Game Mode/capture, startup/services, storage, memory, and security settings are detected and left unchanged.
- System Restore is supplemental and best effort. It is never enabled by the optimizer; verified local configuration and power-scheme exports are required before the optional restore-point attempt, which occurs before plan creation or setting changes.
- The custom plan is created/reused and activated automatically when preflight and verification pass. A successful recovery reactivates the prior plan; it leaves a newly created Platinum plan installed but inactive.

See [`KNOWN-LIMITATIONS.md`](KNOWN-LIMITATIONS.md) for Windows integration requirements and the release checklist. See [`REFERENCES.md`](REFERENCES.md) for the supported Windows interfaces used by the automatic pipeline.
