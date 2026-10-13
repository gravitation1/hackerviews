#!/usr/bin/env python3
"""Summarize timed interactions from a HackerViews debug trace: section switches
(section.switch, by destination) and note editor opens (note.open)."""
import collections
import json
import os
import pathlib
import sys

args = [a for a in sys.argv[1:] if not a.startswith('--')]
path = pathlib.Path(args[0]) if args else pathlib.Path.home() / 'Library/Caches/HackerViews-performance.jsonl'
# --since-build: only events recorded since the Debug app was last built.
since = 0
if '--since-build' in sys.argv:
    since = os.path.getmtime(pathlib.Path(__file__).resolve().parent.parent / 'build/Build/Products/Debug/HackerViews.app/Contents/MacOS/HackerViews')
rows = []
for line in path.read_text().splitlines():
    try:
        row = json.loads(line)
    except json.JSONDecodeError:
        continue
    if row.get('event') in ('section.switch', 'note.open') and row.get('time', 0) >= since:
        rows.append(row)
if not rows:
    raise SystemExit('No timed interactions in the trace yet. Switch sections or open a note in a Debug build first.')

fields = ['actionMs', 'commitMs', 'cpuMs', 'frameMs', 'settledMs', 'busyPasses', 'busyCpuMs']
def stats(values):
    values = sorted(v for v in values if v >= 0)
    if not values:
        return '      -'
    return f'{values[len(values) // 2]:7.1f} (max {values[-1]:6.1f})'

groups = collections.defaultdict(list)
for row in rows:
    groups['switch to ' + row['to'] if row['event'] == 'section.switch' else 'open note' + (' (profile)' if row.get('profile') else '')].append(row)
print(f'{len(rows)} interactions; medians, ms from the input unless noted. settledMs also catches unrelated background work.')
print(f'{"":20} {"n":>3}  ' + '  '.join(f'{f:>20}' for f in fields))
for name in sorted(groups):
    group = groups[name]
    print(f'{name:20} {len(group):3}  ' + '  '.join(f'{stats([r.get(f, -1) for r in group]):>20}' for f in fields))
print('\nLast 10:')
for row in rows[-10:]:
    label = f'{row["from"]:>8} -> {row["to"]:<8}' if row['event'] == 'section.switch' else f'{"open note":>20}'
    print(f'  {label} {row.get("input", "?"):>9} ' + ' '.join(f'{f}={row.get(f, -1):.1f}' for f in fields))
