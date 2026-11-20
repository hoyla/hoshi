"""A web page in front of the two offline translation engines.

  gemma  TranslateGemma via Ollama. Better quality; gives back plain text.
         The page takes the text out of a document first (extract.py).
  libre  LibreTranslate. Keeps a document's layout; good enough for gisting.

It follows the rules of bundle/translate.sh. The uploaded file is only read.
Each translation is written to one folder with a .provenance.json beside it
recording the source hash, engine, exact model and time, and for gemma the
exact text that was sent to the model. Asking again for a translation that
exists gives back the existing one; nothing is overwritten. Each translation
is compared with its source by the helper's own dropped-text check (check.py).

Runs inside a container started from the LibreTranslate image, which already
has Flask, waitress, lxml, PyMuPDF and BeautifulSoup. It listens on localhost
only and refuses requests that name any other host. The computer the container
is on is a Mac or a Windows PC; the page is the same on both but for the few
words that say where to find things.
"""

import hashlib
import json
import os
import queue
import re
import shutil
import tempfile
import threading
import time
import uuid
import warnings
from contextlib import contextmanager
from datetime import datetime, timezone
from urllib.parse import urlsplit

# LibreTranslate's environment pins versions requests grumbles about on import
warnings.filterwarnings("ignore", message=".*doesn't match a supported version.*")

import requests  # noqa: E402
from flask import Flask, abort, jsonify, request, send_from_directory  # noqa: E402

import check  # noqa: E402
import extract  # noqa: E402
import gemma  # noqa: E402

VERSION = "3"
HERE = os.path.dirname(os.path.abspath(__file__))
# Which build of these files this is; written by whatever packaged them
try:
    with open(os.path.join(HERE, "BUILD"), encoding="utf-8") as handle:
        BUILD = handle.read().strip()
except OSError:
    BUILD = ""
TOOL = f"airgapped-translation web v{VERSION}" + (f" ({BUILD})" if BUILD else "")


def env(name, default):
    return os.environ.get(name) or default


LT_URL = env("LT_URL", "http://host.docker.internal:5050").rstrip("/")
OLLAMA_API = env("OLLAMA_API", "http://host.docker.internal:11434").rstrip("/")
# Where translations go, and what that folder is called on the computer itself
DATA_DIR = env("DATA_DIR", "/data")
HOST_DATA_DIR = env("HOST_DATA_DIR", DATA_DIR)
# "mac" or "windows": the installer says which, for the page's directions
HOST_OS = env("HOST_OS", "mac")
UPLOAD_DIR = env("UPLOAD_DIR", os.path.join(tempfile.gettempdir(), "translation-web-uploads"))
LANGFILE = env("LANGFILE", os.path.join(HERE, "languages.tsv"))
DEFAULT_MODEL = env("DEFAULT_MODEL", "translategemma:12b")
BUNDLE_MODELS = [m for m in env("GEMMA_MODELS", DEFAULT_MODEL).split(",") if m]
LT_IMAGE = env("LT_IMAGE", "unknown")
LT_IMAGE_ID = env("LT_IMAGE_ID", "unknown")
# This container is started from LibreTranslate's image, which says what it is
LT_VERSION_FILE = env("LT_VERSION_FILE", "/app/VERSION")
PORT = int(env("PORT", "8080"))

MAX_UPLOAD = 200 * 1024 * 1024
UPLOAD_LIFE = 6 * 3600
# How much of a text file the page shows beside its translation
MAX_SHOWN = 2 * 1024 * 1024

# Every temporary file goes where uploads go, which the installer makes a
# folder in memory: the upload as it arrives (the web framework spools a large
# one to a file), the UTF-8 copy sent to LibreTranslate, the checker's inputs.
os.makedirs(UPLOAD_DIR, exist_ok=True)
tempfile.tempdir = UPLOAD_DIR

app = Flask(__name__, static_folder=os.path.join(HERE, "static"), static_url_path="/static")
app.config["MAX_CONTENT_LENGTH"] = MAX_UPLOAD
app.json.ensure_ascii = False


class UserError(Exception):
    """Something to tell the person at the page, in their terms."""


def load_languages():
    names = {}
    with open(LANGFILE, encoding="utf-8") as handle:
        for line in handle:
            if line.startswith("#") or "\t" not in line:
                continue
            code, name = line.rstrip("\n").split("\t", 1)
            names[code] = name
    return names


GEMMA_LANGS = load_languages()


def gemma_code(code):
    """The TranslateGemma code for a LibreTranslate one, or None."""
    if code in GEMMA_LANGS:
        return code
    base = code.split("-")[0]
    return base if base in GEMMA_LANGS else None


def utc_now(compact=False):
    now = datetime.now(timezone.utc)
    return now.strftime("%Y%m%dT%H%M%SZ" if compact else "%Y-%m-%dT%H:%M:%SZ")


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


# ---------------------------------------------------------------- LibreTranslate
def lt(method, path, timeout=30, **kwargs):
    try:
        reply = requests.request(method, LT_URL + path, timeout=timeout, **kwargs)
    except requests.RequestException:
        raise UserError(
            "LibreTranslate isn't answering. Check in Docker Desktop that its container is running."
        ) from None
    if reply.status_code != 200:
        try:
            detail = reply.json().get("error", reply.text)
        except ValueError:
            detail = reply.text
        raise UserError(f"LibreTranslate returned HTTP {reply.status_code}: {detail}")
    return reply


def lt_version():
    # Not from LibreTranslate's /spec: version 1.9.6 takes about three times
    # longer to answer it on each call, until nothing else gets through.
    try:
        with open(LT_VERSION_FILE, encoding="utf-8") as handle:
            return handle.readline().strip() or "unknown"
    except OSError:
        return "unknown"


LT_VERSION = lt_version()
_lt_cache = {"at": 0.0, "value": None}


def lt_info():
    """LibreTranslate's version, languages and file types, or None if it is down."""
    if time.time() - _lt_cache["at"] < 30:
        return _lt_cache["value"]
    try:
        value = {
            "version": LT_VERSION,
            "languages": [
                {"code": x["code"], "name": x["name"]} for x in lt("GET", "/languages").json()
            ],
            "formats": lt("GET", "/frontend/settings").json().get("supportedFilesFormat", []),
        }
    except (UserError, ValueError):
        value = None
    _lt_cache.update(at=time.time(), value=value)
    return value


def detect_language(text):
    """(code, confidence) from LibreTranslate, which does the detecting for both engines."""
    found = lt("POST", "/detect", timeout=120, data={"q": text[:1500]}).json()
    if not found:
        raise UserError("The language couldn't be detected. Choose it from the list.")
    return found[0]["language"], found[0].get("confidence")


# ----------------------------------------------------------------------- uploads
UPLOADS = {}
uploads_lock = threading.Lock()


def safe_name(name):
    """A file name with nothing in it that could leave the folder."""
    name = os.path.basename((name or "").replace("\\", "/"))
    name = re.sub(r"[\x00-\x1f/:]", "_", name).strip().lstrip(".")
    return name[:150] or "document"


def clear_old_uploads():
    cutoff = time.time() - UPLOAD_LIFE
    with uploads_lock:
        for key in [k for k, v in UPLOADS.items() if v["created"] < cutoff]:
            shutil.rmtree(os.path.dirname(UPLOADS.pop(key)["path"]), ignore_errors=True)


def split_name(name):
    stem, dot, ext = name.rpartition(".")
    return (stem, ext) if dot and stem else (name, "")


def look_at(upload, encoding):
    """What each engine could do with an upload; nothing is translated."""
    ext = upload["ext"].lower()
    out = {
        "upload": upload["id"],
        "name": upload["name"],
        "ext": ext,
        "size": upload["size"],
        "pasted": upload["pasted"],
        "detected": None,
    }
    try:
        text, _, _, notes = extract.extract(upload["path"], ext, encoding)
        pieces = len(gemma.split_pieces(text.encode("utf-8")))
        out["gemma"] = {
            "ok": True,
            "notes": notes,
            "pieces": pieces,
            "words": len(text.split()),
            "characters": len(text),
        }
        try:
            code, confidence = detect_language(text)
            out["detected"] = {"code": code, "confidence": confidence}
        except UserError:
            pass
    except extract.ExtractError as err:
        out["gemma"] = {"ok": False, "error": str(err), "need_encoding": err.need_encoding}
    except gemma.GemmaError as err:
        out["gemma"] = {"ok": False, "error": str(err), "need_encoding": False}

    info = lt_info()
    if info is None:
        out["libre"] = {"ok": False, "error": "LibreTranslate isn't answering."}
    elif "." + ext not in info["formats"]:
        out["libre"] = {"ok": False, "error": f"LibreTranslate can't read .{ext or '?'} files."}
    elif ext in extract.TEXT_TYPES and not out["gemma"]["ok"] and out["gemma"].get("need_encoding"):
        out["libre"] = {"ok": False, "error": out["gemma"]["error"]}
    else:
        out["libre"] = {"ok": True}
    return out


# ------------------------------------------------------------------------ results
def provenance_files():
    try:
        names = os.listdir(DATA_DIR)
    except OSError:
        return []
    return [n for n in names if n.endswith(".provenance.json")]


def read_json(name):
    try:
        with open(os.path.join(DATA_DIR, name), encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def result_name(name):
    return isinstance(name, str) and name not in ("", ".", "..") and not any(c in name for c in "/\\\x00")


def valid_result(side):
    """Only a complete result whose recorded files still match their hashes."""
    output = side.get("output_file")
    if not result_name(output):
        return False
    if os.path.lexists(os.path.join(DATA_DIR, output + ".lock")):
        return False
    files = [(output, side.get("output_sha256"))]
    if side.get("source_text_file"):
        files.append((side["source_text_file"], side.get("source_text_sha256")))
    try:
        return all(
            result_name(name) and digest and sha256_file(os.path.join(DATA_DIR, name)) == digest
            for name, digest in files
        )
    except OSError:
        return False


def already_done(
    source_sha, engine_digest, source_lang, target_lang, input_sha, encoding, engine, options, source_format
):
    """The output of an earlier run on this exact source, engine and language pair."""
    for name in sorted(provenance_files(), reverse=True):
        side = read_json(name)
        if (
            isinstance(side, dict)
            and engine_digest != "unknown"
            and side.get("tool") == TOOL
            and side.get("source_sha256") == source_sha
            and side.get("engine_digest") == engine_digest
            and side.get("source_lang") == source_lang
            and side.get("target_lang") == target_lang
            and side.get("input_sha256") == input_sha
            and side.get("source_encoding") == encoding
            and side.get("engine") == engine
            and side.get("engine_options") == options
            and side.get("source_format") == source_format
            and valid_result(side)
        ):
            return side["output_file"]
    return None


@contextmanager
def reserve_result(base, ext, with_source=False):
    """Reserve the whole result with an exclusive file, also on exFAT.
    A crash may leave a lock or incomplete files; later runs leave them alone."""
    dot_ext = "." + ext if ext else ""
    name = base + dot_ext
    serial = 0
    while True:
        lock = os.path.join(DATA_DIR, name + ".lock")
        try:
            with open(lock, "x"):
                pass
        except FileExistsError:
            pass
        else:
            source = name[:-4] + ".source-text.txt" if with_source else None
            names = [name, name + ".provenance.json"] + ([source] if source else [])
            if not any(os.path.lexists(os.path.join(DATA_DIR, n)) for n in names):
                break
            os.unlink(lock)
        stamp = utc_now(compact=True) + (f"-{serial}" if serial else "")
        name = f"{base}.{stamp}{dot_ext}"
        serial += 1
    try:
        yield name, source
    finally:
        os.unlink(lock)


def write_new(name, data):
    """Write a file that must not already exist."""
    mode = "xb" if isinstance(data, bytes) else "x"
    handle = open(os.path.join(DATA_DIR, name), mode, **({} if "b" in mode else {"encoding": "utf-8"}))
    try:
        with handle:
            handle.write(data)
    except BaseException:
        os.unlink(handle.name)
        raise


def save_result(base, ext, data, upload, source_text=None, **fields):
    """Publish the provenance last. Locked or incomplete results cannot be reused."""
    with reserve_result(base, ext, source_text is not None) as (output, source):
        written = []
        try:
            write_new(output, data)
            written.append(output)
            if source is not None:
                write_new(source, source_text)
                written.append(source)
                fields["source_text_file"] = source
            if fields["engine"] == "libre":
                checked, found = check_libre(
                    upload, ext.lower(), fields.pop("check_source"), output,
                    fields["source_lang"], fields["target_lang"],
                )
                fields.update(dropped_text_check=checked, warnings=found)
            write_provenance(output, upload, **fields)
        except BaseException:
            for name in written:
                os.unlink(os.path.join(DATA_DIR, name))
            raise
    return output


def shown_text(name):
    path = os.path.join(DATA_DIR, name)
    try:
        if os.path.getsize(path) > MAX_SHOWN:
            return None
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except (OSError, UnicodeError):
        return None


def load_result(output):
    side = read_json(output + ".provenance.json")
    if not isinstance(side, dict) or side.get("output_file") != output:
        return None
    if not valid_result(side):
        raise UserError(
            "This translation or its saved source text is missing or has changed since it was made. "
            "Translate the document again to make a new result."
        )
    result = {"output": output, "folder": HOST_DATA_DIR, "provenance": side}
    if output.endswith(".txt"):
        result["text"] = shown_text(output)
    if side.get("source_text_file"):
        result["source_text"] = shown_text(side["source_text_file"])
    return result


# --------------------------------------------------------------------------- jobs
JOBS = {}
jobs_lock = threading.Lock()
work = queue.Queue()


def set_job(job, **changes):
    with jobs_lock:
        job.update(changes)


def run_gemma(job, upload):
    ext = upload["ext"].lower()
    text, encoding, method, notes = extract.extract(upload["path"], ext, job["encoding"])
    detected, confidence = False, ""
    source = job["source"]
    if source == "auto":
        found, confidence = detect_language(text)
        source = gemma_code(found)
        if source is None:
            raise UserError(
                f"The text was detected as '{found}', which TranslateGemma has no name for. "
                "Choose the language from the list."
            )
        detected = True
    for code in (source, job["target"]):
        if code not in GEMMA_LANGS:
            raise UserError(f"'{code}' isn't a language code TranslateGemma knows.")
    try:
        digest = gemma.models(OLLAMA_API).get(job["model"])
    except gemma.GemmaError as err:
        raise UserError(str(err)) from None
    if digest is None:
        raise UserError(f"The model '{job['model']}' isn't installed in Ollama.")
    set_job(job, source_used=source, detected=detected, confidence=confidence)
    input_sha = hashlib.sha256(text.encode("utf-8")).hexdigest()
    options = f"temperature=0 num_ctx={gemma.NUM_CTX} piece_bytes={gemma.SOFT}-{gemma.HARD}"

    if not job["force"]:
        earlier = already_done(
            upload["sha256"], digest, source, job["target"], input_sha, encoding, "gemma", options, ext
        )
        if earlier:
            return earlier, True

    try:
        translation, pieces, warns = gemma.translate(
            OLLAMA_API,
            job["model"],
            text,
            (source, GEMMA_LANGS[source]),
            (job["target"], GEMMA_LANGS[job["target"]]),
            on_piece=lambda i, total: set_job(job, piece=i, pieces=total),
            cancelled=lambda: job["cancel"],
        )
    except gemma.GemmaError as err:
        raise UserError(str(err)) from None
    if not translation.strip():
        raise UserError("The translation came back empty.")
    # gemma.translate has already compared line and paragraph counts piece by piece
    checked, found = check.compare(text, translation, source, job["target"], "--no-struct")

    stem, _ = split_name(upload["name"])
    base = stem if ext in extract.TEXT_TYPES or not ext else f"{stem}.{ext}"
    output = save_result(
        f"{base}.{job['target']}.gemma", "txt", translation, upload, source_text=text,
        input_sha256=input_sha,
        source_encoding=encoding,
        source_lang=source,
        detected=detected,
        confidence=confidence,
        target_lang=job["target"],
        engine="gemma",
        engine_detail=f"{job['model']} via Ollama",
        engine_digest=digest,
        engine_options=options,
        pieces=pieces,
        dropped_text_check=checked,
        warnings=warns + found,
        extraction=method,
        extraction_notes=notes,
    )
    return output, False


def run_libre(job, upload):
    ext = upload["ext"].lower()
    detail = f"LibreTranslate {LT_VERSION} (image {LT_IMAGE})"
    source = job["source"]
    # Plain text has to be UTF-8 for LibreTranslate. Convert a copy, never the original.
    encoding = "n/a"
    sent = upload["path"]
    text = None
    tidy = None
    if ext in extract.TEXT_TYPES:
        try:
            text, encoding, _, _ = extract.extract(upload["path"], ext, job["encoding"])
        except extract.ExtractError as err:
            raise UserError(str(err)) from None
        tidy = tempfile.NamedTemporaryFile("w", encoding="utf-8", newline="", suffix="." + ext, delete=False)
        tidy.write(text)
        tidy.close()
        sent = tidy.name
    try:
        input_sha = sha256_file(sent)
        if not job["force"]:
            earlier = already_done(
                upload["sha256"], LT_IMAGE_ID, source, job["target"], input_sha, encoding, "libre", "", ext
            )
            if earlier:
                return earlier, True
        with open(sent, "rb") as handle:
            reply = lt(
                "POST",
                "/translate_file",
                timeout=7200,
                # under a plain name: LibreTranslate goes by the extension alone
                files={"file": ("upload." + ext, handle)},
                data={"source": source, "target": job["target"]},
            )
        link = reply.json().get("translatedFileUrl")
        if not link or "/download_file/" not in link:
            raise UserError("LibreTranslate's reply had no download link.")
        # re-root the link on LT_URL: the server reports the address it was asked at
        body = lt("GET", "/download_file/" + link.rsplit("/download_file/", 1)[1], timeout=600).content
    finally:
        if tidy:
            os.unlink(tidy.name)
    if not body:
        raise UserError("The translation came back empty.")

    stem, _ = split_name(upload["name"])
    output = save_result(
        f"{stem}.{job['target']}.libre", upload["ext"], body, upload,
        input_sha256=input_sha,
        check_source=text,
        source_encoding=encoding,
        source_lang=source,
        detected=False,
        confidence="",
        target_lang=job["target"],
        engine="libre",
        engine_detail=detail,
        engine_digest=LT_IMAGE_ID,
        engine_options="",
        pieces=0,
    )
    return output, False


def check_libre(upload, ext, text, output, source, target):
    """The dropped-text check on a file LibreTranslate translated, for the
    types the page can take the text out of. text is what was sent, for plain text."""
    translated = os.path.join(DATA_DIR, output)
    try:
        if ext in extract.TEXT_TYPES or ext == "srt":
            if text is None:
                with open(upload["path"], encoding="utf-8") as handle:
                    text = handle.read()
            with open(translated, encoding="utf-8") as handle:
                theirs = handle.read()
            options = ()
        elif ext in ("docx", "odt", "html", "htm"):
            text = extract.extract(upload["path"], ext)[0]
            theirs = extract.extract(translated, ext)[0]
            options = ("--unit", "paragraph")
        else:
            return f"not checked: the page can't line up the text of a .{ext} file with its translation", []
    except UnicodeError:
        return "not checked: the text isn't valid UTF-8", []
    except extract.ExtractError as err:
        return f"not checked: {err}", []
    return check.compare(text, theirs, None if source == "auto" else source, target, *options)


def write_provenance(output, upload, **fields):
    side = {
        "tool": TOOL,
        "translated_at_utc": utc_now(),
        # a browser gives the page a copy of the file and its name, not where it lives
        "source_file": upload["name"],
        "source_origin": "pasted into the web page" if upload["pasted"] else "uploaded to the web page",
        "source_sha256": upload["sha256"],
        "source_format": upload["ext"].lower(),
        "input_sha256": fields.pop("input_sha256"),
        "source_encoding": fields.pop("source_encoding"),
        "source_lang": fields.pop("source_lang"),
        "source_lang_detected": fields.pop("detected"),
        "source_lang_confidence": str(fields.pop("confidence") or ""),
        "target_lang": fields.pop("target_lang"),
        "engine": fields.pop("engine"),
        "engine_detail": fields.pop("engine_detail"),
        "engine_digest": fields.pop("engine_digest"),
        "engine_options": fields.pop("engine_options"),
        "pieces": fields.pop("pieces"),
        "output_file": output,
        "output_sha256": sha256_file(os.path.join(DATA_DIR, output)),
        "dropped_text_check": fields.pop("dropped_text_check"),
        "warnings": fields.pop("warnings"),
    }
    if "source_text_file" in fields:
        side["source_text_file"] = fields["source_text_file"]
        side["source_text_sha256"] = sha256_file(os.path.join(DATA_DIR, fields["source_text_file"]))
        side["extraction"] = fields["extraction"]
        side["extraction_notes"] = fields["extraction_notes"]
    write_new(output + ".provenance.json", json.dumps(side, ensure_ascii=False, indent=2) + "\n")


def worker():
    while True:
        job = work.get()
        if job["cancel"]:
            set_job(job, state="cancelled", finished=time.time())
            continue
        set_job(job, state="running", started=time.time())
        try:
            with uploads_lock:
                upload = UPLOADS.get(job["upload"])
            if upload is None:
                raise UserError("That upload has expired. Choose the document again.")
            os.makedirs(DATA_DIR, exist_ok=True)
            run = run_gemma if job["engine"] == "gemma" else run_libre
            output, reused = run(job, upload)
            set_job(job, state="done", output=output, reused=reused, finished=time.time())
        except (UserError, extract.ExtractError) as err:
            cancelled = job["cancel"] and str(err) == "cancelled"
            set_job(
                job,
                state="cancelled" if cancelled else "failed",
                error=None if cancelled else str(err),
                finished=time.time(),
            )
        except Exception as err:  # the page should hear about it, not wait for ever
            app.logger.exception("job %s failed", job["id"])
            set_job(job, state="failed", error=f"Something went wrong: {err}", finished=time.time())


threading.Thread(target=worker, daemon=True).start()


# ------------------------------------------------------------------------- routes
@app.before_request
def local_only():
    """Answer the browser on this computer and nothing else: a page on another
    site must not be able to post documents here or read translations back."""
    host = urlsplit("//" + request.host).hostname
    if host not in ("localhost", "127.0.0.1", "::1"):
        abort(403)
    origin = request.headers.get("Origin")
    if request.method != "GET" and origin and urlsplit(origin).netloc != request.host:
        abort(403)


@app.errorhandler(UserError)
def user_error(err):
    return jsonify(error=str(err)), 400


@app.errorhandler(413)
def too_large(_):
    return jsonify(error=f"That file is larger than {MAX_UPLOAD // (1024 * 1024)} MB."), 413


@app.get("/")
def index():
    return send_from_directory(app.static_folder, "index.html")


@app.get("/api/config")
def config():
    info = lt_info()
    try:
        installed = gemma.models(OLLAMA_API)
        error = None
    except gemma.GemmaError as err:
        installed, error = {}, str(err)
    # the bundle's models first and in its order, then any other TranslateGemma
    models = [m for m in BUNDLE_MODELS if m in installed]
    models += sorted(m for m in installed if m.startswith("translategemma") and m not in models)
    if not models and error is None:
        error = "No TranslateGemma model is installed in Ollama."
    common = {gemma_code(x["code"]) for x in (info or {}).get("languages", [])}
    return {
        "version": VERSION,
        "tool": TOOL,
        "build": BUILD,
        "folder": HOST_DATA_DIR,
        "os": HOST_OS,
        "libre": {
            "ok": info is not None,
            "version": (info or {}).get("version"),
            "languages": (info or {}).get("languages", []),
            "formats": (info or {}).get("formats", []),
        },
        "gemma": {
            "ok": bool(models),
            "error": error,
            "models": models,
            "default_model": DEFAULT_MODEL if DEFAULT_MODEL in models else (models or [None])[0],
            "languages": [
                {"code": code, "name": name, "common": code in common}
                for code, name in GEMMA_LANGS.items()
            ],
            "formats": ["." + t for t in extract.TYPES if t not in ("text", "markdown", "htm")],
        },
    }


@app.post("/api/inspect")
def inspect():
    clear_old_uploads()
    encoding = request.form.get("encoding") or None
    again = request.form.get("upload")
    if again:
        with uploads_lock:
            upload = UPLOADS.get(again)
        if upload is None:
            raise UserError("That upload has expired. Choose the document again.")
        return look_at(upload, encoding)

    key = uuid.uuid4().hex
    folder = os.path.join(UPLOAD_DIR, key)
    os.makedirs(folder)
    sent = request.files.get("file")
    if sent is not None and sent.filename:
        name = safe_name(sent.filename)
        path = os.path.join(folder, "upload")
        sent.save(path)
        pasted = False
    else:
        text = request.form.get("text", "")
        if not text.strip():
            shutil.rmtree(folder, ignore_errors=True)
            raise UserError("Choose a document or paste some text.")
        name = "pasted-text.txt"
        path = os.path.join(folder, "upload")
        with open(path, "w", encoding="utf-8", newline="") as handle:
            handle.write(text if text.endswith("\n") else text + "\n")
        pasted = True
    upload = {
        "id": key,
        "name": name,
        "ext": split_name(name)[1],
        "path": path,
        "size": os.path.getsize(path),
        "sha256": sha256_file(path),
        "pasted": pasted,
        "created": time.time(),
    }
    with uploads_lock:
        UPLOADS[key] = upload
    return look_at(upload, encoding)


def public(job):
    with jobs_lock:
        out = {k: v for k, v in job.items() if k not in ("cancel",)}
    out["waiting"] = sum(1 for j in list(JOBS.values()) if j["state"] == "queued" and j["created"] < job["created"])
    end = out.get("finished") or time.time()
    out["seconds"] = round(end - out["started"], 1) if out.get("started") else 0
    if out["state"] == "done":
        out["result"] = load_result(out["output"])
    return out


@app.post("/api/translate")
def translate():
    ask = request.get_json(force=True, silent=True) or {}
    engine = ask.get("engine")
    if engine not in ("gemma", "libre"):
        raise UserError("Choose an engine.")
    target = (ask.get("target") or "").strip()
    if not target:
        raise UserError("Choose the language to translate into.")
    with uploads_lock:
        if ask.get("upload") not in UPLOADS:
            raise UserError("That upload has expired. Choose the document again.")
    job = {
        "id": uuid.uuid4().hex,
        "upload": ask["upload"],
        "engine": engine,
        "model": ask.get("model") or DEFAULT_MODEL,
        "source": (ask.get("source") or "auto").strip(),
        "target": target,
        "encoding": ask.get("encoding") or None,
        "force": bool(ask.get("force")),
        "state": "queued",
        "created": time.time(),
        "piece": 0,
        "pieces": 0,
        "cancel": False,
    }
    with jobs_lock:
        JOBS[job["id"]] = job
    work.put(job)
    return public(job)


@app.get("/api/jobs/<key>")
def job_state(key):
    job = JOBS.get(key)
    if job is None:
        abort(404)
    return public(job)


@app.post("/api/jobs/<key>/cancel")
def job_cancel(key):
    job = JOBS.get(key)
    if job is None:
        abort(404)
    set_job(job, cancel=True)
    return public(job)


@app.get("/api/history")
def history():
    rows = []
    for name in provenance_files():
        side = read_json(name)
        if not side or not os.path.isfile(os.path.join(DATA_DIR, side.get("output_file", ""))):
            continue
        rows.append(
            {
                "output": side["output_file"],
                "source_file": side.get("source_file"),
                "source_lang": side.get("source_lang"),
                "target_lang": side.get("target_lang"),
                "engine": side.get("engine"),
                "engine_detail": side.get("engine_detail"),
                "translated_at_utc": side.get("translated_at_utc"),
                "warnings": len(side.get("warnings") or []),
            }
        )
    rows.sort(key=lambda r: r["translated_at_utc"] or "", reverse=True)
    return {"folder": HOST_DATA_DIR, "translations": rows[:50]}


@app.get("/api/result")
def result():
    output = request.args.get("output", "")
    if not result_name(output):
        abort(404)
    found = load_result(output)
    if found is None:
        abort(404)
    return found


@app.get("/files/<path:name>")
def download(name):
    return send_from_directory(DATA_DIR, name, as_attachment=True)


if __name__ == "__main__":
    from waitress import serve

    serve(app, host="0.0.0.0", port=PORT, threads=8)
