#!/bin/bash
# Measure translate.sh's dropped-text check against the translations in data/.
# Needs only perl; takes a few minutes.
#
#   1. False alarms: what it reports on the 64 translations as they are.
#   2. Catch rate: each sentence of each translation is removed in turn, and
#      the check either reports the paragraph it came from or does not.
#
# Each is measured three ways, because the check has three footings:
#   in a document      the paragraph among its eleven neighbours
#   alone, langs known the paragraph by itself, --from and --to given
#   alone              the paragraph by itself, languages not given

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
D="$HERE/data"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
TAB="$(printf '\t')"

# The checker is written out by translate.sh at run time; take it from there.
sed -n "/^cat > \"\$TMP\/check.pl\" <<'PERL'\$/,/^PERL\$/p" "$HERE/../bundle/translate.sh" \
  | sed '1d;$d' > "$W/check.pl"
[ -s "$W/check.pl" ] || { echo "couldn't find the checker inside translate.sh" >&2; exit 1; }
K="$W/check.pl"

para() { awk -v n="$2" 'BEGIN { RS = "" } NR == n' "$1"; }

# engine, direction, language, --from, --to, source, translation
: > "$W/pairs"
for e in gemma libre; do
  for f in "$D/fwd/$e"/en.*."$e".txt; do
    l="${f##*/en.}"; l="${l%%.*}"
    printf '%s\tfwd\t%s\ten\t%s\t%s\t%s\n' "$e" "$l" "$l" "$HERE/en.txt" "$f" >> "$W/pairs"
  done
  for f in "$D/rev/$e"/*.en."$e".txt; do
    l="${f##*/}"; l="${l%%.*}"
    printf '%s\trev\t%s\t%s\ten\t%s\t%s\n' "$e" "$l" "$l" "$D/fwd/gemma/en.$l.gemma.txt" "$f" >> "$W/pairs"
  done
done
echo "$(wc -l < "$W/pairs" | tr -d ' ') translations of $(para "$HERE/en.txt" 1 | head -c 40)..."
echo

echo "1. Reported on the translations as they are"
echo "   (read each one against its source before calling it a false alarm)"
: > "$W/flagged"
judged=0
while IFS="$TAB" read -r e d l from to src out; do
  perl "$K" --from "$from" --to "$to" "$src" "$out" > "$W/res"
  n="$(sed -n 's/^STATUS compared \([0-9]*\) .*/\1/p' "$W/res")"; judged=$((judged + ${n:-0}))
  sed -n 's/^WARN //p' "$W/res" | while IFS= read -r w; do printf '   %s %s %s: %s\n' "$e" "$d" "$l" "$w"; done
  sed -n 's/^WARN paragraph \([0-9]*\) .*/\1/p' "$W/res" | while IFS= read -r p; do echo "$e $d $l $p" >> "$W/flagged"; done
  total="$(awk 'BEGIN { RS = "" } END { print NR }' "$src")"
  p=1
  while [ "$p" -le "$total" ]; do
    para "$src" "$p" > "$W/s.txt"; para "$out" "$p" > "$W/o.txt"
    grep -qx "$e $d $l $p" "$W/flagged" 2>/dev/null || {
      perl "$K" --from "$from" --to "$to" "$W/s.txt" "$W/o.txt" | sed -n 's/^WARN //p' \
        | while IFS= read -r w; do printf '   %s %s %s, paragraph %s alone, langs known: %s\n' "$e" "$d" "$l" "$p" "$w"; done
      perl "$K" "$W/s.txt" "$W/o.txt" | sed -n 's/^WARN //p' \
        | while IFS= read -r w; do printf '   %s %s %s, paragraph %s alone: %s\n' "$e" "$d" "$l" "$p" "$w"; done
    }
    p=$((p + 1))
  done
done < "$W/pairs"
echo "   $judged paragraphs judged, $(wc -l < "$W/flagged" | tr -d ' ') reported in their documents"
echo

echo "2. Share of removed sentences reported, by how much of its paragraph each was"
: > "$W/sim"
while IFS="$TAB" read -r e d l from to src out; do
  rm -rf "$W/d"; mkdir -p "$W/d"
  perl "$HERE/drop.pl" "$out" "$W/d" > "$W/list"
  while IFS="$TAB" read -r f pn k ns len; do
    # a paragraph already reported as it stands proves nothing by being reported again
    if grep -qx "$e $d $l $pn" "$W/flagged" 2>/dev/null; then continue; fi
    a=0; b=0; c=0
    if perl "$K" --from "$from" --to "$to" "$src" "$f" | grep -q "^WARN paragraph $pn "; then a=1; fi
    para "$src" "$pn" > "$W/s.txt"; para "$f" "$pn" > "$W/o.txt"
    if perl "$K" --from "$from" --to "$to" "$W/s.txt" "$W/o.txt" | grep -q "^WARN paragraph "; then b=1; fi
    if perl "$K" "$W/s.txt" "$W/o.txt" | grep -q "^WARN paragraph "; then c=1; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$e $d $l $pn" "$e" "$ns" "$len" "$a" "$b" "$c" "$l" >> "$W/sim"
  done < "$W/list"
done < "$W/pairs"

awk -F'\t' '
  { tot[$1] += $4; row[NR] = $0 }
  END {
    for (i = 1; i <= NR; i++) {
      split(row[i], f, FS); share = f[4] / tot[f[1]]
      b = share < 0.2 ? 1 : share < 0.4 ? 2 : 3
      n[0]++; n[b]++
      for (m = 1; m <= 3; m++) { hit[m, 0] += f[4 + m]; hit[m, b] += f[4 + m] }
      eng[f[2]]++; for (m = 1; m <= 3; m++) ehit[m, f[2]] += f[4 + m]
    }
    name[0] = "all"; name[1] = "under a fifth"; name[2] = "a fifth to two fifths"; name[3] = "two fifths or more"
    printf "   %-24s %6s  %-14s %-19s %s\n", "", "n", "in a document", "alone, langs known", "alone"
    for (b = 0; b <= 3; b++)
      printf "   %-24s %6d  %3.0f%%           %3.0f%%                %3.0f%%\n", name[b], n[b],
        100 * hit[1, b] / n[b], 100 * hit[2, b] / n[b], 100 * hit[3, b] / n[b]
    for (e in eng)
      printf "   %-24s %6d  %3.0f%%           %3.0f%%                %3.0f%%\n", e " translations", eng[e],
        100 * ehit[1, e] / eng[e], 100 * ehit[2, e] / eng[e], 100 * ehit[3, e] / eng[e]
  }' "$W/sim"
