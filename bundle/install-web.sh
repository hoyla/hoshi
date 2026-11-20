#!/bin/bash
# Start the translation web page on a Mac where the offline translation bundle
# is installed. The bundle's install.sh runs this as its last step; it is also
# run by hand from a page update, the small folder build-web-patch.sh makes.
#
# The page runs in a second container made from the LibreTranslate image that
# is already in Docker, with the files in web/ handed to it from the Mac. So
# this needs nothing large: no image, no models. Safe to re-run: it replaces
# the page's files and its container, and never touches a translation or the
# LibreTranslate container.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"

PORT=5080
NAME="translation-web"
PREFIX="$HOME/translation-tools"
FOLDER=""
DOCKER_APP="/Applications/Docker.app"
DO_VERIFY=1
DO_OPEN=1
STANDALONE=1

usage() {
  cat <<EOF
Usage: ./install-web.sh [options]

  --port N         Local port for the page (default: $PORT)
  --name NAME      Docker container name (default: $NAME)
  --prefix DIR     Where the bundle's installer put translate.sh (default: $PREFIX)
  --folder DIR     Where the page saves translations (default: PREFIX/translations)
  --skip-verify    Don't check the files' checksums first
  --no-open        Don't open the page in a browser at the end
  --part-of-install
                   Leave the closing summary and the opening of the page to
                   install.sh, which passes this
  -h, --help       Show this help
EOF
}

say() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
cfg() { sed -n "s/^$1=//p" "$PREFIX/bundle.env" | head -1; }

ORIG_ARGS=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:?}"; shift 2 ;;
    --name) NAME="${2:?}"; shift 2 ;;
    --prefix) PREFIX="${2:?}"; shift 2 ;;
    --folder) FOLDER="${2:?}"; shift 2 ;;
    --skip-verify) DO_VERIFY=0; shift ;;
    --no-open) DO_OPEN=0; shift ;;
    --part-of-install) STANDALONE=0; DO_OPEN=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "this installer is for Macs"
[ -f "$HERE/web/app.py" ] || die "web/app.py not found; run this from inside the folder it came in"
[ -f "$PREFIX/bundle.env" ] \
  || die "the offline translation bundle isn't installed in $PREFIX. Run the bundle's install.sh first, or pass --prefix."
[ -n "$FOLDER" ] || FOLDER="$PREFIX/translations"

# Keep a record of the run, as install.sh does. A new file each run.
if [ -z "${TRANSLATION_INSTALL_LOG:-}" ]; then
  TRANSLATION_INSTALL_LOG="$PREFIX/install-web-$(date -u +%Y%m%dT%H%M%SZ).log"
  export TRANSLATION_INSTALL_LOG
  set +e
  bash "$0" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"} 2>&1 | tee "$TRANSLATION_INSTALL_LOG"
  exit "${PIPESTATUS[0]}"
fi

BUILD="$(cat "$HERE/web/BUILD" 2>/dev/null || echo "not recorded")"
if [ "$STANDALONE" = 1 ]; then
  say "Translation web page installer"
  note "started $(date -u +%Y-%m-%dT%H:%M:%SZ), options: ${ORIG_ARGS[*]:-none}"
  note "page files: $BUILD"
  note "log: $TRANSLATION_INSTALL_LOG"
else
  say "Installing the translation page"
  note "page files: $BUILD"
fi

IMAGE="$(cfg LT_IMAGE)"
IMAGE_ID="$(cfg LT_IMAGE_ID_INSTALLED)"
LT_CONTAINER="$(cfg LT_CONTAINER)"
LT_CONTAINER="${LT_CONTAINER:-libretranslate}"
LT_URL="$(cfg LT_URL)"
[ -n "$IMAGE" ] && [ -n "$LT_URL" ] \
  || die "$PREFIX/bundle.env doesn't say which LibreTranslate image is installed. The page needs it: re-run the bundle's install.sh without --no-docker."
case "$IMAGE_ID" in
  sha256:?*) ;;
  *) die "$PREFIX/bundle.env has no installed image ID. Re-run the bundle's install.sh without --no-docker before installing the page." ;;
esac
OLLAMA_ADDRESS="${OLLAMA_HOST:-127.0.0.1:11434}"
URL="http://127.0.0.1:$PORT"

# ---------------------------------------------------------------- checksums
if [ "$DO_VERIFY" = 1 ]; then
  say "Verifying the page's files"
  [ -f "$HERE/SHA256SUMS" ] || die "SHA256SUMS not found beside this script; pass --skip-verify to install anyway"
  grep -qF "  ./web/app.py" "$HERE/SHA256SUMS" || die "SHA256SUMS doesn't list the page's files"
  (cd "$HERE" && grep -F "  ./web/" SHA256SUMS | shasum -a 256 --quiet -c -) \
    || die "checksum verification failed: the files were damaged or changed in transit"
  note "all files match SHA256SUMS"
fi

# -------------------------------------------------------------------- Docker
if ! command -v docker >/dev/null 2>&1; then
  for dir in /usr/local/bin "$DOCKER_APP/Contents/Resources/bin" "$HOME/.docker/bin"; do
    if [ -x "$dir/docker" ]; then PATH="$PATH:$dir"; break; fi
  done
fi
command -v docker >/dev/null 2>&1 || die "the docker command wasn't found. Run the bundle's install.sh first."
if ! docker info >/dev/null 2>&1; then
  say "Starting Docker Desktop"
  open -a "$DOCKER_APP" || die "Docker isn't running and couldn't be opened. Start it and re-run."
  note "Waiting for Docker to be ready (up to 5 minutes)"
  UP=0
  for _ in $(seq 1 150); do
    if docker info >/dev/null 2>&1; then UP=1; break; fi
    sleep 2
  done
  [ "$UP" = 1 ] || die "Docker didn't become ready. Open Docker from Applications, wait until it says it is running, then re-run."
fi
# A build can move the tag to an image with other language models. Use the
# installed ID even if its tag has moved or disappeared; never fall back to it.
docker image inspect "$IMAGE_ID" >/dev/null 2>&1 \
  || die "Docker here has no image with the installed ID $IMAGE_ID ($IMAGE). Re-run the bundle's install.sh first."
SERVICE_IMAGE_ID="$(docker container inspect --format '{{.Image}}' "$LT_CONTAINER" 2>/dev/null || true)"
if [ -n "$SERVICE_IMAGE_ID" ] && [ "$SERVICE_IMAGE_ID" != "$IMAGE_ID" ]; then
  die "LibreTranslate container '$LT_CONTAINER' uses a different image ($SERVICE_IMAGE_ID) from the installed ID ($IMAGE_ID). Re-run the bundle's install.sh, then install the page again."
fi

if docker container inspect "$NAME" >/dev/null 2>&1; then
  OURS="$(docker container inspect --format '{{index .Config.Labels "airgapped-translation"}}' "$NAME")"
  [ "$OURS" = "1" ] \
    || die "a container named '$NAME' exists that this installer didn't create; remove it or pass --name"
  note "replacing the '$NAME' container from an earlier install"
  docker rm -f "$NAME" >/dev/null \
    || die "Docker couldn't remove the '$NAME' container from the earlier install; its message is above. Quit Docker Desktop, open it again, wait until it says it is running, then run this again."
fi
if nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; then
  die "port $PORT is already in use; pass --port with a free one"
fi

# ---------------------------------------------------------------- the files
if [ "$HERE/web" != "$PREFIX/web" ]; then
  say "Copying the page into $PREFIX/web"
  mkdir -p "$PREFIX/web" && ditto "$HERE/web" "$PREFIX/web" \
    || die "couldn't copy the page's files into $PREFIX/web; the message above says why. If the disk is full, free some space, then run this again."
fi
mkdir -p "$FOLDER" || die "couldn't create $FOLDER, where the page saves translations; pass --folder with a folder you can write to"
FOLDER="$(cd "$FOLDER" && pwd -P)"

# ---------------------------------------------------------------- container
# The page's files and the language list are handed over read-only; the only
# place on the Mac it can write is the translations folder. Documents being
# translated are held in memory (/uploads), not on disk. Like LibreTranslate,
# it answers on this Mac only.
say "Starting the page on $URL"
docker run -d --name "$NAME" --label airgapped-translation=1 \
  --pull never \
  --restart unless-stopped -p "127.0.0.1:$PORT:8080" \
  -v "$PREFIX/web:/opt/translation-web:ro" \
  -v "$PREFIX/languages.tsv:/opt/languages.tsv:ro" \
  -v "$FOLDER:/data" \
  --tmpfs /uploads:rw,mode=1777 \
  -e PYTHONDONTWRITEBYTECODE=1 \
  -e LANGFILE=/opt/languages.tsv \
  -e DATA_DIR=/data -e HOST_DATA_DIR="$FOLDER" -e UPLOAD_DIR=/uploads \
  -e HOST_OS=mac \
  -e LT_URL="http://host.docker.internal:${LT_URL##*:}" \
  -e OLLAMA_API="http://host.docker.internal:${OLLAMA_ADDRESS##*:}" \
  -e LT_IMAGE="$IMAGE" -e LT_IMAGE_ID="$IMAGE_ID" \
  -e GEMMA_MODELS="$(cfg GEMMA_MODELS)" -e DEFAULT_MODEL="$(cfg DEFAULT_MODEL)" \
  --entrypoint /app/venv/bin/python "$IMAGE_ID" -u /opt/translation-web/app.py >/dev/null \
  || die "Docker couldn't start the page; its message is above. If it speaks of a port, pass --port with a free one. If it speaks of a folder it may not share, allow $PREFIX in Docker Desktop under Settings > Resources > File sharing. Then run this again."

CONFIG=""
for _ in $(seq 1 30); do
  if CONFIG="$(curl -fsS "$URL/api/config" 2>/dev/null)"; then break; fi
  sleep 1
done
[ -n "$CONFIG" ] || { docker logs "$NAME" 2>&1 | tail -30 >&2; die "the page did not start; log above"; }
# Where the page is, for "Start Translation" to find after a restart.
SETTINGS="$(grep -v -e '^WEB_URL=' -e '^WEB_CONTAINER=' "$PREFIX/bundle.env" || true)"
printf '%s\nWEB_URL=%s\nWEB_CONTAINER=%s\n' "$SETTINGS" "$URL" "$NAME" > "$PREFIX/bundle.env" \
  || die "couldn't record the page's address in $PREFIX/bundle.env"
[ "$STANDALONE" = 1 ] || exit 0

engine() { # $1 = gemma or libre: whether the page can reach it
  if [ "$(printf '%s' "$CONFIG" | plutil -extract "$1.ok" raw -o - - 2>/dev/null)" = "true" ]; then
    echo "ready"
  else
    echo "NOT answering. The page will say so; start it and reload the page"
  fi
}
GEMMA_STATE="$(engine gemma)"
LIBRE_STATE="$(engine libre)"

say "Done"
cat <<EOF

  Translation page  $URL
  TranslateGemma    $GEMMA_STATE
  LibreTranslate    $LIBRE_STATE
  Translations in   $FOLDER
  Log of this run   $TRANSLATION_INSTALL_LOG

  The page starts with Docker Desktop. To remove it:  docker rm -f $NAME
EOF
if [ "$DO_OPEN" = 1 ]; then open "$URL" || true; fi
