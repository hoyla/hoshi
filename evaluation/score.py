"""Verify complete evaluation records, score them, and export a blind review sheet.

  python3 evaluation/score.py --libre evaluation/results/libre.json --gemma evaluation/results/gemma.json --out evaluation/results/report

Requires evaluation/requirements.txt and Perl for the unchanged checker.
No inference or network access occurs while scoring.
"""

import argparse
import csv
import io
import json
import os
from pathlib import Path
import random
import subprocess
import tempfile

try:
    from . import run
except ImportError:
    import run


def verify(corpus, corpus_bytes, result):
    manifest = result["run"]["identity"]
    if manifest["corpus_sha256"] != run.sha(corpus_bytes):
        raise ValueError("result corpus hash does not match the selected references")
    cases = {case["id"]: case for case in corpus["cases"]}
    expected = {run.case_key(case["id"], source, target)
                for source, target in run.directions(corpus) for case in corpus["cases"]}
    records = {}
    for record in result["records"]:
        key = run.case_key(record["id"], record["source"], record["target"])
        if key not in expected or key in records:
            raise ValueError("unexpected or duplicate evaluation case: " + key)
        run.validate_record(record, cases[record["id"]], record["source"], record["target"], manifest["engine"])
        records[key] = record
    if set(records) != expected or manifest["expected_cases"] != len(expected):
        raise ValueError("incomplete evaluation; every selected case and direction is required")
    if manifest["checker_sha256"] != run.sha(run.checker_program()):
        raise ValueError("the checker changed since inference; score from the recorded checker version")
    return records


def compare_reference(checker, source, reference, from_code, to_code, folder):
    source_file, target_file = folder / "source.txt", folder / "reference.txt"
    source_file.write_bytes((source + "\n").encode("utf-8"))
    target_file.write_bytes((reference + "\n").encode("utf-8"))
    done = subprocess.run(["perl", str(checker), "--from", from_code, "--to", to_code,
                           str(source_file), str(target_file)], capture_output=True, check=True, timeout=30)
    lines = done.stdout.decode("utf-8").splitlines()
    status = [line[7:] for line in lines if line.startswith("STATUS ")]
    if len(status) != 1:
        raise ValueError("checker returned no unambiguous status")
    return {"status": status[0], "warnings": [line[5:] for line in lines if line.startswith("WARN ")]}


def metrics(references, outputs):
    from sacrebleu.metrics import CHRF
    from sacrebleu.significance import PairedTest

    # Fix the resampling seed independently of a caller's shell settings.
    previous = os.environ.get("SACREBLEU_SEED")
    os.environ["SACREBLEU_SEED"] = "20261118"
    try:
        signatures, values = PairedTest(
            [(name, outputs[name]) for name in ("libre", "gemma")],
            {"chrF++": CHRF(word_order=2)}, [references], test_type="bs", n_samples=1000,
        )()
    finally:
        if previous is None:
            os.environ.pop("SACREBLEU_SEED", None)
        else:
            os.environ["SACREBLEU_SEED"] = previous
    metric = next(key for key in values if key != "System")
    result = {"metric": metric, "signature": str(signatures[metric]), "systems": {}}
    for name, value in zip(values["System"], values[metric]):
        result["systems"][name] = {
            "score": float(value.score), "bootstrap_mean": float(value.mean),
            "bootstrap_ci_half_width": float(value.ci),
            "bootstrap_interval": [max(0, float(value.mean - value.ci)), min(100, float(value.mean + value.ci))],
            "paired_p_value": None if value.p_value is None else float(value.p_value),
        }
    return result


def csv_text(value):
    value = str(value)
    return "'" + value if value.startswith(("=", "+", "-", "@", "\t", "\r")) else value


def review_sheet(corpus, records):
    """Keep system identity in a separate key, without inventing human ratings."""
    sheet = io.StringIO(newline="")
    writer = csv.writer(sheet)
    writer.writerow(("case", "direction", "domain", "article_url", "source", "human_reference",
                     "system_A", "system_B", "warnings_A", "warnings_B", "preferred_A_B_tie",
                     "material_errors_A", "material_errors_B", "reviewer_notes"))
    rng = random.Random(20261118)
    key = {}
    for source, target in run.directions(corpus):
        for case in corpus["cases"]:
            identifier = run.case_key(case["id"], source, target)
            names = ["libre", "gemma"]
            rng.shuffle(names)
            a, b = (records[name][identifier] for name in names)
            writer.writerow([csv_text(v) for v in (
                case["id"], f"{source}->{target}", case["domain"], case["url"], case["texts"][source],
                case["texts"][target], a["output"], b["output"],
                "\n".join(a["provenance"]["warnings"]), "\n".join(b["provenance"]["warnings"]), "", "", "", "",
            )])
            key[identifier] = {"A": names[0], "B": names[1]}
    return sheet.getvalue().encode("utf-8-sig"), {"seed": 20261118, "systems": key}


def markdown(report):
    lines = ["# Held-out reference results", "", "Human review: **not performed**. These are automatic reference-overlap scores.",
             "", "| Direction | Cases | Libre chrF++ | Gemma chrF++ | Libre warnings | Gemma warnings | Reference flags / judged |",
             "|---|---:|---:|---:|---:|---:|---:|"]
    for pair in report["directions"]:
        scores = pair["scores"]["systems"]
        lines.append(f"| {pair['source']} → {pair['target']} | {pair['cases']} | "
                     f"{scores['libre']['score']:.2f} | {scores['gemma']['score']:.2f} | "
                     f"{pair['warnings']['libre']} | {pair['warnings']['gemma']} | "
                     f"{pair['reference_flagged']} / {pair['reference_judged']} |")
    lines += ["", "Scores are on a 0–100 reference-overlap scale, not a percentage of correct translations.",
              "Only 24 sentence-level examples are used per direction. There is no overall quality grade or release pass/fail.",
              "", "`scores.json` contains bootstrap intervals, metric signatures and per-case checker findings.",
              "The intervals describe resampling of this small sample, not uncertainty in human adequacy or model training overlap.",
              "Paired p-values are uncorrected across ten directions and are not used to declare a winner.",
              "", "Warnings count cases with any engine/helper warning. Reference flags are false-alarm candidates, still unreviewed.",
              "References too short for the checker are excluded from the judged denominator.",
              "", "## Reproducibility", "", f"Corpus SHA-256: `{report['corpus_sha256']}`", ""]
    for name, engine in report["engines"].items():
        lines.append(f"- {name}: {engine['runtime']}; `{engine['digest']}`")
    lines += ["", "The source, reference and paired outputs are in `review.csv`; keep `review-key.json` separate until review is complete.",
              "A reviewer should check omissions, changed negations, figures, names and any domain-specific terminology.",
              "Review cells are blank. No bilingual expert has assessed these outputs as part of the automatic run.",
              "CSV cells beginning with spreadsheet operators are prefixed with an apostrophe; the original text remains in the corpus and result JSON.",
              "", "Dataset and translations of its excerpts: CC BY-SA 4.0; see `evaluation/README.md` and the per-case source URLs.", ""]
    return "\n".join(lines)


def score(corpus_bytes, results):
    corpus = json.loads(corpus_bytes)
    records = {name: verify(corpus, corpus_bytes, result) for name, result in results.items()}
    if set(records) != {"libre", "gemma"}:
        raise ValueError("both engines are required for a paired comparison")
    for name, result in results.items():
        if result["run"]["identity"]["engine"]["engine"] != name:
            raise ValueError("engine result files are mislabeled")
    if results["libre"]["run"]["identity"]["helper_sha256"] != results["gemma"]["run"]["identity"]["helper_sha256"]:
        raise ValueError("helpers differ between runs; do not combine different pipelines")
    report = {"protocol": corpus["protocol"], "corpus_sha256": run.sha(corpus_bytes),
              "scorer_sha256": run.sha(Path(__file__).read_bytes()), "human_review": "not performed",
              "engines": {name: result["run"]["identity"]["engine"] for name, result in results.items()},
              "directions": []}
    with tempfile.TemporaryDirectory(prefix="hoshi-reference-check-") as directory:
        folder = Path(directory)
        checker = folder / "check.pl"
        checker.write_bytes(run.checker_program())
        for source, target in run.directions(corpus):
            selected = {name: [records[name][run.case_key(c["id"], source, target)] for c in corpus["cases"]]
                        for name in records}
            refs = [c["texts"][target] for c in corpus["cases"]]
            findings = [{"id": c["id"], **compare_reference(checker, c["texts"][source], c["texts"][target], source, target, folder)}
                        for c in corpus["cases"]]
            report["directions"].append({
                "source": source, "target": target, "cases": len(refs),
                "scores": metrics(refs, {name: [r["output"] for r in values] for name, values in selected.items()}),
                "warnings": {name: sum(bool(r["provenance"]["warnings"]) for r in values) for name, values in selected.items()},
                "reference_judged": sum(f["status"].startswith("compared") for f in findings),
                "reference_flagged": sum(bool(f["warnings"]) for f in findings), "reference_findings": findings,
            })
    return report, *review_sheet(corpus, records)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--corpus", type=Path, default=run.CORPUS)
    parser.add_argument("--libre", type=Path, required=True)
    parser.add_argument("--gemma", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    try:
        report, sheet, key = score(args.corpus.read_bytes(), {
            "libre": json.loads(args.libre.read_text(encoding="utf-8")),
            "gemma": json.loads(args.gemma.read_text(encoding="utf-8")),
        })
        for name, data in (("scores.json", run.json_bytes(report)), ("report.md", markdown(report).encode("utf-8")),
                           ("review.csv", sheet), ("review-key.json", run.json_bytes(key))):
            run.write_once(args.out / name, data)
        print(f"Scored {len(report['directions'])} directions; human review remains unperformed")
    except (ValueError, OSError, KeyError, subprocess.SubprocessError) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
