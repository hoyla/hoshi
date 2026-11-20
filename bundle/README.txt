OFFLINE TRANSLATION
===================

Two translation engines that run entirely on one computer, a Mac or a
Windows PC. Nothing leaves the machine and nothing here needs a network.
Everything they need, language models included, is in this folder.

  LibreTranslate   Translates pasted text and whole documents, keeping their
                   formatting. Fast. Quality is good enough to get the gist.

  TranslateGemma   A Google translation model run by the Ollama app.
                   Noticeably better translations. Gives back plain text.
                   Slower. It comes in two sizes: the standard one (12b)
                   and a smaller one (4b) for computers where the standard
                   one is too slow.

You use both from one web page, http://127.0.0.1:5080, which checks each
translation for dropped text and keeps a record of how it was made. There is
a command-line helper as well.

MANIFEST.txt lists exactly what this bundle contains: versions, model digests
and the test translations made when it was built. NOTICE.txt says who made
each part and on what terms it may be used and passed on.

Contents of this guide:

    What the computer needs
    Copying the bundle to the computer
    Installing on a Mac
    Installing on Windows
    Installing a newer bundle over an older one
    Using it
    Trying it on the test files
    Languages and file types that give trouble
    How far to trust it
    After a restart
    If something goes wrong
    Removing it
    Who made this, and passing it on


WHAT THE COMPUTER NEEDS
-----------------------
A Mac
    An Apple Silicon Mac (M1 or later) with macOS 14 or newer and 16 GB of
    memory or more. (With 8 GB, only the smaller TranslateGemma model is
    likely to run, and nobody has tried it.) It does not need Docker
    Desktop already: if it has none,
    the installer puts on the copy in this folder (docker/Docker.dmg), which
    takes the Mac's administrator password.

A Windows PC
    Windows 10 (version 22H2) or Windows 11, with Docker Desktop installed.
    No administrator rights are needed.

    LibreTranslate runs well on any such PC. The standard TranslateGemma
    model (12b) is quick only on a PC whose graphics card has about 12 GB
    of its own memory (NVIDIA or AMD). Without one it still works, but
    slowly: expect minutes for each page. The installer times a test
    translation so you can tell which kind of PC you have. If it is the
    slow kind, use the smaller model (4b): "Using it" says how.

Either one
    About 35 GB of free disk space.

Docker Desktop is free for personal use and for small organisations. Larger
ones need a paid Docker subscription for every machine it is on, so check
with whoever looks after software licences before installing it at work.
Docker does not allow its installer to be passed on to other organisations
(see the last section of this guide).


COPYING THE BUNDLE TO THE COMPUTER
----------------------------------
  1. Use a drive formatted as exFAT. Macs and Windows PCs can both read and
     write it, and it holds very large files. (The older FAT32 format cannot
     hold the largest files here. A drive formatted for only one kind of
     computer may not open on the other.)

  2. Copy this whole folder to the drive. Keep the file and folder names as
     they are. The bundle is somewhere between 20 and 40 GB depending on
     what was built into it, so allow half an hour or more, and eject the
     drive properly before unplugging it.

     To save space and time you can leave out the big files meant for the
     other kind of computer:

         for a Mac only, leave out      docker/...-amd64.tar
                                        ollama/OllamaSetup.exe

         for Windows only, leave out    docker/...-arm64.tar
                                        docker/Docker.dmg
                                        ollama/Ollama-darwin.zip

     (Keep the -arm64 file for a Windows PC with a Snapdragon or other ARM
     processor.) Copy everything else.

  3. Plug the drive into the airgapped computer. You can install straight
     from the drive, or copy the folder to the computer first if you would
     rather. Installing from the drive saves disk space.

The installer checks every file against the list in SHA256SUMS before it
does anything, so a file damaged in copying is caught rather than installed.


INSTALLING ON A MAC
-------------------
Open this folder in Finder and double-click Install.command. (Depending on
your settings it may show as just "Install".)

A Terminal window opens and reports each step. First it checks the Mac: the
macOS version, that the two ports it uses are free, that there is enough
free disk space, and how much memory there is. If one of these will not do,
it says so now, in a minute, and not half an hour in. Then it checks the
files, loads LibreTranslate into Docker, copies Ollama.app into
/Applications and the models into ~/.ollama/models, and puts the
translate.sh helper and some test files in ~/translation-tools. It starts
the translation page, runs a test translation through each engine, and
finishes by opening the page in your browser. Allow 15 to 30 minutes.

The window stays open at the end. It says either "The install finished",
with a summary above that line, or "The install did NOT finish", with the
step it stopped at, what to do, and where the record of the run is. Read
it, then press Return to close the window. It is safe to run again.

If the Mac has no Docker
    The installer says so near the start and waits for you to press Return.
    It then installs Docker Desktop from this folder:

      1. Type the Mac's administrator password when Terminal asks for it.
         Nothing shows as you type. Press Return.
      2. Docker opens and shows its service agreement. Read it and accept
         it. The installer does not accept it for you.
      3. Skip signing in, the survey and any offer to update. If macOS asks
         for the password again for Docker, give it.

    The installer waits while you do this, and carries on by itself once
    Docker is ready.

If Docker is installed but not open, the installer opens it and waits.

If the Mac has less than 16 GB of memory, the installer warns you and
carries on. LibreTranslate is not affected; TranslateGemma's standard model
may be very slow or fail to load, and the smaller one (4b) is the one to
try.

Every run writes a log of what it did and what it found, named
install-DATE.log, in ~/translation-tools. If an install fails, that file
holds everything the installer printed.

If double-clicking does not work, or you want the options
    Open Terminal (in Applications > Utilities), type cd and a space, drag
    this folder into the Terminal window, and press Return. Then run:

        ./install.sh

    It is the same installer; Install.command only runs it for you.
    ./install.sh --help lists the options (different port, skip one engine,
    etc).

A newer translation page may reach you later as a small folder of its own.
Its README.txt says how to install it; it replaces the page and changes
nothing else.


INSTALLING ON WINDOWS
---------------------
  1. Start Docker Desktop and wait until it says it is running. If it asks
     you to sign in or to update, skip both.
  2. Open this folder in File Explorer and double-click install.cmd.
     (Depending on your settings it may show as just "install", of type
     "Windows Command Script".)

A black window opens and reports each step. First it checks the PC: that the
two ports it uses are free, that there is enough free disk space, and how
much memory there is. If one of these will not do, it says so now, in a
minute, and not half an hour in. Then it checks the files, loads
LibreTranslate into Docker, copies the model into the .ollama folder in your
user folder, installs Ollama for your user account, and puts the translate
helper and some test files in the translation-tools folder in your user
folder. It starts the translation page, runs a test translation through each
engine, says how long TranslateGemma took, and finishes by opening the page
in your browser. Allow 10 to 30 minutes. When it says "Press any key to
continue", read the summary above that line, then press a key to close the
window. It is safe to run again.

If the install stops, the window says "The install did not finish", the
step it stopped at, and what to do. Each run also writes a record named
install-DATE.log in the translation-tools folder in your user folder. It
holds what the installer itself printed; some of what Docker printed may be
missing from it.

If Windows shows a blue "Windows protected your PC" box, choose More info,
then Run anyway.

For options (different port, skip one engine, etc), open Command Prompt in
this folder and run:   install.cmd --help

A newer translation page may reach you later as a small folder of its own,
as on a Mac. Its README.txt says how to install it.


INSTALLING A NEWER BUNDLE OVER AN OLDER ONE
-------------------------------------------
Install the newer bundle exactly as you installed the first: there is
nothing to remove beforehand. Your translations, in the translations folder
inside translation-tools, are kept.

Near the start the installer says which bundle the computer has and which
one you are installing, each by the time it was built. If the one you are
installing is OLDER, it says so in capitals, and again at the end; it does
not stop. If they are the same, running it repairs the install.

Once the new LibreTranslate has made its test translation, the installer
removes the older bundle's LibreTranslate from Docker, which frees 9 to
11 GB. It leaves it if anything else in Docker still uses it, and says so.

A TranslateGemma model that the older bundle had and the newer one lacks
(the large 27b model, for example, which takes 17 GB) is NOT removed: it
still works and you may want it. The end of the install lists each such
model, how much space it holds, and the exact command that removes it.

Ollama itself is replaced by the newer bundle's version only if an earlier
install from one of these bundles put it on the computer. An Ollama that was
there before is never replaced; "If something goes wrong" says how to
switch by hand. (A bundle made before this was written kept no note of
having installed Ollama, so the first newer bundle over one of those leaves
Ollama alone as well.)


USING IT
--------
On the translation page
    Open http://127.0.0.1:5080 in a browser. Choose a document or paste
    text, choose TranslateGemma or LibreTranslate, choose the languages,
    and press Translate. Before you press it, the page says what the
    engine you chose is good and bad at for that document.

    LibreTranslate gives back a document of the same kind, with its
    formatting. TranslateGemma gives back plain text: the page takes the
    text out of a .docx, .odt, .pdf or .html file itself and saves exactly
    what it sent to the model beside the translation.

    Every translation is kept in ~/translation-tools/translations (on
    Windows, translation-tools\translations in your user folder) with a
    .provenance.json file recording how it was made, and the page lists
    them. The document you chose is not copied there; the record holds
    its name and its SHA-256. The page makes the checks described under
    "How far to trust it" and shows what they find.

    TranslateGemma comes in two sizes. The page uses the standard one,
    translategemma:12b, unless you choose otherwise. Where that is too
    slow (most often a Windows PC without a suitable graphics card),
    choose translategemma:4b in the Model list, which appears once
    TranslateGemma is selected. The page remembers that choice, in the
    browser you made it in, until you choose 12b again, and says so while
    4b is selected. Every translation's record names the model that made
    it. Before relying on 4b, read what "How far to trust it" says of it.

    The page answers only on the computer it is installed on. Other
    computers can't reach it.

    LibreTranslate has a page of its own, which keeps no record of a
    translation and makes no check of one. The installer turns it off:
    http://127.0.0.1:5050 shows "Not Found" and nothing is wrong. Only an
    install made with --no-web, or from a Windows bundle older than the
    translation page, has it.

From the command line (Mac or Windows)

    On a Mac, in Terminal:

        ~/translation-tools/translate.sh --from ru --to en statement.txt
        ~/translation-tools/translate.sh --to en contract.docx
        ~/translation-tools/translate.sh --from ar --to en --text "..."

    On Windows, in Command Prompt (open the Start menu and type cmd):

        %USERPROFILE%\translation-tools\translate.cmd --from ru --to en statement.txt
        %USERPROFILE%\translation-tools\translate.cmd --to en contract.docx
        %USERPROFILE%\translation-tools\translate.cmd --from ar --to en --text "..."

    Type the command, a space, then drag the document into the window to
    fill in its full name. The options are the same on both; the examples
    below say translate.sh, so read translate.cmd on Windows.

    .txt and .md files go to TranslateGemma; everything else goes to
    LibreTranslate. Force one with --engine gemma or --engine libre.
    Leave out --from and the language is detected for you.
    Common codes: en ru fr zh he ar. Full list: translate.sh --languages

    Text that is not UTF-8 (common for older Russian, Hebrew, Arabic and
    Chinese files) needs --encoding, for example --encoding CP1251.

    The helper uses the standard TranslateGemma model, translategemma:12b.
    For the smaller, faster one, add --model translategemma:4b to the
    command. The helper does not remember this from one run to the next,
    and takes no notice of the model chosen on the translation page. See
    "How far to trust it" below before relying on 4b.

What you get
    statement.txt                             your original, never changed
    statement.en.gemma.txt                    the translation
    statement.en.gemma.txt.provenance.json    how it was made: hash of the
                                              original, engine, exact model,
                                              languages, time, any warnings

    Running the same command again reuses an intact result when the original,
    decoded input, encoding, engine, model, languages, settings and helper
    version match. Its saved hash is checked first. A changed or missing
    translation is made again under a new name; your edits are preserved.
    Older results without the new integrity fields are kept but not reused.
    --force always makes a new result. Nothing is overwritten.

    A .lock file reserves the name while a translation is being made. Two
    runs at once use separate names. If the computer shuts down abruptly,
    a lock or incomplete result may be left behind; later runs leave it
    alone and make a new result instead.

In the Ollama window
    You can chat with the model directly, but TranslateGemma expects a fixed
    instruction before the text, so translate.sh --text is easier.


TRYING IT ON THE TEST FILES
---------------------------
The installer puts a folder of practice documents beside the helper:
~/translation-tools/test-files on a Mac, translation-tools\test-files in
your user folder on Windows. Use them to check that everything works and to
see what each engine's output looks like before you trust it with a real
document.

They are passages of about 1,000 words from Wikipedia's article on Earth in
five languages, each as a Word file and as a PDF:

    english   spanish   russian   arabic   hebrew       (.docx and .pdf)

Each language's passage is different; they are not translations of one
another. README.md in the folder says where each came from. They are
published under the Creative Commons BY-SA 4.0 licence.

On the translation page:

    Press "Choose a document". In the window that opens, on a Mac press
    Command-Shift-G, type ~/translation-tools/test-files and press
    Return; on Windows click the address bar at the top, type
    %USERPROFILE%\translation-tools\test-files and press Enter.
    Translate russian.docx and then arabic.pdf into English with
    LibreTranslate, and arabic.docx with TranslateGemma. The translations
    go to the translations folder in translation-tools, not beside the
    originals.

On a Mac, in Terminal:

    cd ~/translation-tools/test-files
    ../translate.sh --to en russian.docx
    ../translate.sh --to en arabic.pdf

    textutil -convert txt -encoding UTF-8 arabic.docx
    ../translate.sh --to en arabic.txt

On Windows, in Command Prompt:

    cd /d %USERPROFILE%\translation-tools\test-files
    ..\translate.cmd --to en russian.docx
    ..\translate.cmd --to en arabic.pdf

    Then open arabic.docx in Word, use Save As, choose Plain Text and then
    Unicode (UTF-8), save it as arabic.txt in the same folder, and run:

    ..\translate.cmd --to en arabic.txt

The first two commands of each set use LibreTranslate and give back a Word
file and a PDF. The last uses TranslateGemma and gives back plain text. The
helper's translations appear in the same folder, beside the originals.

What came back in testing in November 2026, with LibreTranslate 1.9.6
(translating into English; the English file was translated into French):

                 LibreTranslate      LibreTranslate      TranslateGemma 12b
                 Word file           PDF                 text of the Word file

    spanish      reads well          can be followed;    reads well
    russian                          sentences broken
    english                          at line ends

    hebrew       rough; one figure   scrambled           reads well; every
                 came out changed                        figure correct

    arabic       several passages    scrambled           reads well
                 missing, a phrase
                 repeated over
                 and over

If you get much the same, the installation is working: the poor results in
that table are the engines' limits, not a fault on your computer. The next
section says what to do about them.

On the fast Mac used for the test, LibreTranslate took 3 to 15 seconds for
each file and TranslateGemma 12b took 30 to 45 seconds. The smaller 4b
model was not timed. A slower computer takes longer, and a Windows PC
without a suitable graphics card takes much longer for TranslateGemma.

You can delete the translations, or the whole test-files folder, whenever
you like. Running the installer again puts the originals back.


LANGUAGES AND FILE TYPES THAT GIVE TROUBLE
------------------------------------------
This comes from testing with the files above, so it covers five languages.
For any other language, first translate a document whose contents you
already know and see how it does.

PDFs
    LibreTranslate translates a PDF one small piece at a time: each printed
    line by itself, and a line is cut again wherever the font changes. It
    never sees a whole sentence that runs over a line.

    In Spanish, Russian and other left-to-right languages the result can
    be followed but is worse than the same text from a Word file. In Arabic
    and Hebrew it cannot be used: numbers come loose from their sentences,
    the order is muddled, and stray words such as "No." and "What?" appear
    that are not in the original. Expect the same of other right-to-left
    languages (Persian, Urdu); those were not tested.

    What to do instead, best first:

      1. If you have the same document as a Word file or as text, translate
         that and leave the PDF alone.
      2. Choose the PDF on the translation page and translate it
         with TranslateGemma. The page takes the text out of the PDF and
         gives the model whole paragraphs. With Arabic and Hebrew the text
         that comes out of a PDF is often damaged, with letters swapped
         inside words and punctuation at the wrong end of a line: in the
         one Arabic PDF tested, the translation lost a heading and was
         vaguer than the translation of the same text from Word.
      3. On Windows, copy the text out. Open the PDF, select all of it,
         copy, and paste into Notepad. Save it with a name ending .txt and
         translate that. Copying can itself muddle right-to-left text, and
         this was not tested, so compare a few lines with the PDF before
         you rely on it.
      4. Use LibreTranslate's translated PDF only to see what a
         left-to-right document is about.

    A scanned PDF is a picture of each page and holds no text. If you
    cannot select words in it with the mouse, nothing here can read it:
    this bundle has no text recognition (OCR).

Arabic and Hebrew
    LibreTranslate is much weaker in these than in Russian or Spanish. In
    the test it left several passages out of the Arabic Word file without
    saying so, and it changed a figure in the Hebrew one (0.5 km a second
    became 0.2). TranslateGemma translated both in full with the figures
    intact.

    So for these two languages use TranslateGemma for anything you will
    act on. On the translation page, choose it for the document. From the
    command line, save the document as plain text (the next section shows
    how) and translate the .txt file. Keep LibreTranslate for a first look.

    A Word file translated from Arabic or Hebrew keeps its right-to-left
    layout, so the English sits against the right margin with its full
    stops at the wrong end of the line. The words are not affected. In
    Word, select everything and set the paragraphs to left-to-right.

Numbers, names and web addresses
    Check every figure you intend to use against the original; the digits
    can usually be matched even if you cannot read the language.
    LibreTranslate also sometimes "translates" things that should be left
    alone. It garbled a web address in the Hebrew test file. Take web and
    email addresses, reference numbers and names from the original.

Older Word files (.doc)
    Only .docx is accepted. Open the file in Word and save it as .docx, or
    save it as plain text.

Text that shows as nonsense letters before it is translated
    See "isn't valid UTF-8" under "If something goes wrong".


HOW FAR TO TRUST IT
-------------------
This is machine translation. Use it to find out what a document says and
whether it matters. Do not quote from it. Names, numbers, dates, negations
and idioms are where it goes wrong, and it can read fluently while being
wrong. Anything that will be published needs a human translator working from
the original.

LibreTranslate goes through English when neither language is English (Russian
to French is really Russian to English to French), so errors compound.

LibreTranslate can also leave out whole sentences and say nothing. In testing
it did so repeatedly from Arabic into English: it left several passages out
of the Arabic test file, and in a twelve-paragraph article it cut three
paragraphs down to a single sentence each.
TranslateGemma translated both in full, but those were two documents, and
TranslateGemma can drop text too. Never take either engine's output as proof
that something is absent from a document. For anything that matters, put the
text through both and compare. On the translation page, translate the
document once with each engine. The command-line helper gives TranslateGemma
plain text only; to get plain text out of a Word document on a Mac:

    textutil -convert txt -encoding UTF-8 contract.docx

This writes contract.txt beside the original. On Windows, open the document
in Word and use Save As, choosing Plain Text and then Unicode (UTF-8). The
record the helper keeps for a translation of contract.txt describes that
file, not the Word document it came from, so keep the two together.

TranslateGemma handles long texts in pieces of a few paragraphs, so it does
not see the whole document at once. Terms may be rendered inconsistently
between pieces.

The smaller TranslateGemma model (4b) is there for computers on which the
standard one (12b) is too slow. Everything this guide says about how good
TranslateGemma is, the table of test results included, was found with 12b.
Nobody has yet compared 4b's translations with 12b's, and the checks
described next have not been tried on 4b's output, so they may warn more
or less often than they should. Treat a 4b translation as a first reading.
Where it matters, translate the document again with 12b on a computer that
can run it. The .provenance.json file says which model made a translation.

If the helper prints a warning, or the translation page shows one, read it.
Both make the same two checks, and record what they find in the
.provenance.json file.

With TranslateGemma, on a Mac or on Windows, it checks each piece for signs
that the model dropped or merged text: a different number of paragraphs or
lines, or a reply that was cut short. It warned about the shortened Arabic
above. A warning does not always mean a loss: the model joining two short
lines into one sentence sets it off, and so can a text whose lines were
broken by hand.

With either engine, the helper then compares each paragraph of the
translation with the original and warns when one is much shorter or longer
than it should be, or somewhat shorter and missing a sentence:

    warning: paragraph 4 (starts "..."): the translation is 82% shorter
    than expected and has 1 sentence against 4 in the source; check for
    dropped text

Go to that paragraph in the original, and try the other engine on it. The
provenance file has a line saying what was compared.

With LibreTranslate, this check sees more when you give the language (--from,
or "From" on the page) than when it is left to be detected. If you know the
language, give it.

What this second check does not do:

  - It does not run in LibreTranslate's own page in the browser.
  - It cannot read every kind of file. Text, .srt and Word (.docx) files
    are always compared. .odt and .html files are compared by the
    translation page and by the Mac helper, not by the Windows helper.
    .pdf, .pptx, .odp and .epub files are not compared at all. The provenance file of a file that was not compared
    says "not checked".
  - When the translation has a different number of lines from the
    original, it can only compare the two as a whole, and then it notices
    only a large loss.
  - It rarely notices the loss of a sentence that was less than a fifth of
    its paragraph. In testing it caught about three in four sentences
    removed from a document, and nearly all of the long ones.
  - It knows nothing about whether the words are right.

A translation with no warnings can still be wrong.


AFTER A RESTART
---------------
On a Mac, open the translation-tools folder in your home folder and
double-click "Start Translation.command". On Windows, open the
translation-tools folder in your user folder and double-click
"Start Translation" (of type "Windows Command Script").

It opens Docker Desktop and Ollama if they are not running, waits for
LibreTranslate, TranslateGemma and the translation page, and opens the page
in your browser. Allow a few minutes after a restart. If one of the three
does not answer, it says which one and what to do about it. It installs
nothing and can be used as often as you like. You may drag it to the Dock
(Mac) or make a shortcut to it on the desktop (Windows); leave the file
itself where it is.

By hand, the same thing: start Docker Desktop, and LibreTranslate and the
translation page come back by themselves. For TranslateGemma, Ollama has to
be running. On a Mac, open Ollama from Applications. On Windows it normally
starts when you sign in (a llama icon near the clock); if it has not, open
Ollama from the Start menu.


IF SOMETHING GOES WRONG
-----------------------
On either kind of computer

"The install did not finish"
    These lines end any install that stopped. They name the step it stopped
    at; the reason is in the lines just above them, and often says what to
    do. Nothing that was on the computer before is harmed by a stopped
    install, and running the installer again is safe: it picks up what is
    already done. If the bundle's builder gave a name to ask for help, it
    is the last of those lines. Send them the log file the lines name.

"not enough free disk space"
    The installer adds up what it is about to copy and compares that with
    the free space on the computer's own disk. Free some space and run it
    again. If you are sure there is room (the sum is an estimate), run it
    with --no-space-check.

"Docker isn't running" or "Docker didn't become ready"
    Open Docker Desktop yourself and wait until it says it is running. It
    may ask you to accept its agreement, sign in or update; accept the
    first and skip the others. Then run the installer again.

"checksum verification failed"
    A file was damaged or cut short while copying. The lines above the
    error name the files. Copy those again from the original and re-run.

"port 5050 is already in use"
    Another program on this computer is using that port. Run the installer
    again with --port 5051 (the helper remembers the port).

"couldn't reach Ollama"
    Open Ollama (Applications on a Mac, the Start menu on Windows) and try
    again. The first translation after opening it takes a minute or more
    while the model loads.

"isn't valid UTF-8"
    Pass --encoding with the file's real encoding. CP1251 for Russian, CP1255
    Hebrew, CP1256 Arabic, GBK or Big5 Chinese, UTF-16 for "Unicode" text
    saved by Windows.

"runs past 6000 bytes with no sentence break"
    The text has a very long line with no punctuation the helper can split
    on (often a table or extraction debris). Break it up, or use
    --engine libre.

Ollama was already installed in an older version
    The installer leaves alone an Ollama it did not install itself. To
    switch to the bundled one: quit Ollama, remove the old one (move the
    app to the Trash on a Mac; Settings > Apps on Windows), and run the
    installer again. Your models are kept.

"Start Translation" says something is NOT answering
    It names which of the three it is and what to do. Most often Docker
    Desktop is showing a window that wants an answer: accept its agreement
    if asked, skip signing in and updating, wait until it says it is
    running, and double-click "Start Translation" again.

"port 5080, which the translation page uses, is already in use"
    Run the installer again with --web-port 5081. The page is then at
    http://127.0.0.1:5081.

The translation page says an engine is "not available"
    For TranslateGemma, open Ollama (Applications on a Mac, the Start menu
    on Windows). For LibreTranslate, open Docker Desktop and see that the
    libretranslate container is running. Then reload the page.

http://127.0.0.1:5050 shows "Not Found"
    Nothing is wrong. LibreTranslate's own page is turned off where the
    translation page is installed; use http://127.0.0.1:5080.

On a Mac

Install.command will not open ("cannot be opened", "unidentified developer",
or nothing happens)
    macOS can refuse a script that reached the Mac by download, email or
    AirDrop rather than on a drive. Use the Terminal way under "Installing
    on a Mac" instead; it does the same thing.

"Ollama is still running and can't be replaced while it is"
    Click the llama in the menu bar, choose Quit Ollama, and run the
    installer again.

"Docker's installer failed"
    The lines above the error are Docker's own. To install it by hand,
    open the docker folder here, double-click Docker.dmg, drag Docker to
    Applications, and open it once. Then run ./install.sh again.

"no space left on device" while loading the image
    Docker keeps images in its own disk, with a size limit separate from
    the Mac's. Raise it in Docker Desktop under Settings > Resources, or
    remove an image you no longer need (docker image ls, then
    docker image rm NAME). Nothing removed can be downloaded again on
    this Mac. Then run ./install.sh again.

"permission denied" when running ./install.sh
    Run   bash install.sh   instead.

On Windows

The window says running scripts is disabled, or closes at once
    Your organisation's settings block PowerShell scripts, and install.cmd
    cannot get past that kind of block. Whoever manages the PC needs to
    allow it.

"Docker Desktop is set to Windows containers"
    Right-click the Docker whale near the clock, choose "Switch to Linux
    containers", wait for Docker to restart, and run install.cmd again.

"docker was not found"
    Docker Desktop is not installed, or was installed after this window was
    opened. Close the window and start again.

"no space left on device" while loading the image
    The drive Docker keeps its images on (usually C:) is full. Free some
    space, or remove an image you no longer need (docker image ls, then
    docker image rm NAME). Nothing removed can be downloaded again on
    this PC. Then run install.cmd again.

TranslateGemma takes minutes for a short text
    The PC has no graphics card the model can use, so it is running on the
    processor alone. It will finish; give long documents an hour or more.
    Or use the smaller model: choose translategemma:4b in the Model list
    on the translation page, or add --model translategemma:4b to the
    helper's command. For a quick first reading there is also
    LibreTranslate (--engine libre).

Russian, Arabic, Hebrew or Chinese shows as boxes or question marks in the
Command Prompt window
    The window cannot draw those letters; the translation itself is fine.
    Translate a file rather than using --text, and open the result in
    Notepad or Word.


REMOVING IT
-----------
On a Mac

    docker rm -f translation-web libretranslate
    docker image rm $(grep '^LT_IMAGE=' ~/translation-tools/bundle.env | cut -d= -f2)

    Move ~/translation-tools/translations somewhere else if you want to
    keep what the page translated. Then move Ollama.app to the Trash and
    delete ~/translation-tools.
    ~/.ollama holds the models. Delete it only if this Mac had no Ollama
    before: it holds every Ollama model on the Mac, not just these.

    If the installer put Docker Desktop on the Mac (its log says so) and
    you want that gone as well, run:

        /Applications/Docker.app/Contents/MacOS/uninstall

    and then move Docker.app to the Trash.

On Windows, in Command Prompt

    docker rm -f translation-web libretranslate
    findstr /b LT_IMAGE= "%USERPROFILE%\translation-tools\bundle.env"
    docker image rm NAME        (NAME is what the line above printed after =)

    Move the translations folder out of translation-tools if you want to
    keep what the page translated. Then uninstall Ollama in Settings >
    Apps, and delete the translation-tools folder in your user folder. The .ollama folder there
    holds the models. Delete it only if this PC had no Ollama before: it
    holds every Ollama model on the PC, not just these.


WHO MADE THIS, AND PASSING IT ON
--------------------------------
This bundle was built with Hoshi, https://github.com/hoyla/hoshi. Hoshi is
the installers, the translation page, the translate helpers and the checks
they make. It is free
software under the GNU Affero General Public License, version 3, which is in
LICENSE.txt.

The translating is done by other people's work, carried here unchanged:

    LibreTranslate    by the LibreTranslate contributors
    Argos Translate   by Argos Open Technologies, with language models
                      trained on text collected by the OPUS project
    Ollama            by Ollama
    TranslateGemma    by Google
    Docker Desktop    by Docker (only if this bundle has a docker folder)
    the test files    by the contributors to Wikipedia

NOTICE.txt gives each one's licence and where its source is. The licences
folder holds the terms that came with each TranslateGemma model and the
credits for every language model.

Hoshi is not officially associated with LibreTranslate or its products, or
with any of the others.

If you give this bundle to someone else:

    - Give them the whole folder, so the notices and licences go with it.
    - TranslateGemma is not open-source software. Google's terms for it are
      in the licences folder and bind whoever uses it. They forbid some
      uses; tell the person you give it to.
    - Docker's agreement does not allow Docker Desktop to be passed on to
      another organisation. If this bundle has a docker folder, don't give
      it to one. Ask whoever built it for a bundle built without Docker
      Desktop; a Mac it goes on then needs Docker Desktop from Docker's
      own site first.
