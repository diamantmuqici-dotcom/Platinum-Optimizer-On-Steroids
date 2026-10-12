# Regression audit — why the optimizer stopped optimizing

Date: 2026-10-12 · Repository: `diamantmuqici-dotcom/Platinum-Optimizer-On-Steroids`
Audited range: `main` @ `2c195e8` ("version 2.0.1")

This document records how the automatic engine was traced from "runs for a
few seconds, creates a power plan, exits" back to its cause. Every claim below
is backed by a command that can be re-run against this repository.

## 1. Symptom

An automatic administrator run performs a short assessment, creates a backup
and the `Platinum On Steroids` power plan, prints a small report and exits.
Network, gaming, GPU/display, memory and storage categories report nothing.

## 2. How the history was recovered

`main` contains a single squashed commit, so `git log` shows no history:

```
$ git log --oneline
2c195e8 Merge pull request #6 from ...
```

The prior branch states are still on the remote as pull-request refs, which
expose every historical commit:

```
$ git fetch origin '+refs/pull/*/head:refs/remotes/pr/*'
$ git log --all --oneline
2c195e8 Merge pull request #6 ...
5f7d3cf Fix power plan rename and automatic report serialization
00f0e2b Merge pull request #5 ...
fe638e6 Merge main and resolve CMD launcher conflicts
6bf77a4 Harden elevation detection for Windows launchers
8e94aa1 Replace GUI with automatic CMD optimization workflow
f0033ed Merge pull request #4 ...
cadefa6 v2.0: remove the WPF UI entirely; ship the automatic CMD optimization engine
71ecf2a Merge pull request #3 ...
1887fd1 Add Platinum On Steroids power plan, audio & display modules, unified workflow ...
```

## 3. Root cause

**The automatic engine was replaced in commit `8e94aa1` (PR #5), and the new
entry point imports only five of the eight modules the pipeline needs. The
three modules that own the network, gaming and pipeline-orchestration
categories are still present in `src/core/` but are never imported, so they
can never execute.**

Evidence — the entry point's import list before and after `8e94aa1`:

```
$ git diff pr/4 HEAD -- src/PlatinumOptimizer.ps1
-Import-Module ... 'core\PlatinumOptimizer.Network.psm1' -Global -Force
-Import-Module ... 'core\PlatinumOptimizer.Gaming.psm1'  -Global -Force
-Import-Module ... 'core\PlatinumOptimizer.Engine.psm1'  -Global -Force
+$moduleFiles = @(
+    'src\core\PlatinumOptimizer.Core.psm1',
+    'src\core\PlatinumOptimizer.Power.psm1',
+    'src\core\PlatinumOptimizer.Audio.psm1',
+    'src\core\PlatinumOptimizer.Display.psm1',
+    'src\core\PlatinumOptimizer.Automatic.psm1'
+)
```

The replacement module states this was deliberate, not accidental:

> `src/core/PlatinumOptimizer.Automatic.psm1`
> "This module deliberately keeps network, security, services, startup,
> display and capture settings read-only; the automatic writer is the
> verified Platinum power-plan path."

`Automatic.psm1` then emits seven hard-coded `SKIPPED` entries instead of
calling the real modules, which is why the console shows no work for those
categories.

So the other categories were **not** unsupported, missing or misdetected.
They are **implemented and disconnected from the execution pipeline**.

## 4. Why simply re-adding the imports would not have worked

Reconnecting the modules surfaces three additional regressions introduced by
the same rewrite. Each was confirmed by comparing `pr/4` against `HEAD`.

### 4.1 `Add-POBackupFile` was deleted from Core

`PlatinumOptimizer.Network.psm1` calls `Add-POBackupFile` to capture the
TCP and adapter before-state into the run backup. The function existed at
`pr/4` and is gone at `HEAD`, so the network stage would throw on every run.

```
$ git grep -n "function Add-POBackupFile" pr/4 -- src/core/PlatinumOptimizer.Core.psm1
pr/4:src/core/PlatinumOptimizer.Core.psm1:1733:function Add-POBackupFile {
$ grep -c "Add-POBackupFile" src/core/PlatinumOptimizer.Core.psm1
0          # (only the two call sites in Network.psm1 and Engine.psm1 remain)
```

### 4.2 The Network module's ledger sections were removed from every allowlist

Three separate allowlists lost `network-tcp` and `network-adapter-power`,
which makes any backup written by the network stage unrestorable, and would
make the network stage's own ledger calls fail parameter validation.

| Location | `pr/4` | `HEAD` (before this fix) |
|---|---|---|
| `Restore-POBackup` `$allowedSections` | includes both | dropped |
| `Add-POBackupChange` `ValidateSet` | includes both | dropped |
| `Update-POBackupChangeStatus` `ValidateSet` | includes both | dropped |

### 4.3 The restore dispatch lost its network handlers

`pr/4` dispatched `network-tcp` and `network-adapter-power` to
`Restore-PONetworkTcpSection` / `Restore-PONetworkAdapterPowerSection`.
`HEAD` has no branch for them, so `Restore-POBackup` would fall through to
`default { throw "No restore handler exists..." }`.

## 5. The unapproved-verb warning

The run printed:

> "The names of some imported commands from the module
> 'PlatinumOptimizer.Display' include unapproved verbs"

`PlatinumOptimizer.Display.psm1` exported `Compute-POGammaRamp`. `Compute` is
not in the approved verb list returned by `Get-Verb`. Renamed to
`New-POGammaRamp` (it constructs a gamma-ramp object), with all call sites and
the test harness updated. No warning was suppressed.

## 6. What was NOT the cause

- **Not** the legacy V9.3 batch file. `legacy/Platinum+Optimizer.V9.3.FREE.cmd.disabled.txt`
  is inert text and is never launched by either CMD entry point. The original
  2,841-line V9.3 script was retired on purpose in `af3f168` (PR #1) and its
  1,687 extracted effects are catalogued in `docs/legacy-v9.3-tweak-inventory.csv`.
  Nothing from it was restored to execution.
- **Not** a 30-minute runtime. No historical commit contains artificial
  waiting; `Start-Sleep` appears only inside `Get-POBenchmarkSnapshot`, where
  it is the counter-sampling interval. There was no legitimate long-running
  work to recover — the original detailed terminal output came from the staged
  `PlatinumOptimizer.Engine.psm1` pipeline (preflight → detection → recovery →
  power → gaming → GPU/display → network → storage → verification → report),
  which was orphaned, not deleted.
- **Not** a missing capability. Every module in `src/core/` compiles and
  exports its functions; they were simply unreachable.

## 7. Fix summary

| # | Defect | Fix |
|---|---|---|
| 1 | Entry point imports 5 of 8 modules | `src/PlatinumOptimizer.ps1` imports all 8; the BOOT stage verifies each is loaded and reports any that is not |
| 2 | No detailed live pipeline | `PlatinumOptimizer.Engine.psm1` restored and extended to 12 stage-tagged stages |
| 3 | `Add-POBackupFile` deleted | Restored in `PlatinumOptimizer.Core.psm1` and re-exported |
| 4 | Network ledger sections dropped | Restored in all three allowlists |
| 5 | Network restore handlers dropped | Dispatch branches restored |
| 6 | `Compute-POGammaRamp` unapproved verb | Renamed to `New-POGammaRamp` |
| 7 | No guard against recurrence | `tools/ps_contract_check.py` + `tests/test_pipeline_contract.py` |

The checker was verified against the real defects: simulating each one in a
scratch copy of the repository makes it fail with the expected message.

## 8. Verification status

- Static and contract tests: **executed** (see `docs/IMPLEMENTATION-REPORT.md`).
- Windows PowerShell 5.1 runtime tests: **written but not executed here** —
  this workspace has no Windows host. See `docs/KNOWN-LIMITATIONS.md`.
