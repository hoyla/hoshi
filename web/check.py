"""The dropped-text check, for the page.

bundle/translate.sh carries the checker as a perl program and runs it on every
translation it makes. The page runs that same program: whatever packages web/
takes it out of translate.sh and puts it here as check.pl, so the two cannot
come to different verdicts. The LibreTranslate image has perl.
"""

import os
import subprocess
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CHECK_PL = os.environ.get("CHECK_PL") or os.path.join(HERE, "check.pl")
FAILED = "not checked: the comparison itself failed"


def compare(source, translation, source_lang, target_lang, *options):
    """(status, warnings) for a text and its translation, in translate.sh's words.
    source_lang is None when LibreTranslate was left to detect it."""
    if not os.path.isfile(CHECK_PL):
        return "not checked: this copy of the page came without the checker", []
    with tempfile.TemporaryDirectory() as work:
        paths = []
        for name, text in (("source.txt", source), ("translation.txt", translation)):
            paths.append(os.path.join(work, name))
            with open(paths[-1], "w", encoding="utf-8", newline="") as handle:
                handle.write(text)
        command = ["perl", CHECK_PL]
        if source_lang:
            command += ["--from", source_lang]
        command += ["--to", target_lang, *options, *paths]
        try:
            done = subprocess.run(command, capture_output=True, timeout=600)
        except (OSError, subprocess.TimeoutExpired):
            return FAILED, []
    if done.returncode != 0:
        return FAILED, []
    status, found = FAILED, []
    for line in done.stdout.decode("utf-8", "replace").splitlines():
        if line.startswith("STATUS "):
            status = line[len("STATUS "):]
        elif line.startswith("WARN "):
            found.append(line[len("WARN "):])
    return status, found
