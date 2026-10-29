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
    if payload.get('stage') == 'latency':
        validate_latency(payload)
    return payload['records']

def validate_latency(payload):
    configuration = payload.get('latencyConfiguration', {})
    repetitions = configuration.get('repetitions', 0)
    fixtures = configuration.get('fixtures', [])
    if repetitions < 3 or not fixtures or len({f['id'] for f in fixtures}) != len(fixtures):
        raise ValueError('Latency comparison requires declared fixtures and at least three repetitions')
    revision = payload.get('sourceRevision')
    if not revision or revision == 'unknown':
        raise ValueError('Latency source revision is unknown')
    expected = {(f['id'], n, mode) for f in fixtures for n in range(repetitions) for mode in ('baseline', 'prepared')}
    declared = {f['id']: f['requiresHit'] for f in fixtures}
    seen = set()
    voices = set()
    for row in payload['records']:
        key = (row['fixture'], row['repetition'], row['mode'])
        if key not in expected or key in seen:
            raise ValueError('Unexpected or duplicate latency pair')
        seen.add(key)
        voices.add(row.get('voice'))
        if row.get('sourceRevision') != revision or row.get('stage') != 'latency':
            raise ValueError('Mixed latency source revisions or stages')
        if (row.get('steps'), row.get('threads'), row.get('speed')) != (8, 2, 1.05):
            raise ValueError('Latency inference settings changed')
        if row.get('requiresPreparationHit') != declared[row['fixture']]:
            raise ValueError('Latency fixture contract changed')
        if row.get('outcome') != 'success' or row.get('applicationStateRawValue') != 0:
            raise ValueError('Latency trial did not succeed in foreground')
        inputs = row.get('inputs', [])
        if not inputs or ''.join(i['original'] for i in inputs) != row.get('response'):
            raise ValueError('Latency speech inputs differ from original response')
        events = row.get('events', [])
        for point in ('speechEnqueued', 'speechStarted', 'speechFinished'):
            relevant = [e for e in events if e['point'] == point]
            if [e.get('sentenceOrdinal') for e in relevant] != list(range(len(inputs))):
                raise ValueError('Missing, duplicate or unordered latency sentence events')
        for ordinal in range(len(inputs)):
            times = [next(e['at'] for e in events if e['point'] == point and e.get('sentenceOrdinal') == ordinal)
                     for point in ('speechEnqueued', 'speechStarted', 'speechFinished')]
            if not all(math.isfinite(t) for t in times) or times != sorted(times):
                raise ValueError('Audio started before confirmation or timing is invalid')
        value = metrics(row)
        if value['start'] is None or value['total'] is None:
            raise ValueError('Missing latency interval')
    if seen != expected or len(voices) != 1 or None in voices:
        raise ValueError('Missing latency pairs or mixed voices')


def latency_acceptance(rows):
    if len({(r['runID'], r['sourceRevision']) for r in rows}) != 1:
        raise ValueError('Latency acceptance must evaluate one run and source revision')
    fixtures = {}
    for fixture in sorted({r['fixture'] for r in rows}):
        group = [r for r in rows if r['fixture'] == fixture]
        paired = {(r['repetition'], r['mode']): r for r in group}
        repetitions = sorted({r['repetition'] for r in group})
        differences = [metrics(paired[n, 'prepared'])['start'] - metrics(paired[n, 'baseline'])['start'] for n in repetitions]
        prepared = [r for r in group if r['mode'] == 'prepared']
        hits = sum(sum(e['point'] == 'preparationUsed' for e in r.get('events', [])) for r in prepared)
        attempts = sum(sum(e['point'] == 'preparationStarted' for e in r.get('events', [])) for r in prepared)
        discarded = sum(sum(e['point'] == 'preparationDiscarded' for e in r.get('events', [])) for r in prepared)
        delta = distribution(differences)
        requires_hit = group[0]['requiresPreparationHit']
        passed = delta['p95'] <= .100 and (not requires_hit or (delta['median'] < 0 and hits == len(prepared)))
        # A hit must use the prepared first PCM rather than silently synthesize it again.
        resynthesized_hits = sum(any(e['point'] == 'preparationUsed' for e in r.get('events', []))
                                and any(e['point'] == 'synthesisStarted' and e.get('sentenceOrdinal') == 0 for e in r.get('events', []))
                                for r in prepared)
        passed = passed and resynthesized_hits == 0
        fixtures[fixture] = dict(pairedStartDifference=delta, preparationHits=hits, preparationAttempts=attempts,
                                 discardedPreparations=discarded, resynthesizedHits=resynthesized_hits, passed=passed)
    return dict(passed=bool(fixtures) and all(f['passed'] for f in fixtures.values()),
                p95RegressionLimitSeconds=.100, fixtures=fixtures)


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
    for key, group_rows in grouped.items():
        good = [r for r in group_rows if r['outcome'] == 'success']
        values = [metrics(r) for r in good]
        peaks = [max((s['bytes'] for s in r.get('footprintSamples', []) if s.get('bytes') is not None), default=None) for r in good]
        result[key] = dict(totalTrials=len(group_rows), successfulTrials=len(good),
                           start=distribution([v['start'] for v in values]),
                           gap=distribution([g for v in values for g in v['gaps']]),
                           total=distribution([v['total'] for v in values]), footprintBytes=distribution(peaks),
                           cooldownSeconds=sum(r.get('cooldownSeconds', 0) for r in group_rows),
                           hotEnds=sum(r.get('thermalAfter') in ['serious', 'critical'] for r in group_rows))
    latency = [r for r in rows if r['stage'] == 'latency']
    if latency:
        result['latencyAcceptance'] = latency_acceptance(latency)
    return result

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('files', type=Path, nargs='+')
    parser.add_argument('--expected-run-id')
    parser.add_argument('--require-latency-acceptance', action='store_true')
    args = parser.parse_args()
    rows = [r for path in args.files for r in validate_run(json.loads(path.read_text()), args.expected_run_id)]
    result = summarize(rows)
    print(json.dumps(result, indent=2))
    if args.require_latency_acceptance and not result.get('latencyAcceptance', {}).get('passed'):
        raise SystemExit(1)
