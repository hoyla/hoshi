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
                     "install-web.cmd", "languages.tsv", "Install.command", "Start Translation.command",
                     "Start Translation.cmd", "start-translation.ps1", "Hoshi Offline Translation.applescript",
                     "icons/hoshi.icns", "icons/hoshi.ico"):
            data = (ROOT / "bundle" / name).read_bytes()
            if name.endswith(".cmd"):
                data = data.replace(b"\r\n", b"\n").replace(b"\n", b"\r\n")
            (self.bundle / name).parent.mkdir(parents=True, exist_ok=True)
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

    def run_command(self, command, success=True):
        (self.root / "settings.json").write_text(json.dumps(self.settings))
        env = dict(self.environment)
        for setting, variable in (("libre_down", "HOSHI_TEST_LIBRE_DOWN"),
                                  ("ollama_down", "HOSHI_TEST_OLLAMA_DOWN"),
                                  ("web_down", "HOSHI_TEST_WEB_DOWN"),
                                  ("translation_fails", "HOSHI_TEST_TRANSLATION_FAIL")):
            env[variable] = "1" if self.settings.get(setting) else "0"
        done = subprocess.run(command, env=env, input="\n", capture_output=True, text=True, timeout=40)
        self.assertEqual(done.returncode == 0, success, done.stdout + done.stderr)
        return done.stdout + done.stderr

    def run_installer(self, *options, success=True):
        output = self.run_command(self.command(*options), success)
        if success:
            self.assertIn("==> Done", output)
        return output

    def set_bundle(self, **values):
        """Change lines of the bundle's bundle.env, as a different build would."""
        lines = [line for line in (self.bundle / "bundle.env").read_text().splitlines()
                 if line.split("=", 1)[0] not in values]
        self.write("bundle.env", "\n".join(lines + [f"{key}={value}" for key, value in values.items()]) + "\n")
        self.checksums()

    def earlier_install(self, text):
        """The bundle.env an earlier install would have left in the prefix."""
        self.prefix.mkdir(exist_ok=True)
        (self.prefix / "bundle.env").write_text(text)

    def installed(self):
        return (self.prefix / "bundle.env").read_text(encoding="utf-8-sig")

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


@unittest.skipUnless(sys.platform == "darwin", "the build script runs on a Mac")
class BundleBuildTests(unittest.TestCase):
    """What can be said of build-bundle.sh without Docker: a real build needs both engines."""

    def test_build_copies_the_launchers_it_ships(self):
        build = (ROOT / "build-bundle.sh").read_text()
        for name in ("Install.command", "Start Translation.command", "Start Translation.cmd",
                     "start-translation.ps1", "Hoshi Offline Translation.applescript", "icons/hoshi.icns",
                     "icons/hoshi.ico"):
            with self.subTest(name=name):
                self.assertTrue((ROOT / "bundle" / name).is_file())
                self.assertIn(name, build)
        for name in ("Install.command", "Start Translation.command"):
            self.assertTrue(os.access(ROOT / "bundle" / name, os.X_OK), name)

    def test_support_line_must_be_one_line(self):
        done = subprocess.run(["/bin/bash", str(ROOT / "build-bundle.sh"), "--support", "Sam\n020 7946 0000"],
                              capture_output=True, text=True, timeout=20)
        self.assertNotEqual(done.returncode, 0)
        self.assertIn("one line", done.stderr)


class InstallerCases:
    web_name = "translation-web"

    def started(self):
        return [call for call in self.calls("docker") if call[0] == "run" and "-d" in call]

    def test_install_copies_payload_and_records_actual_image(self):
        message = self.run_installer()
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
        self.assertNotIn("did not finish", message)
        self.assertNotIn("already has an install", message)
        self.assertNotIn("GB of memory", message.split("==> Done")[1]) # 16 GB here: nothing to remark on
        # the app (Mac) or Start-menu entry (Windows) that starts it all after a restart
        self.assert_launcher_made(self.launcher())
        self.assertIn(f"{self.launcher_key}={self.launcher()}", settings)
        self.assertIn("Hoshi Offline Translation", message.split("==> Done")[1])

    def test_rerun_replaces_only_our_container_and_keeps_translations(self):
        self.settings["old_image_present"] = True # in Docker, but no install of ours recorded it
        self.run_installer()
        translation = self.prefix / "keep.en.txt"
        translation.write_text("Existing translation.\n")
        self.mark_launcher()
        message = self.run_installer()
        self.assertEqual(translation.read_text(), "Existing translation.\n")
        self.assertFalse(self.launcher_marked()) # the installer's own, so made again
        self.assert_launcher_made(self.launcher())
        self.assertIn("built 2026-11-18T00:00:00Z from commit fixture-commit", message)
        self.assertIn("same bundle", message)
        self.assertEqual(self.image_removals(), [])
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
        # found before the checksum pass and the image load, not after them
        self.assertNotIn("Verifying the bundle's checksums", message)
        self.assert_not_started()

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

    def test_container_start_failure_says_what_to_do(self):
        self.settings["run_fails"] = True
        message = self.run_installer(success=False)
        self.assertNotIn("==> Done", message)
        self.assertIn("couldn't start LibreTranslate", message)

    def test_libre_unavailable_is_reported(self):
        self.settings["libre_down"] = True
        self.assertIn("LibreTranslate did not start", self.run_installer(success=False))

    def test_smoke_translation_failure_is_reported(self):
        self.settings["translation_fails"] = True
        self.assertIn("test translation failed", self.run_installer(success=False))

    def test_model_copy_failure_says_what_to_do(self):
        self.existing_ollama() # so that the models are the only thing copied
        self.settings["copy_fails"] = True
        message = self.run_installer("--no-docker", success=False)
        self.assertNotIn("==> Done", message)
        self.assertIn("couldn't copy the TranslateGemma models", message)

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

    # ---- checks made before any slow step
    def test_too_little_disk_space_stops_before_anything_is_installed(self):
        self.settings["disk_free_kb"] = 2000
        message = self.run_installer(success=False)
        self.assertIn("not enough free disk space", message)
        self.assertNotIn("Verifying the bundle's checksums", message)
        self.assert_not_started()

    def test_space_check_can_be_turned_off(self):
        self.settings["disk_free_kb"] = 2000
        self.run_installer("--no-space-check")

    def test_low_memory_warns_and_carries_on(self):
        self.settings["memory_gb"] = 8
        message = self.run_installer()
        self.assertIn("8 GB of memory", message)
        # said again at the end, where it is still on screen
        self.assertIn("8 GB of memory", message.split("==> Done")[1])

    # ---- installing over an earlier install
    def test_reinstall_says_when_the_bundle_is_newer_and_when_it_is_older(self):
        self.run_installer()
        self.set_bundle(BUNDLE_BUILT_UTC="2026-11-19T00:00:00Z", SOURCE_COMMIT="newer-commit")
        message = self.run_installer()
        self.assertIn("newer-commit", message)
        self.assertIn("is newer", message)
        self.assertNotIn("OLDER", message)
        self.set_bundle(BUNDLE_BUILT_UTC="2026-11-01T00:00:00Z", SOURCE_COMMIT="older-commit")
        message = self.run_installer()
        self.assertIn("IS OLDER", message)
        self.assertIn("OLDER bundle", message.split("==> Done")[1])

    def previous_image(self):
        self.earlier_install("BUNDLE_BUILT_UTC=2026-10-01T00:00:00Z\nSOURCE_COMMIT=earlier\n"
                             "LT_IMAGE_ID_INSTALLED=sha256:old-image\n")
        self.settings["old_image_present"] = True

    def image_removals(self):
        return [call for call in self.calls("docker") if call[:2] == ["image", "rm"]]

    def test_earlier_installs_image_is_removed_once_the_new_one_works(self):
        self.previous_image()
        self.assertIn("removed sha256:old-image", self.run_installer())
        calls = self.calls("docker")
        self.assertEqual(self.image_removals(), [["image", "rm", "sha256:old-image"]])
        # after both containers have been started on the new image
        last_start = max(index for index, call in enumerate(calls) if call[0] == "run" and "-d" in call)
        self.assertGreater(calls.index(["image", "rm", "sha256:old-image"]), last_start)

    def test_earlier_image_in_use_by_a_container_is_kept(self):
        self.previous_image()
        self.settings["old_image_in_use"] = True
        self.assertIn("still uses it", self.run_installer())
        self.assertEqual(self.image_removals(), [])

    def test_earlier_image_is_still_removed_by_the_run_after_a_failed_one(self):
        self.previous_image()
        self.settings["web_down"] = True
        self.run_installer(success=False)
        self.assertEqual(self.image_removals(), []) # not while the new install isn't working
        self.assertIn("LT_IMAGE_ID_PREVIOUS=sha256:old-image", self.installed())
        del self.settings["web_down"]
        self.run_installer()
        self.assertEqual(self.image_removals(), [["image", "rm", "sha256:old-image"]])

    def test_model_the_new_bundle_lacks_is_listed_and_left(self):
        self.earlier_install("BUNDLE_BUILT_UTC=2026-10-01T00:00:00Z\n"
                             "GEMMA_MODELS=translategemma:27b,translategemma:1b,translategemma:12b\n")
        manifest = self.models / "manifests/registry.ollama.ai/library/translategemma/27b"
        manifest.parent.mkdir(parents=True)
        manifest.write_text('{"config":{"digest":"sha256:c","size":1073741824},'
                            '"layers":[{"digest":"sha256:a","size":16106127360},{"digest":"sha256:b","size":1073741824}]}')
        closing = self.run_installer().split("==> Done")[1]
        self.assertIn("translategemma:27b", closing)
        self.assertIn("17.0 GB", closing)
        self.assertRegex(closing, r'ollama(\.exe)?" rm translategemma:27b')
        self.assertNotIn("rm translategemma:12b", closing) # the new bundle carries it
        self.assertNotIn("translategemma:1b", closing) # no longer on the computer
        self.assertTrue(manifest.is_file())
        # still said by the next run, for as long as the model is there
        self.assertIn("rm translategemma:27b", self.run_installer())

    def test_ollama_an_earlier_install_put_there_is_replaced_by_a_newer_one(self):
        self.run_installer()
        self.assertIn("OLLAMA_APP_BY_INSTALLER=1", self.installed())
        self.newer_ollama_in_bundle()
        self.assertIn("Replacing Ollama", self.run_installer())
        self.assert_ollama_installs(2)
        self.assertIn("OLLAMA_APP_BY_INSTALLER=1", self.installed())

    def test_ollama_and_launcher_that_were_already_there_are_never_replaced(self):
        self.existing_ollama()
        self.newer_ollama_in_bundle()
        self.existing_launcher()
        message = self.run_installer()
        self.assertIn("leaving it as it is", message)
        self.assertIn("To switch", message)
        self.assert_ollama_installs(0)
        self.assertIn("OLLAMA_APP_BY_INSTALLER=0", self.installed())
        self.assertIn("didn't make", message.split("==> Done")[1])
        self.assertTrue(self.launcher_marked())
        self.assertNotIn(self.launcher_key, self.installed())
        # and a second run does not take the first run's record as its own work
        message = self.run_installer()
        self.assertIn("leaving it as it is", message)
        self.assert_ollama_installs(0)
        self.assertTrue(self.launcher_marked())

    # ---- failures
    def test_failure_ends_with_what_stopped_and_that_a_rerun_is_safe(self):
        self.settings["load_fails"] = True
        message = self.run_installer(success=False)
        closing = message.split("The install did not finish")[1]
        self.assertIn("It stopped at this step: Loading libretranslate-offline", closing)
        self.assertIn("safe to run the installer again", closing)
        self.assertNotIn("For help", closing)
        (log,) = self.prefix.glob("install-*.log")
        self.assertIn(str(log), closing)
        self.assertIn("docker load failed", log.read_text(encoding="utf-8-sig"))

    def test_failure_gives_the_builders_support_line(self):
        self.set_bundle(SUPPORT="Sam on the data desk, extension 4321")
        self.settings["load_fails"] = True
        self.assertIn("For help: Sam on the data desk, extension 4321", self.run_installer(success=False))



    # ---- starting again after a restart
    def test_start_translation_opens_the_page_and_names_what_is_not_answering(self):
        self.run_installer("--no-open")
        self.assertIn(f"WEB_URL=http://127.0.0.1:{self.web_port}", self.installed())
        (self.root / "calls.jsonl").unlink()
        message = self.run_command(self.start_command())
        self.assertNotIn("NOT answering", message)
        self.assertEqual(self.opened_pages(), [f"http://127.0.0.1:{self.web_port}"])
        for setting, name, others in (("libre_down", "LibreTranslate", ("TranslateGemma    NOT",)),
                                      ("ollama_down", "TranslateGemma", ("LibreTranslate    NOT",)),
                                      ("web_down", "Translation page", ("LibreTranslate    NOT", "TranslateGemma    NOT"))):
            with self.subTest(setting=setting):
                self.settings = {setting: True}
                (self.root / "calls.jsonl").unlink()
                message = self.run_command(self.start_command(), success=False)
                self.assertRegex(message, name + r" +NOT answering")
                for other in others:
                    self.assertNotIn(other, message)
                # the page is still worth opening with one engine down, but not if it is the page that is down
                self.assertEqual(bool(self.opened_pages()), setting != "web_down")

    def test_start_translation_from_the_bundle_folder_says_to_install_first(self):
        self.prefix = self.bundle # the copy on the drive, which nothing was installed from
        self.assertIn("isn't installed", self.run_command(self.start_command(), success=False))


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
        for command in ("uname", "sysctl", "docker", "curl", "nc", "open", "ditto", "seq", "sleep", "sudo", "hdiutil",
                        "df", "osascript", "pgrep"):
            (binary_folder / command).symlink_to(launcher)
        self.environment["PATH"] = str(binary_folder) + os.pathsep + os.environ["PATH"]


@unittest.skipUnless(sys.platform == "darwin", "Mac installer tests need macOS")
class MacInstallerTests(MacFixture, InstallerCases, unittest.TestCase):
    helper = "translate.sh"

    def command(self, *options):
        return ["/bin/bash", str(self.bundle / "install.sh"), "--prefix", str(self.prefix),
                "--app-dir", str(self.apps), "--port", self.port, "--name", "test-libre",
                "--web-port", self.web_port, *options]

    start_script = "Start Translation.command"

    def start_command(self, *options):
        return ["/bin/bash", str(self.prefix / self.start_script), *options]

    # ---- the Hoshi Offline Translation app
    launcher_key = "LAUNCHER_APP"

    def launcher(self):
        return self.apps / "Hoshi Offline Translation.app"

    def assert_launcher_made(self, app):
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["CFBundleIdentifier"], "local.hoshi.offline-translation")
        self.assertEqual(info["CFBundleName"], "Hoshi Offline Translation")
        resources = app / "Contents/Resources"
        self.assertEqual((resources / "install-folder.txt").read_text(), f"{self.prefix}\n")
        self.assertEqual((resources / "applet.icns").read_bytes(), (ROOT / "bundle/icons/hoshi.icns").read_bytes())
        self.assertTrue((resources / "Scripts/main.scpt").is_file())
        # changed after osacompile signed it, so signed again
        done = subprocess.run(["codesign", "--verify", "--strict", str(app)], capture_output=True, text=True)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertFalse((app.parent / ".hoshi-app-from-bundle").exists())

    def mark_launcher(self):
        (self.launcher() / "Contents/marker.txt").write_text("from before\n")

    def launcher_marked(self):
        return (self.launcher() / "Contents/marker.txt").exists()

    def existing_launcher(self):
        info = self.launcher() / "Contents/Info.plist"
        info.parent.mkdir(parents=True)
        info.write_bytes(plistlib.dumps({"CFBundleIdentifier": "someone.else"}))
        self.mark_launcher()

    def test_app_goes_in_the_home_folders_applications_when_the_app_folder_is_read_only(self):
        self.apps.mkdir()
        self.apps.chmod(0o555)
        self.addCleanup(self.apps.chmod, 0o755)
        home = self.root / "home"
        home.mkdir()
        self.environment["HOME"] = str(home)
        message = self.run_installer("--no-ollama")
        app = home / "Applications/Hoshi Offline Translation.app"
        self.assert_launcher_made(app)
        self.assertIn("can't be written to", message)
        self.assertIn(f"LAUNCHER_APP={app}", self.installed())
        self.assertFalse(self.launcher().exists())

    def start_for_app(self, success=True):
        """What the app would show: the starter run as the app runs it."""
        status = self.root / "status.txt"
        self.run_command(self.start_command("--app", str(status)), success)
        lines = status.read_text().splitlines()
        progress = [line[10:] for line in lines if line.startswith("progress: ")]
        dialog = "\n".join(line[8:] for line in lines if line.startswith("dialog: "))
        self.assertTrue(lines[-1].startswith("done: "), lines)
        return progress, dialog, lines[-1][6:]

    def test_app_says_what_did_not_start_and_what_to_do(self):
        self.set_bundle(SUPPORT="Sam on the data desk, extension 4321")
        self.run_installer("--no-open")
        self.assertEqual((self.launcher() / "Contents/Resources/support.txt").read_text(),
                         "Sam on the data desk, extension 4321\n")
        progress, dialog, status = self.start_for_app()
        self.assertEqual((dialog, status), ("", "0")) # all well: the page opens and nothing is said
        self.assertIn("Waiting for LibreTranslate. It takes a minute or two to load its languages.", progress)
        self.assertEqual(len(self.opened_pages()), 1)
        cases = (
            # setting, what the dialog names, whether the page still opens
            ({"libre_down": True}, "LibreTranslate: Docker is running but LibreTranslate didn't answer", True),
            ({"web_down": True}, "The translation page: Docker is running but the page didn't answer", False),
            ({"ollama_down": True}, "TranslateGemma: Ollama, which runs it, didn't answer", True),
            ({"docker_down": True, "open_fails": True}, "Docker Desktop: it isn't in Applications", False),
            ({"docker_never_ready": True}, "Docker Desktop didn't start", False),
            ({"docker_never_ready": True, "docker_backend_running": True},
             "Docker Desktop is open but didn't become ready", False),
        )
        for settings, named, page_opens in cases:
            with self.subTest(settings=settings):
                self.settings = settings
                (self.root / "calls.jsonl").unlink(missing_ok=True)
                state = json.loads((self.root / "state.json").read_text())
                state["docker_started"] = False # as after a restart
                (self.root / "state.json").write_text(json.dumps(state))
                progress, dialog, status = self.start_for_app(success=False)
                self.assertEqual(status, "1")
                self.assertIn(named, dialog)
                self.assertIn("For help: Sam on the data desk, extension 4321", dialog)
                self.assertEqual(bool(self.opened_pages()), page_opens)
                self.assertEqual(dialog.startswith("The translation page is open"), page_opens)
                if settings.get("docker_backend_running"):
                    self.assertIn("accept its", dialog)
        # Ollama moved or removed: said at once, not after a wait for it
        self.settings = {"ollama_down": True}
        shutil.rmtree(self.apps / "Ollama.app")
        progress, dialog, status = self.start_for_app(success=False)
        self.assertIn("TranslateGemma: Ollama, which runs it, isn't at", dialog)
        self.assertNotIn("Waiting for TranslateGemma (Ollama)", progress)
        self.assertNotIn("Opening Ollama", progress)

    def test_app_started_twice_waits_once(self):
        self.run_installer("--no-open")
        lock = self.prefix / ".start-translation.lock"
        lock.mkdir()
        (lock / "pid").write_text(f"{os.getpid()}\n") # a start that is still running
        (self.root / "calls.jsonl").unlink()
        _, dialog, status = self.start_for_app(success=False)
        self.assertEqual(status, "3")
        self.assertIn("already being started", dialog)
        self.assertFalse(self.calls("open")) # opened nothing, waited for nothing
        self.assertTrue(lock.is_dir()) # and left the other start's lock alone
        # one left by a start that was stopped part-way doesn't stop the next
        (lock / "pid").write_text("999999\n")
        self.assertEqual(self.start_for_app()[2], "0")
        self.assertFalse(lock.exists())

    def test_app_copied_to_a_mac_without_the_install_says_so(self):
        self.prefix = self.root / "nothing installed here"
        self.prefix.mkdir()
        shutil.copy(self.bundle / self.start_script, self.prefix)
        _, dialog, status = self.start_for_app(success=False)
        self.assertEqual(status, "1")
        self.assertIn("isn't installed on this Mac", dialog)
        self.assertIn("Install.command", dialog)

    def test_no_app_makes_none(self):
        self.run_installer("--no-app", "--no-ollama", "--no-docker")
        self.assertFalse(self.launcher().exists())
        self.assertNotIn("LAUNCHER_APP", self.installed())

    def opened_pages(self):
        return [call[0] for call in self.calls("open") if call[0].startswith("http://")]

    def newer_ollama_in_bundle(self):
        with zipfile.ZipFile(self.bundle / "ollama/Ollama-darwin.zip", "w") as archive:
            archive.writestr("Ollama.app/Contents/Info.plist", plistlib.dumps({"CFBundleShortVersionString": "0.0.2"}))
        self.set_bundle(OLLAMA_VERSION="v0.0.2")

    def existing_ollama(self):
        plist = self.apps / "Ollama.app/Contents/Info.plist"
        plist.parent.mkdir(parents=True)
        plist.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "0.0.1"}))
        (plist.parent / "theirs.txt").write_text("not the installer's\n")

    def assert_ollama_installs(self, count):
        unpacked = [call for call in self.calls("ditto") if call[:2] == ["-x", "-k"]]
        self.assertEqual(len(unpacked), count)
        plist = plistlib.loads((self.apps / "Ollama.app/Contents/Info.plist").read_bytes())
        self.assertEqual(plist["CFBundleShortVersionString"], "0.0.2" if count == 2 else "0.0.1")
        self.assertEqual((self.apps / "Ollama.app/Contents/theirs.txt").exists(), count == 0)
        self.assertFalse((self.apps / ".ollama-from-bundle").exists())

    def test_running_ollama_that_will_not_quit_is_not_replaced(self):
        self.run_installer()
        self.newer_ollama_in_bundle()
        self.settings["ollama_wont_quit"] = True
        self.assertIn("still running", self.run_installer(success=False))
        plist = plistlib.loads((self.apps / "Ollama.app/Contents/Info.plist").read_bytes())
        self.assertEqual(plist["CFBundleShortVersionString"], "0.0.1")

    def test_install_command_runs_the_installer_from_its_own_folder(self):
        launcher = self.bundle / "Install.command"
        self.assertTrue(os.access(ROOT / "bundle/Install.command", os.X_OK))
        options = self.command()[2:]
        message = self.run_command(["/bin/bash", str(launcher), *options])
        self.assertIn("==> Done", message)
        self.assertIn("The install finished", message)
        self.settings["load_fails"] = True
        message = self.run_command(["/bin/bash", str(launcher), *options], success=False)
        self.assertIn("did NOT finish", message)

    def test_old_macos_is_refused_before_anything_is_installed(self):
        tool = self.root / "bin/sw_vers"
        tool.write_text("#!/bin/sh\necho 13.6\n")
        tool.chmod(0o755)
        message = self.run_installer(success=False)
        self.assertIn("needs macOS 14", message)
        self.assertNotIn("Verifying the bundle's checksums", message)
        self.assert_not_started()

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
        # installer: a name in the bundle, or the whole path of a script elsewhere
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
                                            "--web-port", self.web_port, "--start-menu-dir", str(self.start_menu),
                                            *options])

    start_script = "start-translation.ps1"

    def start_command(self):
        return self.stubbed(self.prefix / self.start_script, [])

    # ---- the Start-menu entry
    launcher_key = "START_MENU_SHORTCUT"

    @property
    def start_menu(self):
        return self.root / "start menu"

    def launcher(self):
        return self.start_menu / "Hoshi Offline Translation.lnk"

    def assert_launcher_made(self, link):
        script = ("$s = (New-Object -ComObject WScript.Shell).CreateShortcut($env:HOSHI_TEST_LINK); "
                  "$s.TargetPath; $s.WorkingDirectory; $s.IconLocation")
        done = subprocess.run([WINDOWS_RUNTIME, "-NoProfile", "-Command", script],
                              env=dict(self.environment, HOSHI_TEST_LINK=str(link)),
                              capture_output=True, text=True, timeout=30)
        target, folder, icon = done.stdout.splitlines()[:3]
        self.assertTrue(os.path.samefile(target, self.prefix / "Start Translation.cmd"))
        self.assertTrue(os.path.samefile(folder, self.prefix))
        self.assertTrue(icon.endswith(",0"), icon)
        self.assertTrue(os.path.samefile(icon[:-2], self.prefix / "hoshi.ico"))
        self.assertEqual((self.prefix / "hoshi.ico").read_bytes(), (ROOT / "bundle/icons/hoshi.ico").read_bytes())

    # A shortcut file can't hold a marker of its own: an old date stands for one.
    def mark_launcher(self):
        os.utime(self.launcher(), (946684800, 946684800))

    def launcher_marked(self):
        return self.launcher().stat().st_mtime < 978307200

    def existing_launcher(self):
        self.start_menu.mkdir()
        self.launcher().write_bytes(b"someone else's shortcut")
        self.mark_launcher()

    def opened_pages(self):
        return [call[0] for call in self.calls("Start-Process") if call[0].startswith("http://")]

    def ollama_exe(self):
        return Path(self.environment["LOCALAPPDATA"]) / "Programs/Ollama/ollama.exe"

    def newer_ollama_in_bundle(self):
        self.set_bundle(OLLAMA_VERSION="v0.0.2") # the stand-in program stays at 0.0.1

    def existing_ollama(self):
        self.ollama_exe().parent.mkdir(parents=True)
        self.ollama_exe().write_bytes(self.ollama_bytes)

    def assert_ollama_installs(self, count):
        setups = [call for call in self.calls("Start-Process") if call[0].endswith("OllamaSetup.exe")]
        self.assertEqual(len(setups), count)

    def test_run_keeps_a_log_and_installs_the_start_launcher(self):
        self.run_installer()
        (log,) = self.prefix.glob("install-*.log")
        self.assertIn("==> Done", log.read_text(encoding="utf-8-sig"))
        self.assertEqual((self.prefix / "Start Translation.cmd").read_bytes(),
                         (self.bundle / "Start Translation.cmd").read_bytes())

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
        # Start Translation.cmd here is the copy on the drive, which says to install first.
        for launcher in ("install.cmd", "install-web.cmd", "Start Translation.cmd"):
            for option, expected in (("--help", 0), ("--unknown", 1)):
                if launcher.startswith("Start"):
                    expected = 1
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
