#!/bin/bash
# Translate files with the offline engines set up by install.sh.
#
#   gemma  TranslateGemma via Ollama. Better quality; plain-text files only.
#   libre  LibreTranslate. Keeps document formatting (.docx .pptx .odt .pdf
#          .html .epub .srt ...); quality is good enough for gisting.
#
# The source file is never modified. Each translation is written next to it
# with a .provenance.json sidecar recording the source hash, engine, exact
# model and time. Re-running on an unchanged file with the same engine is a
# no-op; anything else writes a new timestamped file rather than overwriting.
#
# Either engine can drop a sentence and still read fluently, so each
# translation is compared with its source, paragraph by paragraph, and anything
# much shorter or longer than expected is printed and recorded as a warning.
#
# Uses only tools that ship with macOS (bash 3.2, curl, awk, sed, plutil, perl,
# textutil). Not iconv: the macOS build wrongly rejects valid UTF-8 that has
# long lines.

set -euo pipefail

VERSION="2"
HERE="$(cd "$(dirname "$0")" && pwd -P)"
LANGFILE="$HERE/languages.tsv"
ENVFILE="$HERE/bundle.env"
TAB="$(printf '\t')"

cfg() { { [ -f "$ENVFILE" ] && sed -n "s/^$1=//p" "$ENVFILE" | tail -1; } || true; }

LT_URL="${LT_URL:-$(cfg LT_URL)}"
LT_URL="${LT_URL:-http://127.0.0.1:5050}"
LT_CONTAINER="${LT_CONTAINER:-$(cfg LT_CONTAINER)}"
LT_CONTAINER="${LT_CONTAINER:-libretranslate}"
case "${OLLAMA_HOST:-}" in
  "") OLLAMA_API="http://127.0.0.1:11434" ;;
  http://*|https://*) OLLAMA_API="$OLLAMA_HOST" ;;
  *) OLLAMA_API="http://$OLLAMA_HOST" ;;
esac
MODEL="$(cfg DEFAULT_MODEL)"
MODEL="${MODEL:-translategemma:12b}"

# TranslateGemma was trained on inputs of up to about 2K tokens, so long texts
# go through in pieces. Sizes are in bytes: a piece closes at the first
# paragraph break after SOFT and is never allowed past HARD.
SOFT=3000
HARD=6000
NUM_CTX=8192

usage() {
  cat <<EOF
Usage:
  translate.sh --to CODE [--from CODE] [options] FILE...
  translate.sh --to CODE [--from CODE] [--engine E] --text "words to translate"
  translate.sh --languages

Options:
  --to CODE        Target language code, e.g. en
  --from CODE      Source language code, e.g. ru, fr, zh, he, ar.
                   Optional: LibreTranslate detects it when omitted.
  --engine NAME    gemma or libre. Default: gemma for .txt/.md, libre otherwise.
  --model NAME     Ollama model for the gemma engine (default: $MODEL)
  --out DIR        Write translations here instead of next to each source file
  --encoding NAME  Source text encoding if not UTF-8, e.g. CP1251 (Russian),
                   CP1255 (Hebrew), CP1256 (Arabic), GBK or Big5 (Chinese), UTF-16
  --force          Translate again even if an identical run already exists
                   (writes a new timestamped file)
  --languages      List the language codes the gemma engine knows
  -h, --help       Show this help

Examples:
  translate.sh --from ru --to en statement.txt
  translate.sh --to en contract.docx
  translate.sh --from ar --to en --engine libre --text "..."
EOF
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*" >&2; }

# stdin -> the body of a JSON string. Works on raw bytes so UTF-8 passes through.
json_escape() {
  LC_ALL=C tr -d '\r' \
    | LC_ALL=C tr '\000-\010\013\014\016-\037' ' ' \
    | LC_ALL=C sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e "s/$TAB/\\\\t/g" \
    | LC_ALL=C awk 'NR > 1 { printf "\\n" } { printf "%s", $0 }'
}
json_str() { printf '%s' "$1" | json_escape; }

is_utf8() { # $1 = file
  perl -MEncode -e 'local $/; my $d = <STDIN>;
    exit(eval { Encode::decode("UTF-8", $d, Encode::FB_CROAK); 1 } ? 0 : 1)' < "$1"
}
to_utf8() { # $1 = encoding name, $2 = file; UTF-8 on stdout
  perl -MEncode -e 'Encode::find_encoding($ARGV[0]) or exit 2;
    local $/; binmode STDOUT;
    my $out = eval { Encode::encode("UTF-8", Encode::decode($ARGV[0], scalar <STDIN>, Encode::FB_CROAK)) };
    defined $out or exit 1; print $out' "$1" < "$2"
}
# stdin -> stdout without a byte-order mark or carriage returns
clean_text() { LC_ALL=C perl -pe 's/^\xEF\xBB\xBF// if $. == 1; tr/\r//d'; }

lang_name() {
  awk -F'\t' -v code="$1" '$1 == code { print $2; found = 1; exit } END { exit !found }' "$LANGFILE"
}

# stdin -> stdout without leading/trailing blank lines, trailing spaces on the
# last line, or a final newline
trim_blank() {
  awk '{ line[NR] = $0 }
       END { s = 1; e = NR
             while (s <= e && line[s] ~ /^[ \t]*$/) s++
             while (e >= s && line[e] ~ /^[ \t]*$/) e--
             if (e >= s) sub(/[ \t]+$/, "", line[e])
             for (i = s; i <= e; i++) printf "%s%s", line[i], (i < e ? "\n" : "") }'
}

# number of blank-line-separated paragraphs in a file
count_paras() { awk 'BEGIN { RS = "" } END { print NR }' "$1"; }
# number of lines in a file that have something on them
count_lines() { awk 'NF { n++ } END { print n + 0 }' "$1"; }

WARNINGS=""
add_warning() {
  info "warning: $1"
  WARNINGS="${WARNINGS:+$WARNINGS, }\"$(json_str "$1")\""
}

# ------------------------------------------------------------------ arguments
TO=""; FROM=""; ENGINE=""; OUT_DIR=""; ENCODING=""; FORCE=0; TEXT=""; HAVE_TEXT=0
FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --to) TO="${2:?}"; shift 2 ;;
    --from) FROM="${2:?}"; shift 2 ;;
    --engine) ENGINE="${2:?}"; shift 2 ;;
    --model) MODEL="${2:?}"; shift 2 ;;
    --out) OUT_DIR="${2:?}"; shift 2 ;;
    --encoding) ENCODING="${2:?}"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --text) TEXT="${2:?}"; HAVE_TEXT=1; shift 2 ;;
    --languages) grep -v '^#' "$LANGFILE"; exit 0 ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do FILES+=("$1"); shift; done ;;
    -*) usage >&2; die "unknown option: $1" ;;
    *) FILES+=("$1"); shift ;;
  esac
done
[ -n "$TO" ] || { usage >&2; die "--to is required"; }
case "$ENGINE" in ""|gemma|libre) ;; *) die "--engine must be gemma or libre" ;; esac
if [ "$HAVE_TEXT" = 0 ] && [ "${#FILES[@]}" -eq 0 ]; then usage >&2; die "nothing to translate"; fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------- dropped-text check
cat > "$TMP/check.pl" <<'PERL'
# Compare a source text with its translation, unit by unit, and report units
# whose translation is much shorter or longer than expected. A translation
# engine can drop a sentence, or repeat or invent one, and still read fluently.
#
#   perl check.pl [--from CODE] [--to CODE] [--unit NAME] [--no-struct] SOURCE TRANSLATION
#
# Prints "STATUS ..." once and "WARN ..." per finding, in UTF-8. With --stats
# it also prints the numbers behind each unit, for recalibrating.
#
# Method. Size is counted in letters and digits, weighted by script so that the
# same content comes out at a similar size in any language (a Chinese
# character carries about as much as 2.6 Latin letters). Each unit's
# translated/source size ratio is compared with what to expect: the document's
# own typical ratio when there is enough of it, which cancels out the language
# pair and the engine's style; otherwise a per-language size table; otherwise
# the script weights alone, with more tolerance. A unit is reported when it
# falls well short of that, or falls somewhat short and also has fewer
# sentences than its source: a merged sentence keeps its length, a dropped one
# does not.
#
# It is a heuristic. It rarely sees a sentence that was under a fifth of its
# paragraph, and it says nothing about whether the words are right. The
# numbers below come from calibration/ in the repository this script is from.
#
# Kept to what perl's core has built in (no Encode, no PerlIO::encoding): the
# web page runs this same file in the LibreTranslate image, which has only
# Debian's minimal perl.
use strict; use warnings; no warnings 'utf8';
binmode STDOUT, ':utf8';

my $MIN_UNIT = 60;    # units smaller than this (weighted letters) are not judged
my $CAL_MIN  = 400;   # other text needed before a short document calibrates itself
my $D_BIG    = 0.35;  # shortfall reported whatever the sentence counts say
my $D_MIN    = 0.12;  # smallest shortfall reported when a sentence is missing
my $K        = 0.50;  # ... and it must be this share of the missing sentences' size
my $LONG     = 2.00;  # times the expected size: reported as too long
my $D_WHOLE  = 0.25;  # shortfall of the whole translation against the language pair
my %SLACK    = (self => 0, pair => 0.05, script => 0.15);   # added to the shortfalls above
my $MAX_WARN = 10;

# Letters of these scripts count for more than a Latin letter.
my @WEIGHT = (
  [qr/(?=[\p{L}\p{N}])\p{Han}/,                2.6],
  [qr/(?=\p{L})[\p{Hiragana}\p{Katakana}]/,    1.3],
  [qr/(?=\p{L})\p{Hangul}/,                    1.95],
  [qr/(?=\p{L})\p{Hebrew}/,                    1.3],
  [qr/(?=\p{L})\p{Arabic}/,                    1.1],
  [qr/(?=\p{L})[\p{Devanagari}\p{Bengali}\p{Gurmukhi}\p{Gujarati}\p{Tamil}\p{Telugu}\p{Kannada}\p{Malayalam}\p{Sinhala}]/, 1.5],
);

# Weighted size of the same content in each language, relative to English.
my %SIZE = (
  en => 1.00, ar => 0.91, de => 1.20, el => 1.18, es => 1.12, fa => 0.99,
  fr => 1.20, he => 0.95, hi => 0.94, ja => 0.91, ko => 0.94, ru => 1.16,
  th => 0.91, tr => 1.14, uk => 1.12, vi => 1.08, zh => 0.94,
);

my ($stats, $unit_name, $no_struct, $from, $to) = (0, '', 0, '', '');
while (@ARGV && $ARGV[0] =~ /^--/) {
  my $o = shift @ARGV;
  if    ($o eq '--stats')     { $stats = 1 }
  elsif ($o eq '--no-struct') { $no_struct = 1 }
  elsif ($o eq '--unit')      { $unit_name = shift @ARGV }
  elsif ($o eq '--from')      { $from = shift @ARGV }
  elsif ($o eq '--to')        { $to = shift @ARGV }
}
@ARGV == 2 or die "usage: check.pl [--from CODE] [--to CODE] [--unit NAME] [--no-struct] SOURCE TRANSLATION\n";
for ($from, $to) { $_ = lc($_ // ''); s/[-_].*//; }

sub slurp {
  open my $f, '<:raw', $_[0] or die "can't read $_[0]\n";
  local $/; my $d = <$f>; $d = '' unless defined $d;
  utf8::decode($d) or die "$_[0] isn't valid UTF-8\n";
  $d =~ s/\r\n?/\n/g; $d =~ s/^\x{FEFF}//;
  return $d;
}

sub wlen {
  my $s = $_[0];
  my $w = () = $s =~ /[\p{L}\p{N}]/g;
  for my $c (@WEIGHT) {
    my $re = $c->[0];
    my $n = () = $s =~ /$re/g;
    $w += $n * ($c->[1] - 1);
  }
  return $w;
}

# Sentence ends: . ! ? and ellipsis before a space or the end, the Arabic
# question mark, Urdu and Armenian full stops, the Devanagari danda, the
# Ethiopic full stop, and the CJK full stop, ! and ? (which need no space).
my $SENT = qr/(?:[.!?\x{2026}]+|[\x{061F}\x{06D4}\x{0589}\x{0964}\x{1362}])(?=["'\x{201D}\x{2019}\x{00BB}\)\]]*(?:\s|\z))|[\x{3002}\x{FF01}\x{FF1F}]+/;
sub sentences { my $n = () = $_[0] =~ /$SENT/g; return $n }

sub count { my ($n, $word) = @_; return "$n $word" . ($n == 1 ? '' : 's') }

# A number to so many decimal places. Rounded by arithmetic and not by sprintf,
# which translate.ps1 cannot follow digit for digit when a number falls halfway.
sub fixed { my ($x, $places) = @_; my $m = 10 ** $places; return sprintf("%.${places}f", int($x * $m + 0.5) / $m) }

# [text, first line number] for each blank-line-separated block / non-blank line
sub paras {
  my @u; my ($buf, $start, $n) = ('', 0, 0);
  for my $l (split /\n/, $_[0], -1) {
    $n++;
    if ($l =~ /\S/) { $start = $n if $buf eq ''; $buf .= "$l\n" }
    elsif ($buf ne '') { push @u, [$buf, $start]; $buf = '' }
  }
  push @u, [$buf, $start] if $buf ne '';
  return @u;
}
sub lines {
  my @u; my $n = 0;
  for my $l (split /\n/, $_[0], -1) { $n++; push @u, [$l, $n] if $l =~ /\S/ }
  return @u;
}

# Text wrapped at a fixed width: most lines inside a block stop mid-sentence.
sub hard_wrapped {
  my ($inside, $open) = (0, 0);
  for my $p (@_) {
    my @l = grep { /\S/ } split /\n/, $p->[0];
    pop @l;
    for (@l) { $inside++; $open++ unless /[.!?:;\x{2026}\x{3002}\x{FF01}\x{FF1F}\x{061F}\x{06D4}\x{0964}]["'\x{201D}\x{2019}\x{00BB}\)\]]*\s*$/ }
  }
  return $inside >= 3 && $open / $inside >= 0.6;
}

my $src = slurp($ARGV[0]);
my $out = slurp($ARGV[1]);
my @sp = paras($src); my @op = paras($out);
my @sl = lines($src); my @ol = lines($out);

# The finest units both texts agree on: lines, unless the text is wrapped at a
# fixed width, then blank-line-separated paragraphs, then the text as a whole.
my (@su, @ou, $kind);
if (@sl >= 2 && @sl == @ol && @sl > @sp && !hard_wrapped(@sp)) { @su = @sl; @ou = @ol; $kind = 'line' }
elsif (@sp == @op && @sp >= 1)                                 { @su = @sp; @ou = @op; $kind = 'paragraph' }
elsif (@sl >= 2 && @sl == @ol)                                 { @su = @sl; @ou = @ol; $kind = 'line' }
else                                                           { @su = ([$src, 1]); @ou = ([$out, 1]); $kind = 'whole' }

my @warn;
if ($kind eq 'whole' && !$no_struct && @sp && @op) {
  push @warn, sprintf('the source has %s and the translation has %d, so they could only be compared as a whole; check for missing or merged text',
    count(scalar @sp, 'paragraph'), scalar @op);
}

my $label = $unit_name || $kind;
my (@sw, @ow, @ss, @os);
my ($tsw, $tow, $tss, $tos) = (0, 0, 0, 0);
for my $i (0 .. $#su) {
  $sw[$i] = wlen($su[$i][0]); $ow[$i] = wlen($ou[$i][0]);
  $ss[$i] = sentences($su[$i][0]); $os[$i] = sentences($ou[$i][0]);
  $tsw += $sw[$i]; $tow += $ow[$i]; $tss += $ss[$i]; $tos += $os[$i];
}
# Sentence counts mean nothing if the translation barely marks sentence ends
# (Thai does not), which shows over a document.
my $sent_ok = !($tss >= 8 && $tos < 0.25 * $tss);
my $pair = exists $SIZE{$from} && exists $SIZE{$to} ? $SIZE{$to} / $SIZE{$from} : 0;

# With five or more units of a fair size, the document's own typical ratio is
# their median, which a few gutted units cannot drag down.
my @ratios = sort { $a <=> $b } map { $ow[$_] / $sw[$_] } grep { $sw[$_] >= $MIN_UNIT } 0 .. $#su;
my $median = @ratios >= 5 ? $ratios[int(@ratios / 2)] : 0;

# The whole translation against what is usual for the language pair. A
# document that calibrates itself hides an engine trimming every unit alike,
# so this is for those; shorter texts are held to the pair unit by unit below.
if ($pair && $median > 0) {
  my $rel = ($tow / $tsw) / $pair;
  push @warn, sprintf('the translation as a whole is %d%% shorter than is usual from %s to %s; check for dropped text',
    int((1 - $rel) * 100 + 0.5), $from, $to) if $rel <= 1 - $D_WHOLE;
}

my ($judged, $flagged) = (0, 0);
for my $i (0 .. $#su) {
  my ($s, $o) = ($sw[$i], $ow[$i]);
  my $rest_s = $tsw - $s; my $rest_o = $tow - $o;
  my ($mode, $expect) = $median > 0                        ? ('self', $median)
                      : $rest_s >= $CAL_MIN && $rest_o > 0 ? ('self', $rest_o / $rest_s)
                      : $pair                              ? ('pair', $pair)
                      :                                      ('script', 1.0);
  my $rel = $s > 0 ? ($o / $s) / $expect : 1;
  my $deficit = 1 - $rel;
  my $lost = $sent_ok && $os[$i] < $ss[$i] ? $ss[$i] - $os[$i] : 0;
  if ($stats) {
    print join("\t", 'STAT', $kind, $i + 1, $s, $o, fixed($s > 0 ? $o / $s : 0, 3),
      fixed($expect, 3), fixed($rel, 3), $ss[$i], $os[$i], $mode, $sent_ok ? 1 : 0), "\n";
  }
  next if $s < $MIN_UNIT;
  $judged++;
  my $slack = $SLACK{$mode};
  my $need = $K * $lost / ($ss[$i] || 1);
  $need = $D_MIN if $need < $D_MIN;
  my $what;
  if ($deficit >= $D_BIG + $slack || ($lost && $deficit >= $need + $slack)) {
    $what = sprintf('the translation is %d%% shorter than expected', int($deficit * 100 + 0.5));
    $what .= sprintf(' and has %s against %d in the source', count($os[$i], 'sentence'), $ss[$i]) if $lost;
    $what .= '; check for dropped text';
  } elsif ($rel >= $LONG * (1 + 2 * $slack)) {
    $what = sprintf('the translation is %s times as long as expected; check for repeated or added text', fixed($rel, 1));
  }
  next unless $what;
  $flagged++;
  next if $flagged > $MAX_WARN;
  (my $snip = $su[$i][0]) =~ s/\s+/ /g; $snip =~ s/^ | $//g;
  $snip = substr($snip, 0, 40) . "\x{2026}" if length($snip) > 40;
  # a plain-text line is named by its line number; anything else by its place in order
  my $where = $kind eq 'whole' ? 'the text' : sprintf('%s %d', $label, $kind eq 'line' && !$unit_name ? $su[$i][1] : $i + 1);
  push @warn, sprintf('%s (starts "%s"): %s', $where, $snip, $what);
}
push @warn, sprintf('%s look too short or too long', count($flagged - $MAX_WARN, "more $label")) if $flagged > $MAX_WARN;

if ($judged == 0) { print "STATUS not checked: too little text to judge\n" }
elsif ($kind eq 'whole') { print "STATUS compared the text as a whole\n" }
else {
  printf "STATUS compared %s%s\n", count($judged, $label), @su > $judged ? sprintf(', %d more too short to judge', @su - $judged) : '';
}
print "WARN $_\n" for @warn;

PERL

CHECK_STATUS="not run"
check_dropped() { # $1 = source text, $2 = translated text, then options for check.pl
  local src="$1" out="$2" line
  shift 2
  CHECK_STATUS="not checked: the comparison itself failed"
  # FROM is empty when LibreTranslate was left to detect the language itself
  perl "$TMP/check.pl" ${FROM:+--from "$FROM"} --to "$TO" "$@" "$src" "$out" \
    > "$TMP/check.out" 2>/dev/null || return 0
  while IFS= read -r line; do
    case "$line" in
      "STATUS "*) CHECK_STATUS="${line#STATUS }" ;;
      "WARN "*) add_warning "${line#WARN }" ;;
    esac
  done < "$TMP/check.out"
}

# The plain text of a document, for the check. When it fails, WHY_NOT says why.
WHY_NOT=""
text_of() { # $1 = file, $2 = lower-case extension, $3 = where to write the text
  case "$2" in
    ""|txt|text|md|markdown|srt)
      is_utf8 "$1" || { WHY_NOT="the text isn't valid UTF-8"; return 1; }
      cp "$1" "$3" ;;
    docx|odt)
      textutil -convert txt -stdout "$1" > "$3" 2>/dev/null \
        || { WHY_NOT="textutil couldn't read the .$2 file"; return 1; } ;;
    html|htm)
      # textutil takes HTML that declares no character set for Latin-1, which
      # doubles the size of any other script and would set off false warnings
      if is_utf8 "$1"; then textutil -convert txt -stdout -inputencoding UTF-8 "$1" > "$3" 2>/dev/null
      else textutil -convert txt -stdout "$1" > "$3" 2>/dev/null; fi \
        || { WHY_NOT="textutil couldn't read the .$2 file"; return 1; } ;;
    *) WHY_NOT="no tool on this Mac reads the text of .$2 files"; return 1 ;;
  esac
}

# ------------------------------------------------------------ language detect
DETECTED=0
DETECT_CONFIDENCE=""
detect_lang() { # $1 = UTF-8 text file; sets FROM
  perl -CSD -e 'local $/; print substr(scalar <STDIN>, 0, 1500)' < "$1" > "$TMP/sample.txt"
  curl -fsS --max-time 120 --data-urlencode "q@$TMP/sample.txt" "$LT_URL/detect" > "$TMP/detect.json" 2>/dev/null \
    || die "no --from given, and LibreTranslate isn't reachable at $LT_URL to detect the language"
  FROM="$(plutil -extract 0.language raw -o - "$TMP/detect.json" 2>/dev/null)" \
    || die "couldn't detect the source language; pass --from"
  DETECT_CONFIDENCE="$(plutil -extract 0.confidence raw -o - "$TMP/detect.json" 2>/dev/null || true)"
  DETECTED=1
  info "    detected source language: $FROM (confidence ${DETECT_CONFIDENCE:-?})"
}

# --------------------------------------------------------------- gemma engine
cat > "$TMP/chunker.awk" <<'AWK'
# Split text into pieces of roughly `soft` bytes, breaking at paragraph breaks
# where possible, then line breaks, then sentence ends inside an over-long
# line. Writes chunk-NNNNN.txt files plus a `joins` file saying what separated
# each piece from the next (para, line, sent or end) so the translation can be
# stitched back together in the same shape.
BEGIN {
  # ASCII sentence punctuation, then CJK full stop / ! / ? / ;, Arabic ?, Urdu full stop
  SENT = "[.!?;][\"\047)]*[ \t]+|\343\200\202|\357\274\201|\357\274\237|\357\274\233|\330\237[ \t]*|\333\224[ \t]*"
}
function flush(join) {
  if (buf == "") return
  n++
  file = sprintf("%s/chunk-%05d.txt", dir, n)
  printf "%s", buf > file
  close(file)
  print join > (dir "/joins")
  buf = ""; size = 0
}
function add_long_line(text,    rest, s, pos, cut, e) {
  rest = text
  while (length(rest) > soft) {
    cut = 0; pos = 0; s = rest
    while (match(s, SENT)) {
      e = pos + RSTART + RLENGTH - 1
      if (e > hard) break
      cut = e
      if (cut >= soft) break
      pos = e; s = substr(rest, pos + 1)
    }
    if (cut == 0) {
      if (length(rest) <= hard) break
      bad = NR; exit
    }
    if (cut >= length(rest)) break
    buf = substr(rest, 1, cut); size = cut
    flush("sent")
    rest = substr(rest, cut + 1)
  }
  buf = rest "\n"; size = length(buf)
}
{
  if ($0 ~ /^[ \t]*$/) {
    if (buf != "") blank = 1
    if (blank && size >= soft) { flush("para"); blank = 0 }
    next
  }
  len = length($0)
  if (len > hard) {
    flush(blank ? "para" : "line"); blank = 0
    add_long_line($0)
    next
  }
  if (size > 0 && size + len + 1 > hard) { flush(blank ? "para" : "line"); blank = 0 }
  if (blank) { buf = buf "\n"; size++; blank = 0 }
  buf = buf $0 "\n"; size += len + 1
}
END {
  if (bad) { print bad > (dir "/too-long"); exit 3 }
  flush("end")
}
AWK

ENGINE_DIGEST=""
gemma_digest() { # sets ENGINE_DIGEST for $MODEL, or dies if it isn't installed
  curl -fsS --max-time 30 "$OLLAMA_API/api/tags" > "$TMP/tags.json" 2>/dev/null \
    || die "couldn't reach Ollama at $OLLAMA_API. Is the Ollama app open?"
  local i=0 name
  while name="$(plutil -extract "models.$i.name" raw -o - "$TMP/tags.json" 2>/dev/null)"; do
    if [ "$name" = "$MODEL" ]; then
      ENGINE_DIGEST="sha256:$(plutil -extract "models.$i.digest" raw -o - "$TMP/tags.json")"
      return 0
    fi
    i=$((i + 1))
  done
  die "the model '$MODEL' isn't installed in Ollama"
}

CHUNKS=0
gemma_translate() { # $1 = UTF-8 text file, $2 = output file; uses FROM, TO, MODEL
  local src="$1" out="$2" dir from_name to_name header total i join chunk code reason want got want_lines got_lines
  from_name="$(lang_name "$FROM")" || die "unknown source language code '$FROM' (see --languages)"
  to_name="$(lang_name "$TO")" || die "unknown target language code '$TO' (see --languages)"
  dir="$(mktemp -d "$TMP/chunks.XXXXXX")"

  if ! LC_ALL=C awk -v dir="$dir" -v soft="$SOFT" -v hard="$HARD" -f "$TMP/chunker.awk" "$src"; then
    [ -f "$dir/too-long" ] && die "line $(cat "$dir/too-long") of the text runs past $HARD bytes with no sentence break, too long to translate in one piece. Re-wrap it, or use --engine libre."
    die "couldn't split the text into pieces"
  fi
  [ -f "$dir/joins" ] || die "there is no text to translate"
  total="$(wc -l < "$dir/joins" | tr -d ' ')"

  header="You are a professional $from_name ($FROM) to $to_name ($TO) translator. Your goal is to accurately convey the meaning and nuances of the original $from_name text while adhering to $to_name grammar, vocabulary, and cultural sensitivities.
Produce only the $to_name translation, without any additional explanations or commentary. Please translate the following $from_name text into $to_name:"

  : > "$out"
  i=0
  while IFS= read -r join <&3; do
    i=$((i + 1))
    chunk="$(printf '%s/chunk-%05d.txt' "$dir" "$i")"
    [ "$total" -le 1 ] || info "    part $i of $total"
    {
      printf '{"model": "%s", "stream": false, "options": {"temperature": 0, "num_ctx": %d}, "prompt": "' \
        "$(json_str "$MODEL")" "$NUM_CTX"
      # the model expects two blank lines between the instruction and the text
      { printf '%s\n\n\n' "$header"; cat "$chunk"; } | json_escape
      printf '"}'
    } > "$dir/req.json"
    code="$(curl -sS --max-time 3600 -o "$dir/resp.json" -w '%{http_code}' \
      -H 'Content-Type: application/json' --data-binary "@$dir/req.json" \
      "$OLLAMA_API/api/generate")" \
      || die "couldn't reach Ollama at $OLLAMA_API. Is the Ollama app open?"
    [ "$code" = "200" ] \
      || die "Ollama returned HTTP $code: $(plutil -extract error raw -o - "$dir/resp.json" 2>/dev/null || cat "$dir/resp.json")"
    plutil -extract response raw -o - "$dir/resp.json" > "$dir/part.txt" 2>/dev/null \
      || die "couldn't read Ollama's reply for part $i"
    trim_blank < "$dir/part.txt" > "$dir/part.trimmed"
    [ -s "$dir/part.trimmed" ] || add_warning "part $i of $total came back empty"
    reason="$(plutil -extract done_reason raw -o - "$dir/resp.json" 2>/dev/null || echo unknown)"
    [ "$reason" = "stop" ] \
      || add_warning "part $i of $total stopped early (done_reason=$reason); its translation may be cut short"
    # A model can drop or merge text and still sound fluent. Paragraph counts
    # are a cheap signal that works for any language pair. Text saved from a
    # Word document has a paragraph on each line and no blank lines, and the
    # model may answer it with blank lines added, so equal line counts pass.
    # Paragraph counts say nothing about such text (it is one block, and so
    # is an answer that has lost a line), so they pass only a source that has
    # blank lines of its own, where the model re-wraps the lines between them.
    want="$(count_paras "$chunk")"; got="$(count_paras "$dir/part.trimmed")"
    want_lines="$(count_lines "$chunk")"; got_lines="$(count_lines "$dir/part.trimmed")"
    [ "$want_lines" = "$got_lines" ] \
      || { [ "$want" = "$got" ] && { [ "$want" -gt 1 ] || [ "$want_lines" -le 1 ]; }; } \
      || add_warning "part $i of $total: the source has $want paragraph(s) on $want_lines line(s) but the translation has $got on $got_lines; check it for missing or merged text"
    cat "$dir/part.trimmed" >> "$out"
    case "$join" in
      para) printf '\n\n' ;;
      sent) printf ' ' ;;
      *) printf '\n' ;;
    esac >> "$out"
  done 3< "$dir/joins"
  CHUNKS="$total"
}

# --------------------------------------------------------------- libre engine
libre_digest() { # sets ENGINE_DETAIL and ENGINE_DIGEST as best it can
  local version image
  # Not /spec, which reports the version: LibreTranslate 1.9.6 takes about
  # three times longer to answer it on each call, until its workers are all
  # tied up and nothing else gets through.
  curl -fsS --max-time 30 -o /dev/null "$LT_URL/languages" 2>/dev/null \
    || die "couldn't reach LibreTranslate at $LT_URL. Is Docker running?"
  # A Terminal opened before Docker was installed may not have docker on PATH.
  command -v docker >/dev/null 2>&1 \
    || PATH="$PATH:/usr/local/bin:/Applications/Docker.app/Contents/Resources/bin:$HOME/.docker/bin"
  # docker prints a blank line when the container doesn't exist, so test the value
  version="$(docker exec "$LT_CONTAINER" cat VERSION 2>/dev/null | head -1)" || version=""
  image="$(docker container inspect --format '{{.Config.Image}}' "$LT_CONTAINER" 2>/dev/null | head -1)" || image=""
  ENGINE_DIGEST="$(docker container inspect --format '{{.Image}}' "$LT_CONTAINER" 2>/dev/null | head -1)" || ENGINE_DIGEST=""
  ENGINE_DETAIL="LibreTranslate ${version:-unknown} (image ${image:-unknown})"
  ENGINE_DIGEST="${ENGINE_DIGEST:-unknown}"
}

libre_translate_file() { # $1 = file to upload, $2 = output file
  local src="$1" out="$2" ext upload code url
  ext="${src##*.}"
  # upload under a plain name: curl -F gives special meaning to , and ; in paths
  upload="$TMP/upload.$ext"
  cp "$src" "$upload"
  code="$(curl -sS --max-time 7200 -o "$TMP/lt.json" -w '%{http_code}' \
    -F "file=@$upload" --form-string "source=${FROM:-auto}" --form-string "target=$TO" \
    "$LT_URL/translate_file")" \
    || die "couldn't reach LibreTranslate at $LT_URL. Is Docker running?"
  [ "$code" = "200" ] \
    || die "LibreTranslate returned HTTP $code: $(plutil -extract error raw -o - "$TMP/lt.json" 2>/dev/null || cat "$TMP/lt.json")"
  url="$(plutil -extract translatedFileUrl raw -o - "$TMP/lt.json" 2>/dev/null)" \
    || die "LibreTranslate's reply had no download link"
  # re-root the link on LT_URL in case the server reports a different host
  curl -fsS --max-time 600 -o "$out" "$LT_URL/download_file/${url##*/download_file/}" \
    || die "couldn't download the translated file"
}

# ------------------------------------------------------------------ text mode
if [ "$HAVE_TEXT" = 1 ]; then
  ENGINE="${ENGINE:-gemma}"
  printf '%s\n' "$TEXT" > "$TMP/text.txt"
  if [ "$ENGINE" = "gemma" ]; then
    [ -n "$FROM" ] || detect_lang "$TMP/text.txt"
    gemma_digest
    gemma_translate "$TMP/text.txt" "$TMP/text.out"
    cat "$TMP/text.out"
    check_dropped "$TMP/text.txt" "$TMP/text.out" --no-struct
  else
    code="$(curl -sS --max-time 600 -o "$TMP/lt.json" -w '%{http_code}' \
      --data-urlencode "q@$TMP/text.txt" --data-urlencode "source=${FROM:-auto}" \
      --data-urlencode "target=$TO" -d "format=text" "$LT_URL/translate")" \
      || die "couldn't reach LibreTranslate at $LT_URL. Is Docker running?"
    [ "$code" = "200" ] \
      || die "LibreTranslate returned HTTP $code: $(plutil -extract error raw -o - "$TMP/lt.json" 2>/dev/null || cat "$TMP/lt.json")"
    plutil -extract translatedText raw -o - "$TMP/lt.json" > "$TMP/text.out"
    cat "$TMP/text.out"
    check_dropped "$TMP/text.txt" "$TMP/text.out"
  fi
  exit 0
fi

# ------------------------------------------------------------------ file mode
is_text_ext() { case "$1" in txt|text|md|markdown) return 0 ;; *) return 1 ;; esac; }

already_done() { # $1 = sidecar; true if it records this exact source, engine and language pair
  [ -f "$1" ] \
    && grep -qF "\"source_sha256\": \"$SRC_SHA\"" "$1" \
    && grep -qF "\"engine_digest\": \"$(json_str "$ENGINE_DIGEST")\"" "$1" \
    && grep -qF "\"source_lang\": \"$(json_str "$SRC_LANG")\"" "$1" \
    && grep -qF "\"target_lang\": \"$(json_str "$TO")\"" "$1"
}

FROM_ARG="$FROM"
for FILE in "${FILES[@]}"; do
  [ -f "$FILE" ] || die "not a file: $FILE"
  FROM="$FROM_ARG"; DETECTED=0; DETECT_CONFIDENCE=""; WARNINGS=""; CHUNKS=0
  SRC_ABS="$(cd "$(dirname "$FILE")" && pwd -P)/$(basename "$FILE")"
  BASE="$(basename "$FILE")"
  case "$BASE" in
    *.*) STEM="${BASE%.*}"; EXT="${BASE##*.}" ;;
    *) STEM="$BASE"; EXT="" ;;
  esac
  EXT_LC="$(printf '%s' "$EXT" | tr '[:upper:]' '[:lower:]')"

  FILE_ENGINE="$ENGINE"
  if [ -z "$FILE_ENGINE" ]; then
    if is_text_ext "$EXT_LC" || [ -z "$EXT" ]; then FILE_ENGINE="gemma"; else FILE_ENGINE="libre"; fi
  fi
  IS_TEXT=0
  if is_text_ext "$EXT_LC" || [ -z "$EXT" ]; then IS_TEXT=1; fi
  if [ "$FILE_ENGINE" = "gemma" ] && [ "$IS_TEXT" = 0 ]; then
    die "$BASE: the gemma engine reads plain text only. Use --engine libre, or save the text as .txt first."
  fi

  info "$BASE  [$FILE_ENGINE]"
  SRC_SHA="$(shasum -a 256 "$FILE" | awk '{print $1}')"

  # Plain text has to be UTF-8 for either engine. Convert a copy, never the original.
  INPUT="$FILE"
  SRC_ENCODING="n/a"
  if [ "$IS_TEXT" = 1 ]; then
    if [ -n "$ENCODING" ]; then
      to_utf8 "$ENCODING" "$FILE" > "$TMP/input.${EXT_LC:-txt}" \
        || die "$BASE: couldn't convert from $ENCODING (unknown encoding name, or the file isn't in it)"
      INPUT="$TMP/input.${EXT_LC:-txt}"
      SRC_ENCODING="$ENCODING"
    else
      is_utf8 "$FILE" \
        || die "$BASE isn't valid UTF-8. Pass --encoding, e.g. CP1251 (Russian), CP1255 (Hebrew), CP1256 (Arabic), GBK or Big5 (Chinese), or UTF-16."
      SRC_ENCODING="UTF-8"
    fi
    # Text saved on Windows ends its lines with a carriage return, which would
    # hide every paragraph break from the splitter.
    clean_text < "$INPUT" > "$TMP/clean.${EXT_LC:-txt}"
    INPUT="$TMP/clean.${EXT_LC:-txt}"
  fi

  if [ "$FILE_ENGINE" = "gemma" ]; then
    [ -n "$FROM" ] || detect_lang "$INPUT"
    SRC_LANG="$FROM"
    gemma_digest
    ENGINE_DETAIL="$MODEL via Ollama"
    ENGINE_OPTIONS="temperature=0 num_ctx=$NUM_CTX piece_bytes=$SOFT-$HARD"
  else
    SRC_LANG="${FROM:-auto}"
    libre_digest
    ENGINE_OPTIONS=""
  fi

  DEST_DIR="${OUT_DIR:-$(dirname "$SRC_ABS")}"
  mkdir -p "$DEST_DIR"
  OUT="$DEST_DIR/$STEM.$TO.$FILE_ENGINE${EXT:+.$EXT}"
  if [ "$FORCE" = 0 ] && already_done "$OUT.provenance.json"; then
    info "    already translated with this engine, source unchanged: $OUT"
    continue
  fi
  if [ -e "$OUT" ] || [ -e "$OUT.provenance.json" ]; then
    STAMP="$(date -u +%Y%m%dT%H%M%SZ)"; SERIAL=1
    OUT="$DEST_DIR/$STEM.$TO.$FILE_ENGINE.$STAMP${EXT:+.$EXT}"
    # two runs inside the same second must not share a name either
    while [ -e "$OUT" ] || [ -e "$OUT.provenance.json" ]; do
      SERIAL=$((SERIAL + 1))
      OUT="$DEST_DIR/$STEM.$TO.$FILE_ENGINE.$STAMP-$SERIAL${EXT:+.$EXT}"
    done
  fi

  WORK_OUT="$TMP/result"
  if [ "$FILE_ENGINE" = "gemma" ]; then
    gemma_translate "$INPUT" "$WORK_OUT"
  else
    if [ "$INPUT" = "$FILE" ]; then libre_translate_file "$FILE" "$WORK_OUT"
    else libre_translate_file "$INPUT" "$WORK_OUT"; fi
  fi
  [ -s "$WORK_OUT" ] || die "$BASE: the translation came back empty"
  mv "$WORK_OUT" "$OUT"

  CHECK_STATUS="not run"
  if [ "$FILE_ENGINE" = "gemma" ]; then
    # gemma_translate has already compared paragraph counts piece by piece
    check_dropped "$INPUT" "$OUT" --no-struct
  elif text_of "$INPUT" "$EXT_LC" "$TMP/check-src.txt" && text_of "$OUT" "$EXT_LC" "$TMP/check-out.txt"; then
    if [ "$IS_TEXT" = 1 ] || [ "$EXT_LC" = "srt" ]; then
      check_dropped "$TMP/check-src.txt" "$TMP/check-out.txt"
    else
      check_dropped "$TMP/check-src.txt" "$TMP/check-out.txt" --unit paragraph
    fi
  else
    CHECK_STATUS="not checked: $WHY_NOT"
  fi
  info "    dropped-text check: $CHECK_STATUS"

  {
    printf '{\n'
    printf '  "tool": "airgapped-translation translate.sh v%s",\n' "$VERSION"
    printf '  "translated_at_utc": "%s",\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '  "source_file": "%s",\n' "$(json_str "$SRC_ABS")"
    printf '  "source_sha256": "%s",\n' "$SRC_SHA"
    printf '  "source_encoding": "%s",\n' "$(json_str "$SRC_ENCODING")"
    printf '  "source_lang": "%s",\n' "$(json_str "$SRC_LANG")"
    printf '  "source_lang_detected": %s,\n' "$([ "$DETECTED" = 1 ] && echo true || echo false)"
    printf '  "source_lang_confidence": "%s",\n' "$(json_str "$DETECT_CONFIDENCE")"
    printf '  "target_lang": "%s",\n' "$(json_str "$TO")"
    printf '  "engine": "%s",\n' "$FILE_ENGINE"
    printf '  "engine_detail": "%s",\n' "$(json_str "$ENGINE_DETAIL")"
    printf '  "engine_digest": "%s",\n' "$(json_str "$ENGINE_DIGEST")"
    printf '  "engine_options": "%s",\n' "$(json_str "$ENGINE_OPTIONS")"
    printf '  "pieces": %s,\n' "$CHUNKS"
    printf '  "output_file": "%s",\n' "$(json_str "$(basename "$OUT")")"
    printf '  "output_sha256": "%s",\n' "$(shasum -a 256 "$OUT" | awk '{print $1}')"
    printf '  "dropped_text_check": "%s",\n' "$(json_str "$CHECK_STATUS")"
    printf '  "warnings": [%s]\n' "$WARNINGS"
    printf '}\n'
  } > "$OUT.provenance.json"
  info "    wrote $OUT"
  [ -z "$WARNINGS" ] || info "    warnings were recorded in $(basename "$OUT").provenance.json"
done
