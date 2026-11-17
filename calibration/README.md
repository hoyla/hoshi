# Calibrating the dropped-text check

`translate.sh` compares every translation with its source and warns about
paragraphs that came out much shorter or longer than expected (see
[the main README](../README.md#the-dropped-text-check)). This folder is the
evidence for its thresholds and the means to measure them again.

## What is here

| | |
|---|---|
| `en.txt` | A 12-paragraph news-style article written for this purpose: names, figures, dates, quotations, negations, paragraphs of one to four sentences. |
| `data/fwd/` | `en.txt` translated into 16 languages by each engine. |
| `data/rev/` | TranslateGemma's version in each of those languages, translated back into English by each engine. |
| `run.sh` | Regenerates `data/`. Needs both engines running; about half an hour. |
| `measure.sh` | Measures the check against `data/`. Needs only perl; a few minutes. |
| `drop.pl` | Writes copies of a translation with one sentence removed. |
| `results.txt` | What `measure.sh` printed for the thresholds as committed. |
| `windows.sh` | Runs the check in `translate.sh` and its PowerShell rewrite in `translate.ps1` on the same texts and compares everything they print. Needs PowerShell 7, or Docker to fetch it; under a minute. |
| `script-ranges.pl` | Prints the lists of weighted characters that `translate.ps1` carries, from perl's Unicode tables. Run it with `/usr/bin/perl` (5.34), which is what the Macs have. |

The 64 translations were made on 2026-11-17 by TranslateGemma 12B
(`sha256:c2f9a9ca1ec7…`, Ollama 0.40.16, temperature 0) and LibreTranslate
1.9.6 (image `sha256:fcb5d85f01bb…`, all Argos packages). The languages are
Arabic, Chinese, French, German, Greek, Hebrew, Hindi, Japanese, Korean,
Persian, Russian, Spanish, Thai, Turkish, Ukrainian and Vietnamese.

## What is measured

**False alarms.** The check is run on each translation as it stands. Anything
it reports is either a real loss or a false alarm, and only reading the
paragraph against its source says which.

**Catch rate.** Each sentence of each translation is removed in turn, one at a
time, and the check either reports that paragraph or does not. Paragraphs
already reported as they stand are left out.

Both are measured on the check's three footings: a paragraph among its
neighbours in the document, where the document's own median ratio sets the
expectation; a paragraph on its own with the languages given, where the size
table does; and a paragraph on its own with no languages given, where only the
script weights do.

## Results

From [`results.txt`](results.txt).

**False alarms: none found.** 724 paragraphs were judged and five reported, all
in LibreTranslate's translations. Read against their sources, all five are real
losses:

| Translation | Paragraph | What LibreTranslate did |
|---|---|---|
| Arabic to English | 4 | Kept the first of four sentences. |
| Arabic to English | 6 | Lost the opening clause and the last sentence. |
| Arabic to English | 8 | Kept the first of three sentences. |
| Arabic to English | 12 | Kept the second of three sentences. |
| Russian to English | 1 | The headline lost "to the consulting company". |

Run on each remaining paragraph alone, with and without the languages given,
it reported nothing.

**Catch rate**, 2,295 removed sentences:

| The removed sentence was | Cases | In a document | Alone, languages given | Alone, languages not given |
|---|---|---|---|---|
| any size | 2,295 | 76% | 63% | 44% |
| under a fifth of its paragraph | 649 | 38% | 17% | 6% |
| a fifth to two fifths | 1,103 | 86% | 74% | 45% |
| two fifths or more | 543 | 99% | 97% | 89% |

| Translations by | Cases | In a document | Alone, languages given | Alone, languages not given |
|---|---|---|---|---|
| TranslateGemma | 1,162 | 75% | 56% | 37% |
| LibreTranslate | 1,133 | 76% | 71% | 52% |

**Missed.** An earlier version of the check also compared a lone paragraph
with what is usual for its language pair at a 25% shortfall. That flagged four
LibreTranslate paragraphs. Three had really lost phrases or a clause (English
to Turkish 2, English to Ukrainian 11, Thai to English 11); the fourth
(English to Chinese 7) was complete, just terse. The rule could not tell them
apart, so it now applies only to whole documents, and those three real losses
go unreported.

## What was set from this data

- **Script weights.** Letters per script against English letters for the same
  article: Han 2.6, Hangul 1.95, Devanagari 1.5, Hebrew 1.3, kana 1.3, Arabic
  1.1, everything else 1.
- **The size table.** For each language, the square root of (English into it)
  over (it into English), on TranslateGemma's translations. Taking both
  directions keeps the habit translations have of running longer than their
  source out of the figure.
- **Thresholds.** Scanned over the shortfall reported outright (0.30 to 0.40),
  the smallest shortfall reported with a missing sentence (0.10 to 0.15) and
  the share of the missing sentences' size it must reach (0.4 to 0.6). False
  alarms stayed at zero down to 0.5 on the last and appeared at 0.4, so the
  committed values (0.35, 0.12, 0.5) sit one step inside that edge.
- **Tolerances** added when a text cannot calibrate itself: 0.05 with the size
  table (two false alarms at 0), 0.15 on script weights alone (four at 0.05,
  none at 0.10).

## What this does not show

- It is one article. Lists, tables, verse, transcripts and text dense with
  names and numbers will have different ratios, and the thresholds have not
  met them.
- The check reported nothing in TranslateGemma's translations, and they have
  not all been read against their sources, so nothing is known here about how
  its real omissions look. LibreTranslate's did not look like the simulation:
  it cut paragraphs to a single sentence and dropped clauses inside sentences.
- The sources for `data/rev/` are machine translations, tidier than documents
  written by people.
- Removing a whole sentence cleanly is the easiest kind of loss to see. A
  dropped clause or a dropped "not" changes the length by almost nothing.
- Languages outside the 16 rely on the script weights and wide tolerances.

## Measuring again

After changing a threshold, the weights or the size table in the checker
inside [`../bundle/translate.sh`](../bundle/translate.sh):

```bash
./measure.sh | tee results.txt
```

After changing an engine or a model, move `data/` aside and run `./run.sh`
first.
