#!/bin/bash
# Double-click this in Finder to install the bundle on a Mac. It runs
# install.sh from the folder it is in, in a Terminal window, and keeps the
# window open at the end so the summary, or the reason it stopped, can be read.
# Options go to install.sh:  ./Install.command --help

cd "$(dirname "$0")" || { echo "error: couldn't open the folder this file is in"; exit 1; }
if [ ! -f install.sh ]; then
  echo "error: install.sh isn't beside this file. Keep the bundle's files together"
  echo "in one folder, as they came, and double-click Install.command there."
  STATUS=1
else
  /bin/bash ./install.sh "$@"
  STATUS=$?
fi
echo
if [ "$STATUS" = 0 ]; then
  echo "The install finished. The summary is just above."
else
  echo "The install did NOT finish. The lines above say why and what to do."
fi
# Opened by double-click, the window could close and take the result with it.
if [ -t 0 ]; then
  printf 'Press Return to close. '
  read -r _ || true
fi
exit "$STATUS"
