"""Exercise the unmodified installers with tiny bundles and service stand-ins.

    python3 -m unittest discover -s tests -v

Mac tests use native Bash and file/checksum tools. Windows tests run the real
installer under HOSHI_PWSH, Windows PowerShell 5.1 by default on Windows.
Docker, application setup, network transports and long waits are stand-ins;
no Docker image, model, real application or administrator access is needed.
"""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
WINDOWS = sys.platform == "win32"
WINDOWS_RUNTIME = os.environ.get("HOSHI_PWSH") or shutil.which("powershell") or shutil.which("pwsh")


class BundleFixture:
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hoshi-install-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bundle = self.root / "bundle files"
        self.bundle.mkdir()
        self.prefix = self.root / "translation tools"
        self.apps = self.root / "applications"
        self.models = self.root / "models"
        self.settings = {}
        self.port = "56123"
        self.web_port = "56124"
        if WINDOWS:
            # Both held at once, so the second isn't given the first's number.
            with socket.socket() as sock, socket.socket() as web_sock:
                sock.bind(("127.0.0.1", 0))
                web_sock.bind(("127.0.0.1", 0))
                self.port = str(sock.getsockname()[1])
                self.web_port = str(web_sock.getsockname()[1])
        (self.root / "state.json").write_text('{"container":false,"docker_started":false}')
        self.environment = dict(os.environ, HOSHI_INSTALL_TEST_ROOT=str(self.root),
                                OLLAMA_MODELS=str(self.models), OLLAMA_HOST="127.0.0.1:11434")
        self.environment.pop("TRANSLATION_INSTALL_LOG", None)
        # Python launched by pwsh inherits its Core module paths. Let each
        # child PowerShell runtime construct its own native module search path.
        for name in tuple(self.environment):
            if name.upper() == "PSMODULEPATH":
                del self.environment[name]
        for name in ("install.sh", "install.ps1", "install.cmd", "install-web.sh", "install-web.ps1",
                     "install-web.cmd", "languages.tsv"):
            data = (ROOT / "bundle" / name).read_bytes()
            if name.endswith(".cmd"):
                data = data.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
            (self.bundle / name).write_bytes(data)
        self.write("bundle.env", """BUNDLE_BUILT_UTC=2026-11-18T00:00:00Z
SOURCE_COMMIT=fixture-commit
LT_IMAGE_ARM64=libretranslate-offline:test-arm64
LT_TAR_ARM64=docker/libretranslate-test-arm64.tar
LT_IMAGE_ID_ARM64=sha256:build-image
LT_IMAGE_AMD64=libretranslate-offline:test-amd64
LT_TAR_AMD64=docker/libretranslate-test-amd64.tar
LT_IMAGE_ID_AMD64=sha256:build-image
LT_SELFTEST_PAIR=en:fr
OLLAMA_VERSION=v0.0.1
OLLAMA_ZIP=ollama/Ollama-darwin.zip
OLLAMA_SETUP=ollama/OllamaSetup.exe
GEMMA_MODELS=translategemma:12b
DEFAULT_MODEL=translategemma:12b
""")
        for name in ("MANIFEST.txt", "README.txt", "test-files/example.txt",
                     "docker/libretranslate-test-arm64.tar", "docker/libretranslate-test-amd64.tar",
                     "docker/Docker.dmg", "ollama/OllamaSetup.exe", "ollama/models/blobs/test-model",
                     "web/app.py", "web/static/index.html"):
            self.write(name, "fixture: " + name + "\n")
        # Installed helpers are stand-ins: installer tests assert the installer
        # copies and calls them; test_output_integrity runs the actual helpers.
        self.write("translate.sh", """#!/bin/bash
printf '%s\\n' "$*" >> "$HOSHI_INSTALL_TEST_ROOT/helper-calls.txt"
[ "${HOSHI_TEST_TRANSLATION_FAIL:-0}" != 1 ] || exit 1
printf '%s\\n' 'Les documents sont arrives ce matin.'
""")
        self.write("translate.ps1", """[System.IO.File]::AppendAllText((Join-Path $env:HOSHI_INSTALL_TEST_ROOT 'helper-calls.txt'), ($args -join ' ') + "`n")
if ($env:HOSHI_TEST_TRANSLATION_FAIL -eq '1') { exit 1 }
Write-Output 'Les documents sont arrives ce matin.'
exit 0
""")
        self.write("translate.cmd", "@echo off\r\n")
        with zipfile.ZipFile(self.bundle / "ollama/Ollama-darwin.zip", "w") as archive:
            archive.writestr("Ollama.app/Contents/Info.plist", plistlib.dumps({"CFBundleShortVersionString": "0.0.1"}))
        self.checksums()

    def write(self, relative, text):
        path = self.bundle / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(text.encode("utf-8"))

    def checksums(self):
        entries = []
        for path in sorted(self.bundle.rglob("*")):
            if path.is_file() and path.name != "SHA256SUMS":
                digest = hashlib.sha256(path.read_bytes()).hexdigest()
                entries.append(f"{digest}  ./{path.relative_to(self.bundle).as_posix()}\n")
        self.write("SHA256SUMS", "".join(entries))

    def run_installer(self, *options, success=True):
        (self.root / "settings.json").write_text(json.dumps(self.settings))
        env = dict(self.environment)
        for setting, variable in (("libre_down", "HOSHI_TEST_LIBRE_DOWN"),
                                  ("ollama_down", "HOSHI_TEST_OLLAMA_DOWN"),
                                  ("web_down", "HOSHI_TEST_WEB_DOWN"),
                                  ("translation_fails", "HOSHI_TEST_TRANSLATION_FAIL")):
            env[variable] = "1" if self.settings.get(setting) else "0"
        done = subprocess.run(self.command(*options), env=env, input="\n",
                              capture_output=True, text=True, timeout=40)
        self.assertEqual(done.returncode == 0, success, done.stdout + done.stderr)
        if success:
            self.assertIn("==> Done", done.stdout)
        return done.stdout + done.stderr

    def calls(self, command):
        path = self.root / "calls.jsonl"
        if not path.exists():
            return []
        return [row["arguments"] for line in path.read_text(encoding="utf-8-sig").splitlines()
                if (row := json.loads(line))["command"] == command]

    def assert_not_started(self):
        self.assertFalse(any(call[0] in ("run", "load", "rm") for call in self.calls("docker")))
        self.assertFalse(self.calls("Start-Process"))
        self.assertFalse(self.calls("ditto"))
        self.assertFalse(self.calls("robocopy"))


class InstallerCases:
    web_name = "translation-web"

    def started(self):
        return [call for call in self.calls("docker") if call[0] == "run" and "-d" in call]

    def test_install_copies_payload_and_records_actual_image(self):
        self.run_installer()
        self.assertEqual((self.prefix / self.helper).read_bytes(), (self.bundle / self.helper).read_bytes())
        self.assertEqual((self.models / "blobs/test-model").read_bytes(), b"fixture: ollama/models/blobs/test-model\n")
        self.assertTrue((self.prefix / "test-files/example.txt").is_file())
        settings = (self.prefix / "bundle.env").read_text(encoding="utf-8-sig")
        self.assertIn(f"LT_URL=http://127.0.0.1:{self.port}", settings)
        self.assertIn("LT_IMAGE_ID_INSTALLED=sha256:test-loaded-image", settings)
        run = next(call for call in self.calls("docker") if call[0] == "run" and "-d" in call)
        self.assertIn(f"127.0.0.1:{self.port}:5000", run)
        self.assertIn("airgapped-translation=1", run)
        self.assertIn("--pull", run)
        self.assertEqual(run[run.index("--pull") + 1], "never")
        self.assertEqual(run[-1], "sha256:test-loaded-image")
        self.assertIn("--engine gemma", (self.root / "helper-calls.txt").read_text())

    def test_rerun_replaces_only_our_container_and_keeps_translations(self):
        self.run_installer()
        translation = self.prefix / "keep.en.txt"
        translation.write_text("Existing translation.\n")
        self.run_installer()
        self.assertEqual(translation.read_text(), "Existing translation.\n")
        removals = [call for call in self.calls("docker") if call[0] == "rm"]
        self.assertEqual(removals, [["rm", "-f", "test-libre"], ["rm", "-f", self.web_name]])

    def test_translation_page_takes_the_place_of_libretranslates_own(self):
        self.run_installer()
        libre, page = self.started()
        self.assertIn("LT_DISABLE_WEB_UI=true", libre)
        self.assertEqual(page[page.index("--name") + 1], self.web_name)
        self.assertIn(f"127.0.0.1:{self.web_port}:8080", page)
        self.assertEqual((self.prefix / "web/app.py").read_bytes(), (self.bundle / "web/app.py").read_bytes())

    def test_no_web_leaves_libretranslates_own_page_on(self):
        self.run_installer("--no-web")
        (libre,) = self.started()
        self.assertNotIn("LT_DISABLE_WEB_UI=true", libre)
        self.assertFalse((self.prefix / "web").exists())

    def test_page_start_failure_is_not_reported_as_done(self):
        self.settings["web_down"] = True
        message = self.run_installer(success=False)
        self.assertIn("page did not start", message)
        self.assertNotIn("==> Done", message)

    def test_tampered_file_fails_before_installing(self):
        self.write("ollama/models/blobs/test-model", "tampered")
        self.assertIn("checksum verification failed", self.run_installer(success=False))
        self.assert_not_started()

    def test_missing_payload_fails_before_installing(self):
        (self.bundle / "ollama/models/blobs/test-model").unlink()
        self.assertIn("checksum verification failed", self.run_installer(success=False))
        self.assert_not_started()

    def test_other_platform_files_can_be_left_off(self):
        omitted = ("ollama/Ollama-darwin.zip", "docker/Docker.dmg", "docker/libretranslate-test-arm64.tar") if WINDOWS else (
            "ollama/OllamaSetup.exe", "docker/libretranslate-test-amd64.tar")
        for relative in omitted:
            (self.bundle / relative).unlink()
        self.run_installer()

    def test_foreign_container_is_never_removed(self):
        self.settings["foreign_container"] = True
        self.assertIn("didn't create", self.run_installer(success=False))
        self.assertFalse(any(call[0] == "rm" or (call[0] == "run" and "-d" in call)
                             for call in self.calls("docker")))

    def test_port_conflict_is_reported(self):
        self.settings["port_taken"] = True
        if WINDOWS:
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", int(self.port)))
                listener.listen()
                message = self.run_installer(success=False)
        else:
            message = self.run_installer(success=False)
        self.assertIn("already in use", message)
        self.assertFalse(any(call[0] == "run" and "-d" in call for call in self.calls("docker")))

    def test_image_load_failure_is_reported(self):
        self.settings["load_fails"] = True
        self.assertIn("docker load failed", self.run_installer(success=False))
        self.assertFalse(any(call[0] == "run" for call in self.calls("docker")))

    def test_failed_image_inspection_preserves_existing_container(self):
        self.run_installer()
        calls_before = len(self.calls("docker"))
        self.settings["image_missing"] = True
        self.assertIn("couldn't read the loaded", self.run_installer(success=False))
        self.assertFalse(any(call[0] in ("rm", "run") for call in self.calls("docker")[calls_before:]))

    def test_container_start_failure_is_not_reported_as_done(self):
        self.settings["run_fails"] = True
        self.assertNotIn("==> Done", self.run_installer(success=False))

    def test_libre_unavailable_is_reported(self):
        self.settings["libre_down"] = True
        self.assertIn("LibreTranslate did not start", self.run_installer(success=False))

    def test_smoke_translation_failure_is_reported(self):
        self.settings["translation_fails"] = True
        self.assertIn("test translation failed", self.run_installer(success=False))

    def test_copy_failure_is_not_reported_as_done(self):
        self.settings["copy_fails"] = True
        self.assertNotIn("==> Done", self.run_installer(success=False))

    def test_ollama_not_ready_is_explained(self):
        self.settings["ollama_down"] = True
        self.assertIn("not answering", self.run_installer())

    def test_skip_engines_still_installs_the_helper(self):
        self.run_installer("--no-docker", "--no-ollama")
        self.assertTrue((self.prefix / self.helper).is_file())
        self.assert_not_started()
        self.assertFalse(self.models.exists())

    def test_no_launch_does_not_run_gemma_smoke_test(self):
        self.run_installer("--no-launch")
        path = self.root / "helper-calls.txt"
        self.assertNotIn("--engine gemma", path.read_text() if path.exists() else "")


class MacFixture(BundleFixture):
    def setUp(self):
        super().setUp()
        binary_folder = self.root / "bin"
        binary_folder.mkdir()
        # An absolute interpreter also works when a developer's Python lives
        # in a pyenv or virtualenv directory rather than /usr/bin.
        launcher = self.root / "stand-in"
        launcher.write_text("#!" + sys.executable + "\n" + (ROOT / "tests/install_stubs.py").read_text())
        launcher.chmod(0o755)
        for command in ("uname", "sysctl", "docker", "curl", "nc", "open", "ditto", "seq", "sleep", "sudo", "hdiutil"):
            (binary_folder / command).symlink_to(launcher)
        self.environment["PATH"] = str(binary_folder) + os.pathsep + os.environ["PATH"]


@unittest.skipUnless(sys.platform == "darwin", "Mac installer tests need macOS")
class MacInstallerTests(MacFixture, InstallerCases, unittest.TestCase):
    helper = "translate.sh"

    def command(self, *options):
        return ["/bin/bash", str(self.bundle / "install.sh"), "--prefix", str(self.prefix),
                "--app-dir", str(self.apps), "--port", self.port, "--name", "test-libre",
                "--web-port", self.web_port, *options]

    def test_stopped_docker_is_handled_without_real_services(self):
        self.settings["docker_down"] = True
        if Path("/Applications/Docker.app").is_dir():
            self.run_installer()
            self.assertTrue(self.calls("open"))
        else:
            self.assertIn("Docker isn't running", self.run_installer(success=False))
            self.assertFalse(self.calls("open"))

    def run_docker_start(self, success=True):
        # Exercise the installer's actual startup function with a fixture app
        # path; a hosted runner does not need /Applications/Docker.app.
        source = (self.bundle / "install.sh").read_text()
        definitions = [re.search(rf"^{name}\(\) \{{.*?^\}}", source, re.M | re.S).group()
                       for name in ("start_docker",)]
        definitions += [re.search(rf"^{name}\(\) \{{[^\n]*", source, re.M).group()
                        for name in ("say", "note")]
        script = '\n'.join(definitions) + '\nDOCKER_APP="$HOSHI_INSTALL_TEST_ROOT/applications/Docker.app"\nstart_docker\n'
        (self.root / "settings.json").write_text(json.dumps(self.settings))
        done = subprocess.run(["/bin/bash", "-c", script], env=self.environment,
                              capture_output=True, text=True, timeout=15)
        self.assertEqual(done.returncode == 0, success, done.stdout + done.stderr)

    def test_docker_start_uses_fixture_app_and_waits_for_engine(self):
        self.settings["docker_down"] = True
        self.run_docker_start()
        self.assertEqual(self.calls("open"), [["-a", str(self.apps / "Docker.app")]])

    def test_docker_start_reports_failed_application_open(self):
        self.settings["open_fails"] = True
        self.run_docker_start(success=False)

    def test_docker_start_reports_engine_never_ready(self):
        self.settings["docker_never_ready"] = True
        self.run_docker_start(success=False)

    def test_run_keeps_a_log(self):
        self.run_installer()
        logs = list(self.prefix.glob("install-*.log"))
        self.assertEqual(len(logs), 1)
        self.assertIn("==> Done", logs[0].read_text())
        self.assertFalse(self.calls("sudo"))
        self.assertFalse(self.calls("hdiutil"))


class WindowsFixture(BundleFixture):
    def stubbed(self, installer, arguments):
        argument_file = self.root / "arguments.json"
        argument_file.write_text(json.dumps(arguments))
        return [WINDOWS_RUNTIME, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                str(ROOT / "tests/install_stubs.ps1"), "-Installer", str(self.bundle / installer),
                "-ArgumentsFile", str(argument_file)]


@unittest.skipUnless(WINDOWS and WINDOWS_RUNTIME, "Windows installer tests need Windows")
class WindowsInstallerTests(WindowsFixture, InstallerCases, unittest.TestCase):
    helper = "translate.ps1"

    @classmethod
    def setUpClass(cls):
        cls.binary_temp = tempfile.TemporaryDirectory(prefix="hoshi-fake-ollama-")
        cls.addClassCleanup(cls.binary_temp.cleanup)
        folder = Path(cls.binary_temp.name)
        source = folder / "ollama.cs"
        source.write_text('public class Ollama { public static int Main() { System.Console.WriteLine("ollama version is 0.0.1"); return 0; } }')
        output = folder / "ollama.exe"
        env = dict(os.environ, HOSHI_TEST_EXE_SOURCE=str(source), HOSHI_TEST_EXE_OUTPUT=str(output))
        subprocess.run([shutil.which("powershell"), "-NoProfile", "-Command",
                        "Add-Type -TypeDefinition (Get-Content -Raw -LiteralPath $env:HOSHI_TEST_EXE_SOURCE) "
                        "-OutputAssembly $env:HOSHI_TEST_EXE_OUTPUT -OutputType ConsoleApplication"],
                       env=env, capture_output=True, check=True, timeout=30)
        cls.ollama_bytes = output.read_bytes()

    def setUp(self):
        super().setUp()
        self.environment["LOCALAPPDATA"] = str(self.root / "local app data")
        (self.root / "fake-ollama.exe").write_bytes(self.ollama_bytes)

    def command(self, *options):
        return self.stubbed("install.ps1", ["--prefix", str(self.prefix), "--port", self.port, "--name", "test-libre",
                                            "--web-port", self.web_port, *options])

    def test_stopped_docker_is_reported(self):
        self.settings["docker_down"] = True
        self.assertIn("Docker isn't running", self.run_installer(success=False))
        self.assert_not_started()

    def test_windows_containers_are_rejected(self):
        self.settings["windows_containers"] = True
        self.assertIn("Windows containers", self.run_installer(success=False))
        self.assert_not_started()

    def test_arm64_docker_uses_arm64_payload(self):
        self.settings["arm64"] = True
        self.run_installer()
        load = next(call for call in self.calls("docker") if call[0] == "load")
        self.assertTrue(load[-1].endswith("-arm64.tar"))

    def test_failed_ollama_setup_is_reported(self):
        self.settings["setup_fails"] = True
        self.assertIn("Ollama installer did not finish", self.run_installer(success=False))

    def test_cmd_launchers_help_and_failure_status(self):
        for launcher in ("install.cmd", "install-web.cmd"):
            for option, expected in (("--help", 0), ("--unknown", 1)):
                with self.subTest(launcher=launcher, option=option):
                    done = subprocess.run(f'"{self.bundle / launcher}" {option}', shell=True,
                                          env=self.environment, input="\n", capture_output=True, text=True, timeout=20)
                    self.assertEqual(done.returncode, expected, done.stdout + done.stderr)


class WebInstallerCases:
    test_foreign_container_is_never_removed = InstallerCases.test_foreign_container_is_never_removed
    test_port_conflict_is_reported = InstallerCases.test_port_conflict_is_reported

    def setUp(self):
        super().setUp()
        self.prefix.mkdir()
        shutil.copy(self.bundle / "languages.tsv", self.prefix)
        (self.prefix / "bundle.env").write_text(
            "LT_IMAGE=libretranslate-offline:test-arm64\nLT_IMAGE_ID_INSTALLED=sha256:test-loaded-image\n"
            "LT_CONTAINER=installed-libre\nLT_URL=http://127.0.0.1:5050\n"
            "GEMMA_MODELS=translategemma:12b\nDEFAULT_MODEL=translategemma:12b\n"
        )

    def test_web_installer_publishes_only_on_loopback(self):
        self.run_installer()
        run = next(call for call in self.calls("docker") if call[0] == "run")
        self.assertIn(f"127.0.0.1:{self.port}:8080", run)
        self.assertIn("/uploads:rw,mode=1777", run)
        self.assertIn("sha256:test-loaded-image", " ".join(run))
        self.assertEqual((self.prefix / "web/app.py").read_bytes(), (self.bundle / "web/app.py").read_bytes())

    def test_page_is_told_the_folder_and_the_system_it_is_on(self):
        self.run_installer()
        run = next(call for call in self.calls("docker") if call[0] == "run")
        # Compared as a place, not as text: either side may spell the temporary
        # folder its own way (a symlink on macOS, a short name on Windows).
        folder = next(arg for arg in run if arg.startswith("HOST_DATA_DIR=")).split("=", 1)[1]
        self.assertTrue(os.path.samefile(folder, self.prefix / "translations"))
        self.assertIn(f"{folder}:/data", run)
        self.assertIn(f"HOST_OS={self.host_os}", run)
        self.assertIn("LT_URL=http://host.docker.internal:5050", run)
        self.assertIn("OLLAMA_API=http://host.docker.internal:11434", run)

    def test_web_uses_installed_image_when_tag_moves_or_disappears(self):
        for change in ("tag_moved", "tag_missing"):
            with self.subTest(change=change):
                self.settings = {change: True}
                self.run_installer()
                run = next(call for call in reversed(self.calls("docker")) if call[0] == "run")
                self.assertEqual(run[run.index("--entrypoint") + 2], "sha256:test-loaded-image")
                self.assertEqual(run[run.index("--pull") + 1], "never")
                self.assertIn("LT_IMAGE_ID=sha256:test-loaded-image", run)

    def test_missing_installed_id_does_not_fall_back_to_tag(self):
        settings = self.prefix / "bundle.env"
        settings.write_text(settings.read_text().replace("LT_IMAGE_ID_INSTALLED=sha256:test-loaded-image\n", ""))
        self.assertIn("installed image ID", self.run_installer(success=False))
        self.assert_not_started()

    def test_changed_service_image_preserves_the_existing_page(self):
        self.run_installer()
        self.settings["libre_image_changed"] = True
        calls_before = len(self.calls("docker"))
        page = self.prefix / "web/app.py"
        page.write_text("Existing page files.\n")
        self.assertIn("different image", self.run_installer(success=False))
        self.assertFalse(any(call[0] in ("rm", "run") for call in self.calls("docker")[calls_before:]))
        self.assertEqual(page.read_text(), "Existing page files.\n")

    def test_web_can_start_while_libre_container_is_absent(self):
        self.settings["libre_container_missing"] = True
        self.run_installer()

    def test_web_files_are_verified(self):
        self.write("web/app.py", "changed")
        self.assertIn("checksum verification failed", self.run_installer(success=False))
        self.assert_not_started()

    def test_existing_translations_survive_web_reinstall(self):
        self.run_installer()
        output = self.prefix / "translations/keep.txt"
        output.write_text("Existing translation.\n")
        self.run_installer()
        self.assertEqual(output.read_text(), "Existing translation.\n")

    def test_missing_bundle_install_is_reported(self):
        (self.prefix / "bundle.env").unlink()
        self.assertIn("isn't installed", self.run_installer(success=False))
        self.assert_not_started()

    def test_missing_image_is_reported(self):
        self.settings["image_missing"] = True
        self.assertIn("has no image", self.run_installer(success=False))
        self.assert_not_started()
        inspected = [call[-1] for call in self.calls("docker") if call[:2] == ["image", "inspect"]]
        self.assertEqual(inspected, ["sha256:test-loaded-image"])

    def test_page_start_failure_is_reported(self):
        self.settings["web_down"] = True
        self.assertIn("page did not start", self.run_installer(success=False))


@unittest.skipUnless(sys.platform == "darwin", "Mac web installer tests need macOS")
class WebInstallerTests(WebInstallerCases, MacFixture, unittest.TestCase):
    host_os = "mac"

    def command(self, *options):
        return ["/bin/bash", str(self.bundle / "install-web.sh"), "--prefix", str(self.prefix),
                "--port", self.port, "--name", "test-web", "--no-open", *options]


@unittest.skipUnless(WINDOWS and WINDOWS_RUNTIME, "Windows web installer tests need Windows")
class WindowsWebInstallerTests(WebInstallerCases, WindowsFixture, unittest.TestCase):
    host_os = "windows"

    def command(self, *options):
        return self.stubbed("install-web.ps1", ["--prefix", str(self.prefix), "--port", self.port,
                                                "--name", "test-web", "--no-open", *options])


if __name__ == "__main__":
    unittest.main()
