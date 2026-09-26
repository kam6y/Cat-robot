import unittest
from summarize_supertonic_integration import metrics, summarize, validate_run

class IntegrationSummaryTests(unittest.TestCase):
    def record(self):
        return dict(runID='run', stage='fixed', mode='sentencePrefetch', outcome='success', events=[
            dict(point='request', at=1), dict(point='speechStarted', at=2, sentenceOrdinal=0),
            dict(point='speechFinished', at=4, sentenceOrdinal=0), dict(point='speechStarted', at=4.1, sentenceOrdinal=1),
            dict(point='speechFinished', at=6, sentenceOrdinal=1), dict(point='finished', at=6.1)])
    def test_real_boundary_and_reply_start_are_separate(self):
        value = metrics(self.record())
        self.assertEqual(value['start'], 1)
        self.assertAlmostEqual(value['gaps'][0], .1)
        self.assertAlmostEqual(value['total'], 5.1)
    def test_missing_event_is_not_zero_latency(self):
        row = self.record(); row['events'] = [e for e in row['events'] if e['point'] != 'speechStarted']
        self.assertIsNone(metrics(row)['start'])
        self.assertEqual(metrics(row)['gaps'], [])
    def test_failed_and_skipped_trials_are_excluded_from_success_metrics(self):
        good = self.record(); bad = dict(good, outcome='failed'); skipped = dict(good, outcome='skipped')
        result = summarize([good, bad, skipped])['fixed/sentencePrefetch']
        self.assertEqual(result['totalTrials'], 3)
        self.assertEqual(result['successfulTrials'], 1)
        self.assertEqual(result['start']['count'], 1)
    def test_run_identity_mismatch_is_rejected(self):
        with self.assertRaises(ValueError): validate_run(dict(runID='different', records=[self.record()]), 'different')
        with self.assertRaises(ValueError): validate_run(dict(runID='run', records=[self.record()]), 'old')
