#!/usr/bin/env python3
"""External-command stand-ins for installer tests; never operate real services."""

import json
import os
from pathlib import Path
import shutil
import sys
import zipfile

root = Path(os.environ["HOSHI_INSTALL_TEST_ROOT"]).resolve()
settings = json.loads((root / "settings.json").read_text())
state_path = root / "state.json"
state = json.loads(state_path.read_text())
command = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / "calls.jsonl").open("a", encoding="utf-8") as log:
    log.write(json.dumps({"command": command, "arguments": args}) + "\n")


def save():
    state_path.write_text(json.dumps(state))


def fail(message="stand-in failure", code=1):
    print(message, file=sys.stderr)
    sys.exit(code)


def destination(path):
    resolved = Path(path).resolve()
    if not resolved.is_relative_to(root):
        fail(f"test attempted a write outside its fixture: {resolved}")
    return resolved


if command == "uname":
    print("Darwin" if args == ["-s"] else "arm64")
elif command == "sysctl":
    print(16 * 1024**3 if args[-1] == "hw.memsize" else "Test Apple Silicon")
elif command == "docker":
    if args[0] == "info":
        if settings.get("docker_down") and not state.get("docker_started"):
            fail("Docker is stopped")
        print("overlay2")
    elif args[0] == "version":
        print("test-docker")
    elif args[0] == "load":
        if settings.get("load_fails"):
            fail("no space left on device")
        if not Path(args[-1]).is_file():
            fail("missing image")
        print("Loaded image")
    elif args[:2] == ["image", "inspect"]:
        if settings.get("image_missing"):
            fail("no such image")
        print("sha256:test-loaded-image")
    elif args[:2] == ["container", "inspect"]:
        if not state.get("container") and not settings.get("foreign_container"):
            fail("no such container")
        print("0" if settings.get("foreign_container") else "1")
    elif args[0] == "rm":
        state["container"] = False
        save()
    elif args[0] == "run":
        if settings.get("run_fails"):
            fail("could not start container")
        if "--rm" in args:
            print("Filesystem 1M-blocks Used Available Use% Mounted\nfixture 100000 1000 99000 1% /")
        else:
            state["container"] = True
            save()
            print("test-container-id")
    elif args[0] == "logs":
        print("test container log")
    elif args[:2] == ["system", "df"]:
        print("test Docker disk usage")
    else:
        fail(f"unexpected docker call: {args}")
elif command == "curl":
    url = next(arg for arg in args if arg.startswith("http://"))
    if url.endswith("/languages"):
        if settings.get("libre_down"):
            fail(code=22)
        print('[{"code":"en","targets":["fr"]},{"code":"fr","targets":["en"]}]')
    elif url.endswith("/translate"):
        if settings.get("translation_fails"):
            fail(code=22)
        print('{"translatedText":"Les documents sont arrives ce matin."}')
    elif url.endswith("/api/version"):
        if settings.get("ollama_down"):
            fail(code=22)
        print('{"version":"test"}')
    elif url.endswith("/api/config"):
        if settings.get("web_down"):
            fail(code=22)
        print('{"gemma":{"ok":true},"libre":{"ok":true}}')
    else:
        fail(f"unexpected curl call: {args}")
elif command == "nc":
    sys.exit(0 if settings.get("port_taken") else 1)
elif command == "open":
    if settings.get("open_fails"):
        fail("could not open application")
    state["docker_started"] = True
    save()
elif command == "ditto":
    if settings.get("copy_fails"):
        fail("copy failed")
    target = destination(args[-1])
    if args[:2] == ["-x", "-k"]:
        with zipfile.ZipFile(args[-2]) as archive:
            archive.extractall(target)
    else:
        shutil.copytree(args[-2], target, dirs_exist_ok=True)
elif command == "seq":
    # Exercise timeout failures without waiting several minutes.
    print(1)
elif command == "sleep":
    pass
elif command in ("sudo", "hdiutil"):
    fail(f"{command} must never be called by the full-installer harness")
else:
    fail(f"unexpected stand-in: {command}")
