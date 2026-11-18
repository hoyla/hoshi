"""Select a frozen, domain-balanced reference subset without model outputs."""

import argparse
from collections import defaultdict
import csv
import hashlib
import io
import json
from pathlib import Path
import random
import tarfile

HERE = Path(__file__).resolve().parent
ARCHIVE_SHA256 = "b8b0b76783024b85797e5cc75064eb83fc5288b41e9654dabc7be6ae944011f6"
ARCHIVE_URL = "https://dl.fbaipublicfiles.com/nllb/flores200_dataset.tar.gz"
SEED = 20261118
PER_DOMAIN = 8
LANGUAGES = {
    "en": "eng_Latn", "fr": "fra_Latn", "ru": "rus_Cyrl",
    "zh": "zho_Hans", "he": "heb_Hebr", "ar": "arb_Arab",
}


def select(metadata, per_domain=PER_DOMAIN, seed=SEED):
    """One sentence from each of eight distinct articles per domain."""
    rng = random.Random(seed)
    selected = []
    for domain in ("wikinews", "wikibooks", "wikivoyage"):
        articles = defaultdict(list)
        for index, row in enumerate(metadata):
            if row["domain"] == domain:
                articles[row["URL"]].append(index)
        urls = sorted(articles)
        if len(urls) < per_domain:
            raise ValueError(f"not enough distinct articles in {domain}")
        for url in sorted(rng.sample(urls, per_domain)):
            selected.append(rng.choice(articles[url]))
    return sorted(selected)


def prepare(archive):
    if hashlib.sha256(archive.read_bytes()).hexdigest() != ARCHIVE_SHA256:
        raise ValueError("archive checksum mismatch; refusing a changed benchmark")
    prefix = "./flores200_dataset/"
    with tarfile.open(archive) as bundle:
        def read(name):
            member = bundle.getmember(prefix + name)
            if not member.isfile() or member.size > 2 * 1024 * 1024:
                raise ValueError(f"unexpected archive member: {name}")
            return bundle.extractfile(member).read().decode("utf-8")

        metadata = list(csv.DictReader(io.StringIO(read("metadata_devtest.tsv")), delimiter="\t"))
        texts = {code: read(f"devtest/{flores}.devtest").splitlines()
                 for code, flores in LANGUAGES.items()}
    if len(metadata) != 1012 or any(len(lines) != len(metadata) for lines in texts.values()):
        raise ValueError("unexpected or misaligned devtest rows")
    indices = select(metadata)
    cases = [{"id": f"flores-devtest-{i + 1:04d}", "row": i + 1,
              "url": metadata[i]["URL"], "domain": metadata[i]["domain"],
              "texts": {code: lines[i] for code, lines in texts.items()}}
             for i in indices]
    return {"protocol": 1, "dataset": "FLORES-200", "split": "devtest",
            "source_url": ARCHIVE_URL, "archive_sha256": ARCHIVE_SHA256,
            "license": "CC-BY-SA-4.0", "seed": SEED, "articles_per_domain": PER_DOMAIN,
            "languages": LANGUAGES, "cases": cases}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--out", type=Path, default=HERE / "corpus.json")
    args = parser.parse_args()
    data = json.dumps(prepare(args.archive), ensure_ascii=False, indent=2) + "\n"
    if args.out.exists():
        if args.out.read_bytes() != data.encode("utf-8"):
            parser.error("the selected corpus differs; use another --out and review the change")
    else:
        args.out.write_bytes(data.encode("utf-8"))
    print(f"{len(json.loads(data)['cases'])} cases; corpus SHA-256 {hashlib.sha256(data.encode()).hexdigest()}")


if __name__ == "__main__":
    main()
