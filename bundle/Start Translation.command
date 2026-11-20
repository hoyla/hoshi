#!/bin/bash
# Double-click this after the Mac has restarted, or whenever the translation
# page doesn't answer. It opens Docker Desktop and Ollama if they aren't
# running, waits for LibreTranslate, TranslateGemma and the translation page,
# and opens the page. It installs nothing and changes nothing: the installer
# puts it beside translate.sh, and it reads the settings that install left.

HERE="$(cd "$(dirname "$0")" && pwd -P)"
ENVFILE="$HERE/bundle.env"
DOCKER_APP="/Applications/Docker.app"

say() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
cfg() { { [ -f "$ENVFILE" ] && sed -n "s/^$1=//p" "$ENVFILE" | head -1; } || true; }
answers() { curl -fsS --max-time 5 "$1" >/dev/null 2>&1; }
wait_for() { # $1 = address, $2 = how many tries, two seconds apart
  local i
  for i in $(seq 1 "$2"); do
    if answers "$1"; then return 0; fi
    sleep 2
  done
  return 1
}
finish() { # $1 = exit status
  # Opened by double-click, the window could close and take the result with it.
  if [ -t 0 ]; then
    printf '\nPress Return to close. '
    read -r _ || true
  fi
  exit "$1"
}

LT_URL="$(cfg LT_URL)"
if [ -z "$LT_URL" ]; then
  echo "Offline translation isn't installed from this folder yet."
  echo "Run the installer first (double-click Install.command in the bundle"
  echo "folder). It puts a copy of this file in the translation-tools folder in"
  echo "your home folder: that copy is the one to double-click after a restart."
  finish 1
fi
WEB_URL="$(cfg WEB_URL)"
LT_CONTAINER="$(cfg LT_CONTAINER)"
WEB_CONTAINER="$(cfg WEB_CONTAINER)"
OLLAMA_APP="$(cfg OLLAMA_APP)"
OLLAMA_API="http://${OLLAMA_HOST:-127.0.0.1:11434}"
SUPPORT="$(cfg SUPPORT)"
WANT_DOCKER=0
[ -z "$(cfg LT_IMAGE_ID_INSTALLED)" ] || WANT_DOCKER=1

say "Starting offline translation"

# Both apps are opened first and waited for afterwards, so they start together.
DOCKER_STATE="ready"
if [ "$WANT_DOCKER" = 1 ]; then
  if ! command -v docker >/dev/null 2>&1; then
    for dir in /usr/local/bin "$DOCKER_APP/Contents/Resources/bin" "$HOME/.docker/bin"; do
      if [ -x "$dir/docker" ]; then PATH="$PATH:$dir"; break; fi
    done
  fi
  if ! docker info >/dev/null 2>&1; then
    note "opening Docker Desktop"
    open -a "$DOCKER_APP" >/dev/null 2>&1 || note "macOS couldn't open Docker Desktop"
    DOCKER_STATE="opened"
  fi
fi
if [ -n "$OLLAMA_APP" ] && ! answers "$OLLAMA_API/api/version"; then
  note "opening Ollama"
  open "$OLLAMA_APP" >/dev/null 2>&1 || note "macOS couldn't open $OLLAMA_APP"
fi

LIBRE=""; GEMMA=""; PAGE=""; ADVICE=""
advise() { ADVICE="$ADVICE  $*"$'\n'; }
if [ "$WANT_DOCKER" = 1 ]; then
  if [ "$DOCKER_STATE" = "opened" ]; then
    note "waiting for Docker Desktop (up to 5 minutes)"
    for _ in $(seq 1 150); do
      if docker info >/dev/null 2>&1; then DOCKER_STATE="ready"; break; fi
      sleep 2
    done
  fi
  if [ "$DOCKER_STATE" = "ready" ]; then
    # They start with Docker by themselves, unless someone stopped them by hand.
    docker start "${LT_CONTAINER:-libretranslate}" >/dev/null 2>&1 || true
    [ -z "$WEB_URL" ] || docker start "${WEB_CONTAINER:-translation-web}" >/dev/null 2>&1 || true
    note "waiting for LibreTranslate (it takes a minute or two to load its languages)"
    if wait_for "$LT_URL/languages" 150; then
      LIBRE="ready"
    else
      LIBRE="NOT answering"
      advise "LibreTranslate: Docker is running but LibreTranslate didn't answer on $LT_URL."
      advise "  Open Docker Desktop, look under Containers for '${LT_CONTAINER:-libretranslate}', and press its start button."
    fi
    if [ -n "$WEB_URL" ]; then
      if wait_for "$WEB_URL/api/config" 30; then
        PAGE="ready"
      else
        PAGE="NOT answering"
        advise "The translation page: Docker is running but the page didn't answer on $WEB_URL."
        advise "  Open Docker Desktop, look under Containers for '${WEB_CONTAINER:-translation-web}', and press its start button."
      fi
    fi
  else
    LIBRE="NOT answering"
    [ -z "$WEB_URL" ] || PAGE="NOT answering"
    advise "LibreTranslate and the translation page run inside Docker Desktop, which didn't become ready."
    advise "  Open Docker from Applications, answer anything it asks (skip signing in and"
    advise "  updates), wait until it says it is running, then double-click this again."
  fi
fi
if [ -n "$OLLAMA_APP" ]; then
  if wait_for "$OLLAMA_API/api/version" 30; then
    GEMMA="ready"
  else
    GEMMA="NOT answering"
    advise "TranslateGemma: Ollama, which runs it, didn't answer."
    advise "  Open Ollama from $(dirname "$OLLAMA_APP"), finish anything it asks, then double-click this again."
  fi
fi

echo
[ -z "$PAGE" ] || echo "  Translation page  $PAGE${WEB_URL:+  $WEB_URL}"
[ -z "$LIBRE" ] || echo "  LibreTranslate    $LIBRE"
[ -z "$GEMMA" ] || echo "  TranslateGemma    $GEMMA"

# The page is worth opening with one engine down: it says which, and the other works.
OPEN_URL=""
if [ "$PAGE" = "ready" ]; then
  OPEN_URL="$WEB_URL"
elif [ -z "$WEB_URL" ] && [ "$LIBRE" = "ready" ]; then
  OPEN_URL="$LT_URL" # an install made with --no-web: LibreTranslate's own page
fi
if [ -n "$OPEN_URL" ]; then
  open "$OPEN_URL" || true
  echo
  echo "  Opened $OPEN_URL in your browser."
fi
if [ -z "$ADVICE" ]; then
  [ -n "$OPEN_URL" ] || { echo; echo "  Ready. Use $HERE/translate.sh"; }
  finish 0
fi
printf '\nNot everything started:\n%s' "$ADVICE"
[ -z "$SUPPORT" ] || printf '\n  For help: %s\n' "$SUPPORT"
finish 1
