#!/usr/bin/env python3
"""Exercise production mention candidates in Form with a real simulator AX client.

Requires idb and an existing simulator. Uses the canonical serial XCTest runner:
SIMULATOR_ID=<udid> DERIVED_DATA=<external-path> python3 scripts/test-mention-accessibility.py
AX_REPORT_PATH optionally selects the bounded, credential-free JSON evidence file.
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
TEST = "testMentionCandidatesAreIndependentAccessibilityButtonsInsideForm"
started = time.time()
report = {"externalTreeVerified": False, "xctestPassed": False}
worker = None
log_path = None


def capture(path):
    try:
        udid = os.environ.get("SIMULATOR_ID")
        if not udid:
            devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))
            udid = next(d["udid"] for group in devices["devices"].values() for d in group if "iPhone" in d["name"])
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if path.exists() and path.stat().st_mtime >= started and "TASK140_PICKER_READY" in path.read_text():
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("No current XCTest picker-ready signal")
        raw = subprocess.check_output(["idb", "ui", "describe-all", "--udid", udid, "--json"], stderr=subprocess.DEVNULL, timeout=15)
        rows = [{k: e.get(k) for k in ["AXLabel", "AXUniqueId", "role", "traits", "frame"]}
                for e in json.loads(raw) if (e.get("AXUniqueId") or "").startswith("task-comment-mention-employee-")]
        names = ["勤劳的初二", "赛博虎妞", "石一", "嘟嘟", "石二", "华杰", "瑞辰", "香菜", "小试"]
        assert len(rows) == len(names), f"Expected 9 candidate buttons, got {len(rows)}"
        for index, name in enumerate(names):
            row = next(e for e in rows if e["AXUniqueId"] == f"task-comment-mention-employee-{index}")
            assert row["AXLabel"] == "@" + name and row["role"] == "AXButton"
            assert row["frame"]["height"] >= 43.5
        report.update(externalTreeVerified=True, candidates=rows)
    except Exception as error:
        report["captureError"] = f"{type(error).__name__}: {error}"


process = subprocess.Popen([str(ROOT / "scripts/run-tests.sh"), "TaskCommentsTests/" + TEST], cwd=ROOT,
                           stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
for line in process.stdout:
    print(line, end="", flush=True)
    match = re.search(r"test-without-building（日志：(.+?)）", line)
    if match:
        log_path = Path(match.group(1))
        worker = threading.Thread(target=capture, args=(log_path,))
        worker.start()
status = process.wait()
if worker:
    worker.join()
if log_path and log_path.exists():
    report["xctestPassed"] = any(TEST in line and "]' passed" in line for line in log_path.read_text().splitlines())
report["runnerExit"] = status
report["ok"] = status == 0 and report["externalTreeVerified"] and report["xctestPassed"]
destination = Path(os.environ.get("AX_REPORT_PATH", str((log_path.parent if log_path else ROOT) / "mention-accessibility.json")))
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps({k: v for k, v in report.items() if k != "candidates"}, ensure_ascii=False))
sys.exit(0 if report["ok"] else 1)
