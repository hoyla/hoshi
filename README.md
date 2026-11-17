# Hoshi

Offline document translation for airgapped computers.

Hoshi builds a single folder that installs two offline translation engines on
an airgapped Apple Silicon Mac or Windows PC: no Homebrew, no pip, no winget, no
network. A Windows PC needs Docker Desktop already. A Mac doesn't, because the
bundle carries Docker Desktop's installer for it. One bundle serves both kinds
of machine, and every model is inside it.

<img alt="Screenshot 2026-11-19 at 14 12 24" src="https://github.com/user-attachments/assets/a7a1e69a-212d-43b8-9594-927f976bb1ea" />


| | LibreTranslate | TranslateGemma 12B |
|---|---|---|
| Runs in | Docker | Ollama, natively on macOS or Windows |
| Good for | Whole documents with formatting (.docx, .pptx, .pdf, .html ...), quick gisting | Best available quality on plain text |
| Languages | 50 (every Argos Translate model, 100 packages) | 55 core languages |
| On a Mac | [Hoshi's page](#the-web-page-mac-only) on `127.0.0.1:5080`, `translate.sh` | The same page, `translate.sh`, Ollama's chat window |
| On Windows | Its own web page on `127.0.0.1:5050`, `translate.cmd` | `translate.cmd`, Ollama's chat window |
| Size in bundle | 9 to 11 GB per target | about 8 GB, shared |

Both cover English, Russian, French, Chinese, Hebrew and Arabic.

Hoshi translates nothing itself. It is built from LibreTranslate's open source
software, and on Argos Translate, Ollama and Google's TranslateGemma. Hoshi is
not officially associated with LibreTranslate or its products, or with any of
the others. [Credits and licences](#credits-and-licences) says who made what.

## Why two engines, and why one is outside Docker

Docker on macOS runs a Linux VM with no access to the Apple GPU. LibreTranslate's
small models are fast on CPU, so it lives in Docker. A 12B-parameter model on
CPU is unusably slow, so TranslateGemma runs through Ollama natively. Ollama is
a self-contained signed app and its models are plain files, so neither needs a
package manager on the target.

The same split is used on Windows. Docker Desktop there can reach an NVIDIA
card, but only with WSL 2 GPU support set up, which an airgapped PC can't be
relied on to have. Native Ollama uses whatever NVIDIA or AMD card and driver
the PC already has, and falls back to the CPU when there is none. Its Windows
installer needs no administrator rights.

## Targets

`--targets` picks what the bundle installs on. The default is both.

| `--targets` | LibreTranslate images | Ollama | Bundle size (all languages, 12B) |
|---|---|---|---|
| `mac` | linux/arm64 | Mac app | 18 to 19.5 GB |
| `windows` | linux/amd64 | Windows installer | about 19 to 21 GB |
| `mac,windows` | both | both | about 29 to 33 GB |

Each range runs from Docker's newer image store to its older one on the build
Mac (see Things to know). The Mac figures include 0.6 GB for Docker Desktop's
installer. Only the `mac` figures rest on a measured build; the others are
worked out from it.

Docker runs Linux for the machine's own processor, so a Mac needs the arm64
image and an Intel or AMD PC the amd64 one. The language models are baked into
each image, which is why a second target costs another 9 to 11 GB; the TranslateGemma
model is the same files on both and is carried once. A Windows PC with an ARM
processor uses the arm64 image, so it is covered only by the two-target bundle.

Either installer checks and uses only its own platform's files, so the other
platform's big files can be left off a drive bound for one kind of machine
([bundle/README.txt](bundle/README.txt) says which).

## Build (connected Mac)

Needs an Apple Silicon Mac with Docker running. For one target: about 30 GB
free on the Mac, and 12 or 30 GB free inside Docker's own disk, depending on
which image store Docker uses (see Things to know). For both targets: about
45 GB on the Mac and twice the Docker figure. Docker Desktop keeps images in a
virtual disk with its own size limit (Settings > Resources), so a Mac with
plenty of space can still have a full Docker. The script checks this before
the long download and stops with advice if it is short.

The Windows image is built and tested on the Mac as an Intel/AMD image under
emulation, so Docker Desktop needs Rosetta turned on (Settings > General >
Virtual Machine Options; it is by default). The script checks that too.

The build stops if any file here differs from the last git commit, so that the
commit it writes into the manifest is what the bundle was made from.
`--allow-dirty` builds anyway, and the manifest then lists the changed files.

```bash
./build-bundle.sh                    # Mac and Windows
./build-bundle.sh --targets mac      # Macs only
./build-bundle.sh --targets mac --model translategemma:12b,translategemma:27b
```

For one target this downloads about 18 GB and writes
`dist/translation-bundle-YYYYMMDD/` (18 to 19.5 GB for the Mac target). Allow
about an hour at 5 MB/s. Both targets come to about 29 GB of downloads. It:

1. for the Mac target, downloads the pinned Docker Desktop for Apple Silicon
   and checks it against its pinned SHA-256, Gatekeeper, its code signature
   and the version number inside it (`--no-docker-desktop` leaves it out)
2. for each target's processor type, pulls the pinned LibreTranslate image and
   bakes every language model into it ([Dockerfile](Dockerfile)), then starts it
   with `--network none` and makes a test translation to prove it works offline
3. downloads the pinned Ollama release for each target and checks each file
   against its pinned SHA-256; verifies the Mac app's code signature and
   Gatekeeper status (a Mac has no tool to check the Windows installer's
   publisher signature, so the installer reports it on the PC instead)
4. pulls TranslateGemma into a model store inside the bundle, using the Mac
   Ollama on a private port so your own Ollama setup is untouched, and runs a
   test translation from that store
5. copies in the scripts, the user guide and the test documents in
   [bundle/test-files/](bundle/test-files/), and for the Mac target
   [the web page](#the-web-page-mac-only), after checking that the page
   splits text exactly as `translate.sh` does
6. writes `MANIFEST.txt` (the commit of these scripts, versions, digests, test
   results, every language model's version) and `SHA256SUMS` for every file

Re-running resumes an interrupted build. While a build runs, its folder holds
`BUILD-NOT-FINISHED.txt` and no installer, guide, manifest or checksums, so
that a build into a folder that already held a bundle can't be taken for a
finished one.
Options: `./build-bundle.sh --help`.
A subset of languages is much smaller: `--langs en,ru,fr,zh,he,ar` is about 1 GB
of models per image instead of 8.4 GB.

## Transfer

Copy the whole bundle folder on a drive formatted as **exFAT**, which both
macOS and Windows read and write. FAT32 cannot hold the files over 4 GB; APFS
is fine if the drive is only going to Macs.

## Install and use (airgapped machine)

On a Mac, `./install.sh` in Terminal. On Windows, double-click `install.cmd`.

On a Mac with no Docker, `install.sh` installs Docker Desktop from the bundle.
It asks first, runs Docker's own installer with `sudo` (so it needs an
administrator's password), opens Docker and waits for it. It does not accept
Docker's service agreement: the person at the Mac does that in Docker's window.
If Docker is installed but not running, it starts it.

`install.sh` also starts [the web page](#the-web-page-mac-only) and ends by
opening it, and starts LibreTranslate with its own page turned off.
`--no-web` installs neither change: no page from Hoshi, and LibreTranslate's
own on port 5050. `install.cmd` has no page to start, so on Windows
LibreTranslate's own page stays.

Each run of `install.sh` writes `~/translation-tools/install-DATE.log`: the
Mac's model, memory and macOS version, the bundle's build time and commit,
Docker's version and image store, Docker's disk use before and after the image
is loaded, how long the load took, and everything else it printed.

Both installers copy the test documents to `test-files` beside the translate
helper, so that translations of them are written there and not into the
bundle. They are extracts of Wikipedia's article on Earth in English, Spanish,
Russian, Arabic and Hebrew, each as .docx and .pdf;
[bundle/test-files/README.md](bundle/test-files/README.md) gives the source
revisions and the licence. The user guide says what each engine made of them,
so someone at the target can tell a working install from a broken one.

Then see [bundle/README.txt](bundle/README.txt), which ships inside the bundle
and is written for the people using the machine: copying the bundle over,
installing on each platform, using it, and what to do when something fails.

## The web page (Mac only)

[web/](web/) is a page for translating a document or pasted text with either
engine, at `http://127.0.0.1:5080`. It runs in a second container started from
the LibreTranslate image already in Docker, with the page's files handed to it
from `~/translation-tools/web`. The image is not rebuilt, so the image ID that
LibreTranslate sidecars record does not change. There is no Windows installer
for it.

- **Every Mac bundle carries it**, and `install.sh` starts it by running
  [bundle/install-web.sh](bundle/install-web.sh) as its last step.
- **It can be replaced without copying a bundle again.**
  `./build-web-patch.sh` builds `dist/translation-web-DATE-TIME/`, about
  170 KB, and `bash install-web.sh` in that folder replaces the page on a Mac
  where a bundle is installed. Both builders lay the page out with
  [web/assemble.sh](web/assemble.sh), so an update and a bundle built from
  the same commit carry the same files.
- **Where `install.sh` starts the page, LibreTranslate's own is turned off.**
  That page keeps no record of a translation and makes no check of one, so it
  is not left beside one that does. `install.sh` starts the LibreTranslate
  container with `LT_DISABLE_WEB_UI=true`, which makes `/` and `/js/app.js`
  answer 404 and leaves the API, which the page and `translate.sh` use, as it
  was. `install-web.sh` run on its own never touches the LibreTranslate
  container, so a Mac whose bundle had no page and which got one as an update
  has both until a bundle is installed on it again.
- **Same TranslateGemma method as `translate.sh`.** [web/gemma.py](web/gemma.py)
  is a port of the helper's splitter, prompt and missing-text check.
  `python3 web/tests/test_parity.py` runs the helper's own awk on the same
  texts and compares; both builders refuse to build if they differ. On
  the five Word test documents the page's translations are byte-identical to
  the helper's.
- **Documents for TranslateGemma are read inside the container**
  ([web/extract.py](web/extract.py)): .txt, .md, .docx, .odt, .html and .pdf.
  Not .doc, .rtf, .pptx or .epub. On the test documents the .docx text is
  identical to `textutil`'s. PDF text is not as good: a paragraph that runs
  over a page comes out as two, and Arabic and Hebrew come out with letters
  swapped inside words (the lam-alef ligature) and punctuation moved. The
  Arabic test PDF lost a heading in translation that the .docx kept. The page
  says so when someone picks such a file.
- **The dropped-text check is the helper's own program.**
  `web/assemble.sh` takes the perl out of `translate.sh` and ships it as
  `web/check.pl`, and the page runs it with the perl in the LibreTranslate
  image ([web/check.py](web/check.py)). There is no second copy to drift. See
  [the dropped-text check](#the-dropped-text-check) for which files it reads.
- **It never calls `/spec`** (see Things to know). The LibreTranslate version
  in a sidecar is read from `/app/VERSION`, which the page's container has
  because it is the same image.
- **Where things go.** Translations and sidecars go to
  `~/translation-tools/translations`. For TranslateGemma the exact text sent
  to the model is saved beside the translation and its SHA-256 is in the
  sidecar. The document itself is not copied there: the sidecar records its
  name and SHA-256, and cannot record its path, which a browser does not
  reveal. Uploads are held in memory in the container (a tmpfs) for up to six
  hours.
- **Reachable from this computer only.** The port is published on 127.0.0.1,
  and the page refuses requests whose Host is not local or whose Origin is
  another site.
- **The installed image ID selects the page's runtime.** A later build can
  move the image tag without changing the running LibreTranslate service.
  The web installer uses `LT_IMAGE_ID_INSTALLED` and refuses a missing image
  or a service container using a different one before replacing the page.
  Re-run the web installer after updating LibreTranslate with a new bundle
  so the page's runtime and recorded image ID stay in sync with the service.

Tested in headless Chrome only, not Safari.

## What the translate helper does for defensibility

`translate.sh` (Mac) and `translate.ps1` (Windows, run through `translate.cmd`)
take the same options and behave the same way:

- The source file is never modified. The helpers translate a temporary snapshot,
  so an edit to the original during a run cannot change the recorded input.
  Non-UTF-8 text is converted in that copy.
- Every translation gets a `.provenance.json` sidecar: SHA-256 of the source,
  engine, exact model digest, languages (and whether the source language was
  detected), options, time, output hash, warnings, and which helper wrote it.
  `input_sha256` records the bytes after text decoding and normalization
  (or the document bytes, for LibreTranslate).
- A result is reused only when the source, processed input, encoding, engine,
  model digest, languages, options and helper version match, and the saved
  translation still matches its recorded hash. The web page also verifies its
  saved source text. Changed or missing results are translated again into a new
  file; existing files are preserved. Older sidecars without these fields are
  kept but not reused. `--force` always writes a new result.
- Concurrent runs reserve separate output names with exclusive `.lock` files.
  The provenance is written last; a result with a lock cannot be reused.
  Normal failures clean up incomplete files. An abrupt shutdown may leave a
  lock or incomplete result, which later runs leave alone and do not reuse.
- TranslateGemma runs at temperature 0 so that the same input gives the same
  output. The 12b model did on repeated runs. The 27b model did not: two runs
  on the Arabic test file differed in three phrases (see Status).
- Long texts are split at paragraph, line or sentence boundaries. Anything that
  cannot be split safely is refused rather than silently truncated. The two
  helpers cut a text into the same pieces, so the same file gets the same
  prompts on either platform.
- Each TranslateGemma piece is checked for a reply the model cut short, an
  empty reply, or a different shape from the source. A piece passes if it
  has the same number of non-blank lines as the source: text saved from Word
  has a paragraph on each line and no blank lines, and the model answers it
  that way or with blank lines added. A piece with a different number of
  lines passes only if the source has blank lines of its own and the reply
  has the same number of paragraphs, since the model re-wraps lines that were
  broken by hand. So a single hand-wrapped paragraph that fills a piece gets
  a false warning, and a line lost from inside a multi-line block between
  blank lines gets none.
- With either engine, the finished translation is then compared with its
  source paragraph by paragraph, and a paragraph that came out much shorter
  or longer than expected is reported. See
  [the dropped-text check](#the-dropped-text-check). Both helpers and the web
  page do this, each for the file types it can read.
- Everything found is printed and recorded as a warning in the sidecar,
  beside a `dropped_text_check` line saying what was compared, or that
  nothing could be and why.

The image digest in a sidecar maps to exact language-model versions through the
bundle's `MANIFEST.txt`. Docker can give a loaded image a different ID from the
one it had on the build Mac (it depends on which image store each Docker uses),
so the installers record the ID as loaded, as `LT_IMAGE_ID_INSTALLED` in the
installed `bundle.env`, next to the manifest's. Both bundle installers start
LibreTranslate from that ID, and the web installer starts the page from the
same ID, with Docker pulls disabled. A changed tag cannot select another
image between inspection and startup.

## The dropped-text check

A translation engine can leave a sentence out, or repeat or invent one, and
still read fluently. Both engines here are able to; LibreTranslate did it in
testing, often (see Status). Nothing here can judge a translation, but the
helpers and the web page can measure one.

**What it compares.** The source and the translation are lined up paragraph by
paragraph (line by line where the lines match up, as they do for the text of a
.docx). Each side is sized in letters and digits, weighted by script so that
the same content has a similar size in any language: a Chinese character counts
as 2.6 Latin letters, a Hebrew letter as 1.3.

**What it expects.** With five or more paragraphs, the document's own median
size ratio, which cancels out the language pair and the engine's style. With
less text, a table of how large each of 17 languages runs relative to English.
With languages outside the table, the script weights alone and wider
tolerances.

**What it reports.** A paragraph more than 35% short of expectation; or one at
least 12% short that also has fewer sentences than its source, where the
shortfall is at least half the size of the missing sentences. That second rule
is what separates a dropped sentence from a merged one: a merged sentence keeps
its length. It also reports a paragraph twice as long as expected, and a whole
translation 25% shorter than is usual for its language pair.

**Where it runs.** After TranslateGemma, everywhere: the text sent to the
model is compared with the reply. After LibreTranslate it depends on what can
take the text out of the file and its translation:

| | Compared | Recorded as `not checked` |
|---|---|---|
| `translate.sh` (Mac) | .txt, .srt; .docx, .odt and .html through macOS's `textutil` | .pdf, .pptx, .odp, .epub |
| The web page | .txt, .srt; .docx, .odt and .html through [web/extract.py](web/extract.py) | .pdf, .pptx, .odp, .epub |
| `translate.ps1` (Windows) | .txt, .srt; .docx read by the script itself | .odt, .html, .pdf, .pptx, .odp, .epub |

LibreTranslate's own page at port 5050 does no checking at all.

**One program, and one copy of it.** The check is a perl program inside
`translate.sh`, kept to perl's core so that the minimal perl in the
LibreTranslate image can run it; the web page runs that same file. Windows has
no perl, so `translate.ps1` carries the check rewritten in PowerShell.
`calibration/windows.sh` runs the two on the same 4,185 pairs of texts (the
calibration translations whole, each paragraph alone, each copy with a
sentence removed, and cases made up for line ends, wrapped text, merged
paragraphs and rare Chinese characters) and compares every number, verdict
and warning: they are identical. Two differences remain that it cannot
show. .NET has no script properties, so the PowerShell carries lists of the
weighted characters, generated from perl 5.34's tables by
`calibration/script-ranges.pl`; and it does not count letters beyond the
Basic Multilingual Plane other than rare Chinese ones (historic scripts,
mathematical letters). And Windows PowerShell 5.1 has an older idea of what
is a letter than PowerShell 7, where the comparison ran.

**How well it works.** Measured on [calibration/](calibration/): one
12-paragraph article translated into 16 languages and back by both engines.

- *False alarms.* On the 64 translations as they stood it judged 724
  paragraphs and reported five. Read against their sources, all five were real
  losses by LibreTranslate: four Arabic paragraphs, three of them cut to a
  single sentence, and a Russian headline that lost "to the consulting
  company". It reported nothing in TranslateGemma's translations.
- *Catch rate.* Each sentence of each translation was removed in turn, 2,295
  cases:

  | The removed sentence was | Cases | In a document | Alone, languages given | Alone, languages not given |
  |---|---|---|---|---|
  | any size | 2,295 | 76% | 63% | 44% |
  | under a fifth of its paragraph | 649 | 38% | 17% | 6% |
  | a fifth to two fifths | 1,103 | 86% | 74% | 45% |
  | two fifths or more | 543 | 99% | 97% | 89% |

- *Missed.* At least three LibreTranslate paragraphs that had lost phrases or
  a clause, without losing a whole sentence, came out 26% to 31% short and
  were not reported.

**What it cannot do.** It rarely sees the loss of a sentence that was under a
fifth of its paragraph, or of anything smaller than a sentence. It does not
align sentences, so it points at a paragraph, not a sentence. One article is thin evidence for the thresholds:
lists, tables and text dense with names and numbers will behave differently.
And it says nothing about whether the words are right.

An independent, frozen reference evaluation is in [evaluation/](evaluation/).
It uses 24 human-translated FLORES-200 examples from distinct news, educational
and travel articles, in ten directions across English, French, Russian,
Chinese, Hebrew and Arabic. It records raw outputs, engine identities and
reference-overlap scores without changing the checker thresholds. Its results
are a small sentence-level benchmark; bilingual expert review and evaluation
on documents from the intended workflow remain separate work.

Two weaknesses turned up in use:

- *When the translation has a different number of lines and of paragraphs
  from its source, only the two whole texts are compared*, and the sidecar
  says `compared the text as a whole`. That catches a large loss and little
  else. TranslateGemma 27B's condensed Arabic (see Status) is the case in
  point: one line of eighteen merged away, so the texts no longer lined up;
  the whole came out 13% short of expectation, well inside tolerance, and
  this check reported nothing. The per-piece line count did warn.
- *An engine that trims every paragraph alike is seen only when the language
  pair is known*, because a document of five or more paragraphs sets its own
  expectation. With `--from` given, or after TranslateGemma (which always
  knows the source language), the whole translation is also held to what is
  usual for the pair. With LibreTranslate left to detect the language, it is
  not. With every line of the French calibration translation cut to 30
  characters, nine tenths of it gone, the check said so when given the
  languages. Without them its only warning was that the one line short
  enough to survive nearly whole was too long.

## Layout

```
LICENSE                the GNU Affero General Public License, version 3
NOTICE                 whose work a bundle carries, and on what terms
build-bundle.sh        run on the connected Mac
build-web-patch.sh     builds the small update that replaces the web page
Dockerfile             official LibreTranslate image + baked-in models
bundle/                copied into every bundle (each target gets its own scripts)
  install.sh           run on the airgapped Mac
  install-web.sh       starts the web page; run by install.sh, and by hand
                         from a page update
  translate.sh         command-line helper, installed to ~/translation-tools
  install.cmd          double-clicked on the airgapped PC; runs install.ps1
  install.ps1          the Windows installer
  translate.cmd        command-line helper for Windows; runs translate.ps1,
  translate.ps1          installed to %USERPROFILE%\translation-tools
  languages.tsv        language codes and names for the TranslateGemma prompt
  README.txt           user guide, both platforms
  test-files/          documents to try, installed beside the translate helper
web/                   the web page: app.py, gemma.py, extract.py, check.py,
                         static/, tests/
  assemble.sh          lays the page out for a bundle or a page update
calibration/           how the dropped-text check's thresholds were measured
  en.txt               the test article
  data/                its 64 machine translations
  run.sh               regenerates data/ (needs both engines)
  measure.sh           false alarms and catch rate from data/ (needs only perl)
  results.txt          measure.sh's output for the thresholds as committed
  windows.sh           compares translate.ps1's copy of the check with
                         translate.sh's (needs perl, and PowerShell 7 or Docker)
  script-ranges.pl     generates the character lists in translate.ps1
dist/                  built bundles (not in git)
.cache/                downloaded Ollama and Docker Desktop releases (not in git)
```

`install.sh` and `translate.sh` use only what ships with macOS: bash 3.2, curl,
awk, sed, plutil, perl, textutil. Not `iconv`: the macOS build wrongly rejects
valid UTF-8 that contains long lines.

The `.ps1` scripts use only what ships with Windows 10 and 11: Windows
PowerShell 5.1, the .NET Framework and robocopy. They are kept to ASCII and to
5.1 syntax, and do all text I/O as explicit UTF-8 bytes; the header of
[bundle/translate.ps1](bundle/translate.ps1) says why. The `.cmd` files exist
because Windows blocks double-clicked or unsigned PowerShell scripts by
default; they run the script with that policy bypassed for the one run.

## Updating versions

Versions are pinned at the top of [build-bundle.sh](build-bundle.sh). To move
Ollama, set `OLLAMA_VERSION`, and set `OLLAMA_ZIP_SHA256` and
`OLLAMA_SETUP_SHA256` from the digests shown for `Ollama-darwin.zip` and
`OllamaSetup.exe` on the GitHub release page. To move LibreTranslate, set
`LT_VERSION` to a tag on Docker Hub. To move Docker Desktop, set
`DOCKER_DESKTOP_VERSION`, `DOCKER_DESKTOP_BUILD` and `DOCKER_DMG_SHA256`: the
build number is the folder in the Apple Silicon download link on Docker's
release notes (`desktop.docker.com/mac/main/arm64/BUILD/Docker.dmg`) and the
checksum is in `checksums.txt` in that folder. The build checks the version
inside the file against the first two. Rebuild; the new manifest records what
changed.

## Things to know

- **Licences.** A bundle carries other people's work on several different
  terms, and two of them limit who a bundle can be given to. See
  [Credits and licences](#credits-and-licences). Docker Desktop needs a paid
  subscription in larger organisations, on every machine it is on, which
  matters because the bundle can put Docker on a Mac that had none.
  That is why `install.sh` names the licence, asks before installing, and
  leaves the agreement itself to the person at the Mac.
- **Docker on a Mac that has none.** `install.sh` runs the installer inside
  Docker's disk image the way Docker documents for unattended installs
  (`Docker.app/Contents/MacOS/install --user=NAME`, under `sudo`), without
  `--accept-license`. It needs an administrator account and macOS 14 or newer
  for Docker Desktop 4.99. The disk image is checked against `SHA256SUMS`
  before it runs, even with `--skip-verify`. This step has run for real once,
  on an airgapped Mac, and finished; what it showed there was not recorded
  (see Status).
- **Quality.** LibreTranslate pivots through English for non-English pairs.
  TranslateGemma was trained on inputs of roughly 2K tokens, so it never sees a
  long document whole and may render a term differently between pieces.
- **LibreTranslate drops sentences silently.** From Arabic into English it
  left out the second sentence of a two-sentence paragraph that carried vowel
  marks (tashkeel), though each sentence translated on its own and so did the
  paragraph with the marks stripped. On the 12-paragraph calibration article
  it cut three Arabic paragraphs down to one sentence each and trimmed a
  fourth. The helpers and the page in `web/` report all of these, but
  only for the formats each can read. LibreTranslate's own page reports none
  of them.
- **LibreTranslate's `/spec` endpoint must not be polled.** Version 1.9.6
  takes about three times longer to answer it on each call until its workers
  are all tied up. Both helpers and the page in `web/` read the version from
  the `VERSION` file in the image instead, and nothing here calls `/spec`.
  A bundle and a page update built before this repository existed do (see
  History).
- **LibreTranslate translates a PDF one run of text at a time.** Its PDF code
  (`argostranslatefiles/formats/pdf.py` in the image) walks PyMuPDF's blocks,
  lines and spans and translates each span on its own, never putting a
  sentence back together. A sentence that wraps is translated as two halves.
  A change of font starts a new span, and in the Arabic test PDF the letters
  and the digits are in different fonts, so every number splits its sentence.
  Left-to-right PDFs come out followable; Arabic and Hebrew ones do not. The
  user guide tells people to use a Word or text version instead.
- **The Arabic and Hebrew models are old.** The image carries the newest
  models in the official Argos index, and those are version 1.0 for Arabic
  and 1.5 for Hebrew, against 1.9 for Russian, Spanish and French. Models
  published elsewhere were not looked at.
- **Memory.** TranslateGemma 12B used about 10 GB while loaded, so it wants a
  Mac with 16 GB of RAM or more. LibreTranslate's container used about 1.6 GB.
  `--model translategemma:4b` (3.3 GB) is the fallback for 8 GB machines and
  `translategemma:27b` (17 GB) the larger one for 32 GB and more, which in
  the one comparison made was no better and on one file worse (see Status). `--model` takes
  a comma-separated list, so a bundle can carry more than one and the helper's
  `--model` picks between them on the target.
- **Windows hardware.** There, what matters is the graphics card: 12B is quick
  with an NVIDIA or AMD card that has about 12 GB of its own memory and a
  driver already installed (it can't be fetched on the target). Without one,
  Ollama runs the model on the CPU, which works and is slow; `install.cmd`
  times its test translation so the difference shows. For a fleet of PCs with
  no such card, bundle `translategemma:4b` as well or instead.
- **Windows containers.** Docker Desktop on Windows must be in its default
  Linux-containers mode. `install.cmd` says so if it isn't.
- **macOS.** Ollama needs macOS 14 or newer on the target.
- **Windows.** Ollama asks for Windows 10 22H2 or newer.
- **Ports.** LibreTranslate is published on 5050 because macOS's AirPlay
  Receiver holds 5000. Windows uses the same port so the instructions match.
  The web page is on 5080. Both answer on 127.0.0.1 only.
- **Docker's image store changes the sizes.** Docker Desktop has an older
  image store and a newer one (containerd, the default on recent fresh
  installs). `docker info --format '{{.Driver}}'` prints `overlay2` for the
  older and `overlayfs` for the newer. The older keeps each layer once,
  unpacked, and saves it uncompressed. The newer keeps it compressed as well,
  and a build leaves a second unpacked copy in the build cache. With every
  language the model layer is 9.6 GiB unpacked and 8.4 GiB compressed, so:

  | On the build Mac | Older store | containerd store |
  |---|---|---|
  | Free in Docker's disk to build, per image | 12 GB | 30 GB |
  | Image file in the bundle, per image | 10.9 GB | 9.1 GB |
  | Whole bundle, Mac target | about 19 GB | about 17.5 GB |

  The script's disk check uses the figure for the store it finds. The 30 GB
  was not measured at full size: a 300 MB test layer cost three times its size,
  and the full build left a 19.3 GB build-cache record beside the image.
- **Docker's disk on the target.** Loading the image needs room inside
  Docker's own disk on the airgapped machine: with every language, about 11 GB
  on the older image store and about 20 GB on containerd, which keeps the
  layers as saved beside the unpacked ones. The 20 GB is the size Docker
  reports for the image under containerd; loading a 1.3 GB image into a Docker
  that held none of its layers cost exactly its reported size. A full-size
  load has happened once, on an airgapped Mac, and its figures have not been
  read (see Status). The installers explain the limit if the load fails.

## Smoke test

The regression suite uses temporary bundles and stand-in engines, with no
model downloads or real application installs:

```bash
python3 -m unittest discover -s tests -v
```

It tests output integrity and the Mac, Windows and web installers: successful
installs, reruns, checksum failures, container and port conflicts, image-load
failures, file copies, smoke tests and launch failures. The installer scripts
run unchanged; Docker, application setup and service transports are stand-ins.
The native Windows tests also exercise `install.cmd` and ARM image selection.

[The regression workflow](.github/workflows/regression.yml) runs on macOS and
Windows, including Windows PowerShell 5.1 and PowerShell 7. The Mac tests need
macOS; the Windows installer tests need Windows. `HOSHI_PWSH` selects the
PowerShell runtime. Web tests need Flask, requests and lxml (already in the
LibreTranslate image); `python3 -m pip install -r tests/requirements.txt` adds
the test dependencies on a development machine. Unavailable platforms are
reported as skipped. [tests/README.md](tests/README.md) explains the boundaries
of these tests: they do not validate Docker Desktop's first launch, a real
Ollama setup, GPU support, or a full bundle on a clean disconnected machine.

A small build exercises every step in a few minutes, with about 1.4 GB of
downloads for the Mac target (0.6 GB of it Docker Desktop) and another 2 GB
(mostly Ollama's Windows installer) for the Windows one:

```bash
./build-bundle.sh --langs en,fr --model gemma3:270m --out /tmp/smoke-bundle
```

Every build tags its image `libretranslate-offline:VERSION-ARCH` whatever languages
are in it. A smoke build moves the tag to its two-language image. Running
containers keep their full image, and the current installers select images
by ID. Older web installers selected the moved tag while recording the full
image's ID; use a new web patch before reinstalling the page on such a Mac.
If the installed image is no longer available by ID, load it from the full
bundle or re-run that bundle's installer:

```bash
docker load -i docker/libretranslate-offline-v1.9.6-arm64.tar
```

To install a smoke bundle beside a real installation, give `install.sh` its
own `--prefix`, `--port`, `--name`, `--web-port` and `--web-name`, and set
`OLLAMA_MODELS` to a scratch folder so the model is not copied into the real
store.

## Status (2026-11-17)

This is the manual testing record from before the automated regression workflow
described above was added.

What has been tested and what has not. Except where it says "from this
repository", the tests were run on the code as it stood in the private
repository this one starts from (see History), on Apple Silicon Macs, most of
it on macOS 26.7; the timings are from an M5 Max with 128 GB. PowerShell 7 for the
Windows tests came from `mcr.microsoft.com/dotnet/sdk:8.0`, which has an Apple
Silicon build. `mcr.microsoft.com/powershell` does not, and crashes under
emulation.

**Builds**

- *From this repository:* the smoke build above for the Mac target, and
  `build-web-patch.sh`, twice each. The first pair, from the files as they
  were just before the first commit, is what tested the credits: each output
  carried `NOTICE.txt` and `LICENSE.txt`, the bundle carried `licences/` with
  the terms of its Ollama model and the READMEs of its language models, and
  every file matched `SHA256SUMS`. Neither was installed. The second pair,
  from the files as they were just before the commit that put the web page
  in the bundle, carried the same page: `web/` and `install-web.sh` differed
  only in the build time. That bundle was installed (see below). No
  full-size bundle has been built from this repository
- *Full size, Mac target:* twice. First with every language and
  `translategemma:12b`, on macOS 27, from the build script before it had a
  Windows side. Then with every language, 12B, 27B and Docker Desktop, from
  commit `c91c2cd` of the private repository. The offline test translations
  the build makes passed both times
- *Smoke build, both targets:* including the offline boot and test
  translation of the Intel/AMD image under emulation

**The Mac installer**

- `install.sh` from each full bundle, on the Mac that built it: it verified
  the checksums and brought LibreTranslate up, and `translate.sh` then worked
  against both engines
- from a smoke bundle: a re-run, a port in use, a container it didn't
  create, a tampered file
- into scratch locations, from a copy of a bundle with the Windows files
  left off
- its Docker Desktop step, with stand-ins for `sudo`, `hdiutil`, `open` and
  `docker`, since the test Mac already had Docker: a Mac with no Docker
  (asked and unasked), Docker installed but not running, and each failure it
  reports (no disk image in the bundle, a changed disk image with and
  without `--skip-verify`, a macOS too old, a user who is not an
  administrator, a failed install, Docker never becoming ready). The disk
  image itself was mounted and its signature checked by the real build
- the install log, on a real run against the real Docker
- its copying of the test files, in the stand-in harness, with and without
  them in the bundle
- **on an airgapped Apple Silicon Mac that had no Docker**, the full bundle
  built from `c91c2cd`. That is as reported by the person who installed it:
  `install.sh` ended in `==> Done`. Its log has not been read (see Not yet
  done)
- *from this repository,* the smoke bundle with the web page in it, on the
  build Mac beside a full installation, on other ports and in scratch
  folders. `install.sh` started LibreTranslate with its own page turned off
  (404 at `/` and `/js/app.js`; `/languages`, `/frontend/settings` and
  `/translate` answering) and then the web page, which reported both engines
  ready. Driven through its API, not a browser, the page translated the
  English .docx with LibreTranslate and with the smoke bundle's stand-in
  model, and the English .pdf with LibreTranslate; `translate.sh` translated
  the .docx against the same LibreTranslate. Then: a re-run; a page update
  installed over it with `install-web.sh`, which left the LibreTranslate
  container alone; `--no-web`, which brought LibreTranslate's own page back
  and left the earlier web page running; `--no-docker`; the page's port in
  use, which stopped the installer before it changed anything; and a bundle
  with the page's files taken out. Every run had `--no-launch` and
  `--no-open`, so the Ollama step and the opening of the page did not run.
  The switch that turns LibreTranslate's page off was also tried on the full
  image, with the same answers and `/detect` working

**The Windows installer.** Nothing has run on Windows. `install.ps1`'s logic
was run in PowerShell 7 with stand-ins for Docker, robocopy and the Ollama
installer and with its Windows paths rewritten for Linux: a full install, a
re-run, an ARM PC, and each failure it reports (damaged or missing file,
Docker stopped or in Windows-containers mode, full disk, someone else's
container, port taken, failed copy, failed Ollama install, Ollama not
answering). The lines that copy the test files were run on their own.

**The translate helpers**

- `translate.sh` against both engines: plain text, .docx, .html, .srt and a
  .pdf (recorded as not checked), 40 files in one run, and forced re-runs
  inside the same second
- `translate.ps1` against the same two services, in PowerShell 7 in a Linux
  container. Its output was byte-identical to `translate.sh`'s on plain,
  CRLF, BOM, CP1251 and UTF-16 text and on .html, and its text splitter
  matched the Mac one piece for piece on 47 test texts. Run beside
  `translate.sh` on the Arabic and Spanish .docx and an .srt through
  LibreTranslate and Russian text through TranslateGemma, it gave the same
  translation byte for byte from TranslateGemma, and the same sidecar line
  and the same warnings throughout: three on the Arabic .docx, four with
  `--from ar`. A .pdf was recorded as not checked by both, and an .html and
  an .odt by the PowerShell only
- the check on each TranslateGemma piece, in both helpers, against a
  stand-in Ollama that drops, merges, re-wraps or re-spaces lines, on six
  shapes of source: 42 cases each, the same verdicts from both
- the dropped-text check: measured as
  [The dropped-text check](#the-dropped-text-check) describes, and the copy
  in `translate.ps1` compared with the one in `translate.sh` by
  `calibration/windows.sh`: 4,185 comparisons measuring 33,371 paragraphs
  and lines and raising 1,929 warnings, the same from both in every number,
  verdict and warning

**The web page**, in headless Chrome, against both engines: the five Word
test documents with each, the English .pdf with LibreTranslate, the Arabic
.pdf with TranslateGemma. On the Arabic .docx through LibreTranslate it gave
the warnings `translate.sh` gives, three with the language detected and four
with it chosen. It reported nothing on the Russian, Spanish, Hebrew and
English .docx with either engine, and recorded the LibreTranslate .pdf as
not checked. That nothing calls `/spec` is from reading the code:
LibreTranslate does not log requests, so the service was not watched.

**The engines.** Read by eye, with a crude count of which numbers survived.
None of this is an evaluation.

A two-paragraph document (a name, a company, a date, two figures, three
negations) written in each of English, Russian, French, Chinese, Hebrew and
Arabic, run with the first full build:

- **TranslateGemma 12B into English:** all five accurate. Every name, number,
  date and negation survived. 4 to 9 seconds each
- **TranslateGemma 12B out of English:** French and Arabic accurate, Chinese
  accurate but awkward. Russian turned "not to keep copies" into "not to make
  copies". Hebrew turned "had never been signed" into "has not yet been
  signed"
- **LibreTranslate into English:** Russian and Chinese accurate. French turned
  "to be named" into "to be appointed". Hebrew turned "the ministry" into "the
  firm". Arabic lost a whole sentence (see Things to know)

The test documents in [bundle/test-files/](bundle/test-files/), about 1,000
words each:

- **TranslateGemma 12B on the text of each .docx** (saved as plain text with
  `textutil`): complete and fluent in Russian, Spanish, Arabic and Hebrew into
  English and in English into French. All 38 numbers in the Hebrew survived.
  30 to 45 seconds a file, and a second run gave the same output. The Spanish
  one came back with its title in markdown bold
- **TranslateGemma 27B on the same text:** 50 seconds to two minutes a file.
  Russian, Spanish and Hebrew into English and English into French came out
  the same length as 12B's, paragraph for paragraph; in the Hebrew it joined
  two lines into one sentence with nothing lost. In the first half of the
  Arabic it condensed instead of translating: four paragraphs came out 29%
  shorter than 12B's, two of them merged, "about 200 independent countries"
  gone, and two runs differed from each other in three phrases. The second
  half matched 12B's length. The helper's check on each piece warns on both
  the Arabic and the Hebrew
- **LibreTranslate on the .docx files:** Russian, Spanish and English into
  French read well. Hebrew is rough, turned 0.5 km/s into 0.2 and garbled a
  web address. Arabic dropped passages (six of its numbers are missing),
  repeated "Earth's" in a loop and left `&apos;` in the text. Translations
  from Arabic and Hebrew keep the source's right-to-left paragraph setting.
  3 to 15 seconds a file
- **LibreTranslate on the .pdf files:** as Things to know describes.
  Left-to-right ones followable with sentences broken at line ends; Arabic
  and Hebrew scrambled, with words that are not in the source
- **LibreTranslate and an HTML doctype.** It turned a test page's
  `<!DOCTYPE ...>` into a line of visible text at the top of the translation.
  That left the translation a line longer than its source, so the Mac check
  could not line the two up and compared them as one paragraph

### Not yet done

The Windows items can't be done from a Mac.

- **a real installation on a Windows PC with Docker Desktop and Ollama.**
  The regression workflow now exercises the installers and helpers on Windows
  PowerShell 5.1, including `install.cmd`, with stand-ins for external services
  and application setup. A real silent Ollama install, the Start-menu launch,
  GPU pickup and Docker Desktop on Windows still need testing
- the full build for the Windows target, or for both at once
- a full-size bundle built from this repository. The one full bundle there is
  has helpers that call `/spec` and no web page (see History)
- **a record of the airgapped install.** Three steps ran there for the first
  time and finished: Docker Desktop's installer run by `install.sh` on a Mac
  with no Docker, `docker load` on a machine holding none of the image's
  layers, and the last step, which opens the Ollama app and waits for it.
  What Docker showed on first launch, whether its engine started while the
  sign-in screen was still up, whether `--user` spared a second password
  prompt, how long the load took and what disk it cost are in that Mac's
  install log, and not known here
- the web page in Safari or on Windows, and in any browser since the bundle
  began to carry it: those tests drove its API. `install.sh` opening the page
  at the end of an install
- `translategemma:27b` on a 32 GB Mac, and any comparison of it with 12B
  beyond the five test files. The build's self-test runs only the first
  model in the list
- copying the text out of a PDF and translating that, which the user guide
  suggests when there is no Word version
- bilingual expert evaluation of either engine on real documents from the
  intended workflow, beyond the sentence-level reference benchmark in
  [evaluation/](evaluation/)

Before relying on the Windows side, run a smoke bundle's `install.cmd` on a
connected Windows PC with Docker Desktop.

## Credits and licences

Hoshi's own code is the build scripts, the installers, the translate helpers,
the web page, the dropped-text check, evaluation tools and regression tests.
It is © 2026 Luke Hoyland and is free
software under the [GNU Affero General Public License, version 3](LICENSE).
That is LibreTranslate's licence, and the licence of PyMuPDF, which the web
page uses to read PDFs.

Everything that translates is someone else's work. None of it is in this
repository: `build-bundle.sh` fetches it from its publishers and a bundle
carries it unchanged.

| | By | Terms |
|---|---|---|
| [LibreTranslate](https://github.com/LibreTranslate/LibreTranslate) | the LibreTranslate contributors | AGPL-3.0 |
| [Argos Translate](https://github.com/argosopentech/argos-translate), the engine inside it | Argos Open Technologies, LLC | MIT or CC0 |
| The Argos language models | Argos Open Technologies and the LibreTranslate community. 57 of the 100 are repackaged [OPUS-MT](https://github.com/Helsinki-NLP/OPUS-MT) models (Jörg Tiedemann and Santhosh Thottingal), and nearly all were trained on text collected by [OPUS](https://opus.nlpl.eu) | each package's own; CC BY 4.0 for the OPUS-MT ones |
| [Ollama](https://github.com/ollama/ollama) | Ollama | MIT |
| [TranslateGemma](https://arxiv.org/abs/2601.09012) | Google | [Gemma Terms of Use](https://ai.google.dev/gemma/terms); not open source |
| Docker Desktop | Docker, Inc. | proprietary; [Docker Subscription Service Agreement](https://www.docker.com/legal/docker-subscription-service-agreement/) |
| The [test files](bundle/test-files/) | the contributors to five Wikipedia articles | CC BY-SA 4.0 |

[NOTICE](NOTICE) has the full account: the libraries inside the LibreTranslate
image, the data each language model names, the citations their makers ask
for, and the Python libraries the web page runs on. Every bundle carries it
as `NOTICE.txt`, with `LICENSE.txt` and a `licences/` folder holding the terms
each Ollama model came with and the README of every language model.

Three things follow from these terms:

- **TranslateGemma.** Google's terms require anyone passing the model on to
  pass on a copy of the terms and to say that the model is subject to their
  use restrictions. A bundle does the first by carrying them; the second is
  for the person handing it over.
- **Docker Desktop.** Docker's agreement, as last updated on 26 August 2026,
  makes it free in "a commercial undertaking with fewer than 250 employees
  and less than US $10,000,000 (or equivalent local currency) in annual
  revenue", and says a customer may not "distribute, license, sublicense,
  lease, rent, loan, or otherwise transfer the Services to any third party".
  So a bundle with Docker Desktop in it is for machines in your own
  organisation. For anyone else, build with `--no-docker-desktop`.
- **LibreTranslate's name** is a trademark with
  [guidelines](https://github.com/LibreTranslate/LibreTranslate/blob/main/TRADEMARK.md)
  that ask projects built on it not to use the name in their own. The image
  a bundle carries is still tagged `libretranslate-offline`, which should
  change.

None of this is legal advice. The terms were read on 17 November 2026.

## History

Hoshi was written on 16 and 17 November 2026 in a private repository of
unrelated utilities, in a folder called `airgapped_translation`. This
repository starts from that folder as it stood at commit `7135781` there.
The commit ids this README gives for work before that (`c91c2cd`, `bcce944`),
and the ones recorded in bundles and page updates built on those two days,
are ids in that repository and will not be found in this one.

One full bundle (from `c91c2cd`) and one web page update (from `bcce944`)
built there on 17 November call LibreTranslate's `/spec` (see Things to
know): the helpers once for each file they give LibreTranslate, the page
whenever it is opened or given a document and for each LibreTranslate
translation. On a machine that has them, the page is put right by a page
update built from this repository, followed once by
`docker restart libretranslate`; the helper by a bundle built from it.

That full bundle also has no web page in it. A Mac it is installed on gets
the page from a page update and keeps LibreTranslate's own page beside it
until a bundle that carries the page is installed there.

The names inside a bundle predate the name Hoshi and have not changed:
`translation-bundle-*`, `~/translation-tools`, the `libretranslate` and
`translation-web` containers.
