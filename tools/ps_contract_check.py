#!/usr/bin/env python3
"""Static contract checks for the Platinum Optimizer PowerShell pipeline.

Windows PowerShell 5.1 remains the authority for real execution (see
docs/KNOWN-LIMITATIONS.md). This developer tool catches the class of
regression that silently disables functionality: a module or a function that
stops being reachable from the execution pipeline while its source file is
still present in the repository.

It is deliberately stdlib-only so it runs anywhere the repository does.

Checks performed:

  1. every module the pipeline needs is imported by the entry point
  2. every exported function name is actually defined in its module
  3. every `Verb-PO...` call resolves to a function exported by one of the
     imported modules (API-drift detection)
  4. every exported function uses an approved PowerShell verb
  5. every optimization stage function is invoked by the pipeline
  6. no `Start-Sleep` is used to pad the automatic run

Exit code 0 when every check passes.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

MODULES = [
    "PlatinumOptimizer.Core",
    "PlatinumOptimizer.Power",
    "PlatinumOptimizer.Audio",
    "PlatinumOptimizer.Display",
    "PlatinumOptimizer.Network",
    "PlatinumOptimizer.Gaming",
    "PlatinumOptimizer.Engine",
    "PlatinumOptimizer.Automatic",
]

# The stages the automatic engine must execute, in order.
REQUIRED_STAGES = [
    "Invoke-POBootStage",
    "Invoke-POScanStage",
    "Invoke-POBackupStage",
    "Invoke-POCpuStage",
    "Invoke-POPowerStage",
    "Invoke-POGamingStage",
    "Invoke-PONetworkStage",
    "Invoke-POGpuStage",
    "Invoke-PODisplayStage",
    "Invoke-POAudioStage",
    "Invoke-POMemoryStorageStage",
    "Invoke-POVerifyStage",
]

APPROVED_VERBS = {
    "Add", "Approve", "Assert", "Backup", "Block", "Checkpoint", "Clear",
    "Close", "Compare", "Complete", "Confirm", "Connect", "Convert",
    "ConvertFrom", "ConvertTo", "Copy", "Debug", "Deny", "Deploy", "Disable",
    "Disconnect", "Dismount", "Edit", "Enable", "Enter", "Exit", "Expand",
    "Export", "Find", "Format", "Get", "Grant", "Group", "Hide", "Import",
    "Initialize", "Install", "Invoke", "Join", "Limit", "Lock", "Measure",
    "Merge", "Mount", "Move", "New", "Open", "Optimize", "Out", "Ping", "Pop",
    "Protect", "Publish", "Push", "Read", "Receive", "Redo", "Register",
    "Remove", "Rename", "Repair", "Request", "Reset", "Resize", "Resolve",
    "Restart", "Restore", "Resume", "Revoke", "Save", "Search", "Select",
    "Send", "Set", "Show", "Skip", "Split", "Start", "Step", "Stop", "Submit",
    "Suspend", "Switch", "Sync", "Test", "Trace", "Unblock", "Undo", "Unhide",
    "Uninstall", "Unlock", "Unprotect", "Unpublish", "Unregister", "Update",
    "Use", "Wait", "Watch", "Write",
}

_FUNCTION_DEF = re.compile(r"^\s*function\s+([A-Za-z0-9_][A-Za-z0-9_\-]*)\s*\{?", re.M)
_EXPORT_BLOCK = re.compile(
    r"Export-ModuleMember\s*-Function\s+@\((.*?)\)", re.S)
_CALL = re.compile(r"\b([A-Z][A-Za-z]+-PO[A-Za-z0-9_]*)\b")


def strip_non_code(text: str) -> str:
    """Blank out comments and string literals so structural scans are clean."""
    out = []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == "#":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if ch == "<" and i + 1 < n and text[i + 1] == "#":
            end = text.find("#>", i + 2)
            i = n if end < 0 else end + 2
            continue
        if ch == "@" and i + 1 < n and text[i + 1] in ("'", '"'):
            quote = text[i + 1]
            j = i + 2
            while j < n and text[j] in (" ", "\t"):
                j += 1
            if j < n and text[j] == "\n":
                terminator = quote + "@"
                end = text.find("\n" + terminator, j)
                if end < 0:
                    i = n
                else:
                    out.append("\n" * text.count("\n", i, end))
                    i = end + 1 + len(terminator)
                continue
        if ch == "'":
            start = i
            i += 1
            while i < n:
                if text[i] == "'":
                    if i + 1 < n and text[i + 1] == "'":
                        i += 2
                        continue
                    break
                i += 1
            i += 1
            # Preserve the span length so line numbers stay stable, but drop
            # the literal content so no token inside a string is analysed.
            out.append(" " * (i - start))
            continue
        if ch == '"':
            start = i
            i += 1
            while i < n:
                if text[i] == "`":
                    i += 2
                    continue
                if text[i] == '"':
                    break
                i += 1
            i += 1
            out.append(" " * (i - start))
            continue
        out.append(ch)
        i += 1
    return "".join(out)


def module_path(name: str) -> Path:
    return REPO_ROOT / "src" / "core" / (name + ".psm1")


def defined_functions(path: Path) -> set[str]:
    text = strip_non_code(path.read_text(encoding="utf-8"))
    return set(_FUNCTION_DEF.findall(text))


def exported_functions(path: Path) -> set[str]:
    # Read from the RAW source: the exported names live inside quoted strings,
    # and strip_non_code() blanks string literals by design.
    text = path.read_text(encoding="utf-8")
    names: set[str] = set()
    for block in _EXPORT_BLOCK.findall(text):
        names.update(re.findall(r"'([^']+)'", block))
    return names


def called_functions(path: Path) -> set[str]:
    text = strip_non_code(path.read_text(encoding="utf-8"))
    return set(_CALL.findall(text))


def check() -> list[str]:
    """Return a list of contract violations (empty means everything passed)."""
    problems: list[str] = []

    # 1. The entry point must import every module the pipeline depends on.
    entry = REPO_ROOT / "src" / "PlatinumOptimizer.ps1"
    entry_text = entry.read_text(encoding="utf-8")
    for module in MODULES:
        if ("core\\" + module + ".psm1") not in entry_text:
            problems.append(
                f"entry point no longer imports {module}.psm1; its optimization "
                f"category can never run"
            )

    # 2/4. Exported names must exist and use approved verbs.
    all_exports: set[str] = set()
    for module in MODULES:
        path = module_path(module)
        if not path.exists():
            problems.append(f"missing module file {path.name}")
            continue
        defined = defined_functions(path)
        exported = exported_functions(path)
        all_exports.update(exported)
        for name in sorted(exported):
            if name not in defined:
                problems.append(f"{module} exports '{name}' but never defines it")
        for name in sorted(exported):
            verb = name.split("-", 1)[0]
            if verb not in APPROVED_VERBS:
                problems.append(
                    f"{module} exports '{name}': '{verb}' is not an approved "
                    f"PowerShell verb, so importing the module emits a warning"
                )

    # 3. Every cross-module call must resolve to an exported function.
    for module in MODULES:
        path = module_path(module)
        if not path.exists():
            continue
        for callee in sorted(called_functions(path)):
            if callee not in all_exports and callee not in defined_functions(path):
                problems.append(
                    f"{module} calls '{callee}', which no imported module "
                    f"exports (API drift)"
                )

    # 5. The engine must invoke every stage.
    engine = module_path("PlatinumOptimizer.Engine")
    engine_calls = called_functions(engine)
    for stage in REQUIRED_STAGES:
        if stage not in engine_calls:
            problems.append(f"the automatic pipeline never invokes {stage}")

    # 6. No artificial waiting in the automatic pipeline. Core's benchmark
    # sampler legitimately sleeps between counter samples; the pipeline must
    # never pad its runtime to look busy.
    engine_text = strip_non_code(engine.read_text(encoding="utf-8"))
    if re.search(r"\bStart-Sleep\b", engine_text):
        problems.append(
            "PlatinumOptimizer.Engine uses Start-Sleep; the optimizer must not "
            "pad its runtime with artificial delays"
        )

    return problems


def main() -> int:
    problems = check()
    if problems:
        for problem in problems:
            print("FAIL  " + problem)
        print(f"\n{len(problems)} contract violation(s) found.")
        return 1
    print("OK    All PowerShell pipeline contract checks passed.")
    print(f"      {len(MODULES)} modules wired, {len(REQUIRED_STAGES)} stages invoked.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
