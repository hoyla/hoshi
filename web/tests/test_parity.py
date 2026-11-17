#!/usr/bin/env python3
"""Check that web/gemma.py splits and counts text exactly as bundle/translate.sh
does, by running the helper's own awk on the same texts.

    python3 web/tests/test_parity.py [more text files...]

Needs a Mac (the helper's awk is the one macOS ships). No services.
"""

import os
import random
import re
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import gemma  # noqa: E402

HELPER = os.path.join(HERE, "..", "..", "bundle", "translate.sh")
with open(HELPER, encoding="utf-8") as handle:
    SCRIPT = handle.read()
CHUNKER = re.search(r"<<'AWK'\n(.*?)\nAWK\n", SCRIPT, re.S).group(1)
TRIM = re.search(r"trim_blank\(\) \{\n  awk '(.*?)'\n\}", SCRIPT, re.S).group(1)
ENV = dict(os.environ, LC_ALL="C")


def awk(program, *args, data=None):
    return subprocess.run(["awk", *args, program], input=data, capture_output=True, env=ENV)


def helper_pieces(data, work):
    folder = tempfile.mkdtemp(dir=work)
    source = os.path.join(folder, "source.txt")
    with open(source, "wb") as handle:
        handle.write(data)
    program = os.path.join(folder, "chunker.awk")
    with open(program, "w", encoding="utf-8") as handle:
        handle.write(CHUNKER)
    done = subprocess.run(
        ["awk", "-v", f"dir={folder}", "-v", f"soft={gemma.SOFT}", "-v", f"hard={gemma.HARD}", "-f", program, source],
        capture_output=True, env=ENV,
    )  # fmt: skip
    if done.returncode != 0:
        return "too long" if os.path.exists(os.path.join(folder, "too-long")) else "failed"
    joins_file = os.path.join(folder, "joins")
    if not os.path.exists(joins_file):
        return []
    with open(joins_file) as handle:
        joins = handle.read().split()
    pieces = []
    for number, join in enumerate(joins, 1):
        with open(os.path.join(folder, f"chunk-{number:05d}.txt"), "rb") as handle:
            pieces.append((handle.read(), join))
    return pieces


def our_pieces(data):
    try:
        return gemma.split_pieces(data)
    except gemma.GemmaError:
        return "too long"


def cases():
    rng = random.Random(20261117)
    sentences = {
        "en": "The documents arrived this morning. Nobody had signed them! Why not? ",
        "ru": "Документы прибыли сегодня утром. Их никто не подписал! Почему? ",
        "ar": "وصلت الوثائق هذا الصباح. لم يوقعها أحد؟ لماذا لا؟ ",
        "he": "המסמכים הגיעו הבוקר. איש לא חתם עליהם! למה לא? ",
        "zh": "文件今天早上到了。没有人签字！为什么？",
        "ur": "دستاویزات آج صبح پہنچیں۔ کسی نے دستخط نہیں کیے۔ ",
    }
    yield "empty", b""
    yield "only blank lines", b"\n \n\t\n"
    yield "one short line, no newline", b"hello"
    for name, sentence in sentences.items():
        yield f"{name}: short", (sentence + "\n").encode()
        yield f"{name}: one long line", (sentence * 400 + "\n").encode()
        yield f"{name}: word-style paragraphs", "".join(sentence * rng.randint(1, 30) + "\n" for _ in range(60)).encode()
        yield f"{name}: blank-line paragraphs", "".join(sentence * rng.randint(1, 30) + "\n\n" for _ in range(60)).encode()
        yield f"{name}: hard-wrapped", "".join(
            sentence.strip() + ("\n\n" if rng.random() < 0.15 else "\n") for _ in range(400)
        ).encode()
        yield f"{name}: mixed", "".join(
            sentence * rng.choice([1, 2, 5, 40, 120, 300]) + rng.choice(["\n", "\n", "\n\n", "\n \n", "\n\n\n"])
            for _ in range(40)
        ).encode()
    yield "no sentence break, under the limit", b"x" * 5000 + b"\n"
    yield "no sentence break, over the limit", b"x" * 7000 + b"\n"
    yield "break only past the limit", b"x" * 6500 + b". " + b"y" * 100 + b"\n"
    yield "long line after text", b"short line\n\n" + b"A sentence here. " * 500 + b"\nlast\n"
    yield "quotes after the stop", (b'He said "no." Then he left.) Next one! ' * 300) + b"\n"
    yield "leading blank lines", b"\n\n\nfirst\n\nsecond\n"
    yield "trailing spaces", b"first  \n  \nsecond\t\n"


def main():
    failures = 0
    checked = 0
    with tempfile.TemporaryDirectory() as work:
        texts = list(cases())
        for path in sys.argv[1:]:
            with open(path, "rb") as handle:
                texts.append((path, handle.read()))
        for name, data in texts:
            checked += 1
            theirs, ours = helper_pieces(data, work), our_pieces(data)
            if theirs != ours:
                failures += 1
                print(f"FAIL split: {name}: helper {summary(theirs)}, web {summary(ours)}")
            # the counts and the trimming, on the text and on each of its pieces
            samples = [data] + ([piece for piece, _ in ours] if isinstance(ours, list) else [])
            for sample in samples[:6]:
                text = sample.decode("utf-8")
                paras = int(awk('BEGIN { RS = "" } END { print NR }', data=sample).stdout or 0)
                count = int(awk("NF { n++ } END { print n + 0 }", data=sample).stdout)
                trimmed = awk(TRIM, data=sample).stdout.decode("utf-8")
                for label, want, got in (
                    ("paragraphs", paras, gemma.count_paras(text)),
                    ("lines", count, gemma.count_lines(text)),
                    ("trim", trimmed, gemma.trim_blank(text)),
                ):
                    if want != got:
                        failures += 1
                        shown = (want, got) if label != "trim" else (len(want), len(got))
                        print(f"FAIL {label}: {name}: helper {shown[0]!r}, web {shown[1]!r}")
    print(f"{checked} texts checked, {failures} differences")
    return 1 if failures else 0


def summary(pieces):
    if isinstance(pieces, str):
        return pieces
    return f"{len(pieces)} pieces {[(len(p), j) for p, j in pieces][:8]}"


if __name__ == "__main__":
    sys.exit(main())
