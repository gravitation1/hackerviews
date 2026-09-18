#!/usr/bin/env python3
"""Summarize the latest instrumented scrolling session; never print page content."""
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path.home() / "Library/Caches/HackerViews-performance.jsonl"
rows = []
for line in path.read_text().splitlines():
    try:
        rows.append(json.loads(line))
    except json.JSONDecodeError:
        pass
samples = [r for r in rows if r.get("event") == "web.scroll.sample" and r.get("frames", 0)]
if not samples:
    raise SystemExit("No scrolling samples yet. Open the instrumented build and scroll a page.")
latest = samples[-1]
all_rows = rows
rows = [r for r in rows if r.get("navigation") == latest.get("navigation") and r.get("tab") == latest.get("tab")]
samples = [r for r in rows if r.get("event") == "web.scroll.sample" and r.get("frames", 0)]
total = lambda key: sum(r.get(key, 0) for r in samples)
peak = lambda key: max((r.get(key, 0) for r in samples), default=0)
print(f"Scrolling windows: {len(samples)}; animation-frame intervals: {total('frames')}")
print(f"Frame interval: average {total('frameTotal') / total('frames'):.1f}ms; worst {peak('frameMax'):.1f}ms")
print(f"Intervals >20ms: {total('framesOver20')}; >34ms: {total('framesOver34')} (thresholds, not measured dropped frames)")
for label, prefix in [("Loader scheduler", "pump"), ("Comment rendering", "render"), ("Reading-anchor scan", "anchor")]:
    calls = total(prefix + "Calls")
    print(f"{label}: {calls} calls; total {total(prefix+'Total'):.1f}ms; worst {peak(prefix+'Max'):.1f}ms")
print(f"Anchor selector total: {total('anchorSelectTotal'):.1f}ms; largest page: {peak('anchorRowsMax')} rows; most rows checked per scan: {peak('anchorCheckedMax')}; scroll-triggered scans: {total('anchorScrollCalls')}; longest callback wait: {peak('anchorWaitMax'):.1f}ms")
print(f"Page-height changes: {total('heightChanges')}; largest {peak('heightMax'):.1f}px")
print(f"Deferred-layout transitions: {total('unskipped')} activated, {total('skipped')} skipped")
corrections = [r for r in rows if r.get("event") == "web.scroll.correction"]
active = [r for r in corrections if r.get("scrolling")]
print(f"Scroll corrections: {len(corrections)}; during scrolling: {len(active)}; largest {max((abs(r.get('delta',0)) for r in corrections),default=0):.1f}px")
saves = [r for r in all_rows if r.get("event") == "session.save" and any(abs(r.get("time", 0)-s["time"]) < 1 for s in samples)]
print(f"Session saves near scrolling: {len(saves)}; total {sum(r.get('ms',0) for r in saves):.1f}ms; worst {max((r.get('ms',0) for r in saves),default=0):.1f}ms (all tabs)")
print("Worst scrolling windows (coincidence is not proof of causation):")
for r in sorted(samples, key=lambda r: r.get("frameMax", 0), reverse=True)[:5]:
    nearby = sum(abs(c["time"]-r["time"]) < 1 for c in corrections)
    print(f"  t={r['time']:.3f}: frame {r.get('frameMax',0):.1f}ms, scheduler {r.get('pumpMax',0):.1f}ms, render {r.get('renderMax',0):.1f}ms, anchor {r.get('anchorMax',0):.1f}ms, height changes {r.get('heightChanges',0)}, nearby corrections {nearby}")
