# Implementation report — Platinum On Steroids expansion (v1.1.0)

> **Historical document (v1.x WPF application).** The graphical interface
> described here was removed in v2.0; see
> [`IMPLEMENTATION-REPORT-V2.md`](IMPLEMENTATION-REPORT-V2.md) for the
> current CMD-only automatic engine. The power-plan, audio, and display
> module internals documented below are still in use (audio/display
> primarily for restoring v1.x backups and read-only assessment).

Date: 2026-10-12 · Branch: `arena/8e6acf82-platinum-optimizer-on-steroids` · Base: `ce99daba`

This report states exactly what was implemented, how it was verified in this
workspace, and what still requires verification on real Windows hardware. It
does not claim FPS, latency, or thermal improvements.

## 1. What was delivered

### 1.1 Power plan: Platinum On Steroids (new module `src/core/PlatinumOptimizer.Power.psm1`)

- **Detection:** active plan GUID, full plan enumeration, and presence check
  for the exact name `Platinum On Steroids` (`Get-POPlatinumPlanInfo`).
- **Idempotent creation:** if the plan exists it is queried and validated —
  never duplicated. If absent, it is created with
  `powercfg /duplicatescheme` from the documented High Performance scheme,
  renamed exactly `Platinum On Steroids`, verified in the scheme list, and a
  `.pow` export is saved. A rename failure deletes the unnamed duplicate.
- **Presets inside one plan:** Gaming, Competitive (separate thermal/power
  confirmation), Balanced, Laptop. All values live in
  `src/data/power-settings.json` with Microsoft-documented GUIDs only
  (verified against Microsoft documentation mirrors during development).
  AC and DC are configured separately; laptop presets cap the processor
  ceiling on battery (≤95%, laptop 85%) and use passive cooling on battery.
  Sleep is never disabled: explicit 15–60 minute sleep timeouts.
- **Apply with verification:** every `powercfg /setacvalueindex` /
  `/setdcvalueindex` write is re-read via `powercfg /qh` and compared.
  Settings the platform rejects (boost policy and core-parking settings on
  systems where Windows manages them internally) are skipped as
  NOT_SUPPORTED and listed in the result — never forced, never reported as
  applied. Split-GUID core-parking settings use their documented AC/DC GUID
  variants.
- **Activation:** separate explicit step, verified by re-reading the active
  scheme GUID; refusal paths leave the previous plan active.
- **Restore:** `Restore-POPreviousPowerPlan` reactivates the recorded
  previous plan (re-importing its `.pow` export if it was removed) and never
  deletes the Platinum plan. Restore Center restores `platinum-power-plan`
  ledger records through the same guarded path (refuses if the user changed
  plans afterwards). Explicit removal of the Platinum plan exists as a
  separate action and is blocked while the plan is active.
- **Quick CPU & core parking:** read-only processor setting report from the
  active plan; Quick CPU installation detection (never bundled/launched);
  the documented core-parking knobs are what the plan configures where the
  platform exposes them.
- **Workflow integration:** `Invoke-POPlatinumPlanWorkflow` runs preflight →
  backup (with Platinum state embedded, checksummed) → create/update →
  preset apply → ledger record → optional activation → state persistence.
  Any failure returns FAILED with the previous plan left active.

### 1.2 Audio & Headphones (new module `src/core/PlatinumOptimizer.Audio.psm1`)

- **Detection:** `Win32_SoundDevice`, PnP `AudioEndpoint` inventory, Audiosrv
  state, connection-type inference from PnP ids (USB / Bluetooth / HDAudio /
  GPU display audio), always labeled as inference. Unexposed fields (default
  endpoint, sample rate, enhancements, spatial state, exclusive mode,
  latency) are reported as Unknown with the supported UI path — never
  fabricated. Handles missing/disconnected devices via guarded queries.
- **Seven presets:** Competitive FPS, Positional Audio, Stereo Headphones,
  Surround/Spatial, Music & General, Microphone & Voice Chat, Restore
  Original Audio Settings. Each preset documents what it changes and why.
- **Change surface:** the single automatic change is the documented
  communications-activity value (`UserDuckingPreference`), captured before
  the first change, written as an exact DWord, read back, recorded in the
  backup ledger (`audio` section), and restorable from either the module
  state or Restore Center. No microphone is disabled, default devices are
  never moved, and no codec/driver/third-party audio software is installed.
  Game-native guidance (CS2 HRTF, Fortnite headphone mode, Rust), spatial
  conflict avoidance, Bluetooth codec caveats, and manual `mmsys.cpl` steps
  are delivered as text; nothing is claimed about latency.
- Audio changes are fully independent of the gaming optimization workflow.

### 1.3 Display & Colors (new module `src/core/PlatinumOptimizer.Display.psm1`)

- **Detection:** active displays via `EnumDisplayDevices`/`EnumDisplaySettings`
  (device name, adapter/vendor, monitor PnP identity, current mode, all
  enumerated modes at the current resolution, highest available refresh,
  primary flag), Windows Color Management ICC association (read-only),
  HDR reported as Unknown where the API cannot expose it, DDC/CI read-only
  capability probe via `dxva2`, and detection of NVIDIA/AMD/Intel color
  control surfaces (guidance only).
- **Nine profiles:** Platinum Competitive, CS2 Visibility, Fortnite
  Visibility, Rust Visibility, Natural Colors, Movie & Media, HDR Gaming
  (guidance-only, opens Windows HDR settings), Color-Accurate/Creator,
  Restore Previous Display Configuration.
- **Color-corruption prevention (critical requirement):**
  - gamma ramps are computed **absolutely** from the identity curve —
    repeated applies cannot accumulate;
  - the identical curve is applied to R/G/B — the code path cannot introduce
    a green or any tint;
  - gamma clamped to 0.85–1.15; no maximum-saturation default exists anywhere;
  - original ramp + mode captured per display before the first change;
  - targeting is per selected display; other displays are untouched;
  - no GPU registry value is ever written; vendor saturation is manual-only;
  - driver read-back verification — a ramp the driver ignores (e.g., under
    HDR) is reported as FAILED, not success;
  - refresh changes go through `CDS_TEST` first and are verified after.
- **Scope honesty:** profiles state whether they change the GPU output of one
  display, and game notes state that global ramp changes cannot be limited to
  a single game. No game memory access, anti-cheat interaction, or injection.

### 1.4 Unified dashboard

- New pages: **Power plan**, **Audio & Headphones**, **Display & Colors**,
  each with refresh, preview/confirm, apply, restore, and status surfaces.
- The main button is now **OPTIMIZE MY PC — PLATINUM ON STEROIDS** and runs
  the combined 13-step workflow: detect system/hardware → identify displays
  and audio devices → inspect power plan/CPU state → inspect network →
  inspect input settings → inspect GPU capabilities → generate hardware-aware
  recommendations (Gaming vs Laptop preset by form factor) → capture a
  baseline sample → create backup + change manifest → apply permitted
  low-risk changes (Platinum plan with confirmation, supported TCP baseline,
  DNS cache flush, Ethernet power-management guard) → verify each change →
  show applied/skipped results → offer restoration. Audio presets, display
  profiles, and DNS resolver changes require their own explicit consent and
  are listed as not-auto-applied.

### 1.5 Single-file release: `PlatinumOptimizer.bat`

- cmd/PowerShell polyglot: the ASCII-only batch section launches built-in
  Windows PowerShell 5.1, which reads the BAT itself, extracts the payload,
  and runs it in memory. The payload expands 14 embedded files (engine,
  4 modules, 8 data files, XAML UI, test harness) **byte-exact** (base64)
  into `%LOCALAPPDATA%\PlatinumOptimizer\runtime\<build-id>` once per build,
  then starts the normal engine. Supports `-Scan` and `-SelfTest`.
- No separate scripts at runtime, no downloads, no Python/third-party
  dependencies; only Windows PowerShell 5.1, which ships with supported
  Windows 10/11 desktop editions.
- Generated by `tools/build_single_file.py`; `--check` re-verifies marker
  uniqueness, ASCII batch section, and byte-exact embedding.

## 2. Verification performed in this workspace (Linux)

| Check | Tool | Result |
|---|---|---|
| All data catalogs parse | `python3` JSON | 7/7 OK |
| XAML parses | `xml.dom.minidom` | OK |
| PowerShell structural scan (strings/herestrings/comments/brackets) | `tools/ps_syntax_sanity.py` | 6/6 sources OK |
| PowerShell parse with the tree-sitter PowerShell grammar | `tools/ps_tree_sitter_check.py` | OK (remaining nodes are documented grammar quirks also present at the pre-change baseline) |
| New modules parse with zero findings | tree-sitter gate | Power/Audio/Display clean |
| Single-file release byte-exactness | `tools/build_single_file.py` | 14/14 embedded files identical to repo sources |
| Release payload parseability | tree-sitter on extracted payload | CLEAN |
| Release structural rules (marker unique, ASCII batch, launcher flags) | `tests/Run-Tests.ps1` (runs on Windows) | authored |
| Preset/policy logic tests (ranges, documented-GUID subset, gamma math, parsers, inference, ledger sections) | `tests/Run-Tests.ps1` pure section | authored |

Because this workspace has no Windows PowerShell or Windows 10/11 runtime,
the test harness itself executes only on Windows (see KNOWN-LIMITATIONS.md).

## 3. Acceptance-test status (from the task brief)

| Acceptance item | How it is satisfied | Verified here | Needs Windows |
|---|---|---|---|
| `Platinum On Steroids` can be created or safely updated | idempotent create/validate path with exit-code + re-read verification | logic + data | powercfg execution |
| Existing power plans remain intact | no `/delete` anywhere except explicit self-removal; plan-list delta logged | code review | runtime confirmation |
| Original active plan can be restored | state file + ledger + `.pow` re-import; Restore Center branch | logic | powercfg execution |
| AC and battery behavior handled | per-AC/DC preset values; battery caps; battery/unknown blocks in workflow | data validation | runtime confirmation |
| CPU and core-parking changes verified | every setting re-read via `/qh`; unsupported settings skipped | parser tests | powercfg execution |
| Audio discovery handles missing devices | guarded queries with explicit failure objects | code review | device states |
| Audio profiles preserve original settings | capture-before-change + ledger + two restore paths | logic | registry round-trip |
| Monitor detection handles multiple displays | per-adapter enumeration; per-display targeting; primary default | code review | multi-monitor rig |
| Color changes do not accumulate / corrupt | absolute ramps, channel-identical curves, clamps, captured originals | gamma math tests | driver behavior |
| Unsupported display APIs produce clear messages | read-back mismatch → FAILED with explanation; DDC probe wording | code review | HDR/DDC hardware |
| BAT remains single-file core release | one 608 KB file; runtime expansion only | byte-exact check | first-run expansion |
| PowerShell 5.1 compatibility | no PS7-only syntax; `#requires -Version 5.1` retained | grammar + review | actual 5.1 run |
| Failure paths never report success | all apply functions return FAILED on exit code/verification mismatch | code review | injected failures |
| Rollback works for supported operations | Restore Center sections power/network/registry/audio/display | logic | runtime |
| Documentation covers unverifiable items | KNOWN-LIMITATIONS.md §"Module limits introduced in 1.1" | written | — |

## 4. Known unresolved items

- **No real-hardware run yet:** powercfg behavior on policy-locked machines,
  AMD boost-mode exposure, core-parking visibility per generation, gamma
  behavior under HDR/MPO, and DDC/CI responsiveness must be confirmed on
  physical systems (checklist items 11–14 in KNOWN-LIMITATIONS.md).
- **Quick CPU:** detection only; its UI cannot be driven programmatically
  without vendor APIs, which the project policy excludes.
- **Per-game color isolation:** not claimed; the report and UI state that
  desktop gamma ramps are global by nature.
