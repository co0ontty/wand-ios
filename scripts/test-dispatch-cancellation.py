#!/usr/bin/env python3
"""Tap the production dispatch Cancel button in a simulator; all requests use a spy.
Uses the serial XCTest entry. Does not connect to a model or install a physical device.
SIMULATOR_ID and DERIVED_DATA are required. AX_REPORT_PATH is optional.
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
TEST = "testTask142ProductionCancelButtonNeverPostsTheDraft"
started = time.time()
report = {"productionCancelTapped": False, "xctestPassed": False}
worker = None
log_path = None


def tap_cancel(path):
    try:
        udid = os.environ["SIMULATOR_ID"]
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if path.exists() and path.stat().st_mtime >= started and "TASK142_CANCEL_READY" in path.read_text():
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("No current production-composer-ready signal")
        deadline = time.monotonic() + 20
        button = None
        while time.monotonic() < deadline:
            rows = json.loads(subprocess.check_output(
                ["idb", "ui", "describe-all", "--udid", udid, "--json"],
                stderr=subprocess.DEVNULL, timeout=15))
            button = next((e for e in rows if e.get("AXUniqueId") == "conversation-cancel-dispatch"), None)
            if button:
                break
            time.sleep(0.2)
        if not button:
            raise RuntimeError("Production Cancel button did not become accessible")
        assert button["role"] == "AXButton" and button["AXLabel"] == "取消"
        frame = button["frame"]
        subprocess.run(["idb", "ui", "tap", "--udid", udid,
                        str(round(frame["x"] + frame["width"] / 2)), str(round(frame["y"] + frame["height"] / 2))],
                       check=True, capture_output=True, timeout=15)
        report.update(productionCancelTapped=True, button={k: button.get(k) for k in ["AXLabel", "AXUniqueId", "role", "frame"]})
    except Exception as error:
        report["error"] = f"{type(error).__name__}: {error}"


process = subprocess.Popen([str(ROOT / "scripts/run-tests.sh"), os.environ.get("TEST_SCOPE", "CurrentAndroidParityTests/" + TEST)],
                           cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
for line in process.stdout:
    print(line, end="", flush=True)
    match = re.search(r"test-without-building（日志：(.+?)）", line)
    if match:
        log_path = Path(match.group(1))
        worker = threading.Thread(target=tap_cancel, args=(log_path,))
        worker.start()
status = process.wait()
if worker:
    worker.join()
if log_path and log_path.exists():
    report["xctestPassed"] = any(TEST in line and "]' passed" in line for line in log_path.read_text().splitlines())
report.update(runnerExit=status, ok=status == 0 and report["productionCancelTapped"] and report["xctestPassed"])
destination = Path(os.environ.get("AX_REPORT_PATH", str((log_path.parent if log_path else ROOT) / "dispatch-cancellation.json")))
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(report, ensure_ascii=False))
sys.exit(0 if report["ok"] else 1)
