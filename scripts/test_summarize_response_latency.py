import unittest
from summarize_supertonic_integration import summarize, validate_run


class ResponseLatencySummaryTests(unittest.TestCase):
    def payload(self):
        fixtures = [{"id": "delayed", "requiresHit": True},
                    {"id": "immediate", "requiresHit": False},
                    {"id": "changed", "requiresHit": False}]
        records = []
        for repetition in range(3):
            for fixture in fixtures:
                for mode in ("baseline", "prepared"):
                    delayed = fixture["id"] == "delayed"
                    changed = fixture["id"] == "changed"
                    start = (0.9 if mode == "prepared" else 1.2) if delayed else (0.65 if changed and mode == "prepared" else 0.6 if changed else 0.4)
                    confirmation = 0.8 if delayed else 0.3 if changed else 0.1
                    events = [{"point": "request", "at": 0}, {"point": "firstCandidate", "at": 0.05},
                              {"point": "speechEnqueued", "sentenceOrdinal": 0, "at": confirmation},
                              {"point": "speechStarted", "sentenceOrdinal": 0, "at": start},
                              {"point": "speechFinished", "sentenceOrdinal": 0, "at": 2.0},
                              {"point": "finished", "at": 2.0, "outcome": "success"}]
                    if delayed and mode == "prepared":
                        events += [{"point": "preparationStarted", "at": 0.125, "sentenceOrdinal": 0},
                                   {"point": "preparationFinished", "at": 0.5, "sentenceOrdinal": 0, "outcome": "success"},
                                   {"point": "preparationUsed", "at": confirmation, "sentenceOrdinal": 0}]
                    records.append({"runID": "run-a", "sourceRevision": "rev-a", "stage": "latency",
                                    "fixture": fixture["id"], "repetition": repetition, "mode": mode,
                                    "requiresPreparationHit": fixture["requiresHit"], "voice": "F1", "steps": 8,
                                    "threads": 2, "speed": 1.05, "applicationStateRawValue": 0,
                                    "events": events, "response": "はい。", "inputs": [{"original": "はい。", "spoken": "ハイ。"}],
                                    "outcome": "success", "thermalAfter": "nominal"})
        return {"runID": "run-a", "sourceRevision": "rev-a", "stage": "latency",
                "latencyConfiguration": {"repetitions": 3, "fixtures": fixtures}, "records": records}

    def test_reports_paired_improvement_and_passed_guard(self):
        result = summarize(validate_run(self.payload(), "run-a"))
        self.assertIn("latencyAcceptance", result)
        acceptance = result["latencyAcceptance"]
        self.assertTrue(acceptance["passed"])
        self.assertAlmostEqual(acceptance["fixtures"]["delayed"]["pairedStartDifference"]["median"], -0.3)
        self.assertEqual(acceptance["fixtures"]["delayed"]["preparationHits"], 3)

    def test_p95_regression_is_not_hidden_by_successful_trial_count(self):
        payload = self.payload()
        row = next(r for r in payload["records"] if r["fixture"] == "immediate" and r["mode"] == "prepared")
        next(e for e in row["events"] if e["point"] == "speechStarted")["at"] = 0.7
        result = summarize(validate_run(payload))
        self.assertIn("latencyAcceptance", result)
        self.assertFalse(result["latencyAcceptance"]["passed"])

    def test_improvement_without_a_reused_preparation_does_not_pass(self):
        payload = self.payload()
        for row in payload["records"]:
            row["events"] = [e for e in row["events"] if e["point"] != "preparationUsed"]
        result = summarize(validate_run(payload))
        self.assertIn("latencyAcceptance", result)
        self.assertFalse(result["latencyAcceptance"]["passed"])

    def test_rejects_mixing_two_individually_valid_comparison_runs(self):
        first = self.payload()
        second = self.payload()
        second["runID"] = "run-b"
        for row in second["records"]: row["runID"] = "run-b"
        rows = validate_run(first) + validate_run(second)
        with self.assertRaises(ValueError): summarize(rows)

    def test_rejects_mixed_source_revision(self):
        payload = self.payload(); payload["records"][0]["sourceRevision"] = "other"
        with self.assertRaises(ValueError): validate_run(payload)

    def test_rejects_missing_control_pair(self):
        payload = self.payload(); payload["records"].pop(0)
        with self.assertRaises(ValueError): validate_run(payload)

    def test_rejects_missing_start_instead_of_reporting_zero(self):
        payload = self.payload()
        payload["records"][0]["events"] = [e for e in payload["records"][0]["events"] if e["point"] != "speechStarted"]
        with self.assertRaises(ValueError): validate_run(payload)

    def test_rejects_audio_started_before_confirmation(self):
        payload = self.payload()
        next(e for e in payload["records"][0]["events"] if e["point"] == "speechStarted")["at"] = 0.7
        with self.assertRaises(ValueError): validate_run(payload)

    def test_rejects_different_voice_or_inference_settings(self):
        for key, value in [("voice", "F2"), ("steps", 4), ("threads", 4), ("speed", 1.2)]:
            payload = self.payload(); payload["records"][0][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError): validate_run(payload)

    def test_rejects_missing_or_changed_original_text(self):
        payload = self.payload(); payload["records"][0]["inputs"][0]["original"] = "別の文。"
        with self.assertRaises(ValueError): validate_run(payload)

    def test_rejects_unknown_source_and_duplicate_pair(self):
        payload = self.payload(); payload["sourceRevision"] = "unknown"
        with self.assertRaises(ValueError): validate_run(payload)
        payload = self.payload(); payload["records"].append(payload["records"][0])
        with self.assertRaises(ValueError): validate_run(payload)


if __name__ == "__main__":
    unittest.main()
