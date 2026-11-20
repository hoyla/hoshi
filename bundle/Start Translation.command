#!/bin/bash
# Double-click this after the Mac has restarted, or whenever the translation
# page doesn't answer. It opens Docker Desktop and Ollama if they aren't
# running, waits for LibreTranslate, TranslateGemma and the translation page,
# and opens the page. It installs nothing and changes nothing: the installer
# puts it beside translate.sh, and it reads the settings that install left.
#
# The Hoshi Offline Translation app the installer makes runs this same file,
# with --app FILE: the app shows a progress window and, at the end, a dialog,
# and this file writes what they say into FILE as it goes:
#   progress: TEXT   what it is doing now (the app shows the last one)
#   dialog: TEXT     one line of what to tell the user at the end (none: all well)
#   done: STATUS     written last; 0 when everything answered

HERE="$(cd "$(dirname "$0")" && pwd -P)"
ENVFILE="$HERE/bundle.env"
DOCKER_APP="/Applications/Docker.app"
STATUS_FILE=""
trap 'exit 143' TERM HUP # Stop in the app's window: so the EXIT trap below still runs
if [ "${1:-}" = "--app" ]; then STATUS_FILE="${2:?--app needs a file}"; : > "$STATUS_FILE"; fi

say() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
progress() { # what the app's window says while this waits
  note "$*"
  [ -z "$STATUS_FILE" ] || printf 'progress: %s\n' "$*" >> "$STATUS_FILE"
}
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
LOCK="$HERE/.start-translation.lock"
finish() { # $1 = exit status
  [ "${HOLD_LOCK:-0}" = 0 ] || rm -rf "$LOCK"
  if [ -n "$STATUS_FILE" ]; then
    printf '%s' "${DIALOG:-}" | sed 's/^/dialog: /' >> "$STATUS_FILE"
    printf 'done: %s\n' "$1" >> "$STATUS_FILE"
  elif [ -t 0 ]; then
    # Opened by double-click, the window could close and take the result with it.
    printf '\nPress Return to close. '
    read -r _ || true
  fi
  exit "$1"
}
DIALOG="" # what the app's closing dialog says, a line at a time
tell() { DIALOG="$DIALOG$*"$'\n'; }

LT_URL="$(cfg LT_URL)"
if [ -z "$LT_URL" ]; then
  if [ -n "$STATUS_FILE" ]; then
    tell "Hoshi Offline Translation isn't installed on this Mac: its settings aren't in $HERE."
    tell ""
    tell "To install it, double-click Install.command in the Hoshi bundle folder (on the USB stick it came on)."
  fi
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
# Where to double-click this again: the app, where the install made one.
AGAIN="double-click this again"
[ -z "$STATUS_FILE" ] || AGAIN="open Hoshi Offline Translation again"

# One start at a time: the app and this file in a Terminal window, or the app
# opened twice, would otherwise each open Docker and wait for it.
if mkdir "$LOCK" 2>/dev/null; then
  echo "$$" > "$LOCK/pid"
  HOLD_LOCK=1
  trap 'rm -rf "$LOCK"' EXIT
elif OTHER="$(cat "$LOCK/pid" 2>/dev/null)" && [ -n "$OTHER" ] && kill -0 "$OTHER" 2>/dev/null; then
  echo "Offline translation is already being started, in another window or by the"
  echo "Hoshi Offline Translation app. Wait for that one: it opens the page when it is ready."
  tell "Hoshi Offline Translation is already being started, in another window."
  tell ""
  tell "Wait for that one: it opens the translation page when everything is ready."
  finish 3
else # left by a start that was stopped part-way
  rm -rf "$LOCK"
  if mkdir "$LOCK" 2>/dev/null; then
    echo "$$" > "$LOCK/pid"
    HOLD_LOCK=1
    trap 'rm -rf "$LOCK"' EXIT
  fi
fi

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
    progress "Opening Docker Desktop"
    # By its place first, then by its name, which finds it if it was moved.
    if open -a "$DOCKER_APP" >/dev/null 2>&1 || open -b com.docker.docker >/dev/null 2>&1; then
      DOCKER_STATE="opened"
    else
      note "macOS couldn't find Docker Desktop to open it"
      DOCKER_STATE="missing"
    fi
  fi
fi
OLLAMA_STATE=""
if [ -n "$OLLAMA_APP" ] && ! answers "$OLLAMA_API/api/version"; then
  if [ ! -d "$OLLAMA_APP" ]; then
    note "Ollama isn't at $OLLAMA_APP any more"
    OLLAMA_STATE="missing"
  else
    progress "Opening Ollama"
    open "$OLLAMA_APP" >/dev/null 2>&1 || { note "macOS couldn't open $OLLAMA_APP"; OLLAMA_STATE="missing"; }
  fi
fi

LIBRE=""; GEMMA=""; PAGE=""; ADVICE=""
advise() { ADVICE="$ADVICE  $*"$'\n'; }
if [ "$WANT_DOCKER" = 1 ]; then
  if [ "$DOCKER_STATE" = "opened" ]; then
    progress "Waiting for Docker Desktop. It can take a few minutes after a restart."
    for i in $(seq 1 150); do
      if docker info >/dev/null 2>&1; then DOCKER_STATE="ready"; break; fi
      # Open but not answering after a minute: most often a window of its own
      # is waiting for an answer.
      if [ "$i" = 30 ] && pgrep -x com.docker.backend >/dev/null 2>&1; then
        progress "Docker Desktop is open but not ready yet. If a Docker window is asking something, answer it: accept its agreement, and skip signing in and updates."
      fi
      sleep 2
    done
  fi
  if [ "$DOCKER_STATE" = "ready" ]; then
    # They start with Docker by themselves, unless someone stopped them by hand.
    docker start "${LT_CONTAINER:-libretranslate}" >/dev/null 2>&1 || true
    [ -z "$WEB_URL" ] || docker start "${WEB_CONTAINER:-translation-web}" >/dev/null 2>&1 || true
    progress "Waiting for LibreTranslate. It takes a minute or two to load its languages."
    if wait_for "$LT_URL/languages" 150; then
      LIBRE="ready"
    else
      LIBRE="NOT answering"
      advise "LibreTranslate: Docker is running but LibreTranslate didn't answer on $LT_URL."
      advise "  Open Docker Desktop, look under Containers for '${LT_CONTAINER:-libretranslate}', and press its start button."
    fi
    if [ -n "$WEB_URL" ]; then
      progress "Waiting for the translation page"
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
    if [ "$DOCKER_STATE" = "missing" ]; then
      advise "Docker Desktop: it isn't in Applications. LibreTranslate and the translation page run inside it."
      advise "  If it was moved, put Docker back in Applications. If it was removed, run the"
      advise "  installer again from the bundle: it installs Docker Desktop. Then $AGAIN."
    elif pgrep -x com.docker.backend >/dev/null 2>&1; then
      advise "Docker Desktop is open but didn't become ready. LibreTranslate and the translation page run inside it."
      advise "  Look for a Docker window that is asking something, and answer it: accept its"
      advise "  agreement, and skip signing in and updates. When Docker says it is running, $AGAIN."
    else
      advise "Docker Desktop didn't start. LibreTranslate and the translation page run inside it."
      advise "  Open Docker from Applications, answer anything it asks (skip signing in and"
      advise "  updates), wait until it says it is running, then $AGAIN."
    fi
  fi
fi
if [ -n "$OLLAMA_APP" ]; then
  if [ "$OLLAMA_STATE" = "missing" ]; then
    GEMMA="NOT answering"
    advise "TranslateGemma: Ollama, which runs it, isn't at $OLLAMA_APP any more."
    advise "  If it was moved, put Ollama back in $(dirname "$OLLAMA_APP"). If it was removed, run the"
    advise "  installer again from the bundle: it installs Ollama. Then $AGAIN."
  else
    progress "Waiting for TranslateGemma (Ollama)"
    if wait_for "$OLLAMA_API/api/version" 30; then
      GEMMA="ready"
    else
      GEMMA="NOT answering"
      advise "TranslateGemma: Ollama, which runs it, didn't answer."
      advise "  Open Ollama from $(dirname "$OLLAMA_APP"), finish anything it asks, then $AGAIN."
    fi
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
if [ -n "$OPEN_URL" ]; then
  tell "The translation page is open, but not everything started:"
else
  tell "Hoshi Offline Translation didn't start:"
fi
tell ""
# A dialog wraps lines itself: each piece of advice as one paragraph, with
# the lines it was wrapped into for Terminal joined up again.
tell "$(printf '%s' "$ADVICE" | awk '
  /^    / { sub(/^ +/, ""); text = text " " $0; next }
  { if (text != "") print text "\n"; sub(/^ +/, ""); text = $0 }
  END { if (text != "") print text }')"
[ -z "$SUPPORT" ] || { tell ""; tell "For help: $SUPPORT"; }
finish 1
