#!/bin/bash
# Install the offline translation bundle on an airgapped Apple Silicon Mac.
#
# Puts on both engines, the translate.sh helper and the translation web page.
# Needs only the tools that ship with macOS, and Docker, which it installs
# from the bundle if the Mac has none. Install.command runs this from a
# double-click. Safe to re-run: every step either
# replaces what an earlier run of this installer put there or leaves existing
# things alone. Each run keeps a log beside the installed helper.

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"

PORT=5050 # not 5000: macOS's AirPlay Receiver listens there
NAME="libretranslate"
WEB_PORT=5080
WEB_NAME="translation-web"
APP_DIR="/Applications"
PREFIX="$HOME/translation-tools"
DOCKER_APP="/Applications/Docker.app" # where Docker's own installer puts it
ASK=1
DO_VERIFY=1
DO_DOCKER=1
DO_OLLAMA=1
DO_LAUNCH=1
DO_WEB=1
DO_OPEN=1
DO_SPACE=1
DO_APP=1

usage() {
  cat <<EOF
Usage: ./install.sh [options]

  --port N         Local port for LibreTranslate (default: $PORT)
  --name NAME      Docker container name (default: $NAME)
  --web-port N     Local port for the translation page (default: $WEB_PORT)
  --web-name NAME  Docker container name for the page (default: $WEB_NAME)
  --app-dir DIR    Where Ollama.app and the Hoshi Offline Translation app go
                   (default: $APP_DIR; the Hoshi app goes in ~/Applications
                   when this one can't be written to)
  --prefix DIR     Where translate.sh goes (default: $PREFIX)
  --skip-verify    Don't check the bundle's checksums first
  --no-space-check Install even if the disk looks too full for it
  --no-docker      Skip LibreTranslate (and Docker, and the translation page,
                   which runs in Docker)
  --no-web         Skip the translation page. LibreTranslate then shows its
                   own page on its port
  --no-open        Don't open the translation page in a browser at the end
  --yes            Don't ask before installing Docker Desktop
  --no-ollama      Skip Ollama and its models
  --no-launch      Install Ollama but don't open it
  --no-app         Don't make the Hoshi Offline Translation app
  -h, --help       Show this help
EOF
}

STEP="checking this Mac and the bundle" # what the closing lines of a failed run name
say() { STEP="$*"; printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
cfg() { sed -n "s/^$1=//p" "$HERE/bundle.env" | head -1; }
# The same from the bundle.env an earlier install left in the prefix.
old() { [ ! -f "$PREFIX/bundle.env" ] || sed -n "s/^$1=//p" "$PREFIX/bundle.env" | head -1; }
gb() { awk -v kb="$1" 'BEGIN { printf "%.1f", kb / 1048576 }'; }
kb_of() { if [ -f "$1" ]; then echo $(( ($(stat -f %z "$1") + 1023) / 1024 )); else echo 0; fi; }
version_lt() { # $1 is an older version than $2
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$1" ]
}

ORIG_ARGS=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) ASK=0; shift ;;
    --port) PORT="${2:?}"; shift 2 ;;
    --name) NAME="${2:?}"; shift 2 ;;
    --web-port) WEB_PORT="${2:?}"; shift 2 ;;
    --web-name) WEB_NAME="${2:?}"; shift 2 ;;
    --app-dir) APP_DIR="${2:?}"; shift 2 ;;
    --prefix) PREFIX="${2:?}"; shift 2 ;;
    --skip-verify) DO_VERIFY=0; shift ;;
    --no-space-check) DO_SPACE=0; shift ;;
    --no-docker) DO_DOCKER=0; shift ;;
    --no-web) DO_WEB=0; shift ;;
    --no-open) DO_OPEN=0; shift ;;
    --no-ollama) DO_OLLAMA=0; shift ;;
    --no-launch) DO_LAUNCH=0; shift ;;
    --no-app) DO_APP=0; shift ;;
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

# What a failed run ends with, whatever stopped it: a command this script
# checks, or one it doesn't.
DMG_MOUNT=""
SUPPORT="$(cfg SUPPORT)"
on_exit() {
  local status=$?
  [ -z "$DMG_MOUNT" ] || hdiutil detach -force "$DMG_MOUNT" >/dev/null 2>&1 || true
  [ "$status" -ne 0 ] || return 0
  {
    printf '\n==> The install did not finish\n'
    note "It stopped at this step: $STEP"
    note "The lines just above say why."
    note "Nothing that was already on this Mac has been harmed: no document and no"
    note "translation was touched. It is safe to run the installer again."
    note "A record of this run is in: $TRANSLATION_INSTALL_LOG"
    [ -z "$SUPPORT" ] || note "For help: $SUPPORT"
  } >&2
}
trap on_exit EXIT

OS_VERSION="$(sw_vers -productVersion)"
OS_MAJOR="${OS_VERSION%%.*}"
MEMORY_GB="$(($(sysctl -n hw.memsize) / 1073741824))"
NEW_BUILT="$(cfg BUNDLE_BUILT_UTC)"
say "Offline translation installer"
note "started $(date -u +%Y-%m-%dT%H:%M:%SZ), options: ${ORIG_ARGS[*]:-none}"
note "bundle built $NEW_BUILT from commit $(cfg SOURCE_COMMIT)"
note "this Mac: macOS $OS_VERSION ($(sw_vers -buildVersion)), $(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo unknown processor), $MEMORY_GB GB memory, $(df -h "$HOME" | awk 'END { print $4 }') free on disk"
note "log: $TRANSLATION_INSTALL_LOG"

# What an earlier install left, read now: its bundle.env is replaced further on.
OLD_BUILT="$(old BUNDLE_BUILT_UTC)"
OLD_IMAGE_ID="$(old LT_IMAGE_ID_INSTALLED)"
OLD_IMAGE_IDS="$OLD_IMAGE_ID $(old LT_IMAGE_ID_PREVIOUS)"
OLD_MODELS="$(old GEMMA_MODELS),$(old GEMMA_MODELS_PREVIOUS)"
OLD_OLLAMA_APP="$(old OLLAMA_APP)"
OLD_OLLAMA_OURS="$(old OLLAMA_APP_BY_INSTALLER)"
OLD_WEB_URL="$(old WEB_URL)"
OLD_WEB_CONTAINER="$(old WEB_CONTAINER)"
OLD_LAUNCHER="$(old LAUNCHER_APP)"
CLOSING="" # lines for the end of the run, where they are still on screen
closing() { CLOSING="$CLOSING  $*"$'\n'; }
if [ -n "$OLD_BUILT" ]; then
  say "This Mac already has an install"
  note "installed now:    bundle built $OLD_BUILT from commit $(old SOURCE_COMMIT)"
  note "being installed:  bundle built $NEW_BUILT from commit $(cfg SOURCE_COMMIT)"
  if [ "$NEW_BUILT" = "$OLD_BUILT" ]; then
    note "They are the same bundle. Running it again repairs the install; nothing is updated."
  elif [[ "$NEW_BUILT" < "$OLD_BUILT" ]]; then
    note "THE BUNDLE BEING INSTALLED IS OLDER than the one this Mac has. Carrying on"
    note "puts the older one in its place. To keep the newer one, press Control-C now."
    closing "This run put an OLDER bundle (built $NEW_BUILT) in place of a newer one (built $OLD_BUILT)."
  else
    note "The bundle being installed is newer: this run updates the install."
  fi
fi

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
# The page runs on the LibreTranslate image, so there is none without Docker.
[ "$DO_DOCKER" = 1 ] || DO_WEB=0
if [ "$DO_WEB" = 1 ] && { [ ! -f "$HERE/install-web.sh" ] || [ ! -f "$HERE/web/app.py" ]; }; then
  die "the translation page's files (install-web.sh and the web folder) are missing from the bundle. Copy them again from the original, or re-run with --no-web."
fi

# ----------------------------------------------------------------- preflight
# Everything that can be found out without installing anything, before the
# checksums, a Docker Desktop install and the image load, which take a while.
find_docker() { # puts the docker command on PATH if it is in a usual place
  command -v docker >/dev/null 2>&1 && return 0
  local dir
  for dir in /usr/local/bin "$DOCKER_APP/Contents/Resources/bin" "$HOME/.docker/bin"; do
    if [ -x "$dir/docker" ]; then PATH="$PATH:$dir"; return 0; fi
  done
  return 1
}

port_held_by_another() { # $1 = port, $2 = the container of ours that may hold it
  nc -z 127.0.0.1 "$1" >/dev/null 2>&1 || return 1
  # A container from an earlier install holds its port and is replaced below.
  # Without Docker running, no container can be what is listening.
  if [ "$DOCKER_UP" = 1 ] && docker container inspect "$2" >/dev/null 2>&1; then return 1; fi
  return 0
}

say "Checking this Mac before anything is installed"
if [ "$DO_OLLAMA" = 1 ] && [ "$OS_MAJOR" -lt 14 ]; then
  die "Ollama needs macOS 14 (Sonoma) or newer; this Mac has $OS_VERSION. Re-run with --no-ollama to install LibreTranslate only."
fi
note "macOS $OS_VERSION is new enough"

DOCKER_UP=0
NEED_DOCKER_DESKTOP=0
if [ "$DO_DOCKER" = 1 ]; then
  if ! find_docker && [ ! -d "$DOCKER_APP" ]; then
    NEED_DOCKER_DESKTOP=1
    DOCKER_DMG="$(cfg DOCKER_DMG)"
    DOCKER_VERSION="$(cfg DOCKER_DESKTOP_VERSION)"
    DOCKER_MIN="$(cfg DOCKER_DESKTOP_MIN_MACOS)"
    [ -n "$DOCKER_DMG" ] || die "Docker isn't installed on this Mac and this bundle doesn't carry it. Install Docker Desktop and re-run, or re-run with --no-docker for TranslateGemma alone."
    [ -f "$HERE/$DOCKER_DMG" ] || die "Docker isn't installed on this Mac and $DOCKER_DMG is missing from the bundle. Copy it again from the original and re-run."
    [ "$OS_MAJOR" -ge "${DOCKER_MIN%%.*}" ] \
      || die "Docker Desktop $DOCKER_VERSION needs macOS $DOCKER_MIN or newer; this Mac has $OS_VERSION. Re-run with --no-docker for TranslateGemma alone."
    case " $(id -Gn) " in
      *" admin "*) ;;
      *) die "Docker isn't installed on this Mac, and installing it needs an administrator account, which '$(id -un)' is not. Have an administrator open $DOCKER_DMG and drag Docker to Applications, then re-run." ;;
    esac
  elif find_docker && docker info >/dev/null 2>&1; then
    DOCKER_UP=1
  fi
  if port_held_by_another "$PORT" "$NAME"; then
    die "port $PORT is already in use; pass --port with a free one"
  fi
  if [ "$DO_WEB" = 1 ] && port_held_by_another "$WEB_PORT" "$WEB_NAME"; then
    die "port $WEB_PORT, which the translation page uses, is already in use; pass --web-port with a free one"
  fi
  note "the ports are free"
fi

# Disk space, from the sizes of this bundle's own files. A model file the Mac
# already has in full is not counted, nor the image of a bundle already
# installed, so a re-run asks for next to nothing.
MODELS_DIR="${OLLAMA_MODELS:-$HOME/.ollama/models}"
NEED_KB=0
if [ "$DO_OLLAMA" = 1 ]; then
  while IFS= read -r FILE; do
    SIZE_KB="$(kb_of "$FILE")"
    [ "$(kb_of "$MODELS_DIR/${FILE#"$HERE/ollama/models/"}")" = "$SIZE_KB" ] || NEED_KB=$((NEED_KB + SIZE_KB))
  done < <(find "$HERE/ollama/models" -type f ! -name '._*' ! -name .DS_Store 2>/dev/null)
  # unpacked, the app is about three times its zip
  [ -d "$APP_DIR/Ollama.app" ] || NEED_KB=$((NEED_KB + 3 * $(kb_of "$HERE/$(cfg OLLAMA_ZIP)")))
fi
if [ "$DO_DOCKER" = 1 ]; then
  # Docker keeps images in a file of its own in the home folder, which grows.
  if [ "$NEW_BUILT" != "$OLD_BUILT" ] || [ -z "$OLD_IMAGE_ID" ]; then
    NEED_KB=$((NEED_KB + $(kb_of "$HERE/$LT_TAR")))
  fi
  [ "$NEED_DOCKER_DESKTOP" = 0 ] || NEED_KB=$((NEED_KB + 4 * $(kb_of "$HERE/$DOCKER_DMG")))
fi
NEED_KB=$((NEED_KB + 1048576)) # and a gigabyte to work in
FREE_KB="$(df -k "$HOME" | awk 'END { print $4 }')"
note "disk: $(gb "$FREE_KB") GB free, about $(gb "$NEED_KB") GB needed"
if [ "$FREE_KB" -lt "$NEED_KB" ]; then
  if [ "$DO_SPACE" = 1 ]; then
    die "not enough free disk space: this Mac has $(gb "$FREE_KB") GB free and the install needs about $(gb "$NEED_KB") GB. Free some space (empty the Trash, move large files to another drive) and run the installer again. To install only part: --no-ollama leaves out TranslateGemma, --no-docker leaves out LibreTranslate. If you are sure there is room, --no-space-check skips this check."
  fi
  note "that is too little by this check, which --no-space-check has turned off"
fi

if [ "$DO_OLLAMA" = 1 ] && [ "$MEMORY_GB" -lt 16 ]; then
  note "WARNING: this Mac has $MEMORY_GB GB of memory. TranslateGemma's standard model (12b)"
  note "is meant for 16 GB or more: here it may be very slow, or fail to load."
  note "LibreTranslate is not affected. The install carries on."
  closing "This Mac has $MEMORY_GB GB of memory, less than the 16 GB TranslateGemma's standard model wants."
  case ",$(cfg GEMMA_MODELS)," in
    *,translategemma:4b,*) closing "If it is too slow, choose translategemma:4b in the Model list on the translation page." ;;
  esac
fi

if [ "$NEED_DOCKER_DESKTOP" = 1 ]; then
  say "Docker isn't installed on this Mac"
  note "LibreTranslate runs inside Docker, and this bundle carries Docker Desktop $DOCKER_VERSION."
  note "Installing it puts Docker.app in /Applications and needs this Mac's password."
  note "Docker Desktop is free for personal use and for small organisations; larger"
  note "ones need a paid subscription for each machine. README.txt says more."
  if [ "$ASK" = 1 ]; then
    printf '\n    Press Return to install Docker Desktop, or Control-C to stop: '
    read -r _ < /dev/tty \
      || die "couldn't ask. Run install.sh in a Terminal window, or pass --yes to install Docker Desktop without being asked."
  fi
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
install_docker_desktop() { # what it needs was checked, and the question asked, above
  local dmg="$DOCKER_DMG" version="$DOCKER_VERSION"
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
  [ "$NEED_DOCKER_DESKTOP" = 0 ] || install_docker_desktop
  find_docker || die "Docker Desktop is in /Applications but its docker command wasn't found. Open Docker once, let it finish setting up, then re-run."
  if ! docker info >/dev/null 2>&1; then
    [ -d "$DOCKER_APP" ] || die "Docker isn't running. Start it and re-run."
    start_docker || die "Docker didn't become ready. Open Docker from Applications, answer anything it asks, wait until it says it is running, then re-run."
  fi
  note "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?'), image store $(docker info --format '{{.Driver}}' 2>/dev/null || echo '?')"
fi

# ------------------------------------------------------------ LibreTranslate
if [ "$DO_DOCKER" = 1 ]; then
  # Checked again now that Docker is answering: before this, a stopped Docker
  # could not say whether a container of ours was what held the page's port.
  if [ "$DO_WEB" = 1 ] && ! docker container inspect "$WEB_NAME" >/dev/null 2>&1 \
      && nc -z 127.0.0.1 "$WEB_PORT" >/dev/null 2>&1; then
    die "port $WEB_PORT, which the translation page uses, is already in use; pass --web-port with a free one"
  fi

  say "Loading $IMAGE into Docker"
  note "Docker's disk before:"
  docker system df 2>&1 | sed 's/^/      /' || true
  LOAD_STARTED=$SECONDS
  docker load -i "$HERE/$LT_TAR" \
    || die "docker load failed. If the message above says 'no space left on device', Docker's own disk is full (it has a size limit separate from the Mac's). Raise the limit in Docker Desktop under Settings > Resources, or remove an image you no longer need ('docker image ls', 'docker image rm NAME'), then re-run. Take care: nothing removed can be downloaded again on this Mac."
  # Sidecars record the image by the ID Docker gives it on this Mac, which can
  # differ from the manifest's depending on how each Docker stores images.
  LOADED_ID="$(docker image inspect --format '{{.Id}}' "$IMAGE")" \
    && [ -n "$LOADED_ID" ] || die "couldn't read the loaded LibreTranslate image ID; re-run the installer"
  note "loaded in $((SECONDS - LOAD_STARTED)) seconds. Docker's disk after:"
  docker system df 2>&1 | sed 's/^/      /' || true
  note "free in Docker's disk: $(docker run --rm --pull never --network none --entrypoint df "$LOADED_ID" -m / 2>/dev/null \
    | awk 'END { if (NR) printf "%d GB", $4 / 1024; else print "unknown" }')"
  [ "$LOADED_ID" = "$IMAGE_ID" ] \
    || note "Docker here knows the image as $LOADED_ID; recorded in bundle.env beside the manifest's ID"

  if docker container inspect "$NAME" >/dev/null 2>&1; then
    OURS="$(docker container inspect --format '{{index .Config.Labels "airgapped-translation"}}' "$NAME" 2>/dev/null || true)"
    [ "$OURS" = "1" ] \
      || die "a container named '$NAME' exists that this installer didn't create; remove it or pass --name"
    note "replacing the '$NAME' container from an earlier install"
    docker rm -f "$NAME" >/dev/null \
      || die "Docker couldn't remove the '$NAME' container from the earlier install; its message is above. Quit Docker Desktop from the whale in the menu bar, open it again, wait until it says it is running, then run the installer again."
  fi
  if nc -z 127.0.0.1 "$PORT" >/dev/null 2>&1; then
    die "port $PORT is already in use; pass --port with a free one"
  fi

  # Where the translation page goes on, LibreTranslate's own page is turned
  # off: it keeps no record of a translation and makes no check of one. The
  # service still answers the translation page and translate.sh.
  LT_OPTIONS=()
  if [ "$DO_WEB" = 1 ]; then
    LT_OPTIONS=(-e LT_DISABLE_WEB_UI=true)
    say "Starting LibreTranslate on $LT_URL, without its own web page"
  else
    say "Starting LibreTranslate on $LT_URL"
  fi
  docker run -d --name "$NAME" --label airgapped-translation=1 \
    --pull never --restart unless-stopped -p "127.0.0.1:$PORT:5000" \
    ${LT_OPTIONS[@]+"${LT_OPTIONS[@]}"} "$LOADED_ID" >/dev/null \
    || die "Docker couldn't start LibreTranslate; its message is above. If it speaks of a port, run the installer again with --port 5051. Otherwise quit Docker Desktop, open it again, wait until it says it is running, then run the installer again."

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
OLLAMA_APP="$APP_DIR/Ollama.app"
OLLAMA_OURS=0 # whether this installer, now or before, is what put the app there
OLLAMA_QUIT=0
if [ "$DO_OLLAMA" = 1 ]; then
  if [ "$OLD_OLLAMA_OURS" = 1 ] && [ "$OLD_OLLAMA_APP" = "$OLLAMA_APP" ]; then OLLAMA_OURS=1; fi
  BUNDLED_VERSION="$(cfg OLLAMA_VERSION)"
  if [ ! -d "$OLLAMA_APP" ]; then
    say "Installing Ollama $BUNDLED_VERSION into $APP_DIR"
    mkdir -p "$APP_DIR" \
      || die "couldn't create $APP_DIR; pass --app-dir \"\$HOME/Applications\" or re-run as an admin user"
    ditto -x -k "$HERE/$(cfg OLLAMA_ZIP)" "$APP_DIR" \
      || die "couldn't write to $APP_DIR; pass --app-dir \"\$HOME/Applications\" or re-run as an admin user"
    OLLAMA_OURS=1
  else
    HAVE="$(plutil -extract CFBundleShortVersionString raw -o - "$OLLAMA_APP/Contents/Info.plist" 2>/dev/null || echo unknown)"
    if [ "v$HAVE" = "$BUNDLED_VERSION" ]; then
      say "Ollama.app is already in $APP_DIR (version $HAVE); leaving it as it is"
    elif [ "$OLLAMA_OURS" = 1 ] && version_lt "$HAVE" "${BUNDLED_VERSION#v}"; then
      # Only an app an earlier run of this installer put there is replaced.
      say "Replacing Ollama $HAVE, which an earlier install put in $APP_DIR, with $BUNDLED_VERSION"
      # Unpacked beside the old app first, so a failed copy leaves the old one.
      STAGING="$APP_DIR/.ollama-from-bundle"
      rm -rf "$STAGING"
      mkdir -p "$STAGING" && ditto -x -k "$HERE/$(cfg OLLAMA_ZIP)" "$STAGING" && [ -d "$STAGING/Ollama.app" ] \
        || { rm -rf "$STAGING"; die "couldn't unpack the newer Ollama into $APP_DIR. The older one is still there and still works. Free some disk space, or re-run with --no-ollama to leave Ollama as it is."; }
      osascript -e 'quit app "Ollama"' >/dev/null 2>&1 || true
      for _ in $(seq 1 20); do
        pgrep -x Ollama >/dev/null 2>&1 || break
        sleep 1
      done
      if pgrep -x Ollama >/dev/null 2>&1; then
        rm -rf "$STAGING"
        die "Ollama is still running and can't be replaced while it is. Quit it from the llama in the menu bar, then run the installer again."
      fi
      OLLAMA_QUIT=1
      rm -rf "$OLLAMA_APP" && mv "$STAGING/Ollama.app" "$OLLAMA_APP" \
        || die "couldn't put the newer Ollama in $APP_DIR. Run the installer again: it installs Ollama afresh if the app is missing."
      rmdir "$STAGING" 2>/dev/null || true
    else
      say "Ollama.app is already in $APP_DIR (version $HAVE); leaving it as it is"
      note "the bundle carries $BUNDLED_VERSION. To switch: quit Ollama, move the old app to the Trash, re-run."
    fi
  fi

  say "Copying models into $MODELS_DIR"
  mkdir -p "$MODELS_DIR" || die "couldn't create $MODELS_DIR"
  ditto "$HERE/ollama/models" "$MODELS_DIR" \
    || die "couldn't copy the TranslateGemma models into $MODELS_DIR; the message above says why. If the disk is full, free some space; if the drive was unplugged, plug it back in. Then run the installer again: it picks up where the copy stopped. To do without TranslateGemma, re-run with --no-ollama."
fi

# Models an earlier bundle installed that this one doesn't carry stay where
# they are: they may be wanted, and ~/.ollama is not this installer's alone.
LEFT_MODELS=""
OLD_IFS="$IFS"; IFS=","
for MODEL in $OLD_MODELS; do
  [ -n "$MODEL" ] || continue
  case ",$(cfg GEMMA_MODELS),$LEFT_MODELS," in *,"$MODEL",*) continue ;; esac
  case "$MODEL" in */*) MODEL_PATH="${MODEL%%:*}" ;; *) MODEL_PATH="library/${MODEL%%:*}" ;; esac
  MODEL_FILE="$MODELS_DIR/manifests/registry.ollama.ai/$MODEL_PATH/${MODEL##*:}"
  [ -f "$MODEL_FILE" ] || continue # removed since
  LEFT_MODELS="${LEFT_MODELS:+$LEFT_MODELS,}$MODEL"
  MODEL_KB="$(tr ',{' '\n\n' < "$MODEL_FILE" | sed -n 's/.*"size": *\([0-9][0-9]*\).*/\1/p' | awk '{ sum += $1 } END { printf "%d", sum / 1024 }')"
  closing "$MODEL, from an earlier bundle, is still on this Mac and holds about $(gb "$MODEL_KB") GB."
  closing "  This bundle doesn't carry it. It still works; to remove it, with Ollama open, run in Terminal:"
  closing "  \"$OLLAMA_APP/Contents/Resources/ollama\" rm $MODEL"
done
IFS="$OLD_IFS"

# ------------------------------------------------------------ helper script
say "Installing translate.sh into $PREFIX"
COPY_ADVICE="The message above says why. If the disk is full, free some space; if the drive was unplugged, plug it back in. Then run the installer again."
mkdir -p "$PREFIX" || die "couldn't create $PREFIX. $COPY_ADVICE"
cp "$HERE/translate.sh" "$HERE/languages.tsv" "$HERE/bundle.env" \
   "$HERE/MANIFEST.txt" "$HERE/README.txt" "$PREFIX/" \
  || die "couldn't copy the translate helper into $PREFIX. $COPY_ADVICE"
chmod +x "$PREFIX/translate.sh" || die "couldn't make $PREFIX/translate.sh runnable. $COPY_ADVICE"
START="Start Translation.command"
if [ -f "$HERE/$START" ]; then
  cp "$HERE/$START" "$PREFIX/" && chmod +x "$PREFIX/$START" \
    || die "couldn't copy '$START' into $PREFIX. $COPY_ADVICE"
fi

# ------------------------------------------------- the app that starts it all
# What a journalist looks for after a restart: an app in Applications,
# Launchpad and Spotlight, not a file in a folder. It is made here, on this
# Mac, so it carries no quarantine for Gatekeeper to stop, from an AppleScript
# file compiled by osacompile: macOS gives such an app a Dock icon and a
# progress window, where a plain script set as an app shows nothing at all.
# It holds no logic: it runs the "Start Translation.command" just copied.
LAUNCHER_NAME="Hoshi Offline Translation"
LAUNCHER_ID="local.hoshi.offline-translation"
LAUNCHER_SOURCE="$HERE/$LAUNCHER_NAME.applescript"
LAUNCHER="" # the app this run made, or found from an earlier one, and recorded
make_launcher() { # $1 = the folder it goes in
  local app="$1/$LAUNCHER_NAME.app" staging="$1/.hoshi-app-from-bundle" made
  made="$staging/$LAUNCHER_NAME.app"
  if [ -e "$app" ]; then
    # Only an app an earlier run of this installer recorded is replaced.
    if [ "$app" != "$OLD_LAUNCHER" ] \
        || [ "$(plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist" 2>/dev/null)" != "$LAUNCHER_ID" ]; then
      note "an app called '$LAUNCHER_NAME' is already in $1 that this installer didn't put there; leaving it"
      closing "An app called '$LAUNCHER_NAME' that this installer didn't make is in $1. It was left as it is."
      closing "  To start translation after a restart, double-click '$START' in $PREFIX."
      return 1
    fi
  fi
  rm -rf "$staging"
  mkdir -p "$staging" \
    && osacompile -o "$made" "$LAUNCHER_SOURCE" 2>/dev/null \
    && cp "$HERE/icons/hoshi.icns" "$made/Contents/Resources/applet.icns" \
    && rm -f "$made/Contents/Resources/Assets.car" \
    && { plutil -remove CFBundleIconName "$made/Contents/Info.plist" 2>/dev/null || true; } \
    && plutil -replace CFBundleIdentifier -string "$LAUNCHER_ID" "$made/Contents/Info.plist" \
    && plutil -replace CFBundleShortVersionString -string "${NEW_BUILT%%T*}" "$made/Contents/Info.plist" \
    && printf '%s\n' "$PREFIX" > "$made/Contents/Resources/install-folder.txt" \
    && printf '%s\n' "$SUPPORT" > "$made/Contents/Resources/support.txt" \
    && codesign --force --sign - "$made" >/dev/null 2>&1 \
    || { rm -rf "$staging"; return 2; }
  # Made in full beside the old one first, so a failure leaves the old one working.
  rm -rf "$app" && mv "$made" "$app" || { rm -rf "$staging"; return 2; }
  rmdir "$staging" 2>/dev/null || true
  LAUNCHER="$app"
}
if [ "$DO_APP" = 1 ] && [ -f "$LAUNCHER_SOURCE" ] && [ -f "$HERE/icons/hoshi.icns" ] && [ -f "$PREFIX/$START" ]; then
  LAUNCHER_DIR="$APP_DIR"
  if ! { mkdir -p "$LAUNCHER_DIR" 2>/dev/null && [ -w "$LAUNCHER_DIR" ]; }; then
    LAUNCHER_DIR="$HOME/Applications"
    mkdir -p "$LAUNCHER_DIR" 2>/dev/null || true
  fi
  say "Making the $LAUNCHER_NAME app in $LAUNCHER_DIR"
  [ "$LAUNCHER_DIR" = "$APP_DIR" ] || note "$APP_DIR can't be written to by '$(id -un)', so it goes in the Applications folder in the home folder"
  STATUS=0
  make_launcher "$LAUNCHER_DIR" || STATUS=$?
  if [ "$STATUS" = 2 ]; then
    note "couldn't make the app in $LAUNCHER_DIR; the rest of the install is not affected"
    closing "The $LAUNCHER_NAME app couldn't be made in $LAUNCHER_DIR. To start translation"
    closing "  after a restart, double-click '$START' in $PREFIX."
  fi
fi
# An app an earlier run made stays recorded while it is there, so a later run
# that couldn't make one doesn't forget it.
if [ -z "$LAUNCHER" ] && [ -n "$OLD_LAUNCHER" ] && [ -d "$OLD_LAUNCHER" ]; then LAUNCHER="$OLD_LAUNCHER"; fi

# A copy to practise on, so translations of it aren't written into the bundle.
TEST_FILES=""
if [ -d "$HERE/test-files" ]; then
  TEST_FILES="$PREFIX/test-files"
  mkdir -p "$TEST_FILES" && cp "$HERE"/test-files/* "$TEST_FILES/" \
    || die "couldn't copy the test files into $TEST_FILES. $COPY_ADVICE"
fi
# The images of earlier installs, to be removed once this one is working. Kept
# on record until then, so a run that stops before that doesn't lose them.
PREVIOUS_IDS=""
FOUND_PREVIOUS=""
if [ "$DO_DOCKER" = 1 ]; then
  for ID in $OLD_IMAGE_IDS; do
    case " $LOADED_ID $PREVIOUS_IDS " in *" $ID "*) ;; *) PREVIOUS_IDS="${PREVIOUS_IDS:+$PREVIOUS_IDS }$ID" ;; esac
  done
fi
# Remember non-default settings so translate.sh finds the services, and what
# this install put on the Mac so the next one knows what is its to replace.
{
  echo "LT_URL=$LT_URL"
  echo "LT_CONTAINER=$NAME"
  if [ "$DO_DOCKER" = 1 ]; then
    echo "LT_IMAGE=$IMAGE"
    echo "LT_IMAGE_ID_INSTALLED=$LOADED_ID"
    [ -z "$PREVIOUS_IDS" ] || echo "LT_IMAGE_ID_PREVIOUS=$PREVIOUS_IDS"
    # --no-web leaves an earlier install's page running; keep its address.
    if [ "$DO_WEB" = 0 ] && [ -n "$OLD_WEB_URL" ] && docker container inspect "${OLD_WEB_CONTAINER:-$WEB_NAME}" >/dev/null 2>&1; then
      echo "WEB_URL=$OLD_WEB_URL"
      echo "WEB_CONTAINER=${OLD_WEB_CONTAINER:-$WEB_NAME}"
    fi
  fi
  if [ "$DO_OLLAMA" = 1 ]; then
    echo "OLLAMA_APP=$OLLAMA_APP"
    echo "OLLAMA_APP_BY_INSTALLER=$OLLAMA_OURS"
  elif [ -n "$OLD_OLLAMA_APP" ] && [ -d "$OLD_OLLAMA_APP" ]; then
    echo "OLLAMA_APP=$OLD_OLLAMA_APP"
    echo "OLLAMA_APP_BY_INSTALLER=${OLD_OLLAMA_OURS:-0}"
  fi
  [ -z "$LEFT_MODELS" ] || echo "GEMMA_MODELS_PREVIOUS=$LEFT_MODELS"
  [ -z "$LAUNCHER" ] || echo "LAUNCHER_APP=$LAUNCHER"
} >> "$PREFIX/bundle.env" || die "couldn't write this install's settings into $PREFIX/bundle.env. $COPY_ADVICE"

# ---------------------------------------------------------- translation page
# install-web.sh is also how the page is replaced later, from a small folder
# of its own. Its files were checked above with the rest of the bundle.
WEB_URL="http://127.0.0.1:$WEB_PORT"
if [ "$DO_WEB" = 1 ]; then
  bash "$HERE/install-web.sh" --prefix "$PREFIX" --port "$WEB_PORT" --name "$WEB_NAME" \
      --skip-verify --part-of-install \
    || die "the translation page did not start; the lines above say why. LibreTranslate and translate.sh are installed. Run ./install.sh again once that is put right, or with --no-web to have LibreTranslate's own page instead."
fi

# ------------------------------------------- the earlier install's image
# Each bundle's image is 9 to 11 GB of Docker's size-limited disk. The one an
# earlier install recorded goes once the new LibreTranslate has translated and
# the page has moved to the new image, and only if no container still uses it.
if [ "$DO_DOCKER" = 1 ] && [ -n "$PREVIOUS_IDS" ]; then
  for ID in $PREVIOUS_IDS; do
    SIZE="$(docker image inspect --format '{{.Size}}' "$ID" 2>/dev/null)" || continue # gone already
    if [ -z "$FOUND_PREVIOUS" ]; then say "Removing the LibreTranslate image of the earlier install"; FOUND_PREVIOUS=1; fi
    USERS="$(docker ps -a --filter "ancestor=$ID" --format '{{.Names}}' 2>/dev/null | tr '\n' ' ' || true)"
    if [ -n "$USERS" ]; then
      note "left in place: a container still uses it ($USERS)"
      closing "The earlier install's LibreTranslate image is still in Docker, in use by: $USERS"
    elif docker image rm "$ID" >/dev/null 2>&1; then
      note "removed $ID, about $(gb "$((${SIZE:-0} / 1024))") GB of Docker's disk"
    else
      note "Docker wouldn't remove it; it does no harm. To remove it by hand: docker image rm $ID"
    fi
  done
fi

# ------------------------------------------------------------ launch + test
OLLAMA_OK="not checked"
[ "$OLLAMA_QUIT" = 0 ] || [ "$DO_LAUNCH" = 1 ] || OLLAMA_OK="replaced and not opened again (--no-launch). Open Ollama from $APP_DIR"
if [ "$DO_OLLAMA" = 1 ] && [ "$DO_LAUNCH" = 1 ]; then
  say "Opening Ollama"
  open "$OLLAMA_APP" || note "macOS wouldn't open $OLLAMA_APP; its message is above"
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

if [ "$DO_DOCKER" = 0 ]; then
  LT_STATE="skipped"
elif [ "$DO_WEB" = 1 ]; then
  LT_STATE="running; use it from the translation page or translate.sh"
else
  LT_STATE="$LT_URL (open in a browser)"
fi
if [ "$DO_WEB" = 1 ]; then
  WEB_STATE="$WEB_URL (open in a browser)"
elif docker container inspect "$WEB_NAME" >/dev/null 2>&1; then
  WEB_STATE="skipped; the one an earlier install started was left as it is"
else
  WEB_STATE="skipped"
fi

say "Done"
cat <<EOF

  Docker Desktop   $([ "$DOCKER_INSTALLED_NOW" = 1 ] && echo "installed by this run" || echo "not installed by this run")
  Translation page $WEB_STATE
  LibreTranslate   $LT_STATE
  Ollama           $([ "$DO_OLLAMA" = 1 ] && echo "$OLLAMA_OK" || echo "skipped")
  Helper           $PREFIX/translate.sh --help
  What's installed $PREFIX/MANIFEST.txt
  How to use it    $PREFIX/README.txt
  Files to try     ${TEST_FILES:-none in this bundle}
  Log of this run  $TRANSLATION_INSTALL_LOG

EOF
if [ -n "$LAUNCHER" ]; then
  cat <<EOF

  After the Mac restarts, open "$LAUNCHER_NAME" from $(dirname "$LAUNCHER")
  (or from Launchpad, or by typing its name in Spotlight) to start everything
  again. "$START" in $PREFIX does the same in a Terminal window.
EOF
else
  cat <<EOF

  After the Mac restarts, double-click "$START" in
  $PREFIX to start everything again.
EOF
fi
[ -z "$CLOSING" ] || printf '\n%s' "$CLOSING"
if [ "$DO_WEB" = 1 ] && [ "$DO_OPEN" = 1 ]; then open "$WEB_URL" || true; fi
