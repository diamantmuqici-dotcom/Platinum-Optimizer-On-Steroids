#!/usr/bin/env python3
"""Lightweight structural sanity checks for the PowerShell sources.

This is NOT a full PowerShell parser (Windows PowerShell 5.1 remains the
authority, see docs/KNOWN-LIMITATIONS.md). It tokenizes each .ps1/.psm1 well
enough to detect the most common structural breakages in an editor-less
environment:

  * unterminated strings, here-strings, or comment blocks
  * unbalanced (), {}, [] outside strings/comments
  * a here-string terminator ('@ or "@) that must start the line having stray
    leading content
"""

import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent


def scan(text: str, name: str):
    errors = []
    i, n = 0, len(text)
    line = 1
    stack = []          # bracket stack: (char, line)
    OPEN = {"(": ")", "{": "}", "[": "]"}
    CLOSE = {")", "}", "]"}

    def col_advance(ch):
        nonlocal line
        if ch == "\n":
            line += 1

    while i < n:
        ch = text[i]
        # Line comment
        if ch == "#":
            while i < n and text[i] != "\n":
                i += 1
            continue
        # Block comment <# ... #>
        if ch == "<" and i + 1 < n and text[i + 1] == "#":
            end = text.find("#>", i + 2)
            if end < 0:
                errors.append(f"{name}: unterminated block comment starting near line {line}")
                break
            for c in text[i:end + 2]:
                col_advance(c)
            i = end + 2
            continue
        # Here-strings: @' ... '@   and   @" ... "@
        if ch == "@" and i + 1 < n and text[i + 1] in ("'", '"'):
            quote = text[i + 1]
            # must be @' or @" followed by end of line
            j = i + 2
            while j < n and text[j] in (" ", "\t"):
                j += 1
            if j < n and text[j] == "\n":
                terminator = quote + "@"
                k = j + 1
                found = -1
                while k < n:
                    if text[k] == "\n":
                        # terminator must be first non-whitespace on the line
                        t = k + 1
                        while t < n and text[t] in (" ", "\t"):
                            t += 1
                        if text.startswith(terminator, t):
                            after = t + 2
                            if after >= n or text[after] in ("\r", "\n", " ", "\t", "#", ";", ")"):
                                found = t
                                break
                    k += 1
                if found < 0:
                    errors.append(f"{name}: unterminated here-string starting near line {line}")
                    break
                for c in text[i:found + 2]:
                    col_advance(c)
                i = found + 2
                continue
            # otherwise fall through (splatting operator @x or array @(...))
        # Single-quoted string
        if ch == "'":
            i += 1
            while i < n:
                if text[i] == "'":
                    if i + 1 < n and text[i + 1] == "'":
                        i += 2
                        continue
                    break
                col_advance(text[i])
                i += 1
            if i >= n:
                errors.append(f"{name}: unterminated single-quoted string near line {line}")
                break
            i += 1
            continue
        # Double-quoted string (with backtick escapes)
        if ch == '"':
            i += 1
            while i < n:
                if text[i] == "`":
                    col_advance(text[i])
                    i += 1
                    if i < n:
                        col_advance(text[i])
                        i += 1
                    continue
                if text[i] == '"':
                    if i + 1 < n and text[i + 1] == '"':
                        i += 2
                        continue
                    break
                col_advance(text[i])
                i += 1
            if i >= n:
                errors.append(f"{name}: unterminated double-quoted string near line {line}")
                break
            i += 1
            continue
        if ch in OPEN:
            stack.append((ch, line))
        elif ch in CLOSE:
            if not stack:
                errors.append(f"{name}: unmatched '{ch}' at line {line}")
            else:
                opener, oline = stack.pop()
                if OPEN[opener] != ch:
                    errors.append(f"{name}: mismatched '{opener}' (line {oline}) closed by '{ch}' at line {line}")
        col_advance(ch)
        i += 1
    if stack:
        for opener, oline in stack:
            errors.append(f"{name}: unclosed '{opener}' opened at line {oline}")
    return errors


def main() -> int:
    targets = []
    for pattern in ("src/**/*.ps1", "src/**/*.psm1", "tests/*.ps1"):
        targets.extend(REPO_ROOT.glob(pattern))
    all_errors = []
    for path in sorted(targets):
        text = path.read_text(encoding="utf-8")
        errs = scan(text, str(path.relative_to(REPO_ROOT)))
        if errs:
            all_errors.extend(errs)
        else:
            print("OK    %s" % path.relative_to(REPO_ROOT))
    if all_errors:
        for e in all_errors:
            print("FAIL  %s" % e)
        return 1
    print("All PowerShell sources passed the structural scan.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
