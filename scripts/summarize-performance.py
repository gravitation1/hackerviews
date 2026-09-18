#!/usr/bin/env python3
"""Summarize a HackerViews debug JSONL trace without printing content or credentials."""
import collections
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else pathlib.Path.home() / 'Library/Caches/HackerViews-performance.jsonl'
rows = []
for line in path.read_text().splitlines():
    try:
        rows.append(json.loads(line))
    except json.JSONDecodeError:
        pass
if not rows:
    raise SystemExit('No trace events yet.')
print(f'{len(rows)} events over {rows[-1]["time"]-rows[0]["time"]:.1f}s')
by_event = collections.defaultdict(list)
for row in rows:
    by_event[row['event']].append(row)
for event in ['item.end', 'profile.end', 'filter.end', 'check.end', 'web.group.start', 'web.batch.dom', 'web.batch.frame', 'web.votes.end']:
    values = sorted(row['ms'] for row in by_event[event] if 'ms' in row)
    if values:
        print(f'{event:24} n={len(values):5} median={values[len(values)//2]:8.1f}ms p95={values[min(len(values)-1,int(len(values)*.95))]:8.1f}ms max={values[-1]:8.1f}ms')
for kind in ['item.cache', 'item.shared', 'profile.cache', 'profile.shared', 'request.retry']:
    print(f'{kind:24} {len(by_event[kind])}')
for kind in ['item.bytes', 'profile.bytes', 'web.votes.response']:
    print(f'{kind:24} {sum(row.get("bytes",0) for row in by_event[kind]):,} bytes')
print('\nSlowest contribution checks:')
for row in sorted(by_event['check.end'], key=lambda row: row['ms'], reverse=True)[:10]:
    print(f'  item {row["id"]}: {row["ms"]:.1f}ms')
print('\nBatch round trips and completed-check hold time (uses per-comment delivery when available):')
for start in by_event['batch.start']:
    end = next((r for r in by_event['batch.deliver'] if (r['tab'], r['navigation'], r['token']) == (start['tab'], start['navigation'], start['token']) and r['time'] >= start['time']), None)
    if not end:
        print(f'  batch {start["token"]}: no delivery (cancelled or still pending)')
        continue
    checks = [r for r in by_event['check.end'] if r['id'] in start['ids'] and start['time'] <= r['time'] <= end['time']]
    deliveries = [d for d in by_event['comment.deliver'] if (d['tab'],d['navigation'],d['token']) == (start['tab'],start['navigation'],start['token'])]
    hold = max(((next((d['time'] for d in deliveries if d['id']==r['id']),end['time'])-r['time'])*1000 for r in checks), default=0)
    print(f'  batch {start["token"]}: {(end["time"]-start["time"])*1000:.1f}ms; earliest finished check held {hold:.1f}ms')
