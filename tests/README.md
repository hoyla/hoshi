# Regression tests

Run from the repository root:

```bash
python3 -m pip install -r tests/requirements.txt
python3 -m unittest discover -s tests -v
python3 web/tests/test_parity.py
```

The pip dependencies support the web and optional evaluation tests. The offline
installers keep using tools supplied by their target operating systems. Evaluation
tests verify the frozen corpus, saved output hashes, complete case coverage,
metric signatures, resumable work files and the absence of invented human
ratings. They never download a model or run real inference in CI.

| Tests | Where they run | What they exercise |
|---|---|---|
| Mac installer | macOS, native Bash | Tiny bundle installation, reruns, checksums, loopback binding, recorded image ID, retained translations, logs, conflicts, Docker startup, copying and engine failures. |
| Windows installer | Windows PowerShell 5.1 or PowerShell 7 on Windows | Tiny bundle installation, reruns, checksums, loopback binding, recorded image ID, retained translations, conflicts, Linux-container checks, ARM image selection, model copying and setup failures. Also the real `install.cmd` launcher for help and error exit codes. |
| Web installer | macOS, native Bash | Checksums, loopback binding, upload tmpfs, prerequisites, moved or missing image tags, image/service identity conflicts, page startup and retained translations during updates. |
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
application opening, application copying, hardware identification and long waits.
The full-installer harness refuses any sudo or disk-image mounting command.
Docker startup is also tested by extracting the installer's actual startup
function and supplying a fixture application path, so those cases do not depend
on Docker Desktop being present on the host.
On Windows, `install_stubs.ps1` supplies Docker, robocopy and process-launch
functions in the installer's parent scope. A process-local .NET request factory
answers service health checks without contacting any network service. A tiny
.NET console executable stands in for the installed Ollama CLI, so reruns still
execute a real program when checking its version. All writes go to fixture
destinations; the user's applications and model store are not used.

These are regression tests of installer logic and native shell compatibility.
They do not establish that Docker Desktop installs, starts or accepts its
agreement on a clean machine; that the genuine Ollama installer runs silently;
that a GPU is picked up; or that multi-gigabyte payloads load on the target's
filesystem and Docker image store. A full smoke bundle still needs a real
Windows machine and a clean airgapped Mac before those claims can be made.
