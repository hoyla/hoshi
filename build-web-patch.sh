#!/bin/bash
# Build the small update that puts the translation web page on a Mac where a
# bundle is already installed: a newer page than the bundle carried, or the
# page itself if the bundle had none. A few hundred kilobytes: the page runs
# on the LibreTranslate image and the models that Mac already has.
#
#   ./build-web-patch.sh [--out DIR] [--allow-dirty]

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
OUT=""
ALLOW_DIRTY=0

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:?}"; shift 2 ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

# Which version of these files the update is built from, as build-bundle.sh records it.
SOURCE_COMMIT="$(git -C "$HERE" rev-parse --verify -q HEAD 2>/dev/null || echo unknown)"
SOURCE_CHANGES="$(git -C "$HERE" status --porcelain -- "$HERE" 2>/dev/null | sed 's/^/    /')"
if [ -n "$SOURCE_CHANGES" ] && [ "$ALLOW_DIRTY" = 0 ]; then
  die "these files differ from the last commit, so the update couldn't say what it was built from:
$SOURCE_CHANGES
       Commit them, or pass --allow-dirty to build anyway and have it say so."
fi

# The page must cut text into pieces exactly as translate.sh does.
python3 "$HERE/web/tests/test_parity.py" || die "web/gemma.py and bundle/translate.sh disagree; not building"

BUILT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
[ -n "$OUT" ] || OUT="$HERE/dist/translation-web-$(date -u +%Y%m%d-%H%M)"
[ ! -e "$OUT" ] || die "$OUT already exists"
mkdir -p "$OUT"

. "$HERE/web/assemble.sh"
assemble_web "$HERE" "$OUT" "built $BUILT from commit $SOURCE_COMMIT${SOURCE_CHANGES:+ plus uncommitted changes}"
cp "$HERE/LICENSE" "$OUT/LICENSE.txt"
cp "$HERE/NOTICE" "$OUT/NOTICE.txt"

cat > "$OUT/README.txt" <<TXT
TRANSLATION WEB PAGE: an update for the offline translation bundle
Built $BUILT from commit $SOURCE_COMMIT${SOURCE_CHANGES:+ plus uncommitted changes}

This puts the translation page on a Mac where the offline translation bundle
is ALREADY installed. It replaces the page the bundle's installer started,
or adds the page if that bundle had none. It is small because it uses the
LibreTranslate image and the TranslateGemma models that Mac already has.
Nothing here changes those, the translate.sh helper, or any translation.

TO INSTALL
  1. Copy this whole folder to the Mac.
  2. Make sure Docker Desktop and Ollama are running.
  3. Open Terminal, type   cd   and a space, drag this folder onto the
     Terminal window, press Return. Then run:

         bash install-web.sh

  It ends with "==> Done" and opens the page: http://127.0.0.1:5080

USING IT
  Choose a document or paste text, choose TranslateGemma or LibreTranslate,
  choose the languages, press Translate. The page says what each engine is
  good and bad at for the document you chose.

  The page compares each translation with its original and warns when a
  paragraph came out much shorter or longer than it should, which is how
  dropped text shows. It cannot do this for .pdf, .pptx, .odp or .epub files
  translated by LibreTranslate. A translation with no warnings can still be
  wrong.

  Translations are saved in   ~/translation-tools/translations   each with
  a .provenance.json file recording how it was made. With TranslateGemma the
  exact text taken out of the document and sent to the model is saved beside
  the translation. The document you chose is not copied there; the
  provenance file records its name and SHA-256.

  The page answers only on this Mac (127.0.0.1). Other computers can't
  reach it.

IF THE PAGE IS ALREADY INSTALLED
  Install this one the same way; it replaces the page and keeps the
  translations.

IF THIS MAC ALSO HAS LIBRETRANSLATE'S OWN PAGE
  A Mac whose bundle had no translation page has LibreTranslate's own at
  http://127.0.0.1:5050, and this update leaves it there. That page keeps
  no record of a translation and makes no check of one, so use this one.

TO REMOVE IT
  docker rm -f translation-web
  Translations already made stay where they are.

Run   bash install-web.sh --help   for options (port, folder).
A log of each run is kept in ~/translation-tools/install-web-*.log

WHO MADE THIS
  The page is part of Hoshi, https://github.com/hoyla/hoshi, which is free
  software under the GNU Affero General Public License, version 3
  (LICENSE.txt). NOTICE.txt says whose work the translation engines and the
  libraries the page uses are. Hoshi is not officially associated with
  LibreTranslate or its products.
TXT

(cd "$OUT" && find . -type f ! -name SHA256SUMS ! -name .DS_Store ! -name '._*' -print0 \
  | LC_ALL=C sort -z | xargs -0 shasum -a 256 > SHA256SUMS)

echo "Built $OUT ($(du -sh "$OUT" | awk '{print $1}'))"
[ -z "$SOURCE_CHANGES" ] || echo "note: built from uncommitted changes; web/BUILD says so"
