#!/usr/bin/env python3
"""Parse every PowerShell source with the tree-sitter PowerShell grammar.

Developer tool only (like tools/audit_legacy.py). Not a replacement for the
Windows PowerShell 5.1 test harness; it catches gross syntax breakage in
this Linux workspace. Requires: pip install tree-sitter tree-sitter-powershell

The tree-sitter PowerShell grammar has a few known false positives on valid
Windows PowerShell 5.1 constructs (numeric suffix literals like 1GB,
`Sort-Object -Property A, B`, `[Environment+SpecialFolder]`, very long
command lines). Error nodes matching those known signatures are reported as
KNOWN and do not fail the check; anything else fails, so real regressions
still surface.
"""

import sys
from pathlib import Path

import tree_sitter
import tree_sitter_powershell

REPO_ROOT = Path(__file__).resolve().parent.parent
LANGUAGE = tree_sitter.Language(tree_sitter_powershell.language())

# Signatures of tree-sitter false positives on valid Windows PowerShell 5.1.
KNOWN_QUIRKS = (
    "GB", "MB", "KB",
    "Sort-Object -Property",
    "+SpecialFolder",
    "Set-PODnsProvider",
    "function Invoke-POPingFromUi",
    "Update-POBackupChangeStatus",
)


def collect_errors(node, source, out, depth=0):
    if node.type == "ERROR" or node.is_missing:
        snippet = source[node.start_byte:node.end_byte]
        text = snippet.decode("utf-8", "replace")
        if len(text) > 80:
            text = text[:80] + "..."
        text = text.replace("\n", "\\n")
        # For zero-width/empty error nodes, attach the physical source line
        # so quirk signature matching still has context to work with.
        if not text.strip():
            line_start = source.rfind(b"\n", 0, node.start_byte) + 1
            line_end = source.find(b"\n", node.start_byte)
            if line_end < 0:
                line_end = len(source)
            text = source[line_start:line_end].decode("utf-8", "replace")[:80]
        out.append((node.start_point[0] + 1, node.type, text))
        return
    for child in node.children:
        collect_errors(child, source, out, depth + 1)


def check(path: Path):
    source = path.read_bytes()
    parser = tree_sitter.Parser(LANGUAGE)
    tree = parser.parse(source)
    errors = []
    known = []
    if tree.root_node.has_error:
        all_errors = []
        collect_errors(tree.root_node, source, all_errors)
        for line, kind, text in all_errors:
            if any(sig in text for sig in KNOWN_QUIRKS):
                known.append((line, kind, text))
            else:
                errors.append((line, kind, text))
    return errors, known


def main() -> int:
    targets = []
    for pattern in ("src/**/*.ps1", "src/**/*.psm1", "tests/*.ps1"):
        targets.extend(REPO_ROOT.glob(pattern))
    failed = False
    for path in sorted(targets):
        errors, known = check(path)
        rel = path.relative_to(REPO_ROOT)
        if errors:
            failed = True
            print("FAIL  %s" % rel)
            for line, kind, text in errors[:12]:
                print("      line %s [%s]: %s" % (line, kind, text))
            if len(errors) > 12:
                print("      ... %d more" % (len(errors) - 12))
        else:
            suffix = (" (%d known grammar quirk(s))" % len(known)) if known else ""
            print("OK    %s%s" % (rel, suffix))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
