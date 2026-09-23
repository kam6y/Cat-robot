#!/usr/bin/env python3
"""Summarize synthetic on-device trials. Missing evidence never implies adoption."""
import argparse
from collections import Counter, defaultdict
import json
import math
from pathlib import Path
import statistics

MODES = ('completeResponse', 'firstSentence')
FIXTURES = ('cat-sleep', 'rain-play', 'morning-walk', 'reading', 'nervous',
            'spring', 'tidy', 'sunset', 'packing', 'tea')
CONTROLS = ('control-word', 'control-one-sentence', 'control-number', 'control-url', 'control-quote')
OUTCOMES = {'success', 'cancelled', 'generationFailure', 'speechFailure', 'saveWarning', 'noResponse', 'ambiguous'}


class SchemaError(ValueError):
    pass


def percentile90(values):
    return sorted(values)[math.ceil(.9 * len(values)) - 1] if values else None


def distribution(values):
    return dict(count=len(values), median=statistics.median(values) if values else None,
                p90=percentile90(values), values=values)


def numeric(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def validate(data):
    if not isinstance(data, dict) or data.get('schemaVersion') != 1 or not isinstance(data.get('trials'), list):
        raise SchemaError('Expected schemaVersion 1 and a trials array')
    ids, keys = set(), set()
    for trial in data['trials']:
        if not isinstance(trial, dict) or trial.get('schemaVersion') != 1:
            raise SchemaError('Invalid trial schema')
        for field in ['trialID', 'fixture', 'thermalState', 'powerState', 'osVersion', 'voiceIdentifier']:
            if not isinstance(trial.get(field), str) or not trial[field]:
                raise SchemaError(f'Missing string field: {field}')
        if (trial.get('mode') not in MODES or trial.get('path') not in ('fast', 'classified', 'typed')
                or trial.get('inputKind') not in ('syntheticRecognition', 'typed', 'microphone')
                or trial.get('outcome') not in OUTCOMES or trial.get('temperature') not in ('warm', 'cold')
                or trial.get('cohort') not in ('normal', 'control', 'compaction')):
            raise SchemaError('Invalid trial mode/path/outcome/cohort')
        for field in ['repetition', 'initialRevision', 'processID']:
            if type(trial.get(field)) is not int or trial[field] < 0:
                raise SchemaError(f'Invalid integer field: {field}')
        for field in ['earlySentenceUsed', 'listeningResumed']:
            if type(trial.get(field)) is not bool:
                raise SchemaError(f'Invalid boolean field: {field}')
        key = tuple(trial[k] for k in ('fixture', 'path', 'inputKind', 'temperature', 'mode', 'repetition', 'cohort'))
        if trial['trialID'] in ids or key in keys:
            raise SchemaError('Duplicate trial')
        ids.add(trial['trialID']); keys.add(key)
        if not isinstance(trial.get('events'), list):
            raise SchemaError('Missing events array')
        event_ids = set()
        previous = -math.inf
        for event in trial['events']:
            if not isinstance(event, dict) or not numeric(event.get('at')) or not isinstance(event.get('point'), str):
                raise SchemaError('Invalid event or timestamp')
            if not isinstance(event.get('id'), str) or not event['id']:
                raise SchemaError('Missing event correlation ID')
            event_ids.add(event['id'])
            if event['at'] < previous:
                raise SchemaError('Events must use a monotonic clock and be in recorded order')
            previous = event['at']
        if len(event_ids) > 1:
            raise SchemaError('Mixed correlation IDs in one trial')
    validation = data.get('validation', {})
    if not isinstance(validation, dict):
        raise SchemaError('Invalid validation object')


def measurement(trial):
    events = trial['events']
    by_point = defaultdict(list)
    for event in events:
        by_point[event['point']].append(event)
    starts = by_point['speechStarted']
    source = starts[0].get('source') if starts else None
    if trial['outcome'] != 'success':
        return None, source
    if len(by_point['request']) != 1 or len(by_point['finished']) != 1 or not starts or not by_point['speechFinished']:
        return None, source
    if source not in ('started', 'willSpeakFallback') or by_point['finished'][0].get('outcome') != 'success':
        return None, source
    parts = [event.get('part') for event in starts]
    ends = [event.get('part') for event in by_point['speechFinished']]
    if len(parts) != len(set(parts)) or sorted(parts) != sorted(ends) or parts not in (['full'], ['first'], ['first', 'remainder']):
        return None, source
    request = by_point['request'][0]['at']
    first = starts[0]['at']
    last = max(event['at'] for event in by_point['speechFinished'])
    if first < request or last < first or by_point['finished'][0]['at'] < last:
        return None, source
    gap = None
    if parts == ['first', 'remainder']:
        first_end = next(event['at'] for event in by_point['speechFinished'] if event['part'] == 'first')
        gap = starts[1]['at'] - first_end
        if gap < 0: return None, source
    return dict(start=first-request, end=last-request, gap=gap,
                compaction=bool(by_point['compactionStarted']),
                sessionCount=len(by_point['sessionStarted'])), source


def summarize(data):
    validate(data)
    trials = data['trials']
    reasons, outcomes, sources = set(), Counter(), Counter()
    groups, measured = defaultdict(list), {}
    invalid = []
    for trial in trials:
        outcomes[trial['outcome']] += 1
        value, source = measurement(trial)
        if source: sources[source] += 1
        if value is None:
            if trial['outcome'] == 'success': invalid.append(trial['trialID'])
            continue
        measured[trial['trialID']] = (value, source)
        group = '/'.join([trial['cohort'], trial['temperature'], trial['path'], trial['mode'], source,
                          'compaction' if value['compaction'] else 'ordinary'])
        groups[group].append((trial, value))
    primary = [t for t in trials if t['cohort'] == 'normal' and t['temperature'] == 'warm'
               and t['inputKind'] == 'syntheticRecognition' and t['path'] in ('fast', 'classified')]
    usable = [t for t in primary if t['trialID'] in measured and measured[t['trialID']][1] == 'started'
              and not measured[t['trialID']][0]['compaction'] and t['listeningResumed']]
    for fixture in FIXTURES:
        for path in ('fast', 'classified'):
            matching = [t for t in usable if t['fixture'] == fixture and t['path'] == path]
            repetitions = [{t['repetition'] for t in matching if t['mode'] == mode} for mode in MODES]
            if len(repetitions[0] & repetitions[1]) < 3:
                reasons.add('insufficient_paired_successes')
    pairs = defaultdict(list)
    for trial in trials:
        if trial["temperature"] == "warm":
            pairs[(trial["fixture"], trial["path"], trial["repetition"])].append(trial)
    for pair in pairs.values():
        if len(pair) != 2: continue
        conditions = ('osVersion', 'voiceIdentifier', 'initialRevision', 'inputKind')
        if any(pair[0][key] != pair[1][key] for key in conditions): reasons.add('unmatched_conditions')
        expected = list(MODES) if pair[0]['repetition'] % 2 == 0 else list(reversed(MODES))
        if [t['mode'] for t in pair] != expected: reasons.add('unbalanced_pair_order')
    if invalid: reasons.add('missing_or_invalid_success_events')
    if any(t['outcome'] != 'success' for t in primary): reasons.add('unsuccessful_normal_trials')

    def values(selected, mode, field):
        return [measured[t['trialID']][0][field] for t in selected if t['mode'] == mode
                and t['trialID'] in measured and measured[t['trialID']][1] == 'started']

    baseline, candidate = values(usable, MODES[0], 'start'), values(usable, MODES[1], 'start')
    comparison = dict(baseline=distribution(baseline), candidate=distribution(candidate))
    if baseline and candidate and statistics.median(baseline) > 0:
        difference = statistics.median(baseline) - statistics.median(candidate)
        fraction = difference / statistics.median(baseline)
        comparison.update(medianImprovementSeconds=difference, medianImprovementFraction=fraction)
        if difference < .5 - 1e-9 or fraction < .2 - 1e-9: reasons.add('median_improvement')
    else:
        reasons.add('missing_or_zero_baseline')
    paths = {}
    for path in ('fast', 'classified'):
        selected = [t for t in usable if t['path'] == path]
        a, b = values(selected, MODES[0], 'start'), values(selected, MODES[1], 'start')
        paths[path] = dict(baseline=distribution(a), candidate=distribution(b))
        if not a or not b or percentile90(b) > percentile90(a) + .5: reasons.add('path_p90_regression')

    controls = [t for t in trials if t['cohort'] == 'control' and t['temperature'] == 'warm' and t['path'] == 'typed']
    for fixture in CONTROLS:
        selected = [t for t in controls if t['fixture'] == fixture]
        for mode in MODES:
            if len(values(selected, mode, 'start')) < 3: reasons.add('insufficient_controls')
        if fixture in CONTROLS[:3]:
            for field in ('start', 'end'):
                a, b = values(selected, MODES[0], field), values(selected, MODES[1], field)
                if not a or not b or statistics.median(b) > statistics.median(a) + .3:
                    reasons.add('single_sentence_regression')
    gaps = [measured[t['trialID']][0]['gap'] for t in usable if t['mode'] == MODES[1]
            and measured[t['trialID']][0]['gap'] is not None]
    if gaps and percentile90(gaps) > 1: reasons.add('sentence_gap_requires_listening_review')

    cold = [t for t in trials if t['temperature'] == 'cold']
    if len({t['processID'] for t in cold}) != len(cold) or {t['processID'] for t in cold} & {t['processID'] for t in trials if t['temperature'] == 'warm'}:
        reasons.add('insufficient_cold_processes')
    for mode in MODES:
        samples = [t for t in cold if t['mode'] == mode and t['outcome'] == 'success']
        if len({t['processID'] for t in samples}) < 3: reasons.add('insufficient_cold_processes')
    validation = data.get('validation', {})
    reviewed = validation.get('listeningReviewedTrialIDs', [])
    if not primary or not {t['trialID'] for t in primary}.issubset(set(reviewed)):
        reasons.add('listening_review_missing')
    if validation.get('listeningIssues'): reasons.add('listening_issues')
    acoustic = validation.get('acousticMeasurements', [])
    acoustic_pairs = {(m.get('mode'), m.get('path')) for m in acoustic if isinstance(m, dict)
                      and numeric(m.get('endToSoundSeconds')) and m['endToSoundSeconds'] >= 0
                      and isinstance(m.get('evidence'), str) and m['evidence']}
    if not {(m, p) for m in MODES for p in ('fast', 'classified')}.issubset(acoustic_pairs):
        reasons.add('acoustic_measurement_missing')
    if validation.get('regressionPassed') is not True: reasons.add('regression_verification_missing')
    if not numeric(validation.get('compactionCycles')) or validation['compactionCycles'] < 2:
        reasons.add('compaction_regression_missing')
    candidate_trials = [t for t in primary if t["mode"] == "firstSentence"]
    return dict(schemaVersion=1, adopt=not reasons, reasons=sorted(reasons), outcomes=dict(outcomes),
                speechStartSources=dict(sources), invalidSuccessTrialIDs=invalid, comparison=comparison,
                paths=paths, sentenceGap=distribution(gaps),
                earlySentenceRate=sum(t['earlySentenceUsed'] for t in candidate_trials) / len(candidate_trials) if candidate_trials else None,
                groups={key: dict(start=distribution([m['start'] for _, m in rows]),
                                  end=distribution([m['end'] for _, m in rows]),
                                  trialIDs=[t['trialID'] for t, _ in rows],
                                  sessionCounts=[m['sessionCount'] for _, m in rows]) for key, rows in groups.items()},
                acousticMeasurements=acoustic,
                note='Speech started is an app event proxy. Small-sample nearest-rank p90 is descriptive; acoustic timing is separate.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    try:
        report = summarize(json.loads(args.input.read_text()))
        args.output.write_text(json.dumps(report, ensure_ascii=False, indent=2, allow_nan=False) + '\n')
    except (ValueError, TypeError, KeyError, OSError) as error:
        parser.exit(2, f'Invalid latency data: {error}\n')


if __name__ == '__main__': main()
