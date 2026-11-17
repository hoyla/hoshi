#!/bin/bash
# Regenerate the calibration translations in data/: en.txt into each language
# with both engines, then TranslateGemma's version of each language back into
# English with both engines. About half an hour.
#
# Needs both engines running. Point at them with the usual variables, e.g.
#   LT_URL=http://127.0.0.1:5050 OLLAMA_HOST=127.0.0.1:11434 ./run.sh
#
# Only needed after changing engines or models. measure.sh works from data/.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
TR="$HERE/../bundle/translate.sh"
D="$HERE/data"
MODEL="${MODEL:-translategemma:12b}"
LANGS="${LANGS:-ru fr zh he ar de es ja ko fa uk tr hi th el vi}"

# translate.sh never overwrites, so a second set would land beside the first
# under timestamped names and measure.sh would count both.
if [ -n "$(find "$D" -type f 2>/dev/null | head -1)" ]; then
  echo "error: $D already holds translations; move it aside first" >&2
  exit 1
fi

mkdir -p "$D/fwd/gemma" "$D/fwd/libre" "$D/rev/gemma" "$D/rev/libre"
for l in $LANGS; do
  "$TR" --engine libre --from en --to "$l" --out "$D/fwd/libre" "$HERE/en.txt" || echo "libre en->$l FAILED"
  "$TR" --engine gemma --model "$MODEL" --from en --to "$l" --out "$D/fwd/gemma" "$HERE/en.txt" || echo "gemma en->$l FAILED"
done
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
for l in $LANGS; do
  src="$D/fwd/gemma/en.$l.gemma.txt"
  [ -s "$src" ] || continue
  # translate.sh names outputs after the source file, so give it a plain one
  cp "$src" "$W/$l.txt"
  "$TR" --engine libre --from "$l" --to en --out "$D/rev/libre" "$W/$l.txt" || echo "libre $l->en FAILED"
  "$TR" --engine gemma --model "$MODEL" --from "$l" --to en --out "$D/rev/gemma" "$W/$l.txt" || echo "gemma $l->en FAILED"
done
echo "Done. The translations and their provenance files are in $D."
