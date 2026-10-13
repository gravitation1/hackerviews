#!/usr/bin/env python3
"""Summarize section switches from a HackerViews debug trace (section.switch events)."""
import collections
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path.home() / 'Library/Caches/HackerViews-performance.jsonl'
rows = []
for line in path.read_text().splitlines():
    try:
        row = json.loads(line)
    except json.JSONDecodeError:
        continue
    if row.get('event') == 'section.switch':
        rows.append(row)
if not rows:
    raise SystemExit('No section switches in the trace yet. Switch sections in a Debug build first.')

fields = ['actionMs', 'commitMs', 'cpuMs', 'frameMs', 'settledMs', 'busyPasses', 'busyCpuMs']
def stats(values):
    values = sorted(v for v in values if v >= 0)
    if not values:
        return '      -'
    return f'{values[len(values) // 2]:7.1f} (max {values[-1]:6.1f})'

by_target = collections.defaultdict(list)
for row in rows:
    by_target[row['to']].append(row)
print(f'{len(rows)} switches; medians, ms from the click unless noted')
print(f'{"to":10} {"n":>3}  ' + '  '.join(f'{f:>20}' for f in fields))
for target in sorted(by_target):
    group = by_target[target]
    print(f'{target:10} {len(group):3}  ' + '  '.join(f'{stats([r.get(f, -1) for r in group]):>20}' for f in fields))
print('\nLast 10:')
for row in rows[-10:]:
    print(f'  {row["from"]:>8} -> {row["to"]:<8} {row.get("input", "?"):>9} ' + ' '.join(f'{f}={row.get(f, -1):.1f}' for f in fields))
