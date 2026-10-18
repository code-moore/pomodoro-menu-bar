#!/usr/bin/env python3
"""Verification harness for the Pomodoro day planner.

Reads the app's UserDefaults via `defaults export` and asserts on real state,
rather than trusting that the code does what it looks like it does.

Scenario a expects the two seeded tasks T1/T2: T1 completed and T2 paused
with a 30-minute countdown. Scenario b expects yesterday's history to remain
after rollover, with no selected countdown. These are fixture checks, not
general checks against an arbitrary user's task list.
"""
import datetime
import json
import os
import plistlib
import subprocess
import sys

DOMAIN = os.environ.get("BUNDLE_ID", "com.codemoore.pomodoro.menubar")
TODAY = datetime.date.today().isoformat()
T1 = "11111111-1111-1111-1111-111111111111"
T2 = "22222222-2222-2222-2222-222222222222"


def prefs():
    out = subprocess.run(["defaults", "export", DOMAIN, "-"], capture_output=True)
    return plistlib.loads(out.stdout) if out.stdout else {}


def show_prefs(d):
    print("   taskHistory keys:", sorted(json.loads(d.get("dayHistory", "{}")).keys()))
    print("   activeBlockID  :", d.get("activeBlockID"))
    print("   isRunning      :", d.get("isRunning"))
    print("   remaining      :", d.get("remaining"))


def test_restore_and_complete():
    d = prefs()
    tasks = json.loads(d["dayHistory"])[TODAY]
    for t in tasks:
        print("   {:<16} est={}m  done={}".format(
            t["title"], t["estimateMinutes"], bool(t.get("completedAt"))))
    show_prefs(d)
    by_id = {task["id"].upper(): task for task in tasks}
    first = by_id.get(T1)
    second = by_id.get(T2)
    expected_block = (
        f"{T2}-work-{second.get('completedBlocks', 0) + 1}" if second else None
    )
    ok = (
        first is not None
        and second is not None
        and bool(first.get("completedAt"))
        and second.get("completedAt") is None
        and d.get("activeBlockID") == expected_block
        and d.get("isRunning") in (False, 0)
        and abs(float(d.get("remaining", 0)) - 1800) < 1
    )
    print("\n   PASS" if ok else "\n   FAIL")
    return ok


def test_rollover():
    d = prefs()
    hist = json.loads(d.get("dayHistory", "{}"))
    yesterday = (datetime.date.today() - datetime.timedelta(days=1)).isoformat()
    kept = hist.get(yesterday, [])
    print("   yesterday's task kept:", bool(kept), "->", kept[0]["title"] if kept else None)
    show_prefs(d)
    ok = (
        bool(kept)
        and d.get("activeBlockID") in (None, "")
        and d.get("isRunning") in (False, 0)
    )
    print("\n   PASS" if ok else "\n   FAIL")
    return ok


if __name__ == "__main__":
    result = {"a": test_restore_and_complete, "b": test_rollover}[sys.argv[1]]()
    sys.exit(0 if result else 1)
