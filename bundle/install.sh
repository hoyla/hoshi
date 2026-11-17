#!/bin/bash
# Install the offline translation bundle on an airgapped Apple Silicon Mac.
#
# Needs only the tools that ship with macOS, and Docker, which it installs
# from the bundle if the Mac has none. Safe to re-run: every step either
# replaces what an earlier run of this installer put there or leaves existing
# things alone. Each run keeps a log beside the installed helper.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"

PORT=5050 # not 5000: macOS's AirPlay Receiver listens there
NAME="libretranslate"
APP_DIR="/Applications"
PREFIX="$HOME/translation-tools"
DOCKER_APP="/Applications/Docker.app" # where Docker's own installer puts it
ASK=1
DO_VERIFY=1
DO_DOCKER=1
DO_OLLAMA=1
DO_LAUNCH=1

usage() {
  cat <<EOF
Usage: ./install.sh [options]

  --port N         Local port for LibreTranslate (default: $PORT)
  --name NAME      Docker container name (default: $NAME)
  --app-dir DIR    Where Ollama.app goes (default: $APP_DIR)
  --prefix DIR     Where translate.sh goes (default: $PREFIX)
  --skip-verify    Don't check the bundle's checksums first
  --no-docker      Skip LibreTranslate (and Docker)
  --yes            Don't ask before installing Docker Desktop
  --no-ollama      Skip Ollama and its models
  --no-launch      Install Ollama but don't open it
  -h, --help       Show this help
EOF
}

say() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
cfg() { sed -n "s/^$1=//p" "$HERE/bundle.env" | head -1; }

ORIG_ARGS=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) ASK=0; shift ;;
    --port) PORT="${2:?}"; shift 2 ;;
    --name) NAME="${2:?}"; shift 2 ;;
    --app-dir) APP_DIR="${2:?}"; shift 2 ;;
    --prefix) PREFIX="${2:?}"; shift 2 ;;
    --skip-verify) DO_VERIFY=0; shift ;;
    --no-docker) DO_DOCKER=0; shift ;;
    --no-ollama) DO_OLLAMA=0; shift ;;
    --no-launch) DO_LAUNCH=0; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
done

[ -f "$HERE/bundle.env" ] || die "bundle.env not found; run this from inside the bundle folder"
[ "$(uname -s)" = "Darwin" ] || die "this installer is for Macs. On Windows, run install.cmd instead."
[ "$(uname -m)" = "arm64" ] || die "this bundle is for Apple Silicon Macs (this one is $(uname -m))"

# Keep a record of the run: start again with everything this prints going to a
# log file as well as the screen. A new file each run; none is overwritten.
if [ -z "${TRANSLATION_INSTALL_LOG:-}" ]; then
  mkdir -p "$PREFIX"
  TRANSLATION_INSTALL_LOG="$PREFIX/install-$(date -u +%Y%m%dT%H%M%SZ).log"
  export TRANSLATION_INSTALL_LOG
  set +e
  bash "$0" ${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"} 2>&1 | tee "$TRANSLATION_INSTALL_LOG"
  exit "${PIPESTATUS[0]}"
fi

OS_VERSION="$(sw_vers -productVersion)"
OS_MAJOR="${OS_VERSION%%.*}"
say "Offline translation installer"
note "started $(date -u +%Y-%m-%dT%H:%M:%SZ), options: ${ORIG_ARGS[*]:-none}"
note "bundle built $(cfg BUNDLE_BUILT_UTC) from commit $(cfg SOURCE_COMMIT)"
note "this Mac: macOS $OS_VERSION ($(sw_vers -buildVersion)), $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown processor), $(($(sysctl -n hw.memsize) / 1073741824)) GB memory, $(df -h "$HOME" | awk 'END { print $4 }') free on disk"
note "log: $TRANSLATION_INSTALL_LOG"

LT_URL="http://127.0.0.1:$PORT"
OLLAMA_API="http://${OLLAMA_HOST:-127.0.0.1:11434}"

IMAGE="$(cfg LT_IMAGE_ARM64)"
LT_TAR="$(cfg LT_TAR_ARM64)"
IMAGE_ID="$(cfg LT_IMAGE_ID_ARM64)"
# A bundle built before there was a Windows side has one image, named plainly.
if [ -z "$IMAGE" ]; then
  IMAGE="$(cfg LT_IMAGE)"
  LT_TAR="$(cfg LT_TAR)"
  IMAGE_ID="$(cfg LT_IMAGE_ID)"
fi
if [ "$DO_DOCKER" = 1 ] && { [ -z "$IMAGE" ] || [ -z "$LT_TAR" ]; }; then
  die "this bundle was built without the Mac version of LibreTranslate. Rebuild it with --targets mac, or re-run with --no-docker."
fi
if [ "$DO_OLLAMA" = 1 ] && [ -z "$(cfg OLLAMA_ZIP)" ]; then
  die "this bundle was built without the Mac version of Ollama. Rebuild it with --targets mac, or re-run with --no-ollama."
fi

# ---------------------------------------------------------------- checksums
if [ "$DO_VERIFY" = 1 ]; then
  say "Verifying the bundle's checksums (a few minutes for the large files)"
  # The Windows payload isn't used here and may have been left off the drive.
  (cd "$HERE" && grep -v -e '-amd64\.tar$' -e '/OllamaSetup\.exe$' SHA256SUMS | shasum -a 256 --quiet -c -) \
    || die "checksum verification failed: the bundle was damaged or changed in transit"
  note "all files match SHA256SUMS"
fi

# -------------------------------------------------------------------- Docker
find_docker() { # puts the docker command on PATH if it is in a usual place
  command -v docker >/dev/null 2>&1 && return 0
  local dir
  for dir in /usr/local/bin "$DOCKER_APP/Contents/Resources/bin" "$HOME/.docker/bin"; do
    if [ -x "$dir/docker" ]; then PATH="$PATH:$dir"; return 0; fi
  done
  return 1
}

DMG_MOUNT=""
trap '[ -z "$DMG_MOUNT" ] || hdiutil detach -force "$DMG_MOUNT" >/dev/null 2>&1 || true' EXIT

install_docker_desktop() {
  local dmg version min
  dmg="$(cfg DOCKER_DMG)"
  version="$(cfg DOCKER_DESKTOP_VERSION)"
  min="$(cfg DOCKER_DESKTOP_MIN_MACOS)"
  [ -n "$dmg" ] || die "Docker isn't installed on this Mac and this bundle doesn't carry it. Install Docker Desktop and re-run, or re-run with --no-docker for TranslateGemma alone."
  [ -f "$HERE/$dmg" ] || die "Docker isn't installed on this Mac and $dmg is missing from the bundle. Copy it again from the original and re-run."
  [ "$OS_MAJOR" -ge "${min%%.*}" ] \
    || die "Docker Desktop $version needs macOS $min or newer; this Mac has $OS_VERSION. Re-run with --no-docker for TranslateGemma alone."
  case " $(id -Gn) " in
    *" admin "*) ;;
    *) die "Docker isn't installed on this Mac, and installing it needs an administrator account, which '$(id -un)' is not. Have an administrator open $dmg and drag Docker to Applications, then re-run." ;;
  esac

  say "Docker isn't installed on this Mac"
  note "LibreTranslate runs inside Docker, and this bundle carries Docker Desktop $version."
  note "Installing it puts Docker.app in /Applications and needs this Mac's password."
  note "Docker Desktop is free for personal use and for small organisations; larger"
  note "ones need a paid subscription for each machine. README.txt says more."
  if [ "$ASK" = 1 ]; then
    printf '\n    Press Return to install Docker Desktop, or Control-C to stop: '
    read -r _ < /dev/tty \
      || die "couldn't ask. Run install.sh in a Terminal window, or pass --yes to install Docker Desktop without being asked."
  fi

  # The file is about to be run as an administrator, so check it even when
  # the rest of the bundle went unchecked.
  if [ "$DO_VERIFY" = 0 ]; then
    (cd "$HERE" && grep -F "  ./$dmg" SHA256SUMS | shasum -a 256 --quiet -c -) \
      || die "$dmg doesn't match SHA256SUMS: it was damaged or changed in transit"
  fi

  DMG_MOUNT="$(mktemp -d)"
  hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$DMG_MOUNT" "$HERE/$dmg" >/dev/null \
    || die "couldn't open $dmg"
  say "Installing Docker Desktop $version (type this Mac's password if asked; nothing shows as you type)"
  sudo "$DMG_MOUNT/Docker.app/Contents/MacOS/install" --user="$(id -un)" \
    || die "Docker's installer failed; its messages are above. To install by hand, open $dmg in the bundle folder, drag Docker to Applications, open it once, then re-run."
  hdiutil detach "$DMG_MOUNT" >/dev/null 2>&1 || true
  DMG_MOUNT=""
  [ -d "$DOCKER_APP" ] || die "Docker's installer finished but $DOCKER_APP isn't there"
  DOCKER_INSTALLED_NOW=1
}

start_docker() { # opens Docker Desktop and waits for its engine to answer
  say "Starting Docker Desktop"
  open -a "$DOCKER_APP" || return 1
  note "If Docker shows its service agreement, read it and accept it to carry on."
  note "Skip signing in, the survey and any update: none is needed, and none works offline."
  note "If macOS asks for the password again for Docker, give it."
  note "Waiting for Docker to be ready (up to 10 minutes)"
  local i
  for i in $(seq 1 300); do
    if docker info >/dev/null 2>&1; then return 0; fi
    [ $((i % 30)) -ne 0 ] || note "still waiting; look for a Docker window that wants an answer"
    sleep 2
  done
  return 1
}

DOCKER_INSTALLED_NOW=0
if [ "$DO_DOCKER" = 1 ]; then
  if ! find_docker && [ ! -d "$DOCKER_APP" ]; then
    install_docker_desktop
  fi
  find_docker || die "Docker Desktop is in /Applications but its docker command wasn't found. Open Docker once, let it finish setting up, then re-run."
  if ! docker info >/dev/null 2>&1; then
    [ -d "$DOCKER_APP" ] || die "Docker isn't running. Start it and re-run."
    start_docker || die "Docker didn't become ready. Open Docker from Applications, answer anything it asks, wait until it says it is running, then re-run."
  fi
  note "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?'), image store $(docker info --format '{{.Driver}}' 2>/dev/null || echo '?')"
fi

# ------------------------------------------------------------ LibreTranslate
if [ "$DO_DOCKER" = 1 ]; then
  say "Loading $IMAGE into Docker"
  note "Docker's disk before:"
  docker system df 2>&1 | sed 's/^/      /' || true
  LOAD_STARTED=$SECONDS
  docker load -i "$HERE/$LT_TAR" \
    || die "docker load failed. If the message above says 'no space left on device', Docker's own disk is full (it has a size limit separate from the Mac's). Raise the limit in Docker Desktop under Settings > Resources, or remove an image you no longer need ('docker image ls', 'docker image rm NAME'), then re-run. Take care: nothing removed can be downloaded again on this Mac."
  # Sidecars record the image by the ID Docker gives it on this Mac, which can
  # differ from the manifest's depending on how each Docker stores images.
  LOADED_ID="$(docker image inspect --format '{{.Id}}' "$IMAGE")"
  note "loaded in $((SECONDS - LOAD_STARTED)) seconds. Docker's disk after:"
  docker system df 2>&1 | sed 's/^/      /' || true
  note "free in Docker's disk: $(docker run --rm --network none --entrypoint df "$IMAGE" -m / 2>/dev/null \
    | awk 'END { if (NR) printf "%d GB", $4 / 1024; else print "unknown" }')"
  [ "$LOADED_ID" = "$IMAGE_ID" ] \
    || note "Docker here knows the image as $LOADED_ID; recorded in bundle.env beside the manifest's ID"

  if docker container inspect "$NAME" >/dev/null 2>&1; then
    OURS="$(docker container inspect --format '{{index .Config.Labels "airgapped-translation"}}' "$NAME")"
    [ "$OURS" = "1" ] \
      || die "a container named '$NAME' exists that this installer didn't create; remove it or pass --name"
    note "replacing the '$NAME' container from an earlier install"
    docker rm -f "$NAME" >/dev/null
  fi
  if nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; then
    die "port $PORT is already in use; pass --port with a free one"
  fi

  say "Starting LibreTranslate on $LT_URL"
  docker run -d --name "$NAME" --label airgapped-translation=1 \
    --restart unless-stopped -p "127.0.0.1:$PORT:5000" "$IMAGE" >/dev/null

  UP=0
  for _ in $(seq 1 150); do
    if curl -fsS "$LT_URL/languages" >/dev/null 2>&1; then UP=1; break; fi
    sleep 2
  done
  [ "$UP" = 1 ] || { docker logs "$NAME" 2>&1 | tail -30 >&2; die "LibreTranslate did not start; log above"; }

  PAIR="$(cfg LT_SELFTEST_PAIR)"
  OUT_TEXT="$(curl -fsS --max-time 300 "$LT_URL/translate" \
      --data-urlencode "q=The documents arrived this morning." \
      -d "source=${PAIR%%:*}" -d "target=${PAIR##*:}" -d "format=text" \
    | plutil -extract translatedText raw -o - -)" \
    || die "LibreTranslate is up but the test translation failed"
  note "test (${PAIR%%:*}->${PAIR##*:}): $OUT_TEXT"
fi

# -------------------------------------------------------------------- Ollama
if [ "$DO_OLLAMA" = 1 ]; then
  [ "$OS_MAJOR" -ge 14 ] || die "Ollama needs macOS 14 (Sonoma) or newer; this Mac has $OS_VERSION. Re-run with --no-ollama to install LibreTranslate only."

  BUNDLED_VERSION="$(cfg OLLAMA_VERSION)"
  if [ -d "$APP_DIR/Ollama.app" ]; then
    HAVE="$(plutil -extract CFBundleShortVersionString raw -o - "$APP_DIR/Ollama.app/Contents/Info.plist" 2>/dev/null || echo unknown)"
    say "Ollama.app is already in $APP_DIR (version $HAVE); leaving it as it is"
    if [ "v$HAVE" != "$BUNDLED_VERSION" ]; then
      note "the bundle carries $BUNDLED_VERSION. To switch: quit Ollama, move the old app to the Trash, re-run."
    fi
  else
    say "Installing Ollama $BUNDLED_VERSION into $APP_DIR"
    mkdir -p "$APP_DIR"
    ditto -x -k "$HERE/$(cfg OLLAMA_ZIP)" "$APP_DIR" \
      || die "couldn't write to $APP_DIR; pass --app-dir \"\$HOME/Applications\" or re-run as an admin user"
  fi

  MODELS_DIR="${OLLAMA_MODELS:-$HOME/.ollama/models}"
  say "Copying models into $MODELS_DIR"
  mkdir -p "$MODELS_DIR"
  ditto "$HERE/ollama/models" "$MODELS_DIR"
fi

# ------------------------------------------------------------ helper script
say "Installing translate.sh into $PREFIX"
mkdir -p "$PREFIX"
cp "$HERE/translate.sh" "$HERE/languages.tsv" "$HERE/bundle.env" \
   "$HERE/MANIFEST.txt" "$HERE/README.txt" "$PREFIX/"
chmod +x "$PREFIX/translate.sh"
# A copy to practise on, so translations of it aren't written into the bundle.
TEST_FILES=""
if [ -d "$HERE/test-files" ]; then
  TEST_FILES="$PREFIX/test-files"
  mkdir -p "$TEST_FILES"
  cp "$HERE"/test-files/* "$TEST_FILES/"
fi
# Remember non-default settings so translate.sh finds the services.
{
  echo "LT_URL=$LT_URL"
  echo "LT_CONTAINER=$NAME"
  if [ "$DO_DOCKER" = 1 ]; then
    echo "LT_IMAGE=$IMAGE"
    echo "LT_IMAGE_ID_INSTALLED=$LOADED_ID"
  fi
} >> "$PREFIX/bundle.env"

# ------------------------------------------------------------ launch + test
OLLAMA_OK="not checked"
if [ "$DO_OLLAMA" = 1 ] && [ "$DO_LAUNCH" = 1 ]; then
  say "Opening Ollama"
  open "$APP_DIR/Ollama.app"
  UP=0
  for _ in $(seq 1 60); do
    if curl -fsS "$OLLAMA_API/api/version" >/dev/null 2>&1; then UP=1; break; fi
    sleep 1
  done
  if [ "$UP" = 1 ]; then
    MODEL="$(cfg DEFAULT_MODEL)"
    note "running a test translation with $MODEL (the first run loads the model, allow a minute)"
    if OUT_TEXT="$("$PREFIX/translate.sh" --engine gemma --from en --to fr \
        --text "The documents arrived this morning.")"; then
      note "test (en->fr): $OUT_TEXT"
      OLLAMA_OK="working"
    else
      OLLAMA_OK="installed, but the test translation failed (see above)"
    fi
  else
    OLLAMA_OK="installed, but not answering yet. Finish any first-launch prompts in the Ollama window, then try translate.sh"
  fi
fi

say "Done"
cat <<EOF

  Docker Desktop   $([ "$DOCKER_INSTALLED_NOW" = 1 ] && echo "installed by this run" || echo "not installed by this run")
  LibreTranslate   $([ "$DO_DOCKER" = 1 ] && echo "$LT_URL (open in a browser)" || echo "skipped")
  Ollama           $([ "$DO_OLLAMA" = 1 ] && echo "$OLLAMA_OK" || echo "skipped")
  Helper           $PREFIX/translate.sh --help
  What's installed $PREFIX/MANIFEST.txt
  How to use it    $PREFIX/README.txt
  Files to try     ${TEST_FILES:-none in this bundle}
  Log of this run  $TRANSLATION_INSTALL_LOG
EOF
