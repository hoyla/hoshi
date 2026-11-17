#!/bin/bash
# Compare translate.ps1's dropped-text check with translate.sh's.
#
# The Windows helper carries the check a second time, rewritten in PowerShell.
# This runs both on the same texts and compares every number, verdict and
# warning. Needs perl, and PowerShell 7: pwsh if it is installed, otherwise
# Docker and the .NET SDK image (PWSH_IMAGE names another). A minute or two.
#
# The texts:
#   - the 64 translations in data/, on each footing the helpers use
#   - every paragraph of each, alone, with and without the languages given
#   - every copy of each with one sentence removed
#   - a few made here for what those never do: Windows and old Mac line ends,
#     lines with no blank lines between, text wrapped at a fixed width, merged
#     paragraphs, more findings than are listed, Chinese characters beyond the
#     Basic Multilingual Plane, next to nothing, nothing
#
# What it cannot tell you: this is PowerShell 7, not the Windows PowerShell 5.1
# a Windows PC has, and the two do not know quite the same characters.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
ROOT="$(dirname "$HERE")"
D="$HERE/data"
W="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$W"' EXIT
TAB="$(printf '\t')"
PWSH_IMAGE="${PWSH_IMAGE:-mcr.microsoft.com/dotnet/sdk:8.0}"

# Both checkers live inside the helpers; take them from there.
sed -n "/^cat > \"\$TMP\/check.pl\" <<'PERL'\$/,/^PERL\$/p" "$ROOT/bundle/translate.sh" \
  | sed '1d;$d' > "$W/check.pl"
[ -s "$W/check.pl" ] || { echo "couldn't find the checker inside translate.sh" >&2; exit 1; }
sed -n '/^# -* dropped-text check$/,/^# -* end of dropped-text check$/p' "$ROOT/bundle/translate.ps1" > "$W/check.ps1"
grep -q '^function Compare-Translation' "$W/check.ps1" || { echo "couldn't find the checker inside translate.ps1" >&2; exit 1; }

para() { awk -v n="$2" 'BEGIN { RS = "" } NR == n' "$1"; }

# One comparison to a line: --from, --to, --unit, --no-struct, source,
# translation. A hyphen is an option not given.
job() { printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@" >> "$W/jobs"; }
: > "$W/jobs"

mkdir "$W/alone" "$W/drop"
for e in gemma libre; do
  for d in fwd rev; do
    for f in "$D/$d/$e"/*."$e".txt; do
      if [ "$d" = fwd ]; then
        l="${f##*/en.}"; l="${l%%.*}"; from=en; to="$l"; src="$HERE/en.txt"
      else
        l="${f##*/}"; l="${l%%.*}"; from="$l"; to=en; src="$D/fwd/gemma/en.$l.gemma.txt"
      fi
      job "$from" "$to" - - "$src" "$f"
      job - "$to" - - "$src" "$f"                 # LibreTranslate left to detect the language
      job - - - - "$src" "$f"
      job "$from" "$to" - 1 "$src" "$f"           # as after TranslateGemma
      job "$from" "$to" paragraph - "$src" "$f"   # as for a Word file
      a="$W/alone/$e.$d.$l"
      p=1
      while [ "$p" -le 12 ]; do
        para "$src" "$p" > "$a.$p.s.txt"; para "$f" "$p" > "$a.$p.o.txt"
        job "$from" "$to" - - "$a.$p.s.txt" "$a.$p.o.txt"
        job - - - - "$a.$p.s.txt" "$a.$p.o.txt"
        p=$((p + 1))
      done
      mkdir "$W/drop/$e.$d.$l"
      perl "$HERE/drop.pl" "$f" "$W/drop/$e.$d.$l" | while IFS="$TAB" read -r g rest; do
        job "$from" "$to" - - "$src" "$g"
      done
    done
  done
done

# The made-up cases, from the article and its French and Chinese translations.
E="$W/edge"; mkdir "$E"
EN="$HERE/en.txt"; FR="$D/fwd/gemma/en.fr.gemma.txt"; ZH="$D/fwd/gemma/en.zh.gemma.txt"
edit() { perl -CSD -0pe "$1" "$2" > "$3"; }   # the whole file is in $_

edit 's/\n/\r\n/g; $_ = "\x{FEFF}$_"' "$EN" "$E/crlf.en.txt"
edit 's/\n/\r\n/g; $_ = "\x{FEFF}$_"' "$FR" "$E/crlf.fr.txt"
job en fr - - "$E/crlf.en.txt" "$E/crlf.fr.txt"
job en fr - - "$EN" "$E/crlf.fr.txt"
edit 's/\n/\r/g' "$EN" "$E/cr.en.txt"
job en fr - - "$E/cr.en.txt" "$FR"

edit 's/\n\s*\n/\n/g' "$EN" "$E/lines.en.txt"
edit 's/\n\s*\n/\n/g' "$FR" "$E/lines.fr.txt"
edit 's/\n\s*\n/\n/g; s/\A/\n\n/' "$FR" "$E/lines-late.fr.txt"
job en fr - - "$E/lines.en.txt" "$E/lines.fr.txt"
job - - - - "$E/lines.en.txt" "$E/lines.fr.txt"
job en fr paragraph - "$E/lines.en.txt" "$E/lines.fr.txt"
job en fr - - "$E/lines-late.fr.txt" "$E/lines.en.txt"   # line numbers, not places in order
edit 's/\n\s*\n/\n/g; s/^(.{30}).*$/$1/mg' "$FR" "$E/lines-cut.fr.txt"
job en fr - - "$E/lines.en.txt" "$E/lines-cut.fr.txt"
job - - - - "$E/lines.en.txt" "$E/lines-cut.fr.txt"       # every line cut alike, pair not known
job en fr paragraph - "$E/lines.en.txt" "$E/lines-cut.fr.txt"

edit 's/(.{1,60})(?: +|$)/$1\n/mg; s/\n\n\n+/\n\n/g' "$EN" "$E/wrapped.en.txt"
edit 's/\n\n/\n/' "$E/wrapped.en.txt" "$E/wrapped-joined.en.txt"
job en en - - "$E/wrapped.en.txt" "$E/wrapped.en.txt"
job en en - - "$E/wrapped.en.txt" "$E/wrapped-joined.en.txt"
job en fr - - "$E/wrapped.en.txt" "$FR"

edit 's/\n\s*\n/ /' "$FR" "$E/merged.fr.txt"
job en fr - - "$EN" "$E/merged.fr.txt"
job en fr - 1 "$EN" "$E/merged.fr.txt"
job - - - - "$EN" "$E/merged.fr.txt"
edit 's/\n\s*\n/ /; s/^(.{200}).*$/$1/mg' "$FR" "$E/merged-cut.fr.txt"
job en fr - - "$EN" "$E/merged-cut.fr.txt"
job - fr - 1 "$EN" "$E/merged-cut.fr.txt"

# three copies end to end, with two paragraphs in every five cut short, or one said three times
edit '$_ = "$_\n$_\n$_"' "$EN" "$E/thrice.en.txt"
edit '$_ = "$_\n$_\n$_"; my $p = 0; s{^(.{40})(.+)$}{my $k = $p++ % 5; $k == 0 || $k == 2 ? $1 : "$1$2"}mge' "$FR" "$E/thrice-cut.fr.txt"
edit '$_ = "$_\n$_\n$_"; my $p = 0; s/^(.+)$/$p++ % 5 == 1 ? "$1 $1 $1" : $1/mge' "$FR" "$E/thrice-said.fr.txt"
job en fr - - "$E/thrice.en.txt" "$E/thrice-cut.fr.txt"
job - - - - "$E/thrice.en.txt" "$E/thrice-cut.fr.txt"
job en fr paragraph - "$E/thrice.en.txt" "$E/thrice-cut.fr.txt"
job en fr - - "$E/thrice.en.txt" "$E/thrice-said.fr.txt"
job - - - - "$E/thrice.en.txt" "$E/thrice-said.fr.txt"

# every third Chinese character replaced by one from plane 2, and some emoji
edit 'my $n = 0; s/((?=\p{L})\p{Han})/$n++ % 3 ? $1 : chr(0x20000 + $n)/ge; s/\x{3002}/\x{3002}\x{1F600}/g' "$ZH" "$E/rare.zh.txt"
job zh en - - "$E/rare.zh.txt" "$EN"
job en zh - - "$EN" "$E/rare.zh.txt"
job - - - - "$E/rare.zh.txt" "$EN"
para "$E/rare.zh.txt" 2 > "$E/rare-1.zh.txt"; para "$EN" 2 > "$E/rare-1.en.txt"
job zh en - - "$E/rare-1.zh.txt" "$E/rare-1.en.txt"
job - - - - "$E/rare-1.zh.txt" "$E/rare-1.en.txt"

printf 'Hello.\n' > "$E/tiny.en.txt"; printf 'Bonjour.\n' > "$E/tiny.fr.txt"; : > "$E/empty.txt"
job en fr - - "$E/tiny.en.txt" "$E/tiny.fr.txt"
job en fr - - "$EN" "$E/empty.txt"
job en fr - - "$E/empty.txt" "$FR"
job - - - - "$E/empty.txt" "$E/empty.txt"

total="$(wc -l < "$W/jobs" | tr -d ' ')"
echo "$total comparisons"

# translate.sh's, one perl to a comparison as the helper runs it
n=0
while IFS="$TAB" read -r from to unit ns src out; do
  n=$((n + 1))
  set -- --stats
  [ "$from" = - ] || set -- "$@" --from "$from"
  [ "$to" = - ] || set -- "$@" --to "$to"
  [ "$unit" = - ] || set -- "$@" --unit "$unit"
  [ "$ns" = - ] || set -- "$@" --no-struct
  echo "== $n"
  perl "$W/check.pl" "$@" "$src" "$out" 2>&1 || echo "FAILED"
done < "$W/jobs" > "$W/perl.txt"

# translate.ps1's, in one PowerShell
cat > "$W/driver.ps1" <<'PS'
param([string]$Block, [string]$Jobs, [string]$Result)
$INVARIANT = [System.Globalization.CultureInfo]::InvariantCulture
$LF = [string][char]10
$strict = New-Object System.Text.UTF8Encoding($false, $true)
. $Block
function Get-Option([string]$Field) { if ($Field -ceq '-') { return '' }; return $Field }
$lines = New-Object System.Collections.Generic.List[string]
$n = 0
foreach ($job in [System.IO.File]::ReadAllLines($Jobs)) {
  $n++
  $f = $job.Split([char]9)
  $lines.Add("== $n")
  try {
    $source = $strict.GetString([System.IO.File]::ReadAllBytes($f[4]))
    $translation = $strict.GetString([System.IO.File]::ReadAllBytes($f[5]))
    $r = Compare-Translation $source $translation (Get-Option $f[0]) (Get-Option $f[1]) (Get-Option $f[2]) ($f[3] -cne '-') $true
    foreach ($line in $r.Stats) { $lines.Add($line) }
    $lines.Add("STATUS $($r.Status)")
    foreach ($line in $r.Warnings) { $lines.Add("WARN $line") }
  } catch {
    $lines.Add("FAILED $($_.Exception.Message)")
  }
}
[System.IO.File]::WriteAllBytes($Result, (New-Object System.Text.UTF8Encoding($false)).GetBytes(($lines -join $LF) + $LF))
PS
if command -v pwsh > /dev/null 2>&1; then
  pwsh -NoProfile -File "$W/driver.ps1" "$W/check.ps1" "$W/jobs" "$W/pwsh.txt"
else
  docker run --rm -v "$HERE:$HERE:ro" -v "$W:$W" "$PWSH_IMAGE" \
    pwsh -NoProfile -File "$W/driver.ps1" "$W/check.ps1" "$W/jobs" "$W/pwsh.txt"
fi
[ -s "$W/pwsh.txt" ] || { echo "PowerShell produced nothing" >&2; exit 1; }
# KEEP names a folder to leave both outputs in, numbered as the lines of jobs
[ -z "${KEEP:-}" ] || cp "$W/perl.txt" "$W/pwsh.txt" "$W/jobs" "$KEEP"/

if cmp -s "$W/perl.txt" "$W/pwsh.txt"; then
  echo "translate.ps1 agrees with translate.sh on all of them:"
  echo "  $(grep -c "^STAT$TAB" "$W/perl.txt") units measured, $(grep -c '^WARN ' "$W/perl.txt") warnings," \
    "$(grep -c '^STATUS not checked' "$W/perl.txt") not checked"
  for k in line paragraph whole; do
    echo "  $(grep -c "^STAT$TAB$k$TAB" "$W/perl.txt") as $k"
  done
else
  echo "translate.ps1 differs from translate.sh (< translate.sh, > translate.ps1):"
  diff "$W/perl.txt" "$W/pwsh.txt" | head -60 || true
  exit 1
fi
