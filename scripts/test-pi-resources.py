#!/usr/bin/env python3
"""Exercise the production missing-Skill buttons with native simulator taps.

Uses a resource-service spy for writes. Optional installed-service input is read-only;
the connection file itself is never copied. No model or physical device is started.
SIMULATOR_ID and DERIVED_DATA are required.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
TEST = "testNativeMissingResourceButtonsRemoveHiddenReferencesAndSave"
MARKER = Path("/tmp/wand-ios-pi-ui-replay-enabled")
INPUT = Path("/tmp/wand-ios-pi-acceptance-input.json")
identity = str(os.getpid())
started = time.time()
report = {"removeTapped": False, "saveTapped": False, "xctestPassed": False}
worker = None
log_path = None
input_created = False


def tap_resources(path):
    try:
        udid = os.environ["SIMULATOR_ID"]
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            if path.exists() and path.stat().st_mtime >= started and "PI_RESOURCES_UI_READY" in path.read_text():
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("No current resource-panel-ready signal")

        def button(identifier):
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                rows = json.loads(subprocess.check_output(
                    ["idb", "ui", "describe-all", "--udid", udid, "--json"],
                    stderr=subprocess.DEVNULL, timeout=15))
                result = next((row for row in rows if row.get("AXUniqueId") == identifier), None)
                if result:
                    return result
                time.sleep(0.2)
            raise RuntimeError("Native control unavailable: " + identifier)

        def tap(row):
            assert row["role"] == "AXButton", row.get("role")
            frame = row["frame"]
            subprocess.run(["idb", "ui", "tap", "--udid", udid,
                            str(round(frame["x"] + frame["width"] / 2)),
                            str(round(frame["y"] + frame["height"] / 2))],
                           check=True, capture_output=True, timeout=15)

        output = Path(os.environ["DERIVED_DATA"]) / "pi-resources-ui"
        output.mkdir(parents=True, exist_ok=True)
        remove = button("pi-remove-unavailable-removed")
        subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", str(output / "missing-before.png")],
                       check=True, capture_output=True, timeout=15)
        tap(remove)
        report.update(removeTapped=True, removeButton={key: remove.get(key) for key in ["AXLabel", "AXUniqueId", "role", "frame"]})
        save = button("pi-resources-save")
        tap(save)
        report.update(saveTapped=True, saveButton={key: save.get(key) for key in ["AXLabel", "AXUniqueId", "role", "frame"]})
    except Exception as error:
        report["error"] = f"{type(error).__name__}: {error}"


try:
    # Refuse concurrent acceptance workers instead of overwriting their coordination files.
    with MARKER.open("x") as marker:
        marker.write(identity)
    if os.environ.get("ACCEPTANCE_CONNECTION_PATH"):
        profile = {"connectionPath": os.environ["ACCEPTANCE_CONNECTION_PATH"], "sessionID": os.environ["PI_SESSION_ID"]}
        with INPUT.open("x") as pointer:
            json.dump(profile, pointer)
        input_created = True
    process = subprocess.Popen([str(ROOT / "scripts/run-tests.sh"), "PiResourcesTests"], cwd=ROOT,
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    for line in process.stdout:
        print(line, end="", flush=True)
        match = re.search(r"test-without-building（日志：(.+?)）", line)
        if match:
            log_path = Path(match.group(1))
            worker = threading.Thread(target=tap_resources, args=(log_path,))
            worker.start()
    status = process.wait()
    if worker:
        worker.join()
    if log_path and log_path.exists():
        report["xctestPassed"] = any(TEST in line and "]' passed" in line for line in log_path.read_text().splitlines())
    report.update(runnerExit=status, ok=status == 0 and report["removeTapped"] and report["saveTapped"] and report["xctestPassed"])
    destination = Path(os.environ["DERIVED_DATA"]) / "pi-resources-ui" / "verification.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False))
    sys.exit(0 if report["ok"] else 1)
finally:
    if MARKER.exists() and MARKER.read_text() == identity:
        MARKER.unlink()
        if input_created and INPUT.exists():
            INPUT.unlink()
