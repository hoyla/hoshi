#!/bin/bash
# Build an offline translation bundle on an internet-connected Apple Silicon Mac.
#
# The result is one folder to copy to an airgapped Apple Silicon Mac or Windows
# PC. A Windows PC needs Docker Desktop already; a Mac without it gets the
# copy carried here:
#   - LibreTranslate as a Docker image with its language models baked in, one
#     image per processor type the targets need
#   - Ollama (the Mac app, the Windows installer, or both) plus a TranslateGemma
#     model, run natively because Docker gives it no GPU on a Mac and none
#     without extra setup on Windows
#   - Docker Desktop's own installer for Macs
#   - an installer and a translate helper for each target, the translation
#     web page, a manifest of exactly what was bundled, and checksums for
#     every file
#
# Re-running into the same --out folder resumes: Docker layers are cached and
# the model pull picks up where it stopped.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"

# Pinned versions. Bump deliberately, then rebuild.
LT_VERSION="v1.9.6"
OLLAMA_VERSION="v0.40.16"
# sha256 of Ollama-darwin.zip and OllamaSetup.exe for OLLAMA_VERSION, as
# published in the GitHub release (sha256sum.txt).
OLLAMA_ZIP_SHA256="4715531bc49d21337381b193765041e535a9fb4716f84e5d6eccc3a9af1b5303"
OLLAMA_SETUP_SHA256="84db4f756ddc9e091142a85cdc0f7ae5db68bc9b3e075f114388b326f8ed912d"
# Docker Desktop for Apple Silicon. The build number is the folder in its
# download address (desktop.docker.com/mac/main/arm64/BUILD/Docker.dmg), and
# the sha256 is the one in checksums.txt in that folder.
DOCKER_DESKTOP_VERSION="4.99.0"
DOCKER_DESKTOP_BUILD="245822"
DOCKER_DMG_SHA256="0ede7f9917b55c396a17b03c069cadf457a7d21904bc264c6d398fe132da7fb9"

TARGETS="mac,windows"       # which machines the bundle installs on
# Comma-separated; the first is the default for the helper and the page. 4b is
# the smaller one, for computers where 12b is slow.
MODELS="translategemma:12b,translategemma:4b"
LANGS=""                    # LibreTranslate language codes; empty = all
OUT=""
WITH_DOCKER_DESKTOP=1       # carry Docker Desktop's installer for Macs that lack it
ALLOW_DIRTY=0               # build from files that differ from the last commit
SUPPORT=""                  # who to ask for help; the installers print it when they fail
PULL_PORT=11535             # private port, so a running Ollama on 11434 is left alone
DOCKER_NEED_GB=12           # free space inside Docker's own disk to bake every language,
                            # per image (measured: an image adds 9.6 GiB and there is no higher peak)
DOCKER_NEED_GB_CONTAINERD=30 # the same under Docker's containerd image store, which keeps
                            # that layer unpacked twice and compressed once (27.6 GiB)

usage() {
  cat <<EOF
Usage: ./build-bundle.sh [options]

  --targets LIST       Machines the bundle installs on: mac, windows, or both
                       (default: $TARGETS). Each one adds a LibreTranslate
                       image of 9 to 11 GB; the TranslateGemma models are shared.
  --langs CODES        LibreTranslate languages to include, e.g. en,ru,fr,zh,he,ar
                       (default: all, about 8.4 GB per image)
  --model NAMES        Ollama model(s), comma-separated (default: $MODELS)
  --out DIR            Output folder (default: dist/translation-bundle-YYYYMMDD)
  --lt-version TAG     LibreTranslate image tag (default: $LT_VERSION)
  --ollama-version TAG Ollama release tag (default: $OLLAMA_VERSION);
                       needs the sha256 option(s) below as well
  --ollama-sha256 HEX  sha256 of that release's Ollama-darwin.zip
  --ollama-setup-sha256 HEX
                       sha256 of that release's OllamaSetup.exe (windows target)
  --no-docker-desktop  Leave out Docker Desktop's installer (0.6 GB, mac target).
                       Every target Mac must then have Docker already.
  --allow-dirty        Build even if files here differ from the last git commit.
                       The manifest then says so.
  --support "TEXT"     Who the people installing should ask for help, on one
                       line, e.g. "Sam Lee, sam@example.org, 020 7946 0000".
                       The installers print it when an install fails.
                       Default: no such line.
  -h, --help           Show this help
EOF
}

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
# Gives a file its own Finder icon, kept in the file's metadata: its bytes,
# and so its checksum, are unchanged. A copy to an exFAT drive keeps the icon
# in the hidden ._ file macOS writes beside it there; a copy that drops those
# (from Windows, say) shows the ordinary icon instead, and nothing else changes.
set_finder_icon() { # $1 = .icns file, $2 = the file to give it to
  osascript -l JavaScript - "$1" "$2" >/dev/null <<'JS'
  ObjC.import('AppKit');
  function run(argv) {
    var image = $.NSImage.alloc.initWithContentsOfFile(argv[0]);
    if (image.isNil() || !$.NSWorkspace.sharedWorkspace.setIconForFileOptions(image, argv[1], 0)) {
      throw new Error('could not set the icon');
    }
  }
JS
}

OLLAMA_VERSION_OVERRIDDEN=0
OLLAMA_SHA_GIVEN=0
OLLAMA_SETUP_SHA_GIVEN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --targets) TARGETS="${2:?}"; shift 2 ;;
    --langs) LANGS="${2:?}"; shift 2 ;;
    --model) MODELS="${2:?}"; shift 2 ;;
    --out) OUT="${2:?}"; shift 2 ;;
    --lt-version) LT_VERSION="${2:?}"; shift 2 ;;
    --ollama-version) OLLAMA_VERSION="${2:?}"; OLLAMA_VERSION_OVERRIDDEN=1; shift 2 ;;
    --ollama-sha256) OLLAMA_ZIP_SHA256="${2:?}"; OLLAMA_SHA_GIVEN=1; shift 2 ;;
    --ollama-setup-sha256) OLLAMA_SETUP_SHA256="${2:?}"; OLLAMA_SETUP_SHA_GIVEN=1; shift 2 ;;
    --no-docker-desktop) WITH_DOCKER_DESKTOP=0; shift ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    --support) SUPPORT="${2:?}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

case "$SUPPORT" in *$'\n'*|*$'\r'*) die "--support takes one line of text" ;; esac

WANT_MAC=0
WANT_WINDOWS=0
OLD_IFS="$IFS"; IFS=','
for target in $TARGETS; do
  case "$target" in
    mac) WANT_MAC=1 ;;
    windows) WANT_WINDOWS=1 ;;
    *) die "unknown target '$target'; --targets takes mac, windows or mac,windows" ;;
  esac
done
IFS="$OLD_IFS"
# Docker runs Linux for the machine's own processor: ARM on an Apple Silicon
# Mac, Intel/AMD on nearly every Windows PC. A Windows PC with an ARM processor
# uses the Mac's image, so only a bundle built for both targets covers one.
TARGETS=""
ARCHES=""
if [ "$WANT_MAC" = 1 ]; then TARGETS="mac"; ARCHES="arm64"; fi
if [ "$WANT_WINDOWS" = 1 ]; then TARGETS="${TARGETS:+$TARGETS,}windows"; ARCHES="${ARCHES:+$ARCHES }amd64"; fi
[ -n "$TARGETS" ] || die "--targets needs mac, windows or mac,windows"

# The Mac zip is always needed: its ollama is what fetches the models here.
if [ "$OLLAMA_VERSION_OVERRIDDEN" = 1 ] && [ "$OLLAMA_SHA_GIVEN" = 0 ]; then
  die "--ollama-version needs --ollama-sha256 (the digest of Ollama-darwin.zip on that release's GitHub page)"
fi
if [ "$OLLAMA_VERSION_OVERRIDDEN" = 1 ] && [ "$WANT_WINDOWS" = 1 ] && [ "$OLLAMA_SETUP_SHA_GIVEN" = 0 ]; then
  die "--ollama-version needs --ollama-setup-sha256 too (the digest of OllamaSetup.exe on that release's GitHub page), or --targets mac"
fi

# ---------------------------------------------------------------- preflight
[ "$(uname -s)" = "Darwin" ] && [ "$(uname -m)" = "arm64" ] \
  || die "build on an Apple Silicon Mac: the build relies on macOS tools and on the Mac version of Ollama"
for tool in docker curl shasum ditto codesign spctl plutil nc perl hdiutil; do
  command -v "$tool" >/dev/null 2>&1 || die "missing required tool: $tool"
done
docker info >/dev/null 2>&1 || die "Docker isn't running. Start Docker Desktop and try again."
# The web page every bundle carries must cut text into pieces exactly as
# translate.sh does.
command -v python3 >/dev/null 2>&1 || die "missing required tool: python3 (it runs the web page's test)"
python3 "$HERE/web/tests/test_parity.py" || die "web/gemma.py and bundle/translate.sh disagree; not building"

# Which version of these scripts the bundle is built from, for the manifest. A
# bundle built from files that differ from the commit can't be traced to them.
SOURCE_COMMIT=""
SOURCE_REPO=""
SOURCE_CHANGES=""
if SOURCE_COMMIT="$(git -C "$HERE" rev-parse HEAD 2>/dev/null)"; then
  SOURCE_REPO="$(git -C "$HERE" config --get remote.origin.url || true)"
  SOURCE_CHANGES="$(git -C "$HERE" status --porcelain -- "$HERE" | sed 's/^/    /')"
  if [ -n "$SOURCE_CHANGES" ] && [ "$ALLOW_DIRTY" = 0 ]; then
    die "these files differ from the last commit, so the manifest couldn't say what the bundle was built from:
$SOURCE_CHANGES
       Commit them, or pass --allow-dirty to build anyway and have the manifest say so."
  fi
else
  SOURCE_COMMIT=""
fi

[ -n "$OUT" ] || OUT="$HERE/dist/translation-bundle-$(date -u +%Y%m%d)"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"
if [ -n "$(ls -A "$OUT")" ] && [ ! -f "$OUT/bundle.env" ]; then
  die "$OUT is not empty and is not a bundle folder; choose another --out"
fi
mkdir -p "$OUT/docker" "$OUT/ollama/models"
CACHE="$HERE/.cache"
mkdir -p "$CACHE"

WORK="$(mktemp -d)"
SERVE_PID=""
SELFTEST_CONTAINER=""
DMG_MOUNT=""
cleanup() {
  [ -z "$SERVE_PID" ] || kill "$SERVE_PID" 2>/dev/null || true
  [ -z "$SELFTEST_CONTAINER" ] || docker rm -f "$SELFTEST_CONTAINER" >/dev/null 2>&1 || true
  [ -z "$DMG_MOUNT" ] || hdiutil detach -force "$DMG_MOUNT" >/dev/null 2>&1 || true
  rm -rf "$WORK"
}
trap cleanup EXIT

# Build from a copy of the scripts taken now, so the bundle matches the commit
# read above even if the checkout changes during the hour the build can take.
SRC="$WORK/src"
mkdir "$SRC"
cp -R "$HERE/bundle" "$HERE/web" "$HERE/Dockerfile" "$HERE/LICENSE" "$HERE/NOTICE" "$SRC/"
. "$SRC/web/assemble.sh"

BUILT_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Mark the folder as a bundle straight away so an interrupted build can resume.
printf 'BUNDLE_BUILT_UTC=%s\n' "$BUILT_UTC" > "$OUT/bundle.env"

# A folder that already holds a bundle would keep that bundle's installers,
# guide, manifest and checksums until the last step replaces them, describing
# files this build has since changed. Take them out now and say why.
rm -f "$OUT/MANIFEST.txt" "$OUT/SHA256SUMS" "$OUT/README.txt" "$OUT/languages.tsv" \
  "$OUT/LICENSE.txt" "$OUT/NOTICE.txt" "$OUT"/install.* "$OUT"/install-web.* "$OUT"/translate.* \
  "$OUT/Install.command" "$OUT/Start Translation.command" "$OUT/Start Translation.cmd" \
  "$OUT/start-translation.ps1" "$OUT/Hoshi Offline Translation.applescript"
rm -rf "$OUT/test-files" "$OUT/licences" "$OUT/web" "$OUT/icons"
mkdir "$OUT/licences"
UNFINISHED="$OUT/BUILD-NOT-FINISHED.txt"
cat > "$UNFINISHED" <<EOF
A build into this folder started at $BUILT_UTC and has not finished.
Don't copy this folder or install from it. Run build-bundle.sh again to
finish it; this file goes when the bundle is complete.
EOF

# ------------------------------------------------------------ Docker Desktop
# Only for Macs: install.sh installs it on one that has no Docker. Windows
# targets are expected to have Docker Desktop already.
if [ "$WANT_MAC" = 0 ]; then WITH_DOCKER_DESKTOP=0; fi
if [ "$WITH_DOCKER_DESKTOP" = 1 ]; then
  DMG="$CACHE/Docker-$DOCKER_DESKTOP_BUILD-arm64.dmg"
  if [ ! -f "$DMG" ]; then
    say "Downloading Docker Desktop $DOCKER_DESKTOP_VERSION for Apple Silicon (about 0.6 GB)"
    curl -fL --retry 3 -C - -o "$DMG.part" \
      "https://desktop.docker.com/mac/main/arm64/$DOCKER_DESKTOP_BUILD/Docker.dmg"
    mv "$DMG.part" "$DMG"
  fi
  GOT_SHA="$(shasum -a 256 "$DMG" | awk '{print $1}')"
  [ "$GOT_SHA" = "$DOCKER_DMG_SHA256" ] \
    || die "Docker.dmg checksum mismatch (expected $DOCKER_DMG_SHA256, got $GOT_SHA); delete $DMG and retry"

  say "Verifying Docker Desktop's signature"
  DOCKER_GATEKEEPER="$(spctl --assess --type open --context context:primary-signature -v "$DMG" 2>&1 \
      | sed 's#^.*\.dmg: ##' | tr '\n' ' ' | sed 's/ *$//')" \
    || die "Gatekeeper rejected Docker.dmg: $DOCKER_GATEKEEPER"
  DMG_MOUNT="$WORK/docker-dmg"
  mkdir "$DMG_MOUNT"
  hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$DMG_MOUNT" "$DMG" >/dev/null \
    || die "couldn't open Docker.dmg"
  DOCKER_APP="$DMG_MOUNT/Docker.app"
  [ -x "$DOCKER_APP/Contents/MacOS/install" ] \
    || die "Docker.dmg has no Docker.app/Contents/MacOS/install, which install.sh runs"
  codesign --verify --deep --strict "$DOCKER_APP" || die "Docker.app failed code-signature verification"
  DOCKER_SIGNER="$(codesign -dv --verbose=2 "$DOCKER_APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
  GOT_VERSION="$(plutil -extract CFBundleShortVersionString raw -o - "$DOCKER_APP/Contents/Info.plist")"
  GOT_BUILD="$(plutil -extract CFBundleVersion raw -o - "$DOCKER_APP/Contents/Info.plist")"
  [ "$GOT_VERSION" = "$DOCKER_DESKTOP_VERSION" ] && [ "$GOT_BUILD" = "$DOCKER_DESKTOP_BUILD" ] \
    || die "Docker.dmg holds version $GOT_VERSION (build $GOT_BUILD), not the pinned $DOCKER_DESKTOP_VERSION ($DOCKER_DESKTOP_BUILD)"
  DOCKER_MIN_MACOS="$(plutil -extract LSMinimumSystemVersion raw -o - "$DOCKER_APP/Contents/Info.plist")"
  hdiutil detach "$DMG_MOUNT" >/dev/null || true
  DMG_MOUNT=""
  echo "    $DOCKER_SIGNER"
  cp "$DMG" "$OUT/docker/Docker.dmg"
fi

# ------------------------------------------------------------ LibreTranslate
BASE_IMAGE="libretranslate/libretranslate:$LT_VERSION"

cat > "$WORK/lt-selftest.py" <<'PY'
import json, urllib.request
base = "http://127.0.0.1:5000"
langs = json.load(urllib.request.urlopen(base + "/languages", timeout=5))
by_code = {l["code"]: l for l in langs}
src = "en" if "en" in by_code else langs[0]["code"]
targets = [t for t in by_code[src]["targets"] if t != src]
tgt = "fr" if "fr" in targets else targets[0]
req = urllib.request.Request(
    base + "/translate",
    data=json.dumps({"q": "The documents arrived this morning.", "source": src,
                     "target": tgt, "format": "text"}).encode(),
    headers={"Content-Type": "application/json"})
out = json.load(urllib.request.urlopen(req, timeout=600))["translatedText"]
print("%d|%s|%s|%s" % (len(langs), src, tgt, out.replace("\n", " ")))
PY

# Docker Desktop keeps images in a virtual disk with its own size limit, so
# free space on the Mac says nothing about room for the images. Checked only
# for the all-languages build (a subset's size isn't known in advance), and
# only for images that aren't already there from an earlier run.
IMAGES_TO_BUILD=0
for ARCH in $ARCHES; do
  docker image inspect "libretranslate-offline:$LT_VERSION-$ARCH" >/dev/null 2>&1 \
    || IMAGES_TO_BUILD=$((IMAGES_TO_BUILD + 1))
done
DISK_CHECKED=0

LT_ENV=""        # bundle.env lines, a set per image
PAYLOAD="|"      # the large files this build puts in the bundle
[ "$WITH_DOCKER_DESKTOP" = 0 ] || PAYLOAD="${PAYLOAD}docker/Docker.dmg|"
LT_TEST_PAIR=""
: > "$WORK/manifest-images.txt"

for ARCH in $ARCHES; do
  PLATFORM="linux/$ARCH"
  IMAGE="libretranslate-offline:$LT_VERSION-$ARCH"
  LT_TAR="docker/libretranslate-offline-$LT_VERSION-$ARCH.tar"
  ARCH_UPPER="$(printf '%s' "$ARCH" | tr '[:lower:]' '[:upper:]')"
  EMULATED=""
  BOOT_TRIES=150
  if [ "$ARCH" = arm64 ]; then
    FOR="Apple Silicon Macs"
    [ "$WANT_WINDOWS" = 0 ] || FOR="$FOR, and Windows PCs with ARM processors"
  else
    FOR="Windows PCs with Intel or AMD processors"
    EMULATED=", under emulation"
    BOOT_TRIES=600 # every model loads at boot, several times slower emulated
  fi

  say "Pulling $BASE_IMAGE ($PLATFORM)"
  docker pull --platform "$PLATFORM" "$BASE_IMAGE"
  # The digest of the multi-platform index, so one value covers every image here.
  BASE_DIGEST="$(docker image inspect --format '{{index .RepoDigests 0}}' "$BASE_IMAGE" 2>/dev/null || echo unknown)"

  if [ "$ARCH" = amd64 ]; then
    RUNS_AS="$(docker run --rm --network none --platform "$PLATFORM" --entrypoint uname "$BASE_IMAGE" -m 2>/dev/null || true)"
    [ "$RUNS_AS" = "x86_64" ] \
      || die "Docker here can't run Intel/AMD (amd64) images, which the Windows image is built and tested as.
       Turn on Rosetta in Docker Desktop (Settings > General > Virtual Machine Options),
       or build for Macs only with --targets mac."
  fi

  if [ "$DISK_CHECKED" = 0 ] && [ -z "$LANGS" ] && [ "$IMAGES_TO_BUILD" -gt 0 ]; then
    # The containerd store holds the baked layer in the build cache, again in
    # the image, and once more compressed. The older store holds it once.
    case "$(docker info --format '{{.DriverStatus}}' 2>/dev/null || true)" in
      *io.containerd.snapshotter*) DOCKER_NEED_GB="$DOCKER_NEED_GB_CONTAINERD" ;;
    esac
    NEED_GB=$((DOCKER_NEED_GB * IMAGES_TO_BUILD))
    FREE_MB="$(docker run --rm --network none --platform "$PLATFORM" --entrypoint df "$BASE_IMAGE" -m / 2>/dev/null \
      | awk 'END { print $4 }' || true)"
    case "$FREE_MB" in ''|*[!0-9]*) FREE_MB="" ;; esac
    if [ -n "$FREE_MB" ] && [ "$FREE_MB" -lt $((NEED_GB * 1024)) ]; then
      die "Docker's own disk has $((FREE_MB / 1024)) GB free; baking every language into $IMAGES_TO_BUILD image(s) needs about $NEED_GB GB.
       Make room ('docker builder prune', 'docker image prune'), raise the limit in
       Docker Desktop (Settings > Resources > Disk usage limit), pass --langs, or
       build for one target with --targets."
    fi
  fi
  DISK_CHECKED=1

  say "Baking language models into $IMAGE (languages: ${LANGS:-all})"
  docker build --platform "$PLATFORM" \
    --build-arg "LT_IMAGE=$BASE_IMAGE" \
    --build-arg "LANGS=$LANGS" \
    -t "$IMAGE" - < "$SRC/Dockerfile"
  IMAGE_ID="$(docker image inspect --format '{{.Id}}' "$IMAGE")"

  say "Checking the image boots and translates with networking disabled$EMULATED"
  SELFTEST_CONTAINER="lt-selftest-$$"
  docker run -d --name "$SELFTEST_CONTAINER" --network none --platform "$PLATFORM" "$IMAGE" >/dev/null
  LT_SELFTEST=""
  for _ in $(seq 1 "$BOOT_TRIES"); do
    LT_SELFTEST="$(docker exec -i "$SELFTEST_CONTAINER" ./venv/bin/python - \
      < "$WORK/lt-selftest.py" 2>/dev/null || true)"
    [ -z "$LT_SELFTEST" ] || break
    sleep 2
  done
  if [ -z "$LT_SELFTEST" ]; then
    docker logs "$SELFTEST_CONTAINER" 2>&1 | tail -30 >&2
    die "LibreTranslate ($PLATFORM) did not come up offline; see the container log above"
  fi
  LT_LANG_COUNT="$(printf '%s' "$LT_SELFTEST" | cut -d'|' -f1)"
  LT_TEST_SRC="$(printf '%s' "$LT_SELFTEST" | cut -d'|' -f2)"
  LT_TEST_TGT="$(printf '%s' "$LT_SELFTEST" | cut -d'|' -f3)"
  LT_TEST_OUT="$(printf '%s' "$LT_SELFTEST" | cut -d'|' -f4-)"
  echo "    $LT_LANG_COUNT languages; $LT_TEST_SRC->$LT_TEST_TGT: $LT_TEST_OUT"
  [ -n "$LT_TEST_PAIR" ] || LT_TEST_PAIR="$LT_TEST_SRC:$LT_TEST_TGT"

  # Exact model versions inside the image, for the manifest.
  docker exec "$SELFTEST_CONTAINER" ./venv/bin/python -c '
from argostranslate import package
for p in sorted(package.get_installed_packages(), key=lambda p: (p.from_code, p.to_code)):
    print("%s -> %s  v%s" % (p.from_code, p.to_code, p.package_version))
' > "$WORK/argos-models-$ARCH.txt"

  # What each model's makers say of its training data and terms. A copy goes
  # in the bundle, where it can be read without opening the image.
  docker exec "$SELFTEST_CONTAINER" ./venv/bin/python -c '
import sys
from argostranslate import package
for p in sorted(package.get_installed_packages(), key=lambda p: (p.from_code, p.to_code)):
    readme = p.package_path / "README.md"
    text = readme.read_text(encoding="utf-8", errors="replace") if readme.is_file() else "(this package has no README)\n"
    sys.stdout.buffer.write(("\n======== %s -> %s  v%s ========\n\n%s" % (p.from_code, p.to_code, p.package_version, text)).encode("utf-8"))
' > "$WORK/argos-readmes-$ARCH.txt"
  [ -s "$WORK/argos-readmes-$ARCH.txt" ] || die "couldn't read the language models' READMEs from $IMAGE"
  docker rm -f "$SELFTEST_CONTAINER" >/dev/null
  SELFTEST_CONTAINER=""

  say "Saving the image to $LT_TAR"
  docker save -o "$OUT/$LT_TAR" "$IMAGE"
  PAYLOAD="$PAYLOAD$LT_TAR|"

  LT_ENV="${LT_ENV}LT_IMAGE_$ARCH_UPPER=$IMAGE
LT_IMAGE_ID_$ARCH_UPPER=$IMAGE_ID
LT_TAR_$ARCH_UPPER=$LT_TAR
"
  {
    echo
    echo "  For $FOR ($PLATFORM)"
    echo "    Bundled image:  $IMAGE"
    echo "    Image ID:       $IMAGE_ID"
    echo "    File:           $LT_TAR"
    echo "    Languages:      $LT_LANG_COUNT (requested: ${LANGS:-all})"
    echo "    Offline self-test ($LT_TEST_SRC->$LT_TEST_TGT, networking disabled$EMULATED):"
    echo "      The documents arrived this morning. => $LT_TEST_OUT"
  } >> "$WORK/manifest-images.txt"
done

# -------------------------------------------------------------------- Ollama
ZIP="$CACHE/Ollama-darwin-$OLLAMA_VERSION.zip"
if [ ! -f "$ZIP" ]; then
  say "Downloading Ollama $OLLAMA_VERSION for macOS"
  curl -fL --retry 3 -o "$ZIP.part" \
    "https://github.com/ollama/ollama/releases/download/$OLLAMA_VERSION/Ollama-darwin.zip"
  mv "$ZIP.part" "$ZIP"
fi
GOT_SHA="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
[ "$GOT_SHA" = "$OLLAMA_ZIP_SHA256" ] \
  || die "Ollama zip checksum mismatch (expected $OLLAMA_ZIP_SHA256, got $GOT_SHA); delete $ZIP and retry"

say "Verifying Ollama.app's signature"
ditto -x -k "$ZIP" "$WORK/app"
APP="$WORK/app/Ollama.app"
[ -d "$APP" ] || die "Ollama.app not found inside the zip"
codesign --verify --deep --strict "$APP" || die "Ollama.app failed code-signature verification"
SIGNER="$(codesign -dv --verbose=2 "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
GATEKEEPER="$(spctl --assess --type execute -v "$APP" 2>&1 | sed 's#^.*Ollama\.app: ##' | tr '\n' ' ' | sed 's/ *$//')" \
  || die "Gatekeeper rejected Ollama.app: $GATEKEEPER"
echo "    $SIGNER"
if [ "$WANT_MAC" = 1 ]; then
  cp "$ZIP" "$OUT/ollama/Ollama-darwin.zip"
  PAYLOAD="${PAYLOAD}ollama/Ollama-darwin.zip|"
fi

if [ "$WANT_WINDOWS" = 1 ]; then
  SETUP="$CACHE/OllamaSetup-$OLLAMA_VERSION.exe"
  if [ ! -f "$SETUP" ]; then
    say "Downloading Ollama $OLLAMA_VERSION for Windows (about 1.9 GB)"
    curl -fL --retry 3 -C - -o "$SETUP.part" \
      "https://github.com/ollama/ollama/releases/download/$OLLAMA_VERSION/OllamaSetup.exe"
    mv "$SETUP.part" "$SETUP"
  fi
  # The checksum is the only check made here: a Mac has no tool for a Windows
  # publisher signature. install.ps1 reports the signature on the target.
  GOT_SHA="$(shasum -a 256 "$SETUP" | awk '{print $1}')"
  [ "$GOT_SHA" = "$OLLAMA_SETUP_SHA256" ] \
    || die "OllamaSetup.exe checksum mismatch (expected $OLLAMA_SETUP_SHA256, got $GOT_SHA); delete $SETUP and retry"
  cp "$SETUP" "$OUT/ollama/OllamaSetup.exe"
  PAYLOAD="${PAYLOAD}ollama/OllamaSetup.exe|"
fi

OLLAMA_BIN="$(find "$APP/Contents" -type f -name ollama -perm -u+x | head -1)"
[ -n "$OLLAMA_BIN" ] || die "ollama CLI not found inside Ollama.app"

say "Pulling model(s) into the bundle: $MODELS"
# Otherwise the checks below would talk to whatever is already listening there.
if nc -z 127.0.0.1 "$PULL_PORT" >/dev/null 2>&1; then
  die "port $PULL_PORT is in use (another build running?); stop it and re-run"
fi
export OLLAMA_HOST="127.0.0.1:$PULL_PORT"
export OLLAMA_MODELS="$OUT/ollama/models"
"$OLLAMA_BIN" serve > "$WORK/ollama-serve.log" 2>&1 &
SERVE_PID=$!
OLLAMA_API="http://127.0.0.1:$PULL_PORT"
for _ in $(seq 1 30); do
  curl -fsS "$OLLAMA_API/api/version" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS "$OLLAMA_API/api/version" >/dev/null 2>&1 \
  || { tail -20 "$WORK/ollama-serve.log" >&2; die "the bundled Ollama did not start"; }

OLD_IFS="$IFS"; IFS=','
for model in $MODELS; do
  IFS="$OLD_IFS"
  "$OLLAMA_BIN" pull "$model"
done
IFS="$OLD_IFS"

# name<TAB>digest for every model now in the bundle's store
curl -fsS "$OLLAMA_API/api/tags" > "$WORK/tags.json"
: > "$WORK/ollama-models.txt"
i=0
while name="$(plutil -extract "models.$i.name" raw -o - "$WORK/tags.json" 2>/dev/null)"; do
  digest="$(plutil -extract "models.$i.digest" raw -o - "$WORK/tags.json")"
  printf '%s\tsha256:%s\n' "$name" "$digest" >> "$WORK/ollama-models.txt"
  i=$((i + 1))
done
[ -s "$WORK/ollama-models.txt" ] || die "no models ended up in the bundle store"

# The terms each model came with. Gemma's say a copy must go with the model.
: > "$WORK/model-licences.txt"
while IFS="$(printf '\t')" read -r name _; do
  file="licences/$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '-').txt"
  "$OLLAMA_BIN" show "$name" --license > "$OUT/$file" 2>/dev/null < /dev/null || true
  if [ -s "$OUT/$file" ]; then
    printf '%s\t%s\n' "$name" "$file" >> "$WORK/model-licences.txt"
  else
    rm -f "$OUT/$file"
    printf '%s\t%s\n' "$name" "NO LICENCE TEXT CAME WITH THIS MODEL; find its terms before passing it on" \
      >> "$WORK/model-licences.txt"
    echo "    note: $name came with no licence text"
  fi
done < "$WORK/ollama-models.txt"

DEFAULT_MODEL="${MODELS%%,*}"
# Every model, not only the default: a model nobody ran here would reach the
# target unproved.
: > "$WORK/gemma-tests.txt"
OLD_IFS="$IFS"; IFS=','
for model in $MODELS; do
  IFS="$OLD_IFS"
  say "Checking $model runs from the bundle's own model store"
  cat > "$WORK/req.json" <<EOF
{"model": "$model", "stream": false, "options": {"temperature": 0},
 "prompt": "You are a professional English (en) to French (fr) translator. Your goal is to accurately convey the meaning and nuances of the original English text while adhering to French grammar, vocabulary, and cultural sensitivities.\nProduce only the French translation, without any additional explanations or commentary. Please translate the following English text into French:\n\n\nThe documents arrived this morning."}
EOF
  curl -fsS --max-time 900 -H 'Content-Type: application/json' \
    --data-binary "@$WORK/req.json" "$OLLAMA_API/api/generate" > "$WORK/resp.json" \
    || die "$model failed to generate; see $WORK/ollama-serve.log"
  GEMMA_TEST_OUT="$(plutil -extract response raw -o - "$WORK/resp.json" | tr '\n' ' ' | sed 's/ *$//')"
  [ -n "$GEMMA_TEST_OUT" ] || die "$model gave an empty test translation; see $WORK/ollama-serve.log"
  echo "    en->fr: $GEMMA_TEST_OUT"
  printf '    %s: The documents arrived this morning. => %s\n' "$model" "$GEMMA_TEST_OUT" >> "$WORK/gemma-tests.txt"
done
IFS="$OLD_IFS"

kill "$SERVE_PID" 2>/dev/null || true
wait "$SERVE_PID" 2>/dev/null || true
SERVE_PID=""

# ------------------------------------------------------- payload and manifest
say "Writing installers, manifest and checksums"
cp "$SRC/bundle/languages.tsv" "$SRC/bundle/README.txt" "$OUT/"
cp -R "$SRC/bundle/test-files" "$OUT/"
cp "$SRC/LICENSE" "$OUT/LICENSE.txt"
cp "$SRC/NOTICE" "$OUT/NOTICE.txt"
cp "$WORK/argos-readmes-${ARCHES%% *}.txt" "$OUT/licences/argos-language-models.txt"
INSTALLS_ON=""
if [ "$WANT_MAC" = 1 ]; then
  cp "$SRC/bundle/install.sh" "$SRC/bundle/translate.sh" "$SRC/bundle/Install.command" \
    "$SRC/bundle/Start Translation.command" "$OUT/"
  chmod +x "$OUT/install.sh" "$OUT/translate.sh" "$OUT/Install.command" "$OUT/Start Translation.command"
  # So the one file to double-click stands out in a busy folder.
  set_finder_icon "$SRC/bundle/icons/hoshi.icns" "$OUT/Install.command" \
    || printf '    note: Install.command keeps its ordinary icon: macOS would not set the Hoshi one\n'
  # install.sh makes the Hoshi Offline Translation app from these, on the Mac
  mkdir -p "$OUT/icons"
  cp "$SRC/bundle/Hoshi Offline Translation.applescript" "$OUT/"
  cp "$SRC/bundle/icons/hoshi.icns" "$OUT/icons/"
  INSTALLS_ON="Apple Silicon Macs (double-click Install.command, which runs install.sh)"
fi
if [ "$WANT_WINDOWS" = 1 ]; then
  cp "$SRC/bundle/install.ps1" "$SRC/bundle/translate.ps1" "$SRC/bundle/start-translation.ps1" "$OUT/"
  # Command Prompt misreads batch files whose lines end the Unix way.
  for f in install.cmd translate.cmd "Start Translation.cmd"; do
    perl -pe 's/\r?\n\z/\r\n/' "$SRC/bundle/$f" > "$OUT/$f"
  done
  # the Start-menu entry's icon
  mkdir -p "$OUT/icons"
  cp "$SRC/bundle/icons/hoshi.ico" "$OUT/icons/"
  INSTALLS_ON="${INSTALLS_ON:+$INSTALLS_ON; }Windows PCs (install.cmd)"
fi
assemble_web "$SRC" "$OUT" "built $BUILT_UTC from commit ${SOURCE_COMMIT:-unknown}${SOURCE_CHANGES:+ plus uncommitted changes}" "$TARGETS"

{
  echo "BUNDLE_BUILT_UTC=$BUILT_UTC"
  echo "SOURCE_COMMIT=${SOURCE_COMMIT:-unknown}${SOURCE_CHANGES:+ plus uncommitted changes}"
  echo "TARGETS=$TARGETS"
  if [ "$WITH_DOCKER_DESKTOP" = 1 ]; then
    echo "DOCKER_DESKTOP_VERSION=$DOCKER_DESKTOP_VERSION"
    echo "DOCKER_DESKTOP_MIN_MACOS=$DOCKER_MIN_MACOS"
    echo "DOCKER_DMG=docker/Docker.dmg"
  fi
  echo "LT_VERSION=$LT_VERSION"
  printf '%s' "$LT_ENV"
  echo "LT_SELFTEST_PAIR=$LT_TEST_PAIR"
  echo "OLLAMA_VERSION=$OLLAMA_VERSION"
  [ "$WANT_MAC" = 0 ] || echo "OLLAMA_ZIP=ollama/Ollama-darwin.zip"
  [ "$WANT_WINDOWS" = 0 ] || echo "OLLAMA_SETUP=ollama/OllamaSetup.exe"
  echo "GEMMA_MODELS=$MODELS"
  echo "DEFAULT_MODEL=$DEFAULT_MODEL"
  [ -z "$SUPPORT" ] || echo "SUPPORT=$SUPPORT"
} > "$OUT/bundle.env"

{
  echo "Offline translation bundle"
  echo "=========================="
  echo "Built (UTC):        $BUILT_UTC"
  echo "Built on:           macOS $(sw_vers -productVersion) $(uname -m)"
  echo "Installs on:        $INSTALLS_ON"
  echo "Help with installs: ${SUPPORT:-no one named (build-bundle.sh --support)}"
  if [ -n "$SOURCE_COMMIT" ]; then
    echo "Built from:         commit $SOURCE_COMMIT"
    echo "                    of ${SOURCE_REPO:-a repository with no remote}, folder $(basename "$HERE")"
    if [ -n "$SOURCE_CHANGES" ]; then
      echo "                    PLUS UNCOMMITTED CHANGES to these files, so the commit"
      echo "                    alone does not reproduce this bundle:"
      printf '%s\n' "$SOURCE_CHANGES" | sed 's/^/                /'
    fi
  else
    echo "Built from:         scripts outside any git checkout; their version is not recorded"
  fi
  if [ "$WITH_DOCKER_DESKTOP" = 1 ]; then
    echo
    echo "Docker Desktop (install.sh installs it only on a Mac that has no Docker)"
    echo "  Version:          $DOCKER_DESKTOP_VERSION (build $DOCKER_DESKTOP_BUILD), needs macOS $DOCKER_MIN_MACOS or newer"
    echo "  File:             docker/Docker.dmg"
    echo "    sha256:         $DOCKER_DMG_SHA256"
    echo "    Signed by:      $DOCKER_SIGNER"
    echo "    Gatekeeper:     $DOCKER_GATEKEEPER"
  fi
  echo
  echo "LibreTranslate"
  echo "  Base image:       $BASE_IMAGE"
  echo "  Base digest:      $BASE_DIGEST"
  cat "$WORK/manifest-images.txt"
  echo
  echo "Ollama"
  echo "  Version:          $OLLAMA_VERSION"
  if [ "$WANT_MAC" = 1 ]; then
    echo "  Mac app:          ollama/Ollama-darwin.zip"
  else
    echo "  Mac app:          Ollama-darwin.zip, not in this bundle; it fetched the models below"
  fi
  echo "    sha256:         $OLLAMA_ZIP_SHA256"
  echo "    Signed by:      $SIGNER"
  echo "    Gatekeeper:     $GATEKEEPER"
  if [ "$WANT_WINDOWS" = 1 ]; then
    echo "  Windows installer: ollama/OllamaSetup.exe"
    echo "    sha256:         $OLLAMA_SETUP_SHA256"
    echo "    Signature:      not checked at build (a Mac can't); install.cmd reports it"
  fi
  echo "  Models (name, digest):"
  sed 's/^/    /' "$WORK/ollama-models.txt"
  echo "  Self-test of each model (en->fr, temperature 0, on the build Mac):"
  cat "$WORK/gemma-tests.txt"
  FIRST_ARCH="${ARCHES%% *}"
  for ARCH in $ARCHES; do
    if [ "$ARCH" = "$FIRST_ARCH" ]; then
      echo
      echo "LibreTranslate language models (Argos Translate packages)"
      sed 's/^/  /' "$WORK/argos-models-$ARCH.txt"
    elif ! cmp -s "$WORK/argos-models-$FIRST_ARCH.txt" "$WORK/argos-models-$ARCH.txt"; then
      # Each image downloads the models when it is built, so a release landing
      # between the two builds would show up here.
      echo
      echo "LibreTranslate language models in the $ARCH image, which DIFFER from the above"
      sed 's/^/  /' "$WORK/argos-models-$ARCH.txt"
    else
      echo
      echo "The $ARCH image holds the same models and versions."
    fi
  done
  echo
  echo "Translation page (the installer starts it: install.sh with install-web.sh,"
  echo "install.cmd with install-web.ps1)"
  echo "  Files:            web/"
  echo "  Runs in:          a second container made from the LibreTranslate image"
  echo "                    above that the computer uses, which is not changed"
  echo "  Dropped-text check: web/check.pl, taken from the translate.sh of the commit"
  echo "                    this bundle was built from, on Windows too"
  echo
  echo "Starting it again after a restart (the installers copy these beside the"
  echo "translate helper; they install nothing)"
  [ "$WANT_MAC" = 0 ] || echo "  On a Mac:         Start Translation.command"
  [ "$WANT_WINDOWS" = 0 ] || echo "  On Windows:       Start Translation.cmd, which runs start-translation.ps1"
  echo "  and the way in that a user sees, called Hoshi Offline Translation:"
  [ "$WANT_MAC" = 0 ] || echo "  On a Mac:         an app in Applications, which install.sh makes from"
  [ "$WANT_MAC" = 0 ] || echo "                    Hoshi Offline Translation.applescript and icons/hoshi.icns;"
  [ "$WANT_MAC" = 0 ] || echo "                    it runs Start Translation.command"
  [ "$WANT_WINDOWS" = 0 ] || echo "  On Windows:       a Start-menu entry, with icons/hoshi.ico, that opens"
  [ "$WANT_WINDOWS" = 0 ] || echo "                    Start Translation.cmd"
  echo
  echo "Test files (test-files/; the installers copy them beside the translate helper)"
  echo "  Extracts from Wikipedia's articles on Earth, CC BY-SA 4.0. Sources,"
  echo "  revisions and what was changed: test-files/README.md and sources.json"
  (cd "$OUT/test-files" && find . -type f ! -name .DS_Store ! -name '._*' | LC_ALL=C sort | sed 's|^\./|  |')
  echo
  echo "Credits and licences"
  echo "  NOTICE.txt        whose work each part of this bundle is, and on what terms"
  echo "  LICENSE.txt       the GNU Affero General Public License, version 3: the terms"
  echo "                    for the installers, the translate helpers and the translation"
  echo "                    page, and for LibreTranslate"
  echo "  licences/argos-language-models.txt"
  echo "                    the README of each LibreTranslate language model"
  echo "  The terms each Ollama model came with (model, file):"
  sed 's/^/    /' "$WORK/model-licences.txt"
} > "$OUT/MANIFEST.txt"

rm -f "$UNFINISHED"
(
  cd "$OUT"
  find . -type f ! -name SHA256SUMS ! -name .DS_Store ! -name '._*' -print0 \
    | LC_ALL=C sort -z | xargs -0 shasum -a 256 > SHA256SUMS
)

say "Bundle ready: $OUT ($(du -sh "$OUT" | awk '{print $1}'))"
cat <<EOF

Copy the whole folder to the airgapped machine on a drive formatted as exFAT,
which Macs and Windows PCs both read (FAT32 cannot hold files over 4 GB). Then:

  on a Mac        double-click Install.command (or run ./install.sh in Terminal)
  on Windows      double-click install.cmd

Each ends by opening the translation page.

README.txt inside the folder has the full instructions.
EOF

# Left by an earlier build into this folder with other versions or targets.
for f in "$OUT"/docker/*.tar "$OUT/docker/Docker.dmg" "$OUT/ollama/Ollama-darwin.zip" "$OUT/ollama/OllamaSetup.exe"; do
  [ -f "$f" ] || continue
  case "$PAYLOAD" in
    *"|${f#"$OUT"/}|"*) ;;
    *) printf '\nnote: %s is left over from an earlier build and no installer in this bundle uses it; delete it to save space, then re-run to refresh the checksums.\n' "${f#"$OUT"/}" ;;
  esac
done
