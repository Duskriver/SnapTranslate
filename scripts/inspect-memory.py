#!/usr/bin/env python3
"""Read-only snapshot of an app and the active XPC services in its PID domains."""
import argparse
import json
import re
import subprocess


def command(*args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=15)
    if result.returncode:
        raise RuntimeError(f"{args[0]} failed for {args[-1]}: {result.stderr.strip()}")
    return result.stdout


def active_services(domain):
    in_services = False
    for line in domain.splitlines():
        if line.strip() == "services = {":
            in_services = True
            continue
        if in_services:
            if line.strip() == "}":
                break
            fields = line.split()
            if len(fields) == 3 and fields[0].isdigit() and int(fields[0]) > 0:
                yield int(fields[0]), fields[2]


def footprint_mib(summary, peak=False):
    label = "Physical footprint (peak)" if peak else "Physical footprint"
    match = re.search(rf"^{re.escape(label)}:\s*([\d.]+)([BKMG]?)", summary, re.MULTILINE)
    if not match:
        raise RuntimeError("vmmap did not report physical footprint")
    scale = {"": 1 / 1048576, "B": 1 / 1048576, "K": 1 / 1024, "M": 1, "G": 1024}
    return round(float(match[1]) * scale[match[2]], 3)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pid", type=int, help="running SnapTranslate PID")
    parser.add_argument("--check-ui-services", action="store_true",
                        help="fail if ThemeWidget or Password AutoFill is active; use without key editing or accessibility/UI automation inspection")
    args = parser.parse_args()
    if args.pid <= 0:
        parser.error("PID must be positive")
    pending = [(args.pid, "SnapTranslate", None)]
    visited = set()
    processes = []
    errors = []
    while pending:
        pid, name, owner = pending.pop(0)
        if pid in visited:
            continue
        visited.add(pid)
        entry = {"pid": pid, "name": name, "owner_pid": owner}
        processes.append(entry)
        try:
            summary = command("vmmap", "-summary", str(pid))
            entry["footprint_mib"] = footprint_mib(summary)
            entry["peak_mib"] = footprint_mib(summary, peak=True)
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            errors.append(str(error))
        try:
            domain = command("launchctl", "print", f"pid/{pid}")
            pending.extend((child, label, pid) for child, label in active_services(domain))
        except (RuntimeError, subprocess.TimeoutExpired) as error:
            errors.append(str(error))
    optional_ui_services = [entry for entry in processes if any(
        token in entry["name"] for token in ("ThemeWidgetControlViewService", "SafariPlatformSupport.Helper")
    )]
    report = {
        "scope": "Main process and recursively discovered active XPC services; sequential snapshot, excluding WindowServer/GPU and other shared daemons. Sum is not deduplicated physical RAM.",
        "processes": processes,
        "sampled_footprint_sum_mib": round(sum(entry.get("footprint_mib", 0) for entry in processes), 3),
        "optional_ui_service_count": len(optional_ui_services),
        "errors": errors,
    }
    print(json.dumps(report, ensure_ascii=False, indent=2))
    return 1 if errors or (args.check_ui_services and optional_ui_services) else 0


if __name__ == "__main__":
    raise SystemExit(main())
