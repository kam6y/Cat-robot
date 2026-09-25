#!/usr/bin/env python3
"""Summarize callback timings; these are not acoustic measurements."""
import argparse
import json
import math
import statistics
from collections import defaultdict
from pathlib import Path

def validate_run(payload, expected=None):
    if expected is not None and payload['runID'] != expected:
        raise ValueError('Requested run ID differs from exported data')
    if any(r['runID'] != payload['runID'] for r in payload['records']):
        raise ValueError('Mixed run IDs')
    return payload['records']

def metrics(row):
    events = row.get('events', [])
    def time(point):
        return next((e['at'] for e in events if e['point'] == point), None)
    def ordinal(e):
        if e.get('sentenceOrdinal') is not None: return e['sentenceOrdinal']
        return {'first': 0, 'full': 0, 'remainder': 1}.get(e.get('part'))
    starts = {ordinal(e): e['at'] for e in events if e['point'] == 'speechStarted'}
    finishes = {ordinal(e): e['at'] for e in events if e['point'] == 'speechFinished'}
    gaps = [at - finishes[n - 1] for n, at in starts.items()
            if n is not None and n > 0 and n - 1 in finishes and at >= finishes[n - 1]]
    def interval(end, start):
        return end - start if end is not None and start is not None and end >= start else None
    return dict(start=interval(time('speechStarted'), time('request')),
                total=interval(time('finished'), time('request')), gaps=gaps)

def distribution(values):
    values = sorted(v for v in values if v is not None)
    return dict(count=len(values), median=statistics.median(values) if values else None,
                p95=values[max(0, math.ceil(len(values) * .95) - 1)] if values else None)

def summarize(rows):
    grouped = defaultdict(list)
    for row in rows: grouped[row['stage'] + '/' + row['mode']].append(row)
    result = {}
    for key, rows in grouped.items():
        good = [r for r in rows if r['outcome'] == 'success']
        values = [metrics(r) for r in good]
        peaks = [max((s['bytes'] for s in r.get('footprintSamples', []) if s.get('bytes') is not None), default=None) for r in good]
        result[key] = dict(totalTrials=len(rows), successfulTrials=len(good),
                           start=distribution([v['start'] for v in values]),
                           gap=distribution([g for v in values for g in v['gaps']]),
                           total=distribution([v['total'] for v in values]), footprintBytes=distribution(peaks),
                           cooldownSeconds=sum(r.get('cooldownSeconds', 0) for r in rows),
                           hotEnds=sum(r.get('thermalAfter') in ['serious', 'critical'] for r in rows))
    return result

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('files', type=Path, nargs='+')
    parser.add_argument('--expected-run-id')
    args = parser.parse_args()
    rows = [r for path in args.files for r in validate_run(json.loads(path.read_text()), args.expected_run_id)]
    print(json.dumps(summarize(rows), indent=2))
