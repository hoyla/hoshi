#!/bin/bash
# Every check that can be run on a Mac, in one command. Run it from anywhere
# before saying a change is done:
#
#     tests/check.sh
#
# It runs the regression tests, the splitter parity check, a syntax check of
# every shell script and of every PowerShell script, and the rule that the
# Windows scripts stay ASCII. PowerShell 7 is used from `pwsh` if that is
# installed, and otherwise from a Docker image (PWSH_IMAGE), as
# calibration/windows.sh does. It does NOT run the Windows installer tests:
# those need Windows, and Windows PowerShell 5.1 exists nowhere else, so the
# regression workflow on a pull request is their only run.

set -uo pipefail
cd "$(dirname "$0")/.."

PWSH_IMAGE="${PWSH_IMAGE:-mcr.microsoft.com/dotnet/sdk:8.0}"
FAILED=""
step() { printf '\n==> %s\n' "$*"; }
failed() { FAILED="$FAILED  $*"$'\n'; printf 'FAILED: %s\n' "$*"; }

step "Regression tests"
python3 -m unittest discover -s tests || failed "regression tests"

step "Splitter parity"
python3 web/tests/test_parity.py || failed "splitter parity"

step "Shell syntax (macOS's own bash)"
for script in build-*.sh bundle/*.sh bundle/*.command calibration/*.sh tests/*.sh web/*.sh; do
  /bin/bash -n "$script" || failed "shell syntax: $script"
done

step "PowerShell syntax"
POWERSHELL_FILES=(bundle/*.ps1 tests/*.ps1)
if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -File tests/parse_powershell.ps1 "${POWERSHELL_FILES[@]}" || failed "PowerShell syntax"
elif docker image inspect "$PWSH_IMAGE" >/dev/null 2>&1; then
  # Nothing in the files is run, and the container gets no network and no
  # way to write to the checkout.
  docker run --rm --network none -v "$PWD:/src:ro" -w /src "$PWSH_IMAGE" \
    pwsh -NoProfile -File tests/parse_powershell.ps1 "${POWERSHELL_FILES[@]}" || failed "PowerShell syntax"
else
  failed "PowerShell syntax: no PowerShell to check with. Install it (brew install powershell), or with Docker running: docker pull $PWSH_IMAGE"
fi

step "Windows scripts are ASCII"
# Windows PowerShell 5.1 reads a script without a byte-order mark in the PC's
# own code page; translate.ps1's header says more.
if LC_ALL=C grep -n '[^[:print:][:space:]]' bundle/*.ps1 bundle/*.cmd; then
  failed "non-ASCII characters in the Windows scripts, on the lines above"
fi

if [ -n "$FAILED" ]; then
  printf '\nNOT PASSED:\n%s' "$FAILED"
  exit 1
fi
printf '\nAll checks passed. Not run here: the Windows installer tests (see the top of this file).\n'
