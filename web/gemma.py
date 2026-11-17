"""TranslateGemma via Ollama: the same splitting, prompt and checks as
bundle/translate.sh, so the web page and the command line give the same
translation of the same text.

Sizes are in bytes of UTF-8, as they are in the helper, and the splitter works
on bytes for that reason. tests/parity.sh runs this against the helper.
"""

import json
import re
import urllib.error
import urllib.request

# TranslateGemma was trained on inputs of up to about 2K tokens, so long texts
# go through in pieces. A piece closes at the first paragraph break after SOFT
# and is never allowed past HARD.
SOFT = 3000
HARD = 6000
NUM_CTX = 8192

# ASCII sentence punctuation, then CJK full stop / ! / ? / ;, Arabic ?, Urdu full stop
SENT = re.compile(
    rb"[.!?;][\"')]*[ \t]+|\xe3\x80\x82|\xef\xbc\x81|\xef\xbc\x9f|\xef\xbc\x9b"
    rb"|\xd8\x9f[ \t]*|\xdb\x94[ \t]*"
)
BLANK = re.compile(rb"^[ \t]*$")
CONTROL = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")


class GemmaError(Exception):
    pass


def split_pieces(data, soft=SOFT, hard=HARD):
    """Split UTF-8 bytes into pieces of roughly `soft` bytes, breaking at
    paragraph breaks where possible, then line breaks, then sentence ends
    inside an over-long line. Returns [(piece, join)], where join says what
    separated the piece from the next (para, line, sent or end) so the
    translation can be stitched back together in the same shape."""
    pieces = []
    buf = b""
    size = 0
    blank = False

    def flush(join):
        nonlocal buf, size
        if buf == b"":
            return
        pieces.append((buf, join))
        buf = b""
        size = 0

    lines = data.split(b"\n")
    if lines and lines[-1] == b"":
        lines.pop()
    for number, line in enumerate(lines, 1):
        if BLANK.match(line):
            if buf != b"":
                blank = True
            if blank and size >= soft:
                flush("para")
                blank = False
            continue
        if len(line) > hard:
            flush("para" if blank else "line")
            blank = False
            rest = line
            while len(rest) > soft:
                cut = 0
                pos = 0
                while True:
                    found = SENT.search(rest, pos)
                    if not found or found.end() > hard:
                        break
                    cut = found.end()
                    if cut >= soft:
                        break
                    pos = cut
                if cut == 0:
                    if len(rest) <= hard:
                        break
                    raise GemmaError(
                        f"line {number} of the text runs past {hard} bytes with no sentence "
                        "break, too long to translate in one piece. Re-wrap it, or use "
                        "LibreTranslate."
                    )
                if cut >= len(rest):
                    break
                buf = rest[:cut]
                flush("sent")
                rest = rest[cut:]
            buf = rest + b"\n"
            size = len(buf)
            continue
        if size > 0 and size + len(line) + 1 > hard:
            flush("para" if blank else "line")
            blank = False
        if blank:
            buf += b"\n"
            size += 1
            blank = False
        buf += line + b"\n"
        size += len(line) + 1
    flush("end")
    return pieces


def trim_blank(text):
    """Drop leading and trailing blank lines, trailing spaces on the last
    line, and the final newline."""
    lines = text.split("\n")
    while lines and not lines[0].strip(" \t"):
        lines.pop(0)
    while lines and not lines[-1].strip(" \t"):
        lines.pop()
    if lines:
        lines[-1] = lines[-1].rstrip(" \t")
    return "\n".join(lines)


def count_paras(text):
    """Blank-line-separated paragraphs. Only an empty line separates, as in awk."""
    body = text.strip("\n")
    return len(re.split(r"\n{2,}", body)) if body else 0


def count_lines(text):
    """Lines that have something on them."""
    return sum(1 for line in text.split("\n") if line.strip(" \t"))


def prompt_for(piece, from_name, from_code, to_name, to_code):
    header = (
        f"You are a professional {from_name} ({from_code}) to {to_name} ({to_code}) translator. "
        f"Your goal is to accurately convey the meaning and nuances of the original {from_name} "
        f"text while adhering to {to_name} grammar, vocabulary, and cultural sensitivities.\n"
        f"Produce only the {to_name} translation, without any additional explanations or "
        f"commentary. Please translate the following {from_name} text into {to_name}:"
    )
    # the model expects two blank lines between the instruction and the text
    text = header + "\n\n\n" + piece
    text = CONTROL.sub(" ", text.replace("\r", ""))
    return text[:-1] if text.endswith("\n") else text


def _call(url, payload=None, timeout=30):
    data = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as reply:
            return json.load(reply)
    except urllib.error.HTTPError as err:
        body = err.read().decode("utf-8", "replace")
        try:
            body = json.loads(body).get("error", body)
        except ValueError:
            pass
        raise GemmaError(f"Ollama returned HTTP {err.code}: {body}") from None
    except (OSError, ValueError):
        raise GemmaError(f"couldn't reach Ollama at {url.rsplit('/api/', 1)[0]}. Is the Ollama app open?") from None


def models(api):
    """{name: digest} for every model Ollama holds."""
    return {m["name"]: "sha256:" + m["digest"] for m in _call(api + "/api/tags").get("models", [])}


def translate(api, model, text, from_lang, to_lang, on_piece=None, cancelled=None):
    """Translate UTF-8 text. from_lang and to_lang are (code, name).
    Returns (translation, number of pieces, warnings)."""
    pieces = split_pieces(text.encode("utf-8"))
    if not pieces:
        raise GemmaError("there is no text to translate")
    total = len(pieces)
    out = []
    warnings = []
    for i, (piece, join) in enumerate(pieces, 1):
        if cancelled and cancelled():
            raise GemmaError("cancelled")
        if on_piece:
            on_piece(i, total)
        source = piece.decode("utf-8")
        reply = _call(
            api + "/api/generate",
            {
                "model": model,
                "stream": False,
                "options": {"temperature": 0, "num_ctx": NUM_CTX},
                "prompt": prompt_for(source, from_lang[1], from_lang[0], to_lang[1], to_lang[0]),
            },
            timeout=3600,
        )
        if "response" not in reply:
            raise GemmaError(f"couldn't read Ollama's reply for part {i}")
        part = trim_blank(reply["response"])
        if not part:
            warnings.append(f"part {i} of {total} came back empty")
        reason = reply.get("done_reason", "unknown")
        if reason != "stop":
            warnings.append(
                f"part {i} of {total} stopped early (done_reason={reason}); "
                "its translation may be cut short"
            )
        # A model can drop or merge text and still sound fluent. Paragraph counts
        # are a cheap signal that works for any language pair. Text taken from a
        # Word document has a paragraph on each line and no blank lines, and the
        # model may answer it with blank lines added, so equal line counts pass.
        # Paragraph counts say nothing about such text (it is one block, and so
        # is an answer that has lost a line), so they pass only a source that has
        # blank lines of its own, where the model re-wraps the lines between them.
        want, got = count_paras(source), count_paras(part)
        want_lines, got_lines = count_lines(source), count_lines(part)
        if want_lines != got_lines and not (want == got and (want > 1 or want_lines <= 1)):
            warnings.append(
                f"part {i} of {total}: the source has {want} paragraph(s) on {want_lines} "
                f"line(s) but the translation has {got} on {got_lines}; check it for missing "
                "or merged text"
            )
        out.append(part)
        out.append({"para": "\n\n", "sent": " "}.get(join, "\n"))
    return "".join(out), total, warnings
