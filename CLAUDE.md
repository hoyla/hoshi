# Working in this repository

Hoshi builds an offline translation bundle that is carried on a USB stick to
airgapped Macs and Windows PCs and installed there by journalists, not
developers. [README.md](README.md) is the full account; this file is the
short list of things that are easy to get wrong.

## Before saying a change is done

Run `tests/check.sh`. It is the one definition of "the checks pass" on a Mac:
regression tests, splitter parity, shell syntax, PowerShell syntax, and the
ASCII rule for the Windows scripts. [tests/README.md](tests/README.md) says
what each part covers.

## PowerShell on the development Mac

There is no `pwsh` command on the development Mac, and that does not mean
PowerShell is unavailable. PowerShell 7 runs from the Docker image
`mcr.microsoft.com/dotnet/sdk:8.0`, which `tests/check.sh` and
`calibration/windows.sh` use by themselves. (`mcr.microsoft.com/powershell`
has no Apple Silicon build and crashes under emulation.) Never write or change
a `.ps1` file without at least parsing it this way.

What a Mac cannot do: run the Windows installer tests, or anything under
Windows PowerShell 5.1, which is the version the target PCs have. Those run
only in the regression workflow on a pull request. Code that passes under
PowerShell 7 has failed under 5.1 before, so read that job's result before
calling Windows work finished, and say plainly in the pull request what was
run where.

More generally: before concluding a tool is not available here, search the
repository for how it already gets that tool (scripts, the workflow, the
READMEs), not only `PATH`.

## Constraints on what ships in a bundle

- The installers and helpers may use only what ships with the target system:
  macOS's own tools and bash 3.2 on a Mac; Windows PowerShell 5.1, the .NET
  Framework and robocopy on Windows. Nothing may need a network.
- `.ps1` and `.cmd` files are ASCII only and keep to PowerShell 5.1 syntax.
  The header of `bundle/translate.ps1` says why.
- Every installer step must be safe to run again.
- Never delete what the installer did not itself put there. Its containers
  carry the label `airgapped-translation=1`; `~/.ollama` may hold the user's
  own models; an Ollama app is the installer's only where the installed
  `bundle.env` records it.
- Translations in `~/translation-tools/translations` must survive any install.

## Saying what was tested

README.md separates what has been tested from what has not, in its Status
section. Keep that up: anything a change adds that was not run against the
real thing (a real Docker Desktop, a real Ollama, a clean machine, a real
double-click) goes in "Not yet done", in the same change.
