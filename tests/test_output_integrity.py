"""Result integrity tests using a local stand-in Ollama, without any models.

    python3 -m unittest discover -s tests -v

The Mac helper needs macOS. PowerShell tests use pwsh (or Windows PowerShell
on Windows); HOSHI_PWSH can name a portable runtime. Web tests additionally
need the dependencies already present in the LibreTranslate image.
"""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
PWSH = os.environ.get("HOSHI_PWSH") or shutil.which("pwsh") or (
    shutil.which("powershell") if sys.platform == "win32" else None
)


def sha(data):
    return hashlib.sha256(data).hexdigest()


class Engine(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, data, status=200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.startswith("/download_file/"):
            body = f"Translation {self.path.rsplit('/', 1)[1]}.\n".encode()
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.reply({"models": [{"name": "translategemma:12b", "digest": "test-model"}]})

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        if self.path == "/translate_file":
            message = BytesParser(policy=policy.default).parsebytes(
                b"Content-Type: " + self.headers["Content-Type"].encode() + b"\r\n\r\n" + body
            )
            payload = next(part.get_payload(decode=True) for part in message.iter_parts()
                           if part.get_param("name", header="Content-Disposition") == "file")
            ask = {"input": payload.decode("utf-8")}
        else:
            ask = json.loads(body)
        with self.server.received_lock:
            self.server.received.append(ask)
            number = len(self.server.received)
        if self.server.on_generate:
            self.server.on_generate()
        if self.server.barrier:
            self.server.barrier.wait(timeout=20)
        if self.server.fail:
            self.reply({"error": "test failure"}, 500)
            return
        if self.path == "/translate_file":
            self.reply({"translatedFileUrl": f"/download_file/{number}"})
        else:
            self.reply({"response": f"Translation {number}.", "done_reason": "stop"})


class HelperIntegrityMixin:
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hoshi-integrity-")
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        self.source = self.folder / "source.txt"
        self.source.write_text("The documents arrived this morning.\n", encoding="utf-8")
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Engine)
        self.server.received = []
        self.server.received_lock = threading.Lock()
        self.server.barrier = None
        self.server.on_generate = None
        self.server.fail = False
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        binary_folder = self.folder / "bin"
        binary_folder.mkdir()
        docker = binary_folder / ("docker.cmd" if sys.platform == "win32" else "docker")
        docker.write_text("@echo off\necho test-engine\n" if sys.platform == "win32"
                          else "#!/bin/sh\necho test-engine\n")
        docker.chmod(0o755)
        self.environment = dict(os.environ, OLLAMA_HOST=f"127.0.0.1:{self.server.server_port}",
                                LT_URL=f"http://127.0.0.1:{self.server.server_port}",
                                PATH=str(binary_folder) + os.pathsep + os.environ["PATH"])

    def command(self, *options, engine="gemma"):
        return self.runtime + [str(ROOT / "bundle" / self.helper), "--engine", engine,
                               "--from", "ru", "--to", "en", *options, str(self.source)]

    def run_helper(self, *options, success=True, engine="gemma"):
        done = subprocess.run(self.command(*options, engine=engine), env=self.environment,
                              capture_output=True, text=True, timeout=40)
        self.assertEqual(done.returncode == 0, success, done.stdout + done.stderr)
        return done

    def sides(self):
        return sorted(self.folder.glob("*.provenance.json"))

    def assert_complete(self, count):
        self.assertEqual(len(self.sides()), count)
        for path in self.sides():
            side = json.loads(path.read_text(encoding="utf-8"))
            output = self.folder / side["output_file"]
            self.assertEqual(sha(output.read_bytes()), side["output_sha256"])
            self.assertNotIn(".lock", output.name)
        self.assertEqual(list(self.folder.glob("*.lock")), [])

    def test_unchanged_reuses(self):
        self.run_helper()
        self.run_helper()
        self.assertEqual(len(self.server.received), 1)
        self.assert_complete(1)

    def test_modified_output_is_preserved_and_retranslated(self):
        self.run_helper()
        output = self.folder / json.loads(self.sides()[0].read_text())["output_file"]
        output.write_text("An edited translation.\n", encoding="utf-8")
        self.run_helper()
        self.assertEqual(output.read_text(), "An edited translation.\n")
        self.assertEqual(len(self.sides()), 2)
        # A third run must find the intact timestamped result.
        self.run_helper()
        self.assertEqual(len(self.server.received), 2)
        self.assertEqual(len(self.sides()), 2)

    def test_missing_output_is_retranslated(self):
        self.run_helper()
        side = json.loads(self.sides()[0].read_text())
        (self.folder / side["output_file"]).unlink()
        self.run_helper()
        self.assertEqual(len(self.server.received), 2)
        self.assertEqual(len(self.sides()), 2)

    def test_changed_encoding_is_not_reused(self):
        self.source.write_bytes("Привет мир.\n".encode("cp1251"))
        self.run_helper("--encoding", "CP1251")
        self.run_helper("--encoding", "CP1252")
        self.assertNotEqual(self.server.received[0]["prompt"], self.server.received[1]["prompt"])
        self.assert_complete(2)

    def test_changed_settings_and_old_sidecars_are_not_reused(self):
        self.run_helper()
        for field, value in (("engine_options", "old options"), ("tool", "old helper"),
                             ("input_sha256", "wrong input")):
            with self.subTest(field=field):
                for path in self.sides():
                    side = json.loads(path.read_text())
                    side[field] = value
                    path.write_text(json.dumps(side))
                self.run_helper()
        self.assert_complete(4)

    def test_concurrent_runs_get_separate_complete_results(self):
        self.server.barrier = threading.Barrier(2)
        with ThreadPoolExecutor(max_workers=2) as pool:
            results = [pool.submit(self.run_helper) for _ in range(2)]
            for result in results:
                result.result(timeout=45)
        self.assert_complete(2)
        contents = {(self.folder / json.loads(p.read_text())["output_file"]).read_text() for p in self.sides()}
        self.assertEqual(len(contents), 2)

    def test_force_runs_keep_all_results(self):
        self.run_helper()
        self.run_helper("--force")
        self.run_helper("--force")
        self.assert_complete(3)

    def test_failed_generation_releases_reservation(self):
        self.server.fail = True
        self.run_helper(success=False)
        self.assertEqual(self.sides(), [])
        self.assertEqual(list(self.folder.glob("*.lock")), [])
        self.server.fail = False
        self.run_helper()
        self.assert_complete(1)

    def test_stale_reservation_is_preserved(self):
        lock = self.folder / "source.en.gemma.txt.lock"
        lock.write_text("Interrupted run.\n")
        self.run_helper()
        side = json.loads(self.sides()[0].read_text())
        self.assertNotEqual(side["output_file"], "source.en.gemma.txt")
        self.assertEqual(lock.read_text(), "Interrupted run.\n")

    def test_existing_file_created_during_translation_is_preserved(self):
        output = self.folder / "source.en.gemma.txt"
        self.server.on_generate = lambda: output.write_text("Another writer's result.\n")
        self.run_helper(success=False)
        self.assertEqual(output.read_text(), "Another writer's result.\n")
        self.assertEqual(self.sides(), [])
        self.assertEqual(list(self.folder.glob("*.lock")), [])

    def test_provenance_failure_cleans_only_our_output(self):
        sidecar = self.folder / "source.en.gemma.txt.provenance.json"
        self.server.on_generate = lambda: sidecar.write_text("Another writer's sidecar.\n")
        self.run_helper(success=False)
        self.assertEqual(sidecar.read_text(), "Another writer's sidecar.\n")
        self.assertFalse((self.folder / "source.en.gemma.txt").exists())
        self.assertEqual(list(self.folder.glob("*.lock")), [])

    def test_source_hash_describes_translated_snapshot(self):
        original = self.source.read_bytes()
        self.server.on_generate = lambda: self.source.write_text("Changed while translating.\n")
        self.run_helper()
        side = json.loads(self.sides()[0].read_text())
        self.assertEqual(side["source_sha256"], sha(original))
        self.assertEqual(side["input_sha256"], sha(original))
        self.assertIn(original.decode().strip(), self.server.received[0]["prompt"])

    def test_libre_checks_encoding_and_output_integrity(self):
        self.source.write_bytes("Привет мир.\n".encode("cp1251"))
        self.run_helper("--encoding", "CP1251", engine="libre")
        self.run_helper("--encoding", "CP1251", engine="libre")
        self.assertEqual(len(self.server.received), 1)
        self.run_helper("--encoding", "CP1252", engine="libre")
        output = self.folder / "source.en.libre.txt"
        output.write_text("Edited translation.\n")
        self.run_helper("--encoding", "CP1251", engine="libre")
        self.assertEqual(len(self.server.received), 3)
        self.assertNotEqual(self.server.received[0]["input"], self.server.received[1]["input"])
        self.assertEqual(output.read_text(), "Edited translation.\n")
        self.assertEqual(len(self.sides()), 3)


@unittest.skipUnless(sys.platform == "darwin", "the Mac helper needs macOS tools")
class MacHelperTests(HelperIntegrityMixin, unittest.TestCase):
    runtime = ["/bin/bash"]
    helper = "translate.sh"


@unittest.skipUnless(PWSH, "set HOSHI_PWSH or install PowerShell to test the Windows helper")
class PowerShellHelperTests(HelperIntegrityMixin, unittest.TestCase):
    runtime = [PWSH, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File"]
    helper = "translate.ps1"


WEB_DEPS = all(importlib.util.find_spec(m) for m in ("flask", "requests", "lxml"))


@unittest.skipUnless(WEB_DEPS, "web tests need Flask, requests and lxml")
class WebIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hoshi-web-integrity-")
        self.addCleanup(self.temp.cleanup)
        self.folder = Path(self.temp.name)
        # Import without creating /data or requiring an installed language list.
        with patch.object(tempfile, "tempdir", tempfile.gettempdir()), patch.dict(
            os.environ, UPLOAD_DIR=str(self.folder / "uploads"),
            LANGFILE=str(ROOT / "bundle" / "languages.tsv"),
        ):
            sys.path.insert(0, str(ROOT / "web"))
            import app
        self.app = app
        for name, value in (("DATA_DIR", str(self.folder)), ("LT_IMAGE_ID", "sha256:test-image")):
            active = patch.object(app, name, value)
            active.start()
            self.addCleanup(active.stop)
        self.path = self.folder / "upload"
        self.path.write_bytes("Привет мир.\n".encode("cp1251"))
        self.upload = dict(id="u", name="source.txt", ext="txt", path=str(self.path),
                           size=self.path.stat().st_size, sha256=sha(self.path.read_bytes()), pasted=False)
        self.job = dict(encoding="cp1251", source="ru", target="en", model="translategemma:12b",
                        force=False, cancel=False)
        self.sent = []

        def translate(api, model, text, *args, **kwargs):
            self.sent.append(text)
            return f"Translation {len(self.sent)}.\n", 1, []

        for active in (
            patch.object(app.gemma, "models", return_value={"translategemma:12b": "sha256:test"}),
            patch.object(app.gemma, "translate", side_effect=translate),
            patch.object(app.check, "compare", return_value=("compared", [])),
        ):
            active.start()
            self.addCleanup(active.stop)

    def translate(self, **changes):
        return self.app.run_gemma(dict(self.job, **changes), self.upload)

    def test_unchanged_reuses(self):
        output, reused = self.translate()
        self.assertFalse(reused)
        self.assertEqual(self.translate(), (output, True))
        self.assertEqual(len(self.sent), 1)

    def test_changed_encoding_does_not_reuse(self):
        self.translate()
        self.assertFalse(self.translate(encoding="cp1252")[1])
        self.assertEqual(len(self.sent), 2)
        self.assertNotEqual(*self.sent)

    def test_modified_output_and_source_text_do_not_reuse(self):
        for field in ("output_file", "source_text_file"):
            with self.subTest(field=field):
                output, _ = self.translate(force=True)
                side = self.app.read_json(output + ".provenance.json")
                path = self.folder / side[field]
                path.write_text("Edited text.\n")
                with self.assertRaises(self.app.UserError):
                    self.app.load_result(output)
                self.assertFalse(self.translate()[1])
                self.assertEqual(path.read_text(), "Edited text.\n")
                # Remove other complete results so the next subcase cannot reuse them.
                for p in self.folder.glob("*.provenance.json"):
                    p.unlink()

    def test_changed_options_and_build_do_not_reuse(self):
        self.translate()
        with patch.object(self.app.gemma, "NUM_CTX", 4096):
            self.assertFalse(self.translate()[1])
        with patch.object(self.app, "TOOL", "new build"):
            self.assertFalse(self.translate()[1])

    def test_locked_result_is_not_reused(self):
        output, _ = self.translate()
        (self.folder / (output + ".lock")).touch()
        self.assertFalse(self.translate()[1])

    def test_source_text_collision_is_preserved(self):
        path = self.folder / "source.en.gemma.source-text.txt"
        path.write_text("Existing source.\n")
        output, _ = self.translate()
        self.assertNotEqual(output, "source.en.gemma.txt")
        self.assertEqual(path.read_text(), "Existing source.\n")

    def test_failed_provenance_cleans_partial_result(self):
        with patch.object(self.app, "write_provenance", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                self.translate()
        self.assertEqual(list(self.folder.glob("source.*")), [])

    def test_concurrent_writers_get_separate_results(self):
        barrier = threading.Barrier(2)
        original = self.app.write_provenance

        def write(*args, **kwargs):
            barrier.wait(timeout=10)
            return original(*args, **kwargs)

        with patch.object(self.app, "write_provenance", side_effect=write):
            with ThreadPoolExecutor(max_workers=2) as pool:
                results = [pool.submit(self.translate, force=True) for _ in range(2)]
                outputs = [result.result(timeout=15)[0] for result in results]
        self.assertEqual(len(set(outputs)), 2)
        for output in outputs:
            self.assertTrue(self.app.valid_result(self.app.read_json(output + ".provenance.json")))
        self.assertEqual(list(self.folder.glob("*.lock")), [])

    def test_long_output_names_remain_readable(self):
        self.upload["name"] = "x" * 140 + ".txt"
        output, _ = self.translate()
        self.assertIsNotNone(self.app.load_result(output))
        response = self.app.app.test_client().get("/api/result", query_string={"output": output})
        self.assertEqual(response.status_code, 200)

    def test_libre_checks_encoding_and_output_integrity(self):
        sent = []

        def libre(method, endpoint, **kwargs):
            if method == "POST":
                sent.append(kwargs["files"]["file"][1].read())
                reply = unittest.mock.Mock()
                reply.json.return_value = {"translatedFileUrl": "/download_file/test.txt"}
                return reply
            return unittest.mock.Mock(content=b"A translation.\n")

        with patch.object(self.app, "lt", side_effect=libre):
            output, reused = self.app.run_libre(self.job, self.upload)
            self.assertFalse(reused)
            self.assertEqual(self.app.run_libre(self.job, self.upload), (output, True))
            self.assertFalse(self.app.run_libre(dict(self.job, encoding="cp1252"), self.upload)[1])
            markdown = dict(self.upload, name="source.md", ext="md")
            self.assertFalse(self.app.run_libre(self.job, markdown)[1])
            (self.folder / output).write_text("Edited translation.\n")
            self.assertFalse(self.app.run_libre(self.job, self.upload)[1])
        self.assertEqual(len(sent), 4)
        self.assertNotEqual(sent[0], sent[1])
        self.assertEqual((self.folder / output).read_text(), "Edited translation.\n")


if __name__ == "__main__":
    unittest.main()
