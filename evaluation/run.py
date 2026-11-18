"""Translate the frozen reference subset through Hoshi's production helper.

Examples:
  python3 evaluation/run.py --engine libre --work .cache/evaluation/libre --out evaluation/results/libre.json
  python3 evaluation/run.py --engine gemma --work .cache/evaluation/gemma --out evaluation/results/gemma.json

Interrupted runs resume from intact helper outputs. A changed corpus, helper,
engine digest or runtime requires a new work directory. Exported results are
never overwritten. This script does not download models or start services.
"""

import argparse
from contextlib import contextmanager
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / "evaluation/corpus.json"
OPTIONS = {"gemma": "temperature=0 num_ctx=8192 piece_bytes=3000-6000", "libre": ""}


def sha(data):
    return hashlib.sha256(data).hexdigest()


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2) + "\n").encode("utf-8")


def write_once(path, data):
    if path.exists():
        if path.read_bytes() != data:
            raise ValueError(f"refusing to overwrite different data: {path}")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("xb") as handle:
        handle.write(data)


def checker_program():
    script = (ROOT / "bundle/translate.sh").read_text(encoding="utf-8")
    found = re.search(r"^cat > \"\$TMP/check\.pl\" <<'PERL'\n(.*?)\nPERL$", script, re.M | re.S)
    if found is None:
        raise ValueError("could not find the production dropped-text checker")
    return (found.group(1) + "\n").encode("utf-8")


def directions(corpus):
    return [(source, target) for other in corpus["languages"] if other != "en"
            for source, target in ((other, "en"), ("en", other))]


def validate_corpus(corpus):
    languages = corpus["languages"]
    if corpus["protocol"] != 1 or "en" not in languages or len(languages) < 2 or not corpus["cases"]:
        raise ValueError("expected a nonempty protocol-1 corpus with English and another language")
    if any(not re.fullmatch(r"[a-z]{2,3}(?:-[A-Za-z0-9]+)*", code) for code in languages):
        raise ValueError("unsafe language code in corpus")
    seen = set()
    for case in corpus["cases"]:
        identifier = case["id"]
        if not re.fullmatch(r"[A-Za-z0-9_-]+", identifier) or identifier in seen:
            raise ValueError("unsafe or duplicate case ID in corpus")
        seen.add(identifier)
        if any(not isinstance(case["texts"].get(code), str) or not case["texts"][code].strip()
               or any(c in case["texts"][code] for c in "\r\n\x00") for code in languages):
            raise ValueError("each selected case needs one nonempty text line in every language")


def case_key(case_id, source, target):
    return f"{case_id}.{source}-{target}"


def http_json(url):
    request = urllib.request.Request(url)
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def tool_output(*args):
    return subprocess.run(args, capture_output=True, check=True, text=True, timeout=30).stdout.strip()


def engine_info(args):
    if args.engine == "gemma":
        version = http_json(args.ollama_api.rstrip("/") + "/api/version")["version"]
        models = http_json(args.ollama_api.rstrip("/") + "/api/tags")["models"]
        model = next((m for m in models if m["name"] == args.model), None)
        if model is None:
            raise ValueError(f"model {args.model} is not installed; no model is downloaded automatically")
        return {"engine": "gemma", "model": args.model, "digest": "sha256:" + model["digest"],
                "runtime": "Ollama " + version, "options": OPTIONS["gemma"]}
    version = tool_output("docker", "exec", args.lt_container, "cat", "/app/VERSION")
    digest = tool_output("docker", "container", "inspect", "--format", "{{.Image}}", args.lt_container)
    if not digest.startswith("sha256:"):
        raise ValueError("could not establish the LibreTranslate image digest")
    http_json(args.lt_url.rstrip("/") + "/languages")
    return {"engine": "libre", "digest": digest, "runtime": "LibreTranslate " + version, "options": ""}


def validate_record(record, case, source, target, identity):
    expected_input = (case["texts"][source] + "\n").encode("utf-8")
    provenance = record["provenance"]
    checks = (
        record["id"] == case["id"], record["source"] == source, record["target"] == target,
        provenance["source_sha256"] == sha(expected_input),
        provenance["input_sha256"] == sha(expected_input),
        provenance["engine"] == identity["engine"], provenance["engine_digest"] == identity["digest"],
        provenance["source_lang"] == source, provenance["target_lang"] == target,
        provenance["engine_options"] == identity["options"],
        provenance["output_sha256"] == sha(record["output"].encode("utf-8")),
    )
    if not all(checks):
        raise ValueError(f"invalid or mismatched result: {case_key(case['id'], source, target)}")


def collect(folder, case, source, target, identity):
    for path in sorted(folder.glob("*.provenance.json"), reverse=True):
        try:
            side = json.loads(path.read_text(encoding="utf-8"))
            output_name = side["output_file"]
            if Path(output_name).name != output_name or "\\" in output_name:
                continue
            if (folder / (output_name + ".lock")).exists():
                continue
            output = (folder / output_name).read_bytes().decode("utf-8")
            # Keep the original sidecar in the work directory. The portable
            # copy omits its machine-specific absolute source path.
            side = {k: v for k, v in side.items() if k != "source_file"}
            record = {"id": case["id"], "source": source, "target": target,
                      "output": output, "provenance": side}
            validate_record(record, case, source, target, identity)
            return record
        except (OSError, UnicodeError, ValueError, KeyError, TypeError):
            continue
    return None


def helper_command(args):
    if sys.platform == "darwin":
        return ["/bin/bash", str(ROOT / "bundle/translate.sh")]
    if sys.platform == "win32":
        runtime = os.environ.get("HOSHI_PWSH") or shutil.which("powershell") or shutil.which("pwsh")
        if runtime:
            return [runtime, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(ROOT / "bundle/translate.ps1")]
    raise ValueError("run the production helper on macOS or Windows")


@contextmanager
def work_lock(folder):
    folder.mkdir(parents=True, exist_ok=True)
    lock = folder / ".evaluation.lock"
    with lock.open("x"):
        pass
    try:
        yield
    finally:
        lock.unlink()


def save_log(folder, data):
    serial = 1
    while (folder / f"helper-{serial:04d}.log").exists():
        serial += 1
    write_once(folder / f"helper-{serial:04d}.log", data)


def run(args):
    with work_lock(args.work):
        translate_cases(args)


def translate_cases(args):
    corpus_bytes = args.corpus.read_bytes()
    corpus = json.loads(corpus_bytes)
    validate_corpus(corpus)
    identity = engine_info(args)
    expected = {"protocol": corpus["protocol"], "corpus_sha256": sha(corpus_bytes),
                "engine": identity, "checker_sha256": sha(checker_program()),
                "helper_sha256": {name: sha((ROOT / "bundle" / name).read_bytes())
                                  for name in ("translate.sh", "translate.ps1")},
                "expected_cases": len(corpus["cases"]) * len(directions(corpus))}
    args.work.mkdir(parents=True, exist_ok=True)
    manifest_file = args.work / "run.json"
    if manifest_file.exists():
        manifest = json.loads(manifest_file.read_text(encoding="utf-8"))
        if manifest["identity"] != expected:
            raise ValueError("the corpus, helper, checker or engine changed; choose another --work directory")
    else:
        manifest = {"started_at_utc": datetime.now(timezone.utc).isoformat(), "identity": expected}
        write_once(manifest_file, json_bytes(manifest))
    environment = dict(os.environ, LT_URL=args.lt_url, LT_CONTAINER=args.lt_container, OLLAMA_HOST=args.ollama_api)
    for name in tuple(environment):
        if name.upper() == "PSMODULEPATH":
            del environment[name]
    records, failed = [], []
    command = helper_command(args)
    for source, target in directions(corpus):
        for case in corpus["cases"]:
            key = case_key(case["id"], source, target)
            folder = args.work / "raw" / key
            folder.mkdir(parents=True, exist_ok=True)
            input_file = args.work / "inputs" / f"{case['id']}.{source}.txt"
            write_once(input_file, (case["texts"][source] + "\n").encode("utf-8"))
            record = collect(folder, case, source, target, identity)
            if record is None:
                done = subprocess.run(
                    command + ["--engine", args.engine, "--model", args.model, "--from", source,
                               "--to", target, "--out", str(folder), str(input_file)],
                    env=environment, capture_output=True, timeout=args.timeout,
                )
                save_log(folder, done.stderr)
                if done.returncode == 0:
                    record = collect(folder, case, source, target, identity)
            if record is None:
                failed.append(key)
                print(f"FAILED {key}; inspect {folder}", flush=True)
            else:
                records.append(record)
                print(f"{len(records)}/{expected['expected_cases']} {key}", flush=True)
    if failed:
        raise ValueError(f"{len(failed)} cases failed; no complete result exported. Re-run with the same --work to resume.")
    if engine_info(args) != identity:
        raise ValueError("engine changed during inference; refusing to mix results")
    if any(sha((ROOT / "bundle" / name).read_bytes()) != digest
           for name, digest in expected["helper_sha256"].items()):
        raise ValueError("a production helper changed during inference; refusing to mix pipelines")
    result = {"run": manifest, "records": records}
    write_once(args.out, json_bytes(result))
    print(f"Saved {len(records)} verified results to {args.out}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--engine", choices=("libre", "gemma"), required=True)
    parser.add_argument("--corpus", type=Path, default=CORPUS)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--lt-url", default="http://127.0.0.1:5050")
    parser.add_argument("--lt-container", default="libretranslate")
    parser.add_argument("--ollama-api", default="http://127.0.0.1:11434")
    parser.add_argument("--model", default="translategemma:12b")
    parser.add_argument("--timeout", type=int, default=7200)
    args = parser.parse_args()
    try:
        run(args)
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        parser.exit(1, f"error: {error}\n")


if __name__ == "__main__":
    main()
