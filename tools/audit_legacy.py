#!/usr/bin/env python3
"""Static, non-executing inventory of the retired Platinum+ Optimizer V9.3 batch file.

This script never invokes Windows commands. It extracts source lines and generated
loop targets into a review CSV; annotations deliberately distinguish unknown runtime
state from a documented default.
"""
from __future__ import annotations

import csv
import hashlib
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "legacy" / "Platinum+Optimizer.V9.3.FREE.cmd.disabled.txt"
CSV_PATH = ROOT / "docs" / "legacy-v9.3-tweak-inventory.csv"
SUMMARY_PATH = ROOT / "docs" / "legacy-v9.3-audit-summary.json"

FIELDS = [
    "id", "source_line", "source_section", "operation", "target", "setting", "assigned_value",
    "category", "supported_windows", "source_default", "runtime_current_value", "expected_benefit",
    "risk", "requires_reboot", "requires_admin", "vendor_dependency", "migration_decision",
    "rollback_method", "audit_rationale", "duplicate_count",
]


def section_for(line: str, current: str) -> str:
    stripped = line.strip()
    match = re.match(r"::\s*(\d+[A-Za-z]?[.)]?\s+.+)$", stripped)
    if match and "=" not in match.group(1)[:5]:
        candidate = match.group(1).strip()
        if len(candidate) > 4:
            return candidate
    match = re.match(r"::\s*(FASE\s+\d+:.+|SUBROUTINE\s+.+|---\s*IFEO:.+)", stripped, re.I)
    if match:
        return match.group(1).strip()
    return current


def unquote(value: str) -> str:
    return value.strip().strip('"')


def classify(category_hint: str, target: str, setting: str, operation: str, value: str) -> tuple[str, str, str, str, str]:
    combined = f"{category_hint} {target} {setting} {operation} {value}".lower()
    if any(word in combined for word in ("deviceguard", "hypervisorenforced", "credentialguard", "kernelshadow", "systemguard", "consentprompt", "filteradministratortoken", "featuresettingsoverride", "mpssvc", "defender", "whea", "secureboot", "uac", "security", "crashcontrol")):
        category = "Security / recovery"
    elif any(word in combined for word in ("wuauserv", "windowsupdate", "update", "dosvc", "bits", "usosvc", "waasmedic", "microsoft.windowsstore", "installservice", "pushToInstall", "edgeupdate", "winget", "store")):
        category = "Windows Update / Store / browser maintenance"
    elif any(word in combined for word in ("bcdedit", "bcd", "bootmenupolicy", "x2apic", "platformclock", "dynamictick", "tscsync", "ems")):
        category = "BCD / boot"
    elif any(word in combined for word in ("graphicsdrivers", "direct3d", "directdraw", "dxgkrnl", "nvlddmkm", "nvtweak", "intel\\gmm", "intel\\display", "igfx", "amd\\", "amdwddmg", "radeon", "gpu", "dwm", "dxgi", "vulkan")):
        category = "GPU / graphics / driver"
    elif any(word in combined for word in ("memory management", "prefetch", "memorycompression", "pagefile", "paging", "pool", "numa", "scrub", "throttlingmemory", "cachelimit")):
        category = "Memory / cache"
    elif any(word in combined for word in ("tcpip", "afd", "network", "dns", "iphlp", "remoteaccess", "winrm", "dhcp", "netprofm", "wwan", "wifi", "wlan", "sharedaccess", "deliveryoptimization")):
        category = "Network / connectivity"
    elif any(word in combined for word in ("usb", "hid", "mouse", "keyboard", "bth", "bluetooth", "input", "pci", "acpi", "interrupt", "msi", "affinity")):
        category = "Input / USB / PCI / interrupts"
    elif any(word in combined for word in ("powercfg", "currentcontrolset\\control\\power", "intelppm", "intelpep", "processorperformance", "cstate", "hibernat", "power plan", "turbo", "thermal", "cpu power")):
        category = "Power / CPU policy"
    elif any(word in combined for word in ("storport", "stornvme", "storahci", "disk", "ntfs", "fsutil", "mft", "trim", "compact", "installer", "temp", "cache", "prefetch", "recycle")):
        category = "Storage / cleanup"
    elif any(word in combined for word in ("appx", "remove-appxpackage", "windowsoptionalfeature", "mixedreality", "clipchamp", "zune", "copilot", "solitaire", "debloat")):
        category = "AppX / feature removal"
    elif any(word in combined for word in ("service", "sc config", "sc delete", "start=", "startup")):
        category = "Services / startup"
    elif any(word in combined for word in ("eventlog", "wevtutil", "logman", "autologger", "etl", "wer", "diagnostic", "telemetry", "perflib", "perfdata")):
        category = "Logging / diagnostics / privacy"
    elif any(word in combined for word in ("privacy", "advertising", "contentdelivery", "spotlight", "telemetry", "cortana", "onedrive", "edge", "office")):
        category = "Privacy / applications"
    elif any(word in combined for word in ("visualeffects", "explorer", "desktop", "font", "themes", "menu", "shell", "ui", "toast", "notification")):
        category = "User interface / shell"
    else:
        category = "Other / unclassified"

    high_markers = (
        "remove-appxpackage", "windowsoptionalfeature", "sc delete", "debugger", "systemrestorepointcreationfrequency",
        "featureSettingsoverride", "disablevirtualizationbasedsecurity", "hypervisorenforced", "credentialguard",
        "consentpromptbehavioradmin", "filteradministratortoken", "wevtutil cl", "eventlog-security", "deny system",
        "disablewritecachebufferflush", "thermalthrottlingsoftwaredisable", "pp_thermalautothrottlingenable",
        "softwaredistribution", "catroot2", "driverstore", "system32", "onesetup", "edge\\application",
        "disabledynamictick", "x2apicpolicy", "realtime", "disablememoryscrubbing", "disablememorycompression",
    )
    if any(marker in combined for marker in high_markers) or operation in ("Clear event log", "Remove installed application", "Disable optional Windows feature", "Uninstall browser", "Remove user data"):
        risk = "HIGH"
    elif category in ("Services / startup", "Network / connectivity", "Input / USB / PCI / interrupts", "GPU / graphics / driver", "Power / CPU policy", "BCD / boot", "Memory / cache", "Security / recovery"):
        risk = "MODERATE to HIGH"
    else:
        risk = "LOW to MODERATE"

    requires_admin = "Yes" if any(x in combined for x in ("hklm", "bcdedit", "powercfg", "sc config", "sc delete", "fsutil", "wevtutil", "schtasks", "dism", "allusers", "system32", "windows\\", "winget uninstall", "shutdown /")) else "Usually no (HKCU)"
    reboot = "Yes / often" if any(x in combined for x in ("bcdedit", "memory management", "graphicsdrivers", "nvlddmkm", "intelppm", "intelpep", "stornvme", "storport", "powercfg -h", "disablevirtualizationbasedsecurity", "appx", "optionalfeature", "service start")) else "Unknown / workload dependent"
    vendor = "Vendor/driver-specific; dynamically matched" if any(x in combined for x in ("nvidia", "nvlddmkm", "intelppm", "intelpep", "intel\\gmm", "igfx", "radeon", "amdwddmg", "amd crash")) else "No vendor gate or reliable hardware check in V9.3"
    return category, risk, requires_admin, reboot, vendor


def make_row(line_no: int, section: str, operation: str, target: str, setting: str = "", value: str = "") -> dict[str, str]:
    category, risk, admin, reboot, vendor = classify(section, target, setting, operation, value)
    lower = f"{operation} {target} {setting} {value}".lower()
    if "featureSettingsoverride" in lower or "deviceguard" in lower or "consentprompt" in lower or "wevtutil cl" in lower:
        rationale = "Security, auditability, or recovery is reduced or changed; no source-side compatibility check or verification exists."
    elif "remove-appxpackage" in lower or "uninstall" in lower or "delete" in operation.lower() or operation in ("Delete file/tree", "Clear event log"):
        rationale = "Destructive or difficult to reverse; V9.3 does not preserve the removed payload/state or validate dependencies."
    elif any(x in lower for x in ("reg add", "sc config", "bcdedit", "powercfg", "fsutil")):
        rationale = "The source writes a fixed value without detecting the current state, Windows build, hardware/driver support, dependencies, outcome, or per-operation rollback."
    else:
        rationale = "No controlled before/after benchmark or success verification is present; side effects may be user-, build-, or hardware-dependent."
    rollback = "No reliable per-operation rollback is implemented in V9.3. New engine leaves this retired; use the OS/vendor-supported recovery path or a separately validated backup."
    if operation in ("Create restore point", "Export registry backup", "Create directory"):
        rollback = "Not an optimization mutation; artifact creation is retained only as a local backup concept in the new engine."
    if operation == "Clear event log":
        rollback = "Not reversible; clearing destroys records."
    if operation in ("Delete file/tree", "Remove installed application", "Disable optional Windows feature", "Uninstall browser", "Remove user data"):
        rollback = "Not reliably reversible from V9.3; removed data/package may need re-download, repair, or OS recovery."
    if operation.startswith("Registry") and ("HKCU" in target.upper()):
        rollback = "Could be restored only from an exact pre-change value/type snapshot; V9.3 exports HKLM only and does not capture this HKCU value."
    if operation in ("Power plan command",) or "powercfg" in operation.lower():
        rollback = "V9.3 does not export/record the prior active scheme or settings; no exact rollback."
    return {
        # Filled after extraction so multiple effects expanded from one loop line
        # retain the same source_line but still have unique inventory identifiers.
        "id": "",
        "source_line": str(line_no),
        "source_section": section,
        "operation": operation,
        "target": target,
        "setting": setting,
        "assigned_value": value,
        "category": category,
        "supported_windows": "Unknown: no Windows 10/11 build gate or capability check in V9.3",
        "source_default": "Not established by source; undocumented values have no supportable universal default",
        "runtime_current_value": "Unknown: V9.3 does not read or preserve the pre-change value",
        "expected_benefit": "Not measured in V9.3; the script contains no repeatable before/after game benchmark",
        "risk": risk,
        "requires_reboot": reboot,
        "requires_admin": admin,
        "vendor_dependency": vendor,
        "migration_decision": "RETIRED — not executed by the new optimizer",
        "rollback_method": rollback,
        "audit_rationale": rationale,
        "duplicate_count": "1 (computed after extraction)",
    }


def extract() -> list[dict[str, str]]:
    if not SOURCE.exists():
        raise SystemExit(f"Missing archived source: {SOURCE}")
    lines = SOURCE.read_text(encoding="utf-8-sig", errors="replace").splitlines()
    rows: list[dict[str, str]] = []
    section = "V9.3 startup/menu"
    in_appx_loop = False
    for line_no, line in enumerate(lines, 1):
        stripped = line.strip()
        new_section = section_for(line, section)
        if new_section != section:
            section = new_section
        if re.match(r"for\s+%%A\s+in\s*\(", stripped, re.I):
            in_appx_loop = True
        elif in_appx_loop and stripped == ") do (":
            in_appx_loop = False
        elif in_appx_loop and re.fullmatch(r'"[^"]+"', stripped):
            package = unquote(stripped)
            rows.append(make_row(line_no, section, "Remove installed application (current user loop)", package, "AppX package", "Remove-AppxPackage"))

        # The source has one service list expanded twice: once to sc config and once to Start=4.
        match = re.match(r"set\s+\"SC_DISABLED=(.*?)\"\s*$", stripped, re.I)
        if match:
            names = re.findall(r'"([^"]+)"|([^\s"]+)', match.group(1))
            for quoted, plain in names:
                service = quoted or plain
                if not service:
                    continue
                rows.append(make_row(line_no, section, "sc config generated by SC_DISABLED loop", service, "Startup type", "disabled"))
                rows.append(make_row(line_no, section, "Registry Start=4 generated by SC_DISABLED loop", f"HKLM\\SYSTEM\\CurrentControlSet\\Services\\{service}", "Start", "4 (Disabled)"))
            continue

        # Additional spaced-name service loop.
        if re.match(r"for\s+%%S\s+in\s*\(", stripped, re.I) and "SC_DISABLED" not in stripped:
            names = re.findall(r'"([^"]+)"', stripped)
            for service in names:
                rows.append(make_row(line_no, section, "sc config generated by spaced-service loop", service, "Startup type", "disabled"))

        reg_match = re.match(r"(?:reg(?:\.exe)?|Reg\.exe)\s+(add|delete|export|import)\s+(.+)$", stripped, re.I)
        if reg_match:
            action = reg_match.group(1).lower()
            rest = reg_match.group(2)
            target_match = re.match(r'"([^"]+)"|([^\s]+)', rest)
            target = unquote(target_match.group(1) or target_match.group(2)) if target_match else "unknown"
            value_match = re.search(r"/v\s+\"?([^\s\"]+)\"?", rest, re.I)
            value_name = value_match.group(1) if value_match else "(key or all values)"
            data_match = re.search(r"/d\s+\"([^\"]*)\"|/d\s+([^\s]+)", rest, re.I)
            assigned = unquote(data_match.group(1) or data_match.group(2)) if data_match else ""
            kind_match = re.search(r"/t\s+([^\s]+)", rest, re.I)
            kind = kind_match.group(1) if kind_match else ""
            if action == "add":
                operation = "Registry value write"
                setting = f"{value_name} ({kind})".strip()
            elif action == "delete":
                operation = "Registry value/key delete"
                setting = value_name
            elif action == "export":
                operation = "Export registry backup"
                setting = "Destination"
            else:
                operation = "Registry import"
                setting = "Source"
            rows.append(make_row(line_no, section, operation, target, setting, assigned))
            continue

        # Service Control Manager operations.
        match = re.match(r"sc(?:\.exe)?\s+(config|delete|start|stop|triggerinfo)\s+(.+)$", stripped, re.I)
        if match:
            verb, rest = match.group(1).lower(), match.group(2)
            target = re.match(r'"([^"]+)"|([^\s]+)', rest)
            service = unquote(target.group(1) or target.group(2)) if target else rest
            value = ""
            if verb == "config":
                startup = re.search(r"start\s*=\s*([^\s]+)", rest, re.I)
                value = startup.group(1) if startup else rest
            elif verb == "triggerinfo":
                value = rest[len(service):].strip()
            rows.append(make_row(line_no, section, f"SCM {verb}", service, "Startup/configuration" if verb in ("config", "triggerinfo") else "Service state", value))
            continue

        # Native/PowerShell commands that mutate state.
        bcd = re.match(r"bcdedit(?:\.exe)?\s+(.+)$", stripped, re.I)
        if bcd:
            rows.append(make_row(line_no, section, "BCD write", "{current} boot entry", "BCD option", bcd.group(1)))
            continue
        power = re.match(r"powercfg(?:\.exe)?\s+(.+)$", stripped, re.I)
        if power:
            rows.append(make_row(line_no, section, "Power plan / hibernation command", "Active scheme or system power state", "powercfg", power.group(1)))
            continue
        fsutil = re.match(r"fsutil(?:\.exe)?\s+(.+)$", stripped, re.I)
        if fsutil:
            rows.append(make_row(line_no, section, "Filesystem behavior write", "Windows filesystem", "fsutil", fsutil.group(1)))
            continue
        event = re.match(r"wevtutil(?:\.exe)?\s+(cl|clear-log|set-log)\s+(.+)$", stripped, re.I)
        if event:
            verb = event.group(1).lower()
            rows.append(make_row(line_no, section, "Clear event log" if verb in ("cl", "clear-log") else "Change event log configuration", event.group(2), "Event log", verb))
            continue
        task = re.match(r"schtasks(?:\.exe)?\s+/(change|delete)\s+(.+)$", stripped, re.I)
        if task:
            rest = task.group(2)
            name_match = re.search(r"/tn\s+\"([^\"]+)\"|/tn\s+([^\s]+)", rest, re.I)
            target = unquote(name_match.group(1) or name_match.group(2)) if name_match else rest
            value = "disabled" if "/disable" in rest.lower() else ("enabled" if "/enable" in rest.lower() else "deleted")
            rows.append(make_row(line_no, section, "Scheduled task " + task.group(1).lower(), target, "Task state", value))
            continue
        net = re.match(r"net(?:\.exe)?\s+(stop|start)\s+(.+)$", stripped, re.I)
        if net:
            rows.append(make_row(line_no, section, "Service " + net.group(1).lower(), net.group(2).split()[0], "Running state", net.group(1).lower()))
            continue
        powershell = re.match(r"powershell(?:\.exe)?\s+.*?-Command\s+\"(.*)\"\s*(?:>.*)?$", stripped, re.I)
        if powershell:
            body = powershell.group(1)
            patterns = [
                (r"Checkpoint-Computer", "Create restore point", "System Restore", "Checkpoint-Computer"),
                (r"Disable-MMAgent", "Memory management command", "Memory compression / page combining", body),
                (r"Remove-AppxPackage", "Remove installed application", re.sub(r".*?Get-AppxPackage\s+", "", body), "Remove-AppxPackage"),
                (r"Disable-WindowsOptionalFeature", "Disable optional Windows feature", "Windows optional features", body),
                (r"Set-MpPreference", "Change Defender preference", "Microsoft Defender", body),
                (r"Set-CimInstance", "Change system/pagefile configuration", "Win32_ComputerSystem / page file", body),
                (r"Clear-RecycleBin", "Clear recycle bin", "Current user recycle bin", body),
                (r"Start-Process.*--uninstall", "Uninstall browser", "Microsoft Edge", body),
                (r"Get-Acl|Set-Acl|RegistryAccessRule", "Change registry ACL", "Windows Update service registry keys", body),
            ]
            for pattern, operation, target, value in patterns:
                if re.search(pattern, body, re.I):
                    rows.append(make_row(line_no, section, operation, target, "PowerShell command", value))
                    break
            continue
        if re.match(r"compact(?:\.exe)?\s+", stripped, re.I):
            rows.append(make_row(line_no, section, "CompactOS mode change", "Windows system volume", "CompactOS", stripped)); continue
        if re.match(r"(?:rd|rmdir)\s+", stripped, re.I):
            target = re.sub(r"^(?:rd|rmdir)\s+(?:/s\s+)?(?:/q\s+)?", "", stripped, flags=re.I)
            rows.append(make_row(line_no, section, "Delete file/tree", unquote(target), "Directory tree", "recursive delete")); continue
        if re.match(r"del\s+", stripped, re.I):
            target = re.sub(r"^del\s+(?:/f\s+)?(?:/s\s+)?(?:/q\s+)?", "", stripped, flags=re.I)
            rows.append(make_row(line_no, section, "Delete file/tree", unquote(target), "File pattern", "delete")); continue
        if re.match(r"md\s+", stripped, re.I):
            rows.append(make_row(line_no, section, "Create directory", stripped[3:].strip(), "Directory", "create")); continue
        if re.match(r"icacls\s+", stripped, re.I):
            rows.append(make_row(line_no, section, "Change file ACL", stripped.split()[1], "ACL", stripped)); continue
        if re.match(r"dism(?:\.exe)?\s+", stripped, re.I):
            rows.append(make_row(line_no, section, "DISM feature/state change", "Online Windows image", "DISM", stripped)); continue
        if re.match(r"winget\s+uninstall\s+", stripped, re.I):
            rows.append(make_row(line_no, section, "Remove installed application", stripped.split()[2], "winget package", stripped)); continue
        if re.match(r"diskperf\s+", stripped, re.I):
            rows.append(make_row(line_no, section, "Change disk performance counters", "Disk counters", "diskperf", stripped)); continue
        if re.match(r"verifier\s+", stripped, re.I):
            rows.append(make_row(line_no, section, "Change Driver Verifier configuration", "Driver Verifier", "verifier", stripped)); continue
        if re.match(r"taskkill\s+", stripped, re.I):
            rows.append(make_row(line_no, section, "Terminate process", stripped, "Process", "forced termination")); continue
        if re.match(r"shutdown\s+", stripped, re.I):
            rows.append(make_row(line_no, section, "Forced system reboot", "Windows session", "shutdown", stripped)); continue
        if re.match(r"start\s+explorer\.exe", stripped, re.I):
            rows.append(make_row(line_no, section, "Restart shell process", "Windows Explorer", "explorer.exe", "restart")); continue

    # Assign stable, unique effect IDs after expansion: many generated actions
    # intentionally share one source line and therefore cannot use the line number.
    for effect_number, row in enumerate(rows, 1):
        row["id"] = f"E{effect_number:06d}"

    # Deduplicate by exact effect identity while keeping every source occurrence in the output.
    keys = Counter((r["operation"], r["target"].lower(), r["setting"].lower(), r["assigned_value"].lower()) for r in rows)
    for row in rows:
        key = (row["operation"], row["target"].lower(), row["setting"].lower(), row["assigned_value"].lower())
        row["duplicate_count"] = f"{keys[key]} exact-source occurrence(s)"
    return rows


def main() -> None:
    rows = extract()
    CSV_PATH.parent.mkdir(parents=True, exist_ok=True)
    with CSV_PATH.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)
    by_category = Counter(row["category"] for row in rows)
    by_operation = Counter(row["operation"] for row in rows)
    by_risk = Counter(row["risk"] for row in rows)
    duplicated = [row for row in rows if row["duplicate_count"].startswith(tuple(str(n) for n in range(2, 1000)))]
    summary = {
        "source": str(SOURCE.relative_to(ROOT)),
        "sourceSha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
        "sourceLines": len(SOURCE.read_text(encoding="utf-8-sig", errors="replace").splitlines()),
        "inventoryRows": len(rows),
        "explicitRegistryCommandEffects": sum(row["operation"].startswith("Registry value") for row in rows),
        "generatedServiceActions": sum("SC_DISABLED" in row["operation"] or "spaced-service loop" in row["operation"] for row in rows),
        "generatedRegistryStartupEffects": sum(row["operation"] == "Registry Start=4 generated by SC_DISABLED loop" for row in rows),
        "totalRegistryMutationEffects": sum(row["operation"].startswith("Registry value") or row["operation"] == "Registry Start=4 generated by SC_DISABLED loop" for row in rows),
        "exactlyDuplicatedRows": len(duplicated),
        "rowsWithNoVersionGate": len(rows),
        "rowsWithNoMeasuredBenefit": len(rows),
        "byCategory": dict(sorted(by_category.items())),
        "byRisk": dict(sorted(by_risk.items())),
        "byOperation": dict(sorted(by_operation.items())),
        "decision": "All V9.3 mutations are retired from execution. The archived source is plain text and cannot be launched by the compatibility frontend.",
    }
    SUMMARY_PATH.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Wrote {len(rows)} inventory rows to {CSV_PATH.relative_to(ROOT)}")
    print(f"Wrote summary to {SUMMARY_PATH.relative_to(ROOT)}")
    print(json.dumps({"inventoryRows": len(rows), "explicitRegistryCommandEffects": summary["explicitRegistryCommandEffects"], "generatedRegistryStartupEffects": summary["generatedRegistryStartupEffects"], "totalRegistryMutationEffects": summary["totalRegistryMutationEffects"], "generatedServiceActions": summary["generatedServiceActions"], "exactlyDuplicatedRows": summary["exactlyDuplicatedRows"], "byCategory": summary["byCategory"]}, indent=2))


if __name__ == "__main__":
    main()
