#!/usr/bin/env python3
"""Read-only TASK-144 native touch regression against the installed Wand service.

SIMULATOR_ID=<dedicated simulator> DERIVED_DATA=<external directory> python3 scripts/test-board-chrome.py
Credentials are read by XCTest from the private acceptance file, never copied into logs/arguments.
"""
import json
import os
from pathlib import Path
import subprocess
import signal
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
UDID = os.environ["SIMULATOR_ID"]
OUTPUT = Path(os.environ.get("BOARD_CHROME_REPORT_DIR", str(ROOT.parent / "output/architecture-stage2/task-144")))
OUTPUT.mkdir(parents=True, exist_ok=True)
report = {"touchPassed": False}
started = time.time()


def command(*args):
    return subprocess.check_output(list(args), stderr=subprocess.DEVNULL, timeout=25)


def tree():
    return json.loads(command("idb", "ui", "describe-all", "--udid", UDID, "--json"))


def visible(rows):
    return [e for e in rows if e.get("frame", {}).get("height", 0) > 0]


def wait_for(predicate):
    deadline = time.monotonic() + 25
    while time.monotonic() < deadline:
        rows = visible(tree())
        result = predicate(rows)
        if result:
            return rows, result
        time.sleep(0.3)
    raise RuntimeError("Native UI condition did not become true")


def named(rows, label, role=None):
    return next((e for e in rows if e.get("AXLabel") == label and (not role or e.get("role") == role)), None)


def tap(element):
    f = element["frame"]
    command("idb", "ui", "tap", "--udid", UDID, str(f["x"] + f["width"] / 2), str(f["y"] + f["height"] / 2))


def capture(name, rows):
    (OUTPUT / (name + "-ax.json")).write_text(json.dumps(rows, ensure_ascii=False, indent=2))
    command("xcrun", "simctl", "io", UDID, "screenshot", str(OUTPUT / (name + ".png")))


def drive(log_path):
    try:
        deadline = time.monotonic() + 100
        while time.monotonic() < deadline:
            if log_path.exists() and log_path.stat().st_mtime >= started and "TASK144_BOARD_READY" in log_path.read_text():
                break
            time.sleep(0.2)
        else:
            raise RuntimeError("No current XCTest ready signal")
        rows, switch = wait_for(lambda r: named(r, "切换服务器", "AXButton"))
        tap(switch)
        wait_for(lambda r: named(r, "服务器切换次数：1"))
        rows, current_filter = wait_for(lambda r: named(r, "进行中", "AXButton"))
        tap(current_filter)
        rows, identifier = wait_for(lambda r: named(r, "任务编号 TASK-144"))
        # Tap the task card body, away from its status, session and floating create actions.
        f = identifier["frame"]
        command("idb", "ui", "tap", "--udid", UDID, "180", str(f["y"] + f["height"] / 2))
        rows, back = wait_for(lambda r: named(r, "返回", "AXButton"))
        assert not named(rows, "切换服务器")
        assert back["frame"]["height"] >= 44
        capture("detail-phone-light", rows)
        title = next(e for e in rows if (e.get("AXLabel") or "").startswith("[iOS体验][P3] 任务详情标题行"))
        tap(title)
        # Include the old server control location and the new title's lower edge.
        for x, y in [(95, 100), (180, 128)]:
            command("idb", "ui", "tap", "--udid", UDID, str(x), str(y))
        rows, _ = wait_for(lambda r: named(r, "服务器切换次数：1") and named(r, "返回"))
        assert not named(rows, "切换服务器")
        command("xcrun", "simctl", "ui", UDID, "appearance", "dark")
        command("xcrun", "simctl", "ui", UDID, "content_size", "accessibility-extra-extra-extra-large")
        rows, back = wait_for(lambda r: named(r, "返回", "AXButton"))
        assert not named(rows, "切换服务器")
        assert back["frame"]["height"] >= 44
        capture("detail-phone-dark-large", rows)
        tap(back)
        rows, switch = wait_for(lambda r: named(r, "切换服务器", "AXButton"))
        tap(switch)
        rows, _ = wait_for(lambda r: named(r, "服务器切换次数：2"))
        capture("returned-list", rows)
        tap(named(rows, "完成顶栏验收", "AXButton"))
        report.update(touchPassed=True, detailServerButtons=0, explicitListSwitches=2,
                      titleAndOldControlTapsDidNotSwitch=True, backTouchHeight=back["frame"]["height"],
                      installedService=True, taskWriteActions=0, device="iPhone 18 Pro simulator")
    except Exception as error:
        report["error"] = str(error)
    finally:
        for setting, value in [("appearance", "light"), ("content_size", "large")]:
            try:
                command("xcrun", "simctl", "ui", UDID, setting, value)
            except Exception as error:
                report["restoreError"] = str(error)
        (OUTPUT / "touch-result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")


env = dict(os.environ, TEST_RUNNER_WAND_BOARD_TOUCH_CONNECTION=str(Path.home() / ".wand/acceptance-connection.json"))
process = subprocess.Popen([str(ROOT / "scripts/run-tests.sh"), "TaskBoardTests"], cwd=ROOT,
                           env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
runner_done = threading.Event()


def limit_runner():
    if not runner_done.wait(600):
        report["runnerTimeout"] = True
        # Only this runner's new process group, never shared simulator/system services.
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass


threading.Thread(target=limit_runner, daemon=True).start()
worker = None
for line in process.stdout:
    print(line, end="", flush=True)
    if "test-without-building（日志：" in line:
        path = Path(line.split("日志：", 1)[1].split("）", 1)[0])
        worker = threading.Thread(target=drive, args=(path,))
        worker.start()
status = process.wait()
runner_done.set()
if worker:
    worker.join()
report.update(runnerExit=status, ok=status == 0 and report["touchPassed"])
(OUTPUT / "touch-result.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(report, ensure_ascii=False))
raise SystemExit(0 if report["ok"] else 1)
