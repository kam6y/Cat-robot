import copy
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from summarize_reply_latency import summarize, SchemaError, percentile90

FIXTURES = ['cat-sleep', 'rain-play', 'morning-walk', 'reading', 'nervous',
            'spring', 'tidy', 'sunset', 'packing', 'tea']
CONTROLS = ['control-word', 'control-one-sentence', 'control-number', 'control-url', 'control-quote']


def trial(fixture='cat-sleep', mode='completeResponse', path='fast', repetition=0,
          latency=5.0, cohort='normal', temperature='warm'):
    ident = f'{fixture}/{mode}/{path}/{repetition}/{temperature}'
    events = [dict(id=ident, point='request', at=0.0),
              dict(id=ident, point='generationFinished', at=min(4, latency - .1)),
              dict(id=ident, point='streamFinished', at=min(4.1, latency - .05)),
              dict(id=ident, point='speechStarted', at=latency, source='started', part='full'),
              dict(id=ident, point='speechFinished', at=8.0, part='full'),
              dict(id=ident, point='finished', at=8.0, outcome='success')]
    return dict(schemaVersion=1, trialID=ident, fixture=fixture, mode=mode, path=path,
                inputKind='typed' if path == 'typed' else 'syntheticRecognition', repetition=repetition,
                cohort=cohort, temperature=temperature, processID=1, outcome='success',
                thermalState='nominal', powerState='unplugged', osVersion='test-os',
                voiceIdentifier='test-voice', initialRevision=1, events=events,
                earlySentenceUsed=False, listeningResumed=path != 'typed')


def dataset(candidate=3.5):
    trials = []
    for repetition in range(3):
        modes = ['completeResponse', 'firstSentence'] if repetition % 2 == 0 else ['firstSentence', 'completeResponse']
        for fixture in FIXTURES:
            for path in ['fast', 'classified']:
                for mode in modes:
                    trials.append(trial(fixture, mode, path, repetition, 5 if mode == 'completeResponse' else candidate))
        for fixture in CONTROLS:
            for mode in modes:
                trials.append(trial(fixture, mode, 'typed', repetition, 5 if mode == 'completeResponse' else candidate, 'control'))
        for mode in modes:
            value = trial('cat-sleep', mode, 'fast', repetition, 5 if mode == 'completeResponse' else candidate, temperature='cold')
            value['processID'] = 100 + repetition * 2 + (mode == 'firstSentence')
            trials.append(value)
    reviewed = [t['trialID'] for t in trials if t['temperature'] == 'warm' and t['cohort'] == 'normal']
    return dict(schemaVersion=1, trials=trials, validation=dict(regressionPassed=True, compactionCycles=2,
                listeningReviewedTrialIDs=reviewed,
                acousticMeasurements=[dict(mode=m, path=p, endToSoundSeconds=6, evidence='synthetic-recording.wav')
                                      for m in ['completeResponse', 'firstSentence'] for p in ['fast', 'classified']]))


class SummaryTests(unittest.TestCase):
    def test_known_median_improvement_and_nearest_rank(self):
        report = summarize(dataset())
        self.assertTrue(report['adopt'], report['reasons'])
        self.assertEqual(report['comparison']['medianImprovementSeconds'], 1.5)
        self.assertAlmostEqual(report['comparison']['medianImprovementFraction'], .3)
        self.assertEqual(percentile90([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]), 9)

    def test_twelve_percent_is_not_enough(self):
        report = summarize(dataset(4.4))
        self.assertFalse(report['adopt'])
        self.assertIn('median_improvement', report['reasons'])

    def test_failures_are_counted_and_never_short_successes(self):
        data = dataset()
        data['trials'][0]['outcome'] = 'generationFailure'
        data['trials'][0]['events'] = []
        report = summarize(data)
        self.assertFalse(report['adopt'])
        self.assertEqual(report['outcomes']['generationFailure'], 1)
        self.assertIn('insufficient_paired_successes', report['reasons'])

    def test_missing_event_or_mode_or_all_failures_prevents_adoption(self):
        for change in ['event', 'mode', 'all']:
            data = dataset()
            if change == 'event':
                data['trials'][0]['events'] = []
            elif change == 'mode':
                data['trials'] = [t for t in data['trials'] if t['mode'] != 'firstSentence']
            else:
                for t in data['trials']:
                    t['outcome'] = 'cancelled'
                    t['events'] = []
            self.assertFalse(summarize(data)['adopt'])

    def test_fallback_is_separate_and_not_accepted_as_started(self):
        data = dataset()
        for e in data['trials'][0]['events']:
            if e['point'] == 'speechStarted': e['source'] = 'willSpeakFallback'
        report = summarize(data)
        self.assertFalse(report['adopt'])
        self.assertEqual(report['speechStartSources']['willSpeakFallback'], 1)

    def test_missing_listening_or_acoustic_evidence_blocks_adoption(self):
        for key in ['listeningReviewedTrialIDs', 'acousticMeasurements', 'regressionPassed', 'compactionCycles']:
            data = dataset()
            del data['validation'][key]
            self.assertFalse(summarize(data)['adopt'], key)

    def test_duplicate_trial_and_invalid_schema_rejected(self):
        data = dataset()
        data['trials'].append(copy.deepcopy(data['trials'][0]))
        with self.assertRaises(SchemaError): summarize(data)
        with self.assertRaises(SchemaError): summarize({'schemaVersion': 2, 'trials': []})
        data = dataset()
        data['trials'][0]['events'][0]['at'] = float('nan')
        with self.assertRaises(SchemaError): summarize(data)

    def test_zero_baseline_and_mismatched_voice_do_not_adopt(self):
        data = dataset()
        for t in data['trials']:
            if t['mode'] == 'completeResponse':
                for e in t['events']:
                    if e['point'] in ['speechStarted', 'generationFinished', 'streamFinished']: e['at'] = 0
        self.assertFalse(summarize(data)['adopt'])
        data = dataset()
        data['trials'][0]['voiceIdentifier'] = 'different-voice'
        self.assertIn('unmatched_conditions', summarize(data)['reasons'])

    def test_cold_results_do_not_distort_warm_comparison(self):
        data = dataset()
        for t in data['trials']:
            if t['temperature'] == 'cold':
                for e in t['events']:
                    if e['point'] != 'request': e['at'] += 100
        self.assertEqual(summarize(data)['comparison']['medianImprovementSeconds'], 1.5)

    def test_path_tail_single_sentence_and_gap_gates(self):
        for kind in ['tail', 'control', 'gap']:
            data = dataset()
            for t in data['trials']:
                if t['mode'] != 'firstSentence' or t['temperature'] != 'warm': continue
                if kind == 'tail' and t['path'] == 'classified' and t['fixture'] in FIXTURES[:2]:
                    for e in t['events']:
                        if e['point'] == 'speechStarted': e['at'] = 6
                if kind == 'control' and t['fixture'] == 'control-one-sentence':
                    for e in t['events']:
                        if e['point'] == 'speechFinished': e['at'] = 9
                        if e['point'] == 'finished': e['at'] = 9
                if kind == 'gap' and t['cohort'] == 'normal':
                    for e in t['events']:
                        if e.get('part') == 'full': e['part'] = 'first'
                        if e['point'] == 'speechFinished': e['at'] = 4
                    t['events'].extend([dict(id=t['trialID'], point='speechStarted', at=6, part='remainder', source='started'),
                                        dict(id=t['trialID'], point='speechFinished', at=8, part='remainder')])
                    t['events'].sort(key=lambda e: e['at'])
            self.assertFalse(summarize(data)['adopt'], kind)

    def test_early_sentence_rate_counts_candidate_trials_only(self):
        data = dataset()
        for t in data['trials']:
            t['earlySentenceUsed'] = t['mode'] == 'firstSentence'
        self.assertEqual(summarize(data)['earlySentenceRate'], 1.0)

    def test_cold_trials_need_distinct_processes_and_controls_same_voice(self):
        data = dataset()
        for t in data['trials']:
            if t['temperature'] == 'cold': t['processID'] = 100 + t['repetition']
        self.assertFalse(summarize(data)['adopt'])
        data = dataset()
        next(t for t in data['trials'] if t['cohort'] == 'control')['voiceIdentifier'] = 'different'
        self.assertIn('unmatched_conditions', summarize(data)['reasons'])

    def test_cli_writes_non_adoption_as_valid_report_and_schema_error_as_failure(self):
        script = Path(__file__).with_name('summarize_reply_latency.py')
        with tempfile.TemporaryDirectory() as directory:
            source, output = Path(directory) / 'input.json', Path(directory) / 'report.json'
            source.write_text(json.dumps(dict(schemaVersion=1, trials=[], validation={})))
            result = subprocess.run([sys.executable, str(script), str(source), '--output', str(output)], capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(json.loads(output.read_text())['adopt'])
            source.write_text('{}')
            result = subprocess.run([sys.executable, str(script), str(source), '--output', str(output)], capture_output=True)
            self.assertNotEqual(result.returncode, 0)

if __name__ == '__main__': unittest.main()
