# Held-out reference results

Human review: **not performed**. These are automatic reference-overlap scores.

| Direction | Cases | Libre chrF++ | Gemma chrF++ | Libre warnings | Gemma warnings | Reference flags / judged |
|---|---:|---:|---:|---:|---:|---:|
| fr → en | 24 | 59.37 | 61.71 | 0 | 0 | 0 / 23 |
| en → fr | 24 | 63.30 | 61.39 | 0 | 0 | 0 / 23 |
| ru → en | 24 | 61.20 | 62.24 | 0 | 0 | 0 / 23 |
| en → ru | 24 | 59.08 | 56.42 | 0 | 0 | 0 / 23 |
| zh → en | 24 | 48.42 | 54.79 | 1 | 0 | 0 / 23 |
| en → zh | 24 | 22.87 | 24.31 | 1 | 0 | 0 / 23 |
| he → en | 24 | 59.95 | 63.79 | 0 | 0 | 0 / 23 |
| en → he | 24 | 50.99 | 51.54 | 0 | 0 | 0 / 23 |
| ar → en | 24 | 51.85 | 59.38 | 0 | 0 | 0 / 23 |
| en → ar | 24 | 35.05 | 49.20 | 0 | 0 | 0 / 23 |

Scores are on a 0–100 reference-overlap scale, not a percentage of correct translations.
Only 24 sentence-level examples are used per direction. There is no overall quality grade or release pass/fail.

`scores.json` contains bootstrap intervals, metric signatures and per-case checker findings.
The intervals describe resampling of this small sample, not uncertainty in human adequacy or model training overlap.
Paired p-values are uncorrected across ten directions and are not used to declare a winner.

Warnings count cases with any engine/helper warning. Reference flags are false-alarm candidates, still unreviewed.
References too short for the checker are excluded from the judged denominator.

## Reproducibility

Corpus SHA-256: `116457b9808de6bb8af435af7ab9dff1a6ddec4ffc79fd4a62567f5f988d98b5`

- libre: LibreTranslate 1.9.6; `sha256:fcb5d85f01bb1a3d945e9111d8e02af852f1451de4925eb7b3fca5f0c0bc2d66`
- gemma: Ollama 0.40.16; `sha256:c2f9a9ca1ec7149f2422581c89937ab0363d9399d9355514d753ee012e99c252`

The source, reference and paired outputs are in `review.csv`; keep `review-key.json` separate until review is complete.
A reviewer should check omissions, changed negations, figures, names and any domain-specific terminology.
Review cells are blank. No bilingual expert has assessed these outputs as part of the automatic run.
CSV cells beginning with spreadsheet operators are prefixed with an apostrophe; the original text remains in the corpus and result JSON.

Dataset and translations of its excerpts: CC BY-SA 4.0; see `evaluation/README.md` and the per-case source URLs.
