"""Take the text out of a document so TranslateGemma, which reads plain text
only, can translate it.

Every extractor gives one paragraph to a line with no blank lines between
them, the shape of text saved from Word, and a list of notes saying what it
left out or could not vouch for. The uploaded file is only read.
"""

import re
import zipfile

from lxml import etree

TEXT_TYPES = ("txt", "text", "md", "markdown")
TYPES = TEXT_TYPES + ("docx", "odt", "pdf", "html", "htm")

# A document's XML is small next to its pictures; anything past this is not a
# document this tool should be unpacking into memory.
MAX_XML = 200 * 1024 * 1024

W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
MC_FALLBACK = "{http://schemas.openxmlformats.org/markup-compatibility/2006}Fallback"
ODF_TEXT = "{urn:oasis:names:tc:opendocument:xmlns:text:1.0}"
ODF_OFFICE = "{urn:oasis:names:tc:opendocument:xmlns:office:1.0}"


class ExtractError(Exception):
    """A reason the text can't be taken out, worded for the person at the page."""

    def __init__(self, message, need_encoding=False):
        super().__init__(message)
        self.need_encoding = need_encoding


def extract(path, ext, encoding=None):
    """Returns (text, source encoding, method, notes)."""
    ext = ext.lower()
    if ext in TEXT_TYPES or ext == "":
        text, used = _plain(path, encoding)
        return text, used, "read as plain text", []
    if encoding:
        raise ExtractError("An encoding applies to plain text files only.")
    try:
        if ext == "docx":
            text, notes = _docx(path)
            method = "paragraphs of word/document.xml, lxml " + etree.__version__
        elif ext == "odt":
            text, notes = _odt(path)
            method = "paragraphs of content.xml, lxml " + etree.__version__
        elif ext == "pdf":
            text, notes, method = _pdf(path)
        elif ext in ("html", "htm"):
            text, notes, method = _html(path)
        else:
            raise ExtractError(
                f"TranslateGemma can't read .{ext} files here. It reads "
                + ", ".join("." + t for t in TYPES if t not in ("text", "markdown", "htm"))
                + ". Save the document as one of those; Word and Pages can both save as .docx."
            )
    except (zipfile.BadZipFile, KeyError, etree.XMLSyntaxError):
        raise ExtractError(f"This doesn't look like a real .{ext} file; it couldn't be opened.") from None
    text = _tidy(text)
    if not text.strip():
        raise ExtractError("There is no text in this document to translate.")
    return text, "n/a", method, notes


def _tidy(text):
    """One paragraph to a line, nothing blank, no stray carriage returns."""
    lines = (line.strip(" \t") for line in text.replace("\r", "").split("\n"))
    return "\n".join(line for line in lines if line) + "\n"


def _plain(path, encoding):
    with open(path, "rb") as handle:
        data = handle.read()
    if encoding:
        try:
            text = data.decode(encoding)
        except LookupError:
            raise ExtractError(f"'{encoding}' isn't an encoding this tool knows.", True) from None
        except UnicodeError:
            raise ExtractError(f"The file isn't in {encoding}; it couldn't be converted.", True) from None
    else:
        try:
            text = data.decode("utf-8")
        except UnicodeError:
            raise ExtractError(
                "This text file isn't in UTF-8. Choose its encoding, for example CP1251 "
                "(Russian), CP1255 (Hebrew), CP1256 (Arabic), GBK or Big5 (Chinese), or UTF-16.",
                True,
            ) from None
    # Text saved on Windows ends its lines with a carriage return, which would
    # hide every paragraph break from the splitter.
    text = text.lstrip("﻿").replace("\r", "")
    if not text.strip():
        raise ExtractError("There is no text in this file to translate.")
    return text, encoding or "UTF-8"


def _xml(archive, name):
    info = archive.getinfo(name)
    if info.file_size > MAX_XML:
        raise ExtractError("This document is too large to open.")
    parser = etree.XMLParser(resolve_entities=False, no_network=True, huge_tree=True)
    return etree.fromstring(archive.read(name), parser)


def _inside(element, top, barred):
    """True if something between element and top (a paragraph it belongs to)
    is another paragraph or a part to skip."""
    parent = element.getparent()
    while parent is not None and parent is not top:
        if parent.tag in barred:
            return True
        parent = parent.getparent()
    return False


def _docx(path):
    with zipfile.ZipFile(path) as archive:
        root = _xml(archive, "word/document.xml")
        names = set(archive.namelist())
        notes = []
        for part, label in (("word/footnotes.xml", "footnotes"), ("word/endnotes.xml", "endnotes")):
            if part in names:
                # every document has two of these that only draw the separator line
                real = [n for n in _xml(archive, part) if n.get(W + "type") is None]
                if real:
                    notes.append(f"The document has {len(real)} {label}; they were not translated.")
        if any(re.match(r"word/(header|footer)\d*\.xml$", n) for n in names):
            notes.append("Page headers and footers were not translated.")
        if "word/comments.xml" in names:
            notes.append("Comments in the margin were not translated.")

    paragraphs = []
    # A text box sits inside a paragraph and holds paragraphs of its own, and
    # Word stores a second, older copy of each one under mc:Fallback.
    for para in root.iter(W + "p"):
        if _inside(para, None, (MC_FALLBACK,)):
            continue
        parts = []
        for el in para.iter(W + "t", W + "tab", W + "br", W + "cr", W + "noBreakHyphen"):
            if _inside(el, para, (W + "p", MC_FALLBACK)):
                continue
            if el.tag == W + "t":
                parts.append(el.text or "")
            elif el.tag == W + "tab":
                parts.append("\t")
            elif el.tag == W + "noBreakHyphen":
                parts.append("-")
            else:
                parts.append("\n")
        paragraphs.append("".join(parts))
    if root.find(".//" + W + "del") is not None or root.find(".//" + W + "ins") is not None:
        notes.append(
            "The document has tracked changes. Inserted text was translated; deleted text was not."
        )
    return "\n".join(paragraphs), notes


def _odt(path):
    with zipfile.ZipFile(path) as archive:
        root = _xml(archive, "content.xml")
    body = root.find(f"{ODF_OFFICE}body/{ODF_OFFICE}text")
    if body is None:
        raise ExtractError("This OpenDocument file is not a text document.")
    para_tags = (ODF_TEXT + "p", ODF_TEXT + "h")
    skipped = (ODF_TEXT + "note", ODF_TEXT + "tracked-changes", ODF_TEXT + "annotation")
    notes = []
    if body.find(".//" + ODF_TEXT + "note") is not None:
        notes.append("The document has footnotes or endnotes; they were not translated.")
    if body.find(".//" + ODF_TEXT + "tracked-changes") is not None:
        notes.append("The document has tracked changes; deleted text was not translated.")

    def text_of(element):
        parts = [element.text or ""]
        for child in element:
            if child.tag == ODF_TEXT + "s":
                parts.append(" " * int(child.get(ODF_TEXT + "c", "1")))
            elif child.tag == ODF_TEXT + "tab":
                parts.append("\t")
            elif child.tag == ODF_TEXT + "line-break":
                parts.append("\n")
            elif child.tag not in skipped and not _holds_paragraphs(child):
                parts.append(text_of(child))
            parts.append(child.tail or "")
        return "".join(parts)

    def _holds_paragraphs(element):
        return next(element.iter(*para_tags), None) is not None

    paragraphs = [
        text_of(para) for para in body.iter(*para_tags) if not _inside(para, body, skipped)
    ]
    return "\n".join(paragraphs), notes


def _pdf(path):
    import fitz  # PyMuPDF, which LibreTranslate brings for its own PDF handling

    notes = []
    paragraphs = []
    empty_pages = []
    with fitz.open(path) as doc:
        if doc.needs_pass:
            raise ExtractError("This PDF is protected by a password and can't be opened.")
        pages = len(doc)
        for number, page in enumerate(doc, 1):
            found = False
            # MuPDF groups the lines it sees into blocks, which are paragraphs
            # more often than not. A printed line is not a sentence, so the
            # lines of a block are joined.
            for block in page.get_text("blocks"):
                if block[6] != 0:
                    continue
                lines = [line.strip() for line in block[4].split("\n")]
                joined = " ".join(line for line in lines if line)
                if joined:
                    paragraphs.append(joined)
                    found = True
            if not found:
                empty_pages.append(number)
    if len(empty_pages) == pages:
        raise ExtractError(
            "This PDF has no text in it, only pictures of pages (a scan). "
            "This tool can't read text out of pictures."
        )
    if empty_pages:
        notes.append(
            "No text was found on page"
            + ("s " if len(empty_pages) > 1 else " ")
            + ", ".join(str(n) for n in empty_pages)
            + " (pictures or blank pages)."
        )
    notes.append(
        "Text taken out of a PDF comes in the order the PDF stores it. Columns, tables, "
        "page numbers and running heads can land in the wrong place, and a paragraph "
        "that runs over a page ends up in two pieces. Read the extracted text before "
        "relying on the translation."
    )
    method = "text blocks, " + (fitz.__doc__ or "PyMuPDF").split(":")[0]
    return "\n".join(paragraphs), notes, method


BLOCKS = {
    "address", "article", "aside", "blockquote", "br", "dd", "div", "dl", "dt", "figcaption",
    "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li",
    "main", "nav", "ol", "p", "pre", "section", "table", "td", "th", "tr", "ul",
}  # fmt: skip


def _html(path):
    import bs4

    with open(path, "rb") as handle:
        soup = bs4.BeautifulSoup(handle.read(), "html.parser")
    # the head's title repeats the page's own heading more often than it adds to it
    for junk in soup(["head", "script", "style", "noscript", "template"]):
        junk.decompose()
    parts = []

    def walk(node):
        for child in node.children:
            # comments, the doctype and processing instructions are not words on the page
            if isinstance(child, bs4.element.PreformattedString):
                continue
            if isinstance(child, bs4.NavigableString):
                parts.append(re.sub(r"\s+", " ", str(child)))
            elif child.name in BLOCKS:
                parts.append("\n")
                walk(child)
                parts.append("\n")
            else:
                walk(child)

    walk(soup)
    text = re.sub(r" *\n *", "\n", "".join(parts))
    notes = ["Only the words on the page were translated; the result is plain text, not a web page."]
    return text, notes, "text of the page's elements, BeautifulSoup " + bs4.__version__
