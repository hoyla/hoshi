"""Evaluation invariants and scoring tests; no model or translation service."""

import copy
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch

from evaluation import prepare, run, score


def mini_corpus():
    return {"protocol": 1, "languages": {"en": "eng_Latn", "fr": "fra_Latn"}, "cases": [
        {"id": "one", "domain": "wikinews", "url": "https://example.org/one",
         "texts": {"en": "The documents arrived this morning.", "fr": "Les documents sont arrives ce matin."}},
        {"id": "two", "domain": "wikibooks", "url": "https://example.org/two",
         "texts": {"en": "The committee has not approved the report.", "fr": "Le comite n'a pas approuve le rapport."}},
    ]}


def result_fixture(engine, corpus):
    identity = {"engine": engine, "digest": "sha256:" + engine,
                "runtime": "stand-in", "options": run.OPTIONS[engine]}
    manifest = {"corpus_sha256": run.sha(run.json_bytes(corpus)), "engine": identity,
                "expected_cases": len(corpus["cases"]) * len(run.directions(corpus)),
                "checker_sha256": run.sha(run.checker_program()), "helper_sha256": {"fixture": "same"}}
    records = []
    for source, target in run.directions(corpus):
        for case in corpus["cases"]:
            body = case["texts"][target] + "\n"
            input_sha = run.sha((case["texts"][source] + "\n").encode())
            side = {"source_sha256": input_sha, "input_sha256": input_sha,
                    "engine": engine, "engine_digest": identity["digest"], "engine_options": identity["options"],
                    "source_lang": source, "target_lang": target, "output_sha256": run.sha(body.encode()),
                    "warnings": [], "dropped_text_check": "compared 1 paragraph"}
            records.append({"id": case["id"], "source": source, "target": target, "output": body, "provenance": side})
    return {"run": {"identity": manifest}, "records": records}


class SelectionTests(unittest.TestCase):
    def test_committed_corpus_is_frozen_balanced_and_distinct(self):
        data = run.CORPUS.read_bytes()
        self.assertEqual(run.sha(data), "116457b9808de6bb8af435af7ab9dff1a6ddec4ffc79fd4a62567f5f988d98b5")
        corpus = json.loads(data)
        self.assertEqual(len(corpus["cases"]), 24)
        self.assertEqual(len({c["url"] for c in corpus["cases"]}), 24)
        for domain in ("wikinews", "wikibooks", "wikivoyage"):
            self.assertEqual(sum(c["domain"] == domain for c in corpus["cases"]), 8)
        self.assertEqual(set(corpus["languages"]), {"en", "fr", "ru", "zh", "he", "ar"})
        self.assertEqual(len(run.directions(corpus)), 10)

    def test_selection_uses_unique_articles_and_is_repeatable(self):
        metadata = [{"domain": domain, "URL": f"https://example.org/{domain}/{article}"}
                    for domain in ("wikinews", "wikibooks", "wikivoyage")
                    for article in range(3) for _ in range(2)]
        first = prepare.select(metadata, per_domain=2)
        self.assertEqual(first, prepare.select(metadata, per_domain=2))
        self.assertEqual(len({metadata[i]["URL"] for i in first}), 6)

    def test_changed_archive_is_rejected(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "archive.tar.gz"
            path.write_bytes(b"changed archive")
            with self.assertRaisesRegex(ValueError, "checksum"):
                prepare.prepare(path)

    def test_saved_engine_results_match_the_frozen_corpus(self):
        data = run.CORPUS.read_bytes()
        corpus = json.loads(data)
        for path in (run.CORPUS.parent / "results").glob("*.json"):
            with self.subTest(path=path.name):
                result = json.loads(path.read_text(encoding="utf-8"))
                records = score.verify(corpus, data, result)
                self.assertEqual(len(records), 240)


class EvaluationIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.corpus = mini_corpus()
        self.data = run.json_bytes(self.corpus)
        self.result = result_fixture("libre", self.corpus)

    def test_complete_result_is_accepted(self):
        self.assertEqual(len(score.verify(self.corpus, self.data, self.result)), 4)

    def test_missing_duplicate_and_changed_outputs_are_rejected(self):
        for change in ("missing", "duplicate", "output", "source", "engine", "options", "corpus"):
            with self.subTest(change=change):
                result = copy.deepcopy(self.result)
                if change == "missing":
                    result["records"].pop()
                elif change == "duplicate":
                    result["records"].append(result["records"][0])
                elif change == "output":
                    result["records"][0]["output"] += " changed"
                elif change == "source":
                    result["records"][0]["provenance"]["input_sha256"] = "wrong"
                elif change == "engine":
                    result["records"][0]["provenance"]["engine_digest"] = "wrong"
                elif change == "options":
                    result["records"][0]["provenance"]["engine_options"] = "changed"
                else:
                    result["run"]["identity"]["corpus_sha256"] = "wrong"
                with self.assertRaises(ValueError):
                    score.verify(self.corpus, self.data, result)

    def test_successful_empty_translation_is_retained_for_zero_scoring(self):
        self.result["records"][0]["output"] = ""
        self.result["records"][0]["provenance"]["output_sha256"] = run.sha(b"")
        self.assertEqual(len(score.verify(self.corpus, self.data, self.result)), 4)

    def test_exports_never_replace_existing_data(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "result.json"
            run.write_once(path, b"first")
            run.write_once(path, b"first")
            with self.assertRaises(ValueError):
                run.write_once(path, b"second")
            self.assertEqual(path.read_bytes(), b"first")

    def test_work_lock_and_attempt_logs_preserve_previous_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            with run.work_lock(folder):
                with self.assertRaises(FileExistsError):
                    with run.work_lock(folder):
                        pass
            self.assertFalse((folder / ".evaluation.lock").exists())
            run.save_log(folder, b"first attempt")
            run.save_log(folder, b"retry")
            self.assertEqual((folder / "helper-0001.log").read_bytes(), b"first attempt")
            self.assertEqual((folder / "helper-0002.log").read_bytes(), b"retry")

    def test_cached_helper_result_is_verified_before_resume(self):
        record = self.result["records"][0]
        source, target = record["source"], record["target"]
        side = dict(record["provenance"], output_file="translation.txt", source_file="/machine/specific/path")
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            (folder / "translation.txt").write_bytes(record["output"].encode())
            (folder / "translation.txt.provenance.json").write_bytes(run.json_bytes(side))
            result = run.collect(folder, self.corpus["cases"][0], source, target, self.result["run"]["identity"]["engine"])
            self.assertIsNotNone(result)
            self.assertNotIn("source_file", result["provenance"])
            (folder / "translation.txt").write_bytes(b"edited")
            self.assertIsNone(run.collect(folder, self.corpus["cases"][0], source, target, self.result["run"]["identity"]["engine"]))


@unittest.skipUnless(importlib.util.find_spec("sacrebleu"), "install evaluation/requirements.txt for score tests")
class ScoringTests(unittest.TestCase):
    def test_reference_match_has_maximum_score_and_reports_signature(self):
        result = score.metrics(["A complete reference sentence."], {
            "libre": ["A complete reference sentence."], "gemma": ["An unrelated reply."],
        })
        self.assertAlmostEqual(result["systems"]["libre"]["score"], 100)
        self.assertLess(result["systems"]["gemma"]["score"], 100)
        self.assertIn("seed:20261118", result["signature"])
        self.assertIn("nw:2", result["signature"])
        self.assertIn("version:2.5.1", result["signature"])

    def test_scoring_does_not_invent_human_review(self):
        corpus = mini_corpus()
        results = {engine: result_fixture(engine, corpus) for engine in ("libre", "gemma")}
        with patch.object(score, "compare_reference", return_value={"status": "not checked: too little text", "warnings": []}):
            report, sheet, key = score.score(run.json_bytes(corpus), results)
        self.assertEqual(report["human_review"], "not performed")
        self.assertIn("preferred_A_B_tie", sheet.decode("utf-8-sig"))
        self.assertEqual(len(key["systems"]), 4)
        self.assertEqual(report["directions"][0]["reference_judged"], 0)
        self.assertIn("not performed", score.markdown(report))

    def test_different_helper_versions_cannot_be_combined(self):
        corpus = mini_corpus()
        results = {engine: result_fixture(engine, corpus) for engine in ("libre", "gemma")}
        results["gemma"]["run"]["identity"]["helper_sha256"] = {"fixture": "different"}
        with self.assertRaisesRegex(ValueError, "helpers differ"):
            score.score(run.json_bytes(corpus), results)


class ReferenceCheckerTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("perl"), "reference checker needs Perl")
    def test_reference_check_uses_the_production_checker(self):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            checker = folder / "check.pl"
            checker.write_bytes(run.checker_program())
            found = score.compare_reference(checker, "The documents arrived this morning. " * 5,
                                            "Les documents sont arrives ce matin. " * 5, "en", "fr", folder)
        self.assertTrue(found["status"].startswith("compared"))
        self.assertEqual(found["warnings"], [])


if __name__ == "__main__":
    unittest.main()
