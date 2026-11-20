# Regression tests

One command runs everything a Mac can check, and is what "the checks pass"
means for a change:

```bash
python3 -m pip install -r tests/requirements.txt
tests/check.sh
```

It runs the regression tests, the splitter parity check, a syntax check of
every shell script with macOS's own bash and of every PowerShell script, and
the rule that the Windows scripts stay ASCII. PowerShell 7 comes from `pwsh`
if that is installed and otherwise from the Docker image
`mcr.microsoft.com/dotnet/sdk:8.0` (`PWSH_IMAGE` names another), which is how
a Mac without PowerShell still checks the Windows scripts. The parts can be
run alone:

```bash
python3 -m unittest discover -s tests -v
python3 web/tests/test_parity.py
```

`check.sh` does not run the Windows installer tests. They need Windows, and
Windows PowerShell 5.1, which the target PCs have, exists nowhere else: the
regression workflow on a pull request is their only run. A PowerShell change
that parses here can still fail there.

The pip dependencies support the web and optional evaluation tests. The offline
installers keep using tools supplied by their target operating systems. Evaluation
tests verify the frozen corpus, saved output hashes, complete case coverage,
metric signatures, resumable work files and the absence of invented human
ratings. They never download a model or run real inference in CI.

| Tests | Where they run | What they exercise |
|---|---|---|
| Mac installer | macOS, native Bash | Tiny bundle installation, reruns, checksums, loopback binding, recorded image ID, retained translations, logs, conflicts, Docker startup, copying and engine failures. Checks made before the checksum pass (macOS version, ports, disk space, memory); installing over an earlier install (older or newer bundle, the earlier image removed, kept while in use or after a failed run, leftover models listed and left, Ollama replaced only where an earlier install put it there); the closing lines of a failed run and the support line; `Install.command`; `Start Translation.command` with each service down. The Hoshi Offline Translation app, compiled by the real `osacompile` and signed by the real `codesign`: made and recorded, put in `~/Applications` when the app folder is read-only, replaced on a re-run only where the installer made it, left alone where it didn't, and left out with `--no-app`. What the app runs, `Start Translation.command --app FILE`, with each service down, Docker Desktop missing, open but not ready, or never starting, Ollama moved, the install missing, and a second start while one runs: the dialog text names the right one and the support line, and the page opens only when it answers. |
| Windows installer | Windows PowerShell 5.1 or PowerShell 7 on Windows | Tiny bundle installation, reruns, checksums, loopback binding, recorded image ID, retained translations, conflicts, Linux-container checks, ARM image selection, model copying and setup failures, and the same pre-checksum, reinstall, failure and `start-translation.ps1` cases as the Mac. The Start-menu entry, made with the real `WScript.Shell` in a fixture folder (`--start-menu-dir`): its target, folder and icon read back, replaced on a re-run only where the installer made it, left alone where it didn't. Also the real `install.cmd` and `Start Translation.cmd` launchers for exit codes. |
| Web installers | macOS, native Bash; Windows PowerShell 5.1 or PowerShell 7 on Windows | The same cases against `install-web.sh` and `install-web.ps1`: checksums, loopback binding, upload tmpfs, the folder and system the page is told, prerequisites, moved or missing image tags, image/service identity conflicts, page startup and retained translations during updates. The full installers' cases cover the page being started in place of LibreTranslate's own, and `--no-web`. |
| Output integrity | Mac Bash, PowerShell, Python web code | Both engines, result reuse, changed settings/encoding, output and extracted-text hashes, concurrent writers, source snapshots and failed publication. |
| Splitter parity | macOS | The Python splitter, counters and trimming against the helper's own awk programs. |

`HOSHI_PWSH` can name a PowerShell executable. The output tests use `pwsh` when
available, or Windows PowerShell on Windows. The Windows installer tests default
to Windows PowerShell on Windows. A platform that is not available is reported
as skipped. The CI workflow explicitly selects each Windows runtime; its macOS
job also exercises the portable PowerShell helper.

Child processes start without an inherited `PSModulePath`, so each selected
runtime constructs its native module search path. This avoids the documented
[PowerShell 7 to Python to Windows PowerShell module-path inheritance issue](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_psmodulepath#starting-windows-powershell-from-powershell-7).

Each installer test constructs a fresh bundle and destination under a temporary
directory, including paths containing spaces. Checksums and file-copy assertions
use the fixture's real bytes. The production installer scripts are copied
unchanged into the bundle. The fixture translation helpers are small stand-ins:
these cases test the installer copying and calling them; `test_output_integrity`
runs the production translation helpers separately.

On macOS, the command stand-ins in `install_stubs.py` replace Docker, curl,
application opening, application copying, hardware identification, free disk
space, quitting Ollama and long waits. A started container holds its port in the
stand-ins, as a real one does, so every re-run meets its own earlier container
on the port.
The full-installer harness refuses any sudo or disk-image mounting command.
Docker startup is also tested by extracting the installer's actual startup
function and supplying a fixture application path, so those cases do not depend
on Docker Desktop being present on the host.
On Windows, `install_stubs.ps1` supplies Docker, robocopy, process-launch,
disk and memory queries in the installer's parent scope. A process-local .NET request factory
answers service health checks without contacting any network service. A tiny
.NET console executable stands in for the installed Ollama CLI, so reruns still
execute a real program when checking its version. All writes go to fixture
destinations; the user's applications and model store are not used.

These are regression tests of installer logic and native shell compatibility.
The Mac app's own AppleScript (its progress window and dialogs) is not run
here: only the script it runs, and that the app is made. They do not establish
that Docker Desktop installs, starts or accepts its
agreement on a clean machine; that `Install.command` or the "Start Translation"
files open from Finder or File Explorer; that Docker really frees an earlier
image's space; that a running Ollama quits and is replaced; that the genuine Ollama installer runs silently;
that a GPU is picked up; or that multi-gigabyte payloads load on the target's
filesystem and Docker image store. A full smoke bundle still needs a real
Windows machine and a clean airgapped Mac before those claims can be made.
