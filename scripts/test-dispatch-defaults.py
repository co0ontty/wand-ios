#!/usr/bin/env python3
"""Touch TASK-143's production composer/sheet with a spy service, never a model.
SIMULATOR_ID and DERIVED_DATA are required; report and screenshots stay in the build directory.
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
TEST = "testTask143ProductionDefaultsAreReadOnlyAndNavigateAfterDismissal"
UDID = os.environ["SIMULATOR_ID"]
OUT = Path(os.environ["DERIVED_DATA"])
started = time.time()
report = {"productionFlowTapped": False, "xctestPassed": False}
worker = None
log_path = None


def command(*args):
    return subprocess.check_output(args, stderr=subprocess.DEVNULL, timeout=20)


def outline():
    return json.loads(command("idb", "ui", "describe-all", "--udid", UDID, "--json"))


def find(identifier):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        rows = outline()
        # This runner owns a fresh QA simulator; never grant notification permission.
        if any("想给你发送通知" in (e.get("AXLabel") or "") for e in rows):
            deny = next((e for e in rows if e.get("role") == "AXButton" and e.get("AXLabel") == "不允许"), None)
            if deny:
                tap(deny)
                continue
        item = next((e for e in rows if e.get("AXUniqueId") == identifier), None)
        if item:
            return item
        time.sleep(0.2)
    (OUT / "missing-element-ax.json").write_text(json.dumps(outline(), ensure_ascii=False, indent=2))
    (OUT / "missing-element.png").write_bytes(command("idb", "screenshot", "--udid", UDID, "-"))
    raise RuntimeError("Missing AX element: " + identifier)


def tap(item):
    frame = item["frame"]
    command("idb", "ui", "tap", "--udid", UDID,
            str(round(frame["x"] + frame["width"] / 2)), str(round(frame["y"] + frame["height"] / 2)))


def drive(path):
    try:
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if path.exists() and path.stat().st_mtime >= started and "TASK143_DEFAULTS_READY" in path.read_text():
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("No current production composer ready signal")
        trigger = find("conversation-execution-defaults")
        assert trigger["role"] == "AXButton" and "只读" in trigger["AXLabel"]
        tap(trigger)
        candidate = find("conversation-default-candidate-1")
        assert candidate["role"] != "AXButton", candidate
        assert "降级候选 2" in candidate["AXLabel"] and "Wand Agent" in candidate["AXLabel"]
        rows = outline()
        assert any("员工默认配置（只读）" == e.get("AXLabel") for e in rows)
        assert any("这里不能选择或切换模型" in (e.get("AXLabel") or "") for e in rows)
        assert not any(e.get("role") == "AXButton" and e.get("AXLabel") == "完成" for e in rows)
        (OUT / "defaults-ax.json").write_text(json.dumps(rows, ensure_ascii=False, indent=2))
        (OUT / "defaults-readonly.png").write_bytes(command("idb", "screenshot", "--udid", UDID, "-"))
        tap(candidate)
        assert find("conversation-default-candidate-1")["AXLabel"] == candidate["AXLabel"]
        tap(find("conversation-close-execution-defaults"))
        deadline = time.monotonic() + 8
        while any(e.get("AXUniqueId") == "conversation-close-execution-defaults" for e in outline()):
            if time.monotonic() > deadline:
                raise RuntimeError("Close did not dismiss the read-only sheet")
            time.sleep(0.1)
        # Wait for the native sheet dismissal to release its hit-test surface.
        time.sleep(0.6)
        tap(find("conversation-execution-defaults"))
        edit = find("conversation-edit-execution-defaults")
        time.sleep(0.6)
        tap(edit)
        deadline = time.monotonic() + 8
        while any(e.get("AXUniqueId") == "conversation-close-execution-defaults" for e in outline()):
            if time.monotonic() > deadline:
                raise RuntimeError("Edit entry did not dismiss the read-only sheet")
            time.sleep(0.1)
        report.update(productionFlowTapped=True, passiveCandidateRole=candidate["role"],
                      closeReopenPassed=True, editEntryTapped=True)
    except Exception as error:
        report["error"] = f"{type(error).__name__}: {error}"


process = subprocess.Popen([str(ROOT / "scripts/run-tests.sh"), "CurrentAndroidParityTests/" + TEST],
                           cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
for line in process.stdout:
    print(line, end="", flush=True)
    match = re.search(r"test-without-building（日志：(.+?)）", line)
    if match:
        log_path = Path(match.group(1))
        worker = threading.Thread(target=drive, args=(log_path,))
        worker.start()
status = process.wait()
if worker:
    worker.join()
if log_path and log_path.exists():
    report["xctestPassed"] = any(TEST in line and "]' passed" in line for line in log_path.read_text().splitlines())
report.update(runnerExit=status, ok=status == 0 and report["productionFlowTapped"] and report["xctestPassed"])
OUT.mkdir(parents=True, exist_ok=True)
(OUT / "dispatch-defaults.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(report, ensure_ascii=False))
sys.exit(0 if report["ok"] else 1)
