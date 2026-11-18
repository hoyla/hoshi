# Translate files with the offline engines set up by install.ps1.
#
#   gemma  TranslateGemma via Ollama. Better quality; plain-text files only.
#   libre  LibreTranslate. Keeps document formatting (.docx .pptx .odt .pdf
#          .html .epub .srt ...); quality is good enough for gisting.
#
# The source file is never modified. Each translation is written next to it
# with a .provenance.json sidecar recording the source hash, engine, exact
# model and time. Re-running on an unchanged file with the same engine is a
# no-op; anything else writes a new timestamped file rather than overwriting.
#
# This is the Windows twin of translate.sh: same options, same file names,
# same sidecar, and the same rules for splitting long texts, so a file is cut
# into the same pieces on either kind of machine.
#
# Uses only what ships with Windows 10 and 11 (Windows PowerShell 5.1 and the
# .NET Framework). Run it through translate.cmd, which gets past the default
# policy that blocks scripts.
#
# Kept to ASCII and to PowerShell 5.1 syntax on purpose: 5.1 reads a script
# that has no byte-order mark in the legacy code page, and has no ternary, &&
# or ??. Text is read, sent and written as explicit UTF-8 bytes throughout,
# because 5.1's own defaults (UTF-16 files, Latin-1 web replies) would corrupt
# Russian, Arabic, Hebrew and Chinese.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$VERSION = '3'
$TOOL = "airgapped-translation translate.ps1 v$VERSION"
$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path
$LANGFILE = Join-Path $HERE 'languages.tsv'
$ENVFILE = Join-Path $HERE 'bundle.env'
$ARGV = @($args)
$UTF8 = New-Object System.Text.UTF8Encoding($false)
$UTF8_STRICT = New-Object System.Text.UTF8Encoding($false, $true)
$INVARIANT = [System.Globalization.CultureInfo]::InvariantCulture
$LF = [string][char]10

# So translated text printed by --text reaches the console, or a file it is
# redirected to, as UTF-8. Fails harmlessly when there is no console.
try { [Console]::OutputEncoding = $UTF8 } catch { }
# Code pages such as 1251 are built into Windows PowerShell 5.1 but need
# registering on PowerShell 7, where this type exists.
try { [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance) } catch { }

$script:Died = $false
function Die([string]$Message) { $script:Died = $true; throw $Message }
function Info([string]$Message) { [Console]::Error.WriteLine($Message) }

function Get-Cfg([string]$Key) {
  $value = ''
  if ([System.IO.File]::Exists($ENVFILE)) {
    foreach ($line in [System.IO.File]::ReadAllLines($ENVFILE)) {
      if ($line.StartsWith("$Key=")) { $value = $line.Substring($Key.Length + 1).Trim() }
    }
  }
  return $value
}

function Get-Prop($Object, [string]$Name) {
  if ($null -eq $Object) { return $null }
  $prop = $Object.PSObject.Properties[$Name]
  if ($null -eq $prop) { return $null }
  return $prop.Value
}

$LT_URL = $env:LT_URL
if (-not $LT_URL) { $LT_URL = Get-Cfg 'LT_URL' }
if (-not $LT_URL) { $LT_URL = 'http://127.0.0.1:5050' }
$LT_CONTAINER = $env:LT_CONTAINER
if (-not $LT_CONTAINER) { $LT_CONTAINER = Get-Cfg 'LT_CONTAINER' }
if (-not $LT_CONTAINER) { $LT_CONTAINER = 'libretranslate' }
if (-not $env:OLLAMA_HOST) { $OLLAMA_API = 'http://127.0.0.1:11434' }
elseif ($env:OLLAMA_HOST -match '^https?://') { $OLLAMA_API = $env:OLLAMA_HOST }
else { $OLLAMA_API = "http://$($env:OLLAMA_HOST)" }
$MODEL = Get-Cfg 'DEFAULT_MODEL'
if (-not $MODEL) { $MODEL = 'translategemma:12b' }

# TranslateGemma was trained on inputs of up to about 2K tokens, so long texts
# go through in pieces. Sizes are in UTF-8 bytes, as in translate.sh: a piece
# closes at the first paragraph break after SOFT and is never allowed past HARD.
$SOFT = 3000
$HARD = 6000
$NUM_CTX = 8192

function Show-Usage {
  @"
Usage:
  translate.cmd --to CODE [--from CODE] [options] FILE...
  translate.cmd --to CODE [--from CODE] [--engine E] --text "words to translate"
  translate.cmd --languages

Options:
  --to CODE        Target language code, e.g. en
  --from CODE      Source language code, e.g. ru, fr, zh, he, ar.
                   Optional: LibreTranslate detects it when omitted.
  --engine NAME    gemma or libre. Default: gemma for .txt/.md, libre otherwise.
  --model NAME     Ollama model for the gemma engine (default: $MODEL)
  --out DIR        Write translations here instead of next to each source file
  --encoding NAME  Source text encoding if not UTF-8, e.g. CP1251 (Russian),
                   CP1255 (Hebrew), CP1256 (Arabic), GBK or Big5 (Chinese), UTF-16
  --force          Translate again even if an identical run already exists
                   (writes a new timestamped file)
  --languages      List the language codes the gemma engine knows
  -h, --help       Show this help

Examples:
  translate.cmd --from ru --to en statement.txt
  translate.cmd --to en contract.docx
  translate.cmd --from ar --to en --engine libre --text "..."
"@
}

# The body of a JSON string. Mirrors json_escape in translate.sh: carriage
# returns are dropped, other control characters become spaces, and one final
# newline is not carried over.
function ConvertTo-JsonBody([string]$Text) {
  $s = $Text.Replace([string][char]13, '')
  if ($s.EndsWith($LF)) { $s = $s.Substring(0, $s.Length - 1) }
  $s = [regex]::Replace($s, '[\x00-\x08\x0B\x0C\x0E-\x1F]', ' ')
  return $s.Replace('\', '\\').Replace('"', '\"').Replace([string][char]9, '\t').Replace($LF, '\n')
}

function Get-ByteCount([string]$Text) { return $UTF8.GetByteCount($Text) }

function Get-FullPath([string]$Path) {
  # relative to PowerShell's current folder, with no wildcard expansion
  return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Get-Sha256([string]$Path) {
  return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-UtcStamp([string]$Format) { return [DateTime]::UtcNow.ToString($Format, $INVARIANT) }

function Reserve-Output([string]$Directory, [string]$Base, [string]$Suffix) {
  $stamp = Get-UtcStamp "yyyyMMdd'T'HHmmss'Z'"
  $serial = 0
  while ($true) {
    $tail = ''
    if ($serial -gt 0) { $tail = ".$stamp" }
    if ($serial -gt 1) { $tail += "-$serial" }
    $path = Join-Path $Directory "$Base$tail$Suffix"
    $lock = "$path.lock"
    $stream = $null
    try { $stream = [System.IO.File]::Open($lock, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None) }
    catch [System.IO.IOException] {
      if (-not (Test-Path -LiteralPath $lock)) { throw }
    }
    if ($null -ne $stream) {
      if (-not (Test-Path -LiteralPath $path) -and -not (Test-Path -LiteralPath "$path.provenance.json")) {
        return @{ Path = $path; Lock = $lock; Stream = $stream }
      }
      $stream.Dispose()
      [System.IO.File]::Delete($lock)
    }
    $serial++
  }
}

function Publish-New([string]$Source, [string]$Destination) {
  # CreateNew also works on exFAT and refuses an existing destination.
  $dest = [System.IO.File]::Open($Destination, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
  try {
    $src = [System.IO.File]::OpenRead($Source)
    try { $src.CopyTo($dest); $dest.Flush() } finally { $src.Dispose() }
  } catch {
    $dest.Dispose()
    [System.IO.File]::Delete($Destination)
    throw
  } finally { $dest.Dispose() }
}

function Get-NamedEncoding([string]$Name) { # $null if the name isn't known
  $n = $Name.Trim()
  $ef = [System.Text.EncoderFallback]::ExceptionFallback
  $df = [System.Text.DecoderFallback]::ExceptionFallback
  try {
    # CP1251 and friends are the names translate.sh takes; .NET wants the number
    if ($n -match '^(?:cp|windows-?|ibm)(\d{3,5})$') { return [System.Text.Encoding]::GetEncoding([int]$Matches[1], $ef, $df) }
    return [System.Text.Encoding]::GetEncoding($n, $ef, $df)
  } catch { return $null }
}

# File bytes -> text. $null if the bytes aren't valid in that encoding.
function ConvertFrom-Bytes([byte[]]$Bytes, [System.Text.Encoding]$Encoding) {
  $enc = $Encoding
  # "UTF-16" from Windows is little-endian, but honour a big-endian byte-order mark
  if ($enc.CodePage -eq 1200 -and $Bytes.Length -ge 2 -and $Bytes[0] -eq 0xFE -and $Bytes[1] -eq 0xFF) {
    $enc = [System.Text.Encoding]::GetEncoding(1201, [System.Text.EncoderFallback]::ExceptionFallback, [System.Text.DecoderFallback]::ExceptionFallback)
  }
  try { return $enc.GetString($Bytes) } catch { return $null }
}

# The text as both engines get it: no byte-order mark, no carriage returns.
function ConvertTo-CleanText([string]$Text) {
  $s = $Text
  if ($s.Length -gt 0 -and $s[0] -eq [char]0xFEFF) { $s = $s.Substring(1) }
  return $s.Replace([string][char]13, '')
}

function Get-LangName([string]$Code) { # $null if the code isn't in languages.tsv
  foreach ($line in [System.IO.File]::ReadAllLines($LANGFILE, $UTF8)) {
    $cols = $line.Split([char]9)
    if ($cols.Length -ge 2 -and $cols[0] -ceq $Code) { return $cols[1] }
  }
  return $null
}

# Without leading/trailing blank lines, trailing spaces on the last line, or a
# final newline.
function Remove-BlankEdges([string]$Text) {
  $lines = $Text.Split([char]10)
  $s = 0
  $e = $lines.Length - 1
  while ($s -le $e -and $lines[$s] -match '^[ \t]*$') { $s++ }
  while ($e -ge $s -and $lines[$e] -match '^[ \t]*$') { $e-- }
  if ($e -lt $s) { return '' }
  $lines[$e] = [regex]::Replace($lines[$e], '[ \t]+$', '')
  return [string]::Join($LF, $lines, $s, $e - $s + 1)
}

# Number of blank-line-separated paragraphs.
function Get-ParaCount([string]$Text) {
  $t = $Text.Trim([char]10)
  if ($t.Length -eq 0) { return 0 }
  return [regex]::Split($t, '\n{2,}').Length
}

# Number of lines that have something on them.
function Get-LineCount([string]$Text) {
  return [regex]::Matches($Text, '(?m)^.*\S.*$').Count
}

$script:Warnings = New-Object System.Collections.ArrayList
function Add-Warning([string]$Message) {
  Info "warning: $Message"
  [void]$script:Warnings.Add($Message)
}

# ---------------------------------------------------------- dropped-text check
# Compare a source text with its translation, unit by unit, and report units
# whose translation is much shorter or longer than expected. A translation
# engine can drop a sentence, or repeat or invent one, and still read fluently.
#
# This is check.pl from translate.sh, statement for statement: the method and
# what it cannot see are described there, and the numbers come from
# calibration/ in the repository this script is from. calibration/windows.sh
# there runs the two on the same texts and compares every number.
#
# One difference. .NET sees a character beyond the Basic Multilingual Plane as
# two halves and gives neither a category, so those in planes 2 and 3 (rare
# Chinese characters) are counted here as Han, and any others (historic
# scripts, mathematical letters) are not counted at all.
$CHECK_MIN_UNIT = 60     # units smaller than this (weighted letters) are not judged
$CHECK_CAL_MIN = 400     # other text needed before a short document calibrates itself
$CHECK_D_BIG = 0.35      # shortfall reported whatever the sentence counts say
$CHECK_D_MIN = 0.12      # smallest shortfall reported when a sentence is missing
$CHECK_K = 0.50          # ... and it must be this share of the missing sentences' size
$CHECK_LONG = 2.00       # times the expected size: reported as too long
$CHECK_D_WHOLE = 0.25    # shortfall of the whole translation against the language pair
$CHECK_SLACK = @{ self = 0.0; pair = 0.05; script = 0.15 }   # added to the shortfalls above
$CHECK_MAX_WARN = 10

# Letters of these scripts count for more than a Latin letter. .NET knows
# Unicode blocks, not scripts, so the characters are listed.
$CHECK_SCRIPTS = @{
  # generated by calibration/script-ranges.pl with perl 5.34.1 (Unicode 13.0.0)
  Han    = '\u3005-\u3007\u3021-\u3029\u3038-\u303C\u3192-\u3195\u3220-\u3229\u3280-\u3289\u3400-\u4DBF\u4E00-\u9FFC\uF900-\uFA6D\uFA70-\uFAD9'
  Kana   = '\u3031-\u3035\u303C\u3041-\u3096\u309D-\u309F\u30A1-\u30FA\u30FC-\u30FF\u31F0-\u31FF\uFF66-\uFF9F'
  Hangul = '\u1100-\u11FF\u3131-\u318E\uA960-\uA97C\uAC00-\uD7A3\uD7B0-\uD7C6\uD7CB-\uD7FB\uFFA0-\uFFBE\uFFC2-\uFFC7\uFFCA-\uFFCF\uFFD2-\uFFD7\uFFDA-\uFFDC'
  Hebrew = '\u05D0-\u05EA\u05EF-\u05F2\uFB1D\uFB1F-\uFB28\uFB2A-\uFB36\uFB38-\uFB3C\uFB3E\uFB40-\uFB41\uFB43-\uFB44\uFB46-\uFB4F'
  Arabic = '\u0620-\u064A\u066E-\u066F\u0671-\u06D3\u06D5\u06E5-\u06E6\u06EE-\u06EF\u06FA-\u06FC\u06FF\u0750-\u077F\u08A0-\u08B4\u08B6-\u08C7\uFB50-\uFBB1\uFBD3-\uFD3D\uFD50-\uFD8F\uFD92-\uFDC7\uFDF0-\uFDFB\uFE70-\uFE74\uFE76-\uFEFC'
  Indic  = '\u0904-\u0939\u093D\u0950\u0958-\u0961\u0971-\u0980\u0985-\u098C\u098F-\u0990\u0993-\u09A8\u09AA-\u09B0\u09B2\u09B6-\u09B9\u09BD\u09CE\u09DC-\u09DD\u09DF-\u09E1\u09F0-\u09F1\u09FC\u0A05-\u0A0A\u0A0F-\u0A10\u0A13-\u0A28\u0A2A-\u0A30\u0A32-\u0A33\u0A35-\u0A36\u0A38-\u0A39\u0A59-\u0A5C\u0A5E\u0A72-\u0A74\u0A85-\u0A8D\u0A8F-\u0A91\u0A93-\u0AA8\u0AAA-\u0AB0\u0AB2-\u0AB3\u0AB5-\u0AB9\u0ABD\u0AD0\u0AE0-\u0AE1\u0AF9\u0B83\u0B85-\u0B8A\u0B8E-\u0B90\u0B92-\u0B95\u0B99-\u0B9A\u0B9C\u0B9E-\u0B9F\u0BA3-\u0BA4\u0BA8-\u0BAA\u0BAE-\u0BB9\u0BD0\u0C05-\u0C0C\u0C0E-\u0C10\u0C12-\u0C28\u0C2A-\u0C39\u0C3D\u0C58-\u0C5A\u0C60-\u0C61\u0C80\u0C85-\u0C8C\u0C8E-\u0C90\u0C92-\u0CA8\u0CAA-\u0CB3\u0CB5-\u0CB9\u0CBD\u0CDE\u0CE0-\u0CE1\u0CF1-\u0CF2\u0D04-\u0D0C\u0D0E-\u0D10\u0D12-\u0D3A\u0D3D\u0D4E\u0D54-\u0D56\u0D5F-\u0D61\u0D7A-\u0D7F\u0D85-\u0D96\u0D9A-\u0DB1\u0DB3-\u0DBB\u0DBD\u0DC0-\u0DC6\u1CE9-\u1CEC\u1CEE-\u1CF3\u1CF5-\u1CF6\uA8F2-\uA8F7\uA8FB\uA8FD-\uA8FE'
  # end of generated
}
$CHECK_CLASSES = @(
  ([regex]('(?=[\p{L}\p{N}])[' + $CHECK_SCRIPTS['Han'] + ']')),
  ([regex]('(?=\p{L})[' + $CHECK_SCRIPTS['Kana'] + ']')),
  ([regex]('(?=\p{L})[' + $CHECK_SCRIPTS['Hangul'] + ']')),
  ([regex]('(?=\p{L})[' + $CHECK_SCRIPTS['Hebrew'] + ']')),
  ([regex]('(?=\p{L})[' + $CHECK_SCRIPTS['Arabic'] + ']')),
  ([regex]('(?=\p{L})[' + $CHECK_SCRIPTS['Indic'] + ']'))
)
$CHECK_WEIGHTS = @(2.6, 1.3, 1.95, 1.3, 1.1, 1.5)
$CHECK_LETTER = [regex]'[\p{L}\p{N}]'
$CHECK_PLANE_2_3 = [regex]'[\uD840-\uD8BF][\uDC00-\uDFFF]'

# Weighted size of the same content in each language, relative to English.
$CHECK_SIZE = @{
  en = 1.00; ar = 0.91; de = 1.20; el = 1.18; es = 1.12; fa = 0.99
  fr = 1.20; he = 0.95; hi = 0.94; ja = 0.91; ko = 0.94; ru = 1.16
  th = 0.91; tr = 1.14; uk = 1.12; vi = 1.08; zh = 0.94
}

# Sentence ends: . ! ? and ellipsis before a space or the end, the Arabic
# question mark, Urdu and Armenian full stops, the Devanagari danda, the
# Ethiopic full stop, and the CJK full stop, ! and ? (which need no space).
$CHECK_SENTENCE = [regex]'(?:[.!?\u2026]+|[\u061F\u06D4\u0589\u0964\u1362])(?=["''\u201D\u2019\u00BB\)\]]*(?:\s|\z))|[\u3002\uFF01\uFF1F]+'
$CHECK_CLOSED = [regex]'[.!?:;\u2026\u3002\uFF01\uFF1F\u061F\u06D4\u0964]["''\u201D\u2019\u00BB\)\]]*\s*\z'
$CHECK_INK = [regex]'\S'

function Get-WeightedLength([string]$Text) {
  $beyond = $CHECK_PLANE_2_3.Matches($Text).Count
  $w = [double]($CHECK_LETTER.Matches($Text).Count + $beyond)
  for ($c = 0; $c -lt $CHECK_CLASSES.Length; $c++) {
    $n = $CHECK_CLASSES[$c].Matches($Text).Count
    if ($c -eq 0) { $n += $beyond }
    $w += $n * ($CHECK_WEIGHTS[$c] - 1)
  }
  return $w
}

function Get-Counted([int]$Number, [string]$Word) {
  if ($Number -eq 1) { return "$Number $Word" }
  return "$Number ${Word}s"
}

# A number to so many decimal places, rounded by arithmetic as check.pl does it.
function Get-Fixed([double]$Number, [int]$Places) {
  $m = [Math]::Pow(10, $Places)
  return ([Math]::Truncate($Number * $m + 0.5) / $m).ToString("F$Places", $INVARIANT)
}

# The blank-line-separated blocks of a text, or its lines with something on
# them, and the line each starts on.
function Get-CheckUnits([string]$Text, [bool]$Blocks) {
  $texts = New-Object System.Collections.Generic.List[string]
  $starts = New-Object System.Collections.Generic.List[int]
  $buf = New-Object System.Text.StringBuilder
  $start = 0
  $n = 0
  foreach ($line in $Text.Split([char]10)) {
    $n++
    if ($CHECK_INK.IsMatch($line)) {
      if (-not $Blocks) { $texts.Add($line); $starts.Add($n) }
      else {
        if ($buf.Length -eq 0) { $start = $n }
        [void]$buf.Append($line).Append($LF)
      }
    } elseif ($buf.Length -gt 0) {
      $texts.Add($buf.ToString()); $starts.Add($start)
      [void]$buf.Clear()
    }
  }
  if ($buf.Length -gt 0) { $texts.Add($buf.ToString()); $starts.Add($start) }
  return @{ Text = $texts; Start = $starts }
}

# Text wrapped at a fixed width: most lines inside a block stop mid-sentence.
function Test-HardWrapped($Blocks) {
  $inside = 0
  $open = 0
  foreach ($block in $Blocks) {
    $last = $null
    foreach ($line in $block.Split([char]10)) {
      if (-not $CHECK_INK.IsMatch($line)) { continue }
      if ($null -ne $last) {
        $inside++
        if (-not $CHECK_CLOSED.IsMatch($last)) { $open++ }
      }
      $last = $line
    }
  }
  return ($inside -ge 3 -and $open / $inside -ge 0.6)
}

# Returns Status (the line for the record), Warnings, and when asked the
# numbers behind each unit as check.pl --stats prints them.
function Compare-Translation([string]$Source, [string]$Translation, [string]$From, [string]$To, [string]$UnitName, [bool]$NoStruct, [bool]$WithStats) {
  $warn = New-Object System.Collections.Generic.List[string]
  $numbers = New-Object System.Collections.Generic.List[string]
  # PowerShell names ignore case, so a local can't share a parameter's name
  $fromCode = [regex]::Replace($From.ToLowerInvariant(), '[-_].*', '')
  $toCode = [regex]::Replace($To.ToLowerInvariant(), '[-_].*', '')
  $theirs = [regex]::Replace($Source, '\r\n?', $LF)
  if ($theirs.Length -gt 0 -and $theirs[0] -eq [char]0xFEFF) { $theirs = $theirs.Substring(1) }
  $ours = [regex]::Replace($Translation, '\r\n?', $LF)
  if ($ours.Length -gt 0 -and $ours[0] -eq [char]0xFEFF) { $ours = $ours.Substring(1) }

  $sp = Get-CheckUnits $theirs $true
  $op = Get-CheckUnits $ours $true
  $sl = Get-CheckUnits $theirs $false
  $ol = Get-CheckUnits $ours $false
  $nsp = $sp.Text.Count; $nop = $op.Text.Count; $nsl = $sl.Text.Count; $nol = $ol.Text.Count

  # The finest units both texts agree on: lines, unless the text is wrapped at a
  # fixed width, then blank-line-separated paragraphs, then the text as a whole.
  if ($nsl -ge 2 -and $nsl -eq $nol -and $nsl -gt $nsp -and -not (Test-HardWrapped $sp.Text)) { $su = $sl; $ou = $ol; $kind = 'line' }
  elseif ($nsp -eq $nop -and $nsp -ge 1) { $su = $sp; $ou = $op; $kind = 'paragraph' }
  elseif ($nsl -ge 2 -and $nsl -eq $nol) { $su = $sl; $ou = $ol; $kind = 'line' }
  else {
    $su = @{ Text = @($theirs); Start = @(1) }
    $ou = @{ Text = @($ours); Start = @(1) }
    $kind = 'whole'
  }
  $units = $su.Text.Count

  if ($kind -eq 'whole' -and -not $NoStruct -and $nsp -gt 0 -and $nop -gt 0) {
    $warn.Add("the source has $(Get-Counted $nsp 'paragraph') and the translation has $nop, so they could only be compared as a whole; check for missing or merged text")
  }

  $label = $kind
  if ($UnitName) { $label = $UnitName }
  $sw = New-Object double[] $units; $ow = New-Object double[] $units
  $ss = New-Object int[] $units; $os = New-Object int[] $units
  $tsw = 0.0; $tow = 0.0; $tss = 0; $tos = 0
  for ($i = 0; $i -lt $units; $i++) {
    $sw[$i] = Get-WeightedLength $su.Text[$i]; $ow[$i] = Get-WeightedLength $ou.Text[$i]
    $ss[$i] = $CHECK_SENTENCE.Matches($su.Text[$i]).Count; $os[$i] = $CHECK_SENTENCE.Matches($ou.Text[$i]).Count
    $tsw += $sw[$i]; $tow += $ow[$i]; $tss += $ss[$i]; $tos += $os[$i]
  }
  # Sentence counts mean nothing if the translation barely marks sentence ends
  # (Thai does not), which shows over a document.
  $sentOk = -not ($tss -ge 8 -and $tos -lt 0.25 * $tss)
  $pair = 0.0
  if ($CHECK_SIZE.ContainsKey($fromCode) -and $CHECK_SIZE.ContainsKey($toCode)) { $pair = $CHECK_SIZE[$toCode] / $CHECK_SIZE[$fromCode] }

  # With five or more units of a fair size, the document's own typical ratio is
  # their median, which a few gutted units cannot drag down.
  $ratios = New-Object System.Collections.Generic.List[double]
  for ($i = 0; $i -lt $units; $i++) { if ($sw[$i] -ge $CHECK_MIN_UNIT) { $ratios.Add($ow[$i] / $sw[$i]) } }
  $ratios.Sort()
  $median = 0.0
  if ($ratios.Count -ge 5) { $median = $ratios[[int][Math]::Floor($ratios.Count / 2)] }

  # The whole translation against what is usual for the language pair. A
  # document that calibrates itself hides an engine trimming every unit alike,
  # so this is for those; shorter texts are held to the pair unit by unit below.
  if ($pair -gt 0 -and $median -gt 0) {
    $rel = ($tow / $tsw) / $pair
    if ($rel -le 1 - $CHECK_D_WHOLE) {
      $warn.Add("the translation as a whole is $([int][Math]::Truncate((1 - $rel) * 100 + 0.5))% shorter than is usual from $fromCode to $toCode; check for dropped text")
    }
  }

  $judged = 0
  $flagged = 0
  for ($i = 0; $i -lt $units; $i++) {
    $s = $sw[$i]; $o = $ow[$i]
    $restS = $tsw - $s; $restO = $tow - $o
    if ($median -gt 0) { $mode = 'self'; $expect = $median }
    elseif ($restS -ge $CHECK_CAL_MIN -and $restO -gt 0) { $mode = 'self'; $expect = $restO / $restS }
    elseif ($pair -gt 0) { $mode = 'pair'; $expect = $pair }
    else { $mode = 'script'; $expect = 1.0 }
    $rel = 1.0
    if ($s -gt 0) { $rel = ($o / $s) / $expect }
    $deficit = 1 - $rel
    $lost = 0
    if ($sentOk -and $os[$i] -lt $ss[$i]) { $lost = $ss[$i] - $os[$i] }
    if ($WithStats) {
      $ratio = 0.0
      if ($s -gt 0) { $ratio = $o / $s }
      $sentFlag = 0
      if ($sentOk) { $sentFlag = 1 }
      $numbers.Add((@('STAT', $kind, ($i + 1), $s.ToString('G15', $INVARIANT), $o.ToString('G15', $INVARIANT),
        (Get-Fixed $ratio 3), (Get-Fixed $expect 3), (Get-Fixed $rel 3),
        $ss[$i], $os[$i], $mode, $sentFlag) -join [string][char]9))
    }
    if ($s -lt $CHECK_MIN_UNIT) { continue }
    $judged++
    $slack = $CHECK_SLACK[$mode]
    $had = $ss[$i]
    if ($had -eq 0) { $had = 1 }
    $need = $CHECK_K * $lost / $had
    if ($need -lt $CHECK_D_MIN) { $need = $CHECK_D_MIN }
    $what = ''
    if ($deficit -ge $CHECK_D_BIG + $slack -or ($lost -gt 0 -and $deficit -ge $need + $slack)) {
      $what = "the translation is $([int][Math]::Truncate($deficit * 100 + 0.5))% shorter than expected"
      if ($lost -gt 0) { $what += " and has $(Get-Counted $os[$i] 'sentence') against $($ss[$i]) in the source" }
      $what += '; check for dropped text'
    } elseif ($rel -ge $CHECK_LONG * (1 + 2 * $slack)) {
      $what = "the translation is $(Get-Fixed $rel 1) times as long as expected; check for repeated or added text"
    }
    if (-not $what) { continue }
    $flagged++
    if ($flagged -gt $CHECK_MAX_WARN) { continue }
    # the first 40 characters, counting one beyond the BMP as one, as perl does
    $snip = [regex]::Replace($su.Text[$i], '\s+', ' ').Trim(' ')
    $at = 0
    for ($taken = 0; $taken -lt 40 -and $at -lt $snip.Length; $taken++) {
      if ([char]::IsHighSurrogate($snip[$at]) -and $at + 1 -lt $snip.Length) { $at += 2 } else { $at++ }
    }
    if ($at -lt $snip.Length) { $snip = $snip.Substring(0, $at) + [char]0x2026 }
    # a plain-text line is named by its line number; anything else by its place in order
    if ($kind -eq 'whole') { $where = 'the text' }
    elseif ($kind -eq 'line' -and -not $UnitName) { $where = "$label $($su.Start[$i])" }
    else { $where = "$label $($i + 1)" }
    $warn.Add("$where (starts `"$snip`"): $what")
  }
  if ($flagged -gt $CHECK_MAX_WARN) { $warn.Add("$(Get-Counted ($flagged - $CHECK_MAX_WARN) "more $label") look too short or too long") }

  if ($judged -eq 0) { $status = 'not checked: too little text to judge' }
  elseif ($kind -eq 'whole') { $status = 'compared the text as a whole' }
  else {
    $status = "compared $(Get-Counted $judged $label)"
    if ($units -gt $judged) { $status += ", $($units - $judged) more too short to judge" }
  }
  return @{ Status = $status; Warnings = $warn; Stats = $numbers }
}
# --------------------------------------------------- end of dropped-text check

$W_NS = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main'
$MC_NS = 'http://schemas.openxmlformats.org/markup-compatibility/2006'

# The main text of a Word file, one paragraph to a line with nothing blank,
# for the check. Throws if the file can't be read as one.
function Get-DocxText([string]$Path) {
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $doc = New-Object System.Xml.XmlDocument
  $doc.PreserveWhitespace = $true
  $zip = [System.IO.Compression.ZipFile]::OpenRead($Path)
  try {
    $entry = $zip.GetEntry('word/document.xml')
    if ($null -eq $entry) { throw 'not a Word document' }
    if ($entry.Length -gt 256MB) { throw 'too large to open' }
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $stream = $entry.Open()
    try {
      $reader = [System.Xml.XmlReader]::Create($stream, $settings)
      $doc.Load($reader)
    } finally {
      $stream.Dispose()
    }
  } finally {
    $zip.Dispose()
  }
  $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
  $ns.AddNamespace('w', $W_NS)
  $ns.AddNamespace('mc', $MC_NS)
  $lines = New-Object System.Collections.Generic.List[string]
  # A text box sits inside a paragraph and holds paragraphs of its own, and
  # Word stores a second, older copy of each one under mc:Fallback.
  foreach ($para in $doc.SelectNodes('//w:p[not(ancestor::mc:Fallback)]', $ns)) {
    $words = New-Object System.Text.StringBuilder
    foreach ($node in $para.SelectNodes('.//w:t | .//w:tab | .//w:br | .//w:cr | .//w:noBreakHyphen', $ns)) {
      $skip = $false
      for ($up = $node.ParentNode; $null -ne $up -and -not [object]::ReferenceEquals($up, $para); $up = $up.ParentNode) {
        if (($up.NamespaceURI -ceq $W_NS -and $up.LocalName -ceq 'p') -or ($up.NamespaceURI -ceq $MC_NS -and $up.LocalName -ceq 'Fallback')) { $skip = $true; break }
      }
      if ($skip) { continue }
      if ($node.LocalName -ceq 't') { [void]$words.Append($node.InnerText) }
      elseif ($node.LocalName -ceq 'tab') { [void]$words.Append([char]9) }
      elseif ($node.LocalName -ceq 'noBreakHyphen') { [void]$words.Append('-') }
      else { [void]$words.Append($LF) }
    }
    foreach ($line in $words.ToString().Replace([string][char]13, '').Split([char]10)) {
      $line = $line.Trim([char[]]@(32, 9))
      if ($line.Length -gt 0) { $lines.Add($line) }
    }
  }
  return ([string]::Join($LF, $lines) + $LF)
}

# Runs the check on a text and its translation, adds what it finds to the
# warnings, and returns the line that goes in the record.
function Test-DroppedText([string]$Source, [string]$Translation, [string]$To, [string]$UnitName, [bool]$NoStruct) {
  $from = $script:From   # empty when LibreTranslate was left to detect the language itself
  if (-not $from) { $from = '' }
  try {
    $found = Compare-Translation $Source $Translation $from $To $UnitName $NoStruct $false
  } catch {
    return 'not checked: the comparison itself failed'
  }
  foreach ($message in $found.Warnings) { Add-Warning $message }
  return $found.Status
}

# ----------------------------------------------------------------------- http
Add-Type -AssemblyName System.Net.Http
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.UseProxy = $false # both services are on this machine
$HTTP = New-Object System.Net.Http.HttpClient($handler)
$HTTP.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan # each call sets its own

# Returns @{ Code; Bytes }, or $null if the server couldn't be reached in time.
function Invoke-Http([string]$Method, [string]$Url, $Content, [int]$TimeoutSec) {
  $request = New-Object System.Net.Http.HttpRequestMessage((New-Object System.Net.Http.HttpMethod($Method)), $Url)
  if ($null -ne $Content) { $request.Content = $Content }
  $cancel = New-Object System.Threading.CancellationTokenSource
  $cancel.CancelAfter([TimeSpan]::FromSeconds($TimeoutSec))
  try {
    $response = $HTTP.SendAsync($request, $cancel.Token).GetAwaiter().GetResult()
    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    return @{ Code = [int]$response.StatusCode; Bytes = $bytes }
  } catch {
    return $null
  } finally {
    $cancel.Dispose()
    $request.Dispose()
  }
}

function New-JsonContent([string]$Json) {
  $content = New-Object System.Net.Http.ByteArrayContent -ArgumentList (, $UTF8.GetBytes($Json))
  $content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/json')
  return $content
}

function ConvertFrom-JsonBytes([byte[]]$Bytes) { # $null if it isn't JSON
  try { return ($UTF8.GetString($Bytes) | ConvertFrom-Json) } catch { return $null }
}

# The server's own error message if the reply has one, else the raw reply.
function Get-ErrorText($Reply) {
  $message = Get-Prop (ConvertFrom-JsonBytes $Reply.Bytes) 'error'
  if ($message) { return [string]$message }
  return $UTF8.GetString($Reply.Bytes)
}

# ------------------------------------------------------------ language detect
$script:From = ''
$script:Detected = $false
$script:DetectConfidence = ''
function Find-Language([string]$Text) { # sets $script:From
  $sample = $Text
  if ($sample.Length -gt 1500) {
    $sample = $sample.Substring(0, 1500)
    if ([char]::IsHighSurrogate($sample[1499])) { $sample = $sample.Substring(0, 1499) }
  }
  $reply = Invoke-Http 'POST' "$LT_URL/detect" (New-JsonContent ('{"q": "' + (ConvertTo-JsonBody $sample) + '"}')) 120
  if ($null -eq $reply -or $reply.Code -ne 200) {
    Die "no --from given, and LibreTranslate isn't reachable at $LT_URL to detect the language"
  }
  $first = @(ConvertFrom-JsonBytes $reply.Bytes)[0]
  $language = Get-Prop $first 'language'
  if (-not $language) { Die "couldn't detect the source language; pass --from" }
  $script:From = [string]$language
  $confidence = Get-Prop $first 'confidence'
  # six decimals, as translate.sh records it
  if ($null -ne $confidence) { $script:DetectConfidence = ([double]$confidence).ToString('F6', $INVARIANT) }
  $script:Detected = $true
  $shown = $script:DetectConfidence
  if (-not $shown) { $shown = '?' }
  Info "    detected source language: $($script:From) (confidence $shown)"
}

# --------------------------------------------------------------- gemma engine
# ASCII sentence punctuation, then CJK full stop / ! / ? / ;, Arabic ?, Urdu full stop
$SENTENCE_END = New-Object System.Text.RegularExpressions.Regex('[.!?;]["'')]*[ \t]+|\u3002|\uFF01|\uFF1F|\uFF1B|\u061F[ \t]*|\u06D4[ \t]*')

# Split text into pieces of roughly SOFT bytes, breaking at paragraph breaks
# where possible, then line breaks, then sentence ends inside an over-long
# line. Each piece comes with what separated it from the next (para, line,
# sent or end) so the translation can be stitched back together in the same
# shape. A line-for-line port of the awk chunker in translate.sh.
function Split-Text([string]$Text) {
  $pieces = New-Object System.Collections.ArrayList
  $buf = New-Object System.Text.StringBuilder
  $size = 0
  $blank = $false
  $lines = $Text.Split([char]10)
  $count = $lines.Length
  if ($count -gt 0 -and $lines[$count - 1].Length -eq 0) { $count-- } # the final newline doesn't start a line

  for ($n = 0; $n -lt $count; $n++) {
    $line = $lines[$n]
    if ($line -match '^[ \t]*$') {
      if ($buf.Length -gt 0) { $blank = $true }
      if ($blank -and $size -ge $SOFT) {
        [void]$pieces.Add(@{ Text = $buf.ToString(); Join = 'para' }); [void]$buf.Clear(); $size = 0
        $blank = $false
      }
      continue
    }
    $len = Get-ByteCount $line
    $join = 'line'
    if ($blank) { $join = 'para' }

    if ($len -gt $HARD) {
      if ($buf.Length -gt 0) { [void]$pieces.Add(@{ Text = $buf.ToString(); Join = $join }); [void]$buf.Clear(); $size = 0 }
      $blank = $false
      $rest = $line
      while ((Get-ByteCount $rest) -gt $SOFT) {
        $cut = 0; $cutChars = 0; $pos = 0; $posChars = 0
        while ($true) {
          $m = $SENTENCE_END.Match($rest, $posChars)
          if (-not $m.Success) { break }
          $endChars = $m.Index + $m.Length
          $e = $pos + (Get-ByteCount $rest.Substring($posChars, $endChars - $posChars))
          if ($e -gt $HARD) { break }
          $cut = $e; $cutChars = $endChars
          if ($cut -ge $SOFT) { break }
          $pos = $e; $posChars = $endChars
        }
        if ($cut -eq 0) {
          if ((Get-ByteCount $rest) -le $HARD) { break }
          Die "line $($n + 1) of the text runs past $HARD bytes with no sentence break, too long to translate in one piece. Re-wrap it, or use --engine libre."
        }
        if ($cutChars -ge $rest.Length) { break }
        [void]$pieces.Add(@{ Text = $rest.Substring(0, $cutChars); Join = 'sent' })
        $rest = $rest.Substring($cutChars)
      }
      [void]$buf.Append($rest).Append($LF)
      $size = (Get-ByteCount $rest) + 1
      continue
    }

    if ($size -gt 0 -and $size + $len + 1 -gt $HARD) {
      [void]$pieces.Add(@{ Text = $buf.ToString(); Join = $join }); [void]$buf.Clear(); $size = 0
      $blank = $false
    }
    if ($blank) { [void]$buf.Append($LF); $size++; $blank = $false }
    [void]$buf.Append($line).Append($LF)
    $size += $len + 1
  }
  if ($buf.Length -gt 0) { [void]$pieces.Add(@{ Text = $buf.ToString(); Join = 'end' }) }
  return $pieces
}

$script:EngineDigest = ''
$script:EngineDetail = ''
function Set-GemmaDigest { # sets EngineDigest for $MODEL, or dies if it isn't installed
  $reply = Invoke-Http 'GET' "$OLLAMA_API/api/tags" $null 30
  if ($null -eq $reply -or $reply.Code -ne 200) { Die "couldn't reach Ollama at $OLLAMA_API. Is the Ollama app open?" }
  foreach ($m in @(Get-Prop (ConvertFrom-JsonBytes $reply.Bytes) 'models')) {
    if ((Get-Prop $m 'name') -ceq $MODEL) {
      $script:EngineDigest = 'sha256:' + (Get-Prop $m 'digest')
      return
    }
  }
  Die "the model '$MODEL' isn't installed in Ollama"
}

$script:Chunks = 0
function Invoke-Gemma([string]$Text, [string]$To) { # returns the translation; uses $script:From, $MODEL
  $from = $script:From
  $fromName = Get-LangName $from
  if (-not $fromName) { Die "unknown source language code '$from' (see --languages)" }
  $toName = Get-LangName $To
  if (-not $toName) { Die "unknown target language code '$To' (see --languages)" }

  $pieces = @(Split-Text $Text)
  $total = $pieces.Length
  if ($total -eq 0) { Die 'there is no text to translate' }

  $header = "You are a professional $fromName ($from) to $toName ($To) translator. Your goal is to accurately convey the meaning and nuances of the original $fromName text while adhering to $toName grammar, vocabulary, and cultural sensitivities." +
    $LF + "Produce only the $toName translation, without any additional explanations or commentary. Please translate the following $fromName text into ${toName}:"

  $out = New-Object System.Text.StringBuilder
  $i = 0
  foreach ($piece in $pieces) {
    $i++
    if ($total -gt 1) { Info "    part $i of $total" }
    # the model expects two blank lines between the instruction and the text
    $prompt = $header + $LF + $LF + $LF + $piece.Text
    $json = '{"model": "' + (ConvertTo-JsonBody $MODEL) + '", "stream": false, "options": {"temperature": 0, "num_ctx": ' + $NUM_CTX +
      '}, "prompt": "' + (ConvertTo-JsonBody $prompt) + '"}'
    $reply = Invoke-Http 'POST' "$OLLAMA_API/api/generate" (New-JsonContent $json) 3600
    if ($null -eq $reply) { Die "couldn't reach Ollama at $OLLAMA_API. Is the Ollama app open?" }
    if ($reply.Code -ne 200) { Die "Ollama returned HTTP $($reply.Code): $(Get-ErrorText $reply)" }
    $body = ConvertFrom-JsonBytes $reply.Bytes
    $response = Get-Prop $body 'response'
    if ($null -eq $response) { Die "couldn't read Ollama's reply for part $i" }
    $part = Remove-BlankEdges ([string]$response)
    if ($part.Length -eq 0) { Add-Warning "part $i of $total came back empty" }
    $reason = Get-Prop $body 'done_reason'
    if (-not $reason) { $reason = 'unknown' }
    if ($reason -cne 'stop') { Add-Warning "part $i of $total stopped early (done_reason=$reason); its translation may be cut short" }
    # A model can drop or merge text and still sound fluent. Paragraph counts
    # are a cheap signal that works for any language pair. Text saved from a
    # Word document has a paragraph on each line and no blank lines, and the
    # model may answer it with blank lines added, so equal line counts pass.
    # Paragraph counts say nothing about such text (it is one block, and so
    # is an answer that has lost a line), so they pass only a source that has
    # blank lines of its own, where the model re-wraps the lines between them.
    $want = Get-ParaCount $piece.Text
    $got = Get-ParaCount $part
    $wantLines = Get-LineCount $piece.Text
    $gotLines = Get-LineCount $part
    $parasMatch = ($want -eq $got) -and (($want -gt 1) -or ($wantLines -le 1))
    if ($wantLines -ne $gotLines -and -not $parasMatch) {
      Add-Warning "part $i of ${total}: the source has $want paragraph(s) on $wantLines line(s) but the translation has $got on $gotLines; check it for missing or merged text"
    }
    [void]$out.Append($part)
    if ($piece.Join -eq 'para') { [void]$out.Append($LF + $LF) }
    elseif ($piece.Join -eq 'sent') { [void]$out.Append(' ') }
    else { [void]$out.Append($LF) }
  }
  $script:Chunks = $total
  return $out.ToString()
}

# --------------------------------------------------------------- libre engine
function Get-DockerLine([string[]]$Arguments) { # first line docker prints; '' if it or the container isn't there
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return '' }
  # 5.1 turns anything a program prints on stderr into a terminating error under 'Stop'
  $saved = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $lines = @(& docker @Arguments 2>$null)
    if ($LASTEXITCODE -ne 0 -or $lines.Length -eq 0) { return '' }
    return ([string]$lines[0]).Trim()
  } catch {
    return ''
  } finally {
    $ErrorActionPreference = $saved
  }
}

function Set-LibreDigest { # sets EngineDetail and EngineDigest as best it can
  # Not /spec: LibreTranslate 1.9.6 takes about three times longer to answer
  # it on each call, until nothing else gets through. The version is in the image.
  $reply = Invoke-Http 'GET' "$LT_URL/languages" $null 30
  if ($null -eq $reply -or $reply.Code -ne 200) { Die "couldn't reach LibreTranslate at $LT_URL. Is Docker running?" }
  $version = Get-DockerLine @('exec', $LT_CONTAINER, 'cat', 'VERSION')
  if (-not $version) { $version = 'unknown' }
  $image = Get-DockerLine @('container', 'inspect', '--format', '{{.Config.Image}}', $LT_CONTAINER)
  if (-not $image) { $image = 'unknown' }
  $digest = Get-DockerLine @('container', 'inspect', '--format', '{{.Image}}', $LT_CONTAINER)
  if (-not $digest) { $digest = 'unknown' }
  $script:EngineDetail = "LibreTranslate $version (image $image)"
  $script:EngineDigest = $digest
}

function Invoke-LibreFile([string]$Source, [string]$Ext, [string]$To, [string]$Out) {
  $from = $script:From
  if (-not $from) { $from = 'auto' }
  $form = New-Object System.Net.Http.MultipartFormDataContent
  $stream = [System.IO.File]::OpenRead($Source)
  try {
    $file = New-Object System.Net.Http.StreamContent($stream)
    $file.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse('application/octet-stream')
    # upload under a plain name; the quotes are part of the header, as curl sends them
    $name = 'upload'
    if ($Ext) { $name = "upload.$Ext" }
    $form.Add($file, '"file"', '"' + $name + '"')
    $form.Add((New-Object System.Net.Http.StringContent($from)), '"source"')
    $form.Add((New-Object System.Net.Http.StringContent($To)), '"target"')
    $reply = Invoke-Http 'POST' "$LT_URL/translate_file" $form 7200
  } finally {
    $stream.Dispose()
  }
  if ($null -eq $reply) { Die "couldn't reach LibreTranslate at $LT_URL. Is Docker running?" }
  if ($reply.Code -ne 200) { Die "LibreTranslate returned HTTP $($reply.Code): $(Get-ErrorText $reply)" }
  $url = [string](Get-Prop (ConvertFrom-JsonBytes $reply.Bytes) 'translatedFileUrl')
  $at = $url.IndexOf('/download_file/')
  if ($at -lt 0) { Die "LibreTranslate's reply had no download link" }
  # re-root the link on LT_URL in case the server reports a different host
  $download = Invoke-Http 'GET' ($LT_URL + $url.Substring($at)) $null 600
  if ($null -eq $download -or $download.Code -ne 200) { Die "couldn't download the translated file" }
  [System.IO.File]::WriteAllBytes($Out, $download.Bytes)
}

function Invoke-LibreText([string]$Text, [string]$To) { # returns the translation
  $from = $script:From
  if (-not $from) { $from = 'auto' }
  $json = '{"q": "' + (ConvertTo-JsonBody $Text) + '", "source": "' + (ConvertTo-JsonBody $from) +
    '", "target": "' + (ConvertTo-JsonBody $To) + '", "format": "text"}'
  $reply = Invoke-Http 'POST' "$LT_URL/translate" (New-JsonContent $json) 600
  if ($null -eq $reply) { Die "couldn't reach LibreTranslate at $LT_URL. Is Docker running?" }
  if ($reply.Code -ne 200) { Die "LibreTranslate returned HTTP $($reply.Code): $(Get-ErrorText $reply)" }
  return [string](Get-Prop (ConvertFrom-JsonBytes $reply.Bytes) 'translatedText')
}

# ------------------------------------------------------------------ arguments
$TO = ''; $FROM_ARG = ''; $ENGINE = ''; $OUT_DIR = ''; $ENCODING = ''; $FORCE = $false; $TEXT = ''; $HAVE_TEXT = $false
$FILES = New-Object System.Collections.ArrayList
$usageError = ''
for ($i = 0; $i -lt $ARGV.Length -and -not $usageError; $i++) {
  $arg = [string]$ARGV[$i]
  $takesValue = @('--to', '--from', '--engine', '--model', '--out', '--encoding', '--text') -ccontains $arg
  $value = ''
  if ($takesValue) {
    if ($i + 1 -ge $ARGV.Length -or -not [string]$ARGV[$i + 1]) { $usageError = "$arg needs a value"; break }
    $i++
    $value = [string]$ARGV[$i]
  }
  if ($arg -ceq '--to') { $TO = $value }
  elseif ($arg -ceq '--from') { $FROM_ARG = $value }
  elseif ($arg -ceq '--engine') { $ENGINE = $value }
  elseif ($arg -ceq '--model') { $MODEL = $value }
  elseif ($arg -ceq '--out') { $OUT_DIR = $value }
  elseif ($arg -ceq '--encoding') { $ENCODING = $value }
  elseif ($arg -ceq '--text') { $TEXT = $value; $HAVE_TEXT = $true }
  elseif ($arg -ceq '--force') { $FORCE = $true }
  elseif ($arg -ceq '--languages') {
    foreach ($line in [System.IO.File]::ReadAllLines($LANGFILE, $UTF8)) { if (-not $line.StartsWith('#')) { [Console]::Out.WriteLine($line) } }
    exit 0
  }
  elseif ($arg -ceq '-h' -or $arg -ceq '--help') { Show-Usage; exit 0 }
  elseif ($arg -ceq '--') { for ($i++; $i -lt $ARGV.Length; $i++) { [void]$FILES.Add([string]$ARGV[$i]) } }
  elseif ($arg.StartsWith('-')) { $usageError = "unknown option: $arg" }
  else { [void]$FILES.Add($arg) }
}
if (-not $usageError -and -not $TO) { $usageError = '--to is required' }
if (-not $usageError -and @('', 'gemma', 'libre') -cnotcontains $ENGINE) { $usageError = '--engine must be gemma or libre'; $ENGINE = '' }
if (-not $usageError -and -not $HAVE_TEXT -and $FILES.Count -eq 0) { $usageError = 'nothing to translate' }
if ($usageError) {
  Info (Show-Usage)
  Info "error: $usageError"
  exit 1
}

# ----------------------------------------------------------------------- main
$TEXT_EXTENSIONS = @('txt', 'text', 'md', 'markdown')
$reservation = $null
$ownedOutput = ''; $ownedSidecar = ''
$exitCode = 0
$TMP = Join-Path ([System.IO.Path]::GetTempPath()) ('translate-' + [Guid]::NewGuid().ToString('N'))
[void][System.IO.Directory]::CreateDirectory($TMP)
try {
  if ($HAVE_TEXT) {
    # ---------------------------------------------------------------- text mode
    if (-not $ENGINE) { $ENGINE = 'gemma' }
    $script:From = $FROM_ARG
    $clean = ConvertTo-CleanText $TEXT
    if ($ENGINE -eq 'gemma') {
      if (-not $script:From) { Find-Language $clean }
      Set-GemmaDigest
      [Console]::Out.Write((Invoke-Gemma $clean $TO))
    } else {
      [Console]::Out.Write((Invoke-LibreText $clean $TO) + $LF)
    }
  } else {
    # ---------------------------------------------------------------- file mode
    foreach ($fileArg in $FILES) {
      $srcAbs = Get-FullPath $fileArg
      if (-not [System.IO.File]::Exists($srcAbs)) { Die "not a file: $fileArg" }
      $script:From = $FROM_ARG; $script:Detected = $false; $script:DetectConfidence = ''
      $script:Warnings = New-Object System.Collections.ArrayList
      $script:Chunks = 0
      $base = [System.IO.Path]::GetFileName($srcAbs)
      $dot = $base.LastIndexOf('.')
      if ($dot -ge 0) { $stem = $base.Substring(0, $dot); $ext = $base.Substring($dot + 1) }
      else { $stem = $base; $ext = '' }
      $extLc = $ext.ToLowerInvariant()
      $suffix = ''
      if ($ext) { $suffix = ".$ext" }

      $isText = ($TEXT_EXTENSIONS -ccontains $extLc) -or (-not $ext)
      $fileEngine = $ENGINE
      if (-not $fileEngine) {
        if ($isText) { $fileEngine = 'gemma' } else { $fileEngine = 'libre' }
      }
      if ($fileEngine -eq 'gemma' -and -not $isText) {
        Die "${base}: the gemma engine reads plain text only. Use --engine libre, or save the text as .txt first."
      }

      Info "$base  [$fileEngine]"
      # Hash and translate the same snapshot, even if the source is edited.
      $snapshot = Join-Path $TMP "source.$extLc"
      [System.IO.File]::Copy($srcAbs, $snapshot, $true)
      $srcSha = Get-Sha256 $snapshot

      # Plain text has to be UTF-8 for either engine. Convert a copy, never the original.
      $srcEncoding = 'n/a'
      $clean = ''
      if ($isText) {
        $bytes = [System.IO.File]::ReadAllBytes($snapshot)
        if ($ENCODING) {
          # not $encoding: PowerShell names ignore case, so that is $ENCODING
          $codec = Get-NamedEncoding $ENCODING
          $decoded = $null
          if ($null -ne $codec) { $decoded = ConvertFrom-Bytes $bytes $codec }
          if ($null -eq $decoded) { Die "${base}: couldn't convert from $ENCODING (unknown encoding name, or the file isn't in it)" }
          $srcEncoding = $ENCODING
        } else {
          $decoded = ConvertFrom-Bytes $bytes $UTF8_STRICT
          if ($null -eq $decoded) {
            Die "$base isn't valid UTF-8. Pass --encoding, e.g. CP1251 (Russian), CP1255 (Hebrew), CP1256 (Arabic), GBK or Big5 (Chinese), or UTF-16."
          }
          $srcEncoding = 'UTF-8'
        }
        $clean = ConvertTo-CleanText $decoded
      }
      $inputFile = $snapshot
      if ($isText) {
        $inputFile = Join-Path $TMP 'input'
        [System.IO.File]::WriteAllBytes($inputFile, $UTF8.GetBytes($clean))
      }
      $inputSha = Get-Sha256 $inputFile

      $engineOptions = ''
      if ($fileEngine -eq 'gemma') {
        if (-not $script:From) { Find-Language $clean }
        $srcLang = $script:From
        Set-GemmaDigest
        $script:EngineDetail = "$MODEL via Ollama"
        $engineOptions = "temperature=0 num_ctx=$NUM_CTX piece_bytes=$SOFT-$HARD"
      } else {
        $srcLang = $script:From
        if (-not $srcLang) { $srcLang = 'auto' }
        Set-LibreDigest
      }

      if ($OUT_DIR) { $destDir = Get-FullPath $OUT_DIR } else { $destDir = [System.IO.Path]::GetDirectoryName($srcAbs) }
      [void][System.IO.Directory]::CreateDirectory($destDir)
      $out = Join-Path $destDir "$stem.$TO.$fileEngine$suffix"
      $sidecar = "$out.provenance.json"

      # true if the sidecar records this exact source, engine and language pair
      $alreadyDone = $false
      if (-not $FORCE -and $script:EngineDigest -cne 'unknown') {
        foreach ($candidate in [System.IO.Directory]::GetFiles($destDir)) {
          if (-not $candidate.StartsWith((Join-Path $destDir "$stem.$TO.$fileEngine"), [System.StringComparison]::Ordinal) -or
              -not $candidate.EndsWith("$suffix.provenance.json", [System.StringComparison]::Ordinal)) { continue }
          $priorOutput = $candidate.Substring(0, $candidate.Length - '.provenance.json'.Length)
          if (-not [System.IO.File]::Exists($priorOutput) -or (Test-Path -LiteralPath "$priorOutput.lock")) { continue }
          try {
            $prior = ConvertFrom-JsonBytes ([System.IO.File]::ReadAllBytes($candidate))
            $alreadyDone = ((Get-Prop $prior 'tool') -ceq $TOOL) -and
              ((Get-Prop $prior 'source_sha256') -ceq $srcSha) -and
              ((Get-Prop $prior 'input_sha256') -ceq $inputSha) -and
              ((Get-Prop $prior 'source_encoding') -ceq $srcEncoding) -and
              ((Get-Prop $prior 'engine') -ceq $fileEngine) -and
              ((Get-Prop $prior 'engine_digest') -ceq $script:EngineDigest) -and
              ((Get-Prop $prior 'engine_options') -ceq $engineOptions) -and
              ((Get-Prop $prior 'source_lang') -ceq $srcLang) -and
              ((Get-Prop $prior 'target_lang') -ceq $TO) -and
              ((Get-Prop $prior 'output_file') -ceq [System.IO.Path]::GetFileName($priorOutput)) -and
              ((Get-Prop $prior 'output_sha256') -ceq (Get-Sha256 $priorOutput))
          } catch { $alreadyDone = $false }
          if ($alreadyDone) { $out = $priorOutput; break }
        }
      }
      if ($alreadyDone) {
        Info "    already translated with this engine, source unchanged: $out"
        continue
      }
      $reservation = Reserve-Output $destDir "$stem.$TO.$fileEngine" $suffix
      $out = $reservation.Path
      $sidecar = "$out.provenance.json"

      $workOut = Join-Path $TMP 'result'
      if ([System.IO.File]::Exists($workOut)) { [System.IO.File]::Delete($workOut) }
      $translated = ''
      if ($fileEngine -eq 'gemma') {
        $translated = Invoke-Gemma $clean $TO
        [System.IO.File]::WriteAllBytes($workOut, $UTF8.GetBytes($translated))
      } else {
        Invoke-LibreFile $inputFile $extLc $TO $workOut
      }
      if ((New-Object System.IO.FileInfo($workOut)).Length -eq 0) { Die "${base}: the translation came back empty" }
      Publish-New $workOut $out
      $ownedOutput = $out

      if ($fileEngine -eq 'gemma') {
        # Invoke-Gemma has already compared paragraph counts piece by piece
        $checkStatus = Test-DroppedText $clean $translated $TO '' $true
      } elseif ($isText -or $extLc -ceq 'srt') {
        $theirs = $clean
        if (-not $isText) { $theirs = ConvertFrom-Bytes ([System.IO.File]::ReadAllBytes($snapshot)) $UTF8_STRICT }
        $ours = ConvertFrom-Bytes ([System.IO.File]::ReadAllBytes($out)) $UTF8_STRICT
        if ($null -eq $theirs -or $null -eq $ours) { $checkStatus = "not checked: the text isn't valid UTF-8" }
        else { $checkStatus = Test-DroppedText $theirs $ours $TO '' $false }
      } elseif ($extLc -ceq 'docx') {
        $theirs = $null
        try { $theirs = Get-DocxText $snapshot; $ours = Get-DocxText $out } catch { $theirs = $null }
        if ($null -eq $theirs) { $checkStatus = "not checked: couldn't read the text of the .docx file" }
        else { $checkStatus = Test-DroppedText $theirs $ours $TO 'paragraph' $false }
      } else {
        $checkStatus = "not checked: this helper can't read the text of .$extLc files on Windows"
      }
      Info "    dropped-text check: $checkStatus"

      $warningList = @($script:Warnings | ForEach-Object { '"' + (ConvertTo-JsonBody $_) + '"' }) -join ', '
      $detectedText = 'false'
      if ($script:Detected) { $detectedText = 'true' }
      $record = @(
        '{'
        ('  "tool": "{0}",' -f $TOOL)
        ('  "translated_at_utc": "{0}",' -f (Get-UtcStamp "yyyy-MM-dd'T'HH:mm:ss'Z'"))
        ('  "source_file": "{0}",' -f (ConvertTo-JsonBody $srcAbs))
        ('  "source_sha256": "{0}",' -f $srcSha)
        ('  "input_sha256": "{0}",' -f $inputSha)
        ('  "source_encoding": "{0}",' -f (ConvertTo-JsonBody $srcEncoding))
        ('  "source_lang": "{0}",' -f (ConvertTo-JsonBody $srcLang))
        ('  "source_lang_detected": {0},' -f $detectedText)
        ('  "source_lang_confidence": "{0}",' -f (ConvertTo-JsonBody $script:DetectConfidence))
        ('  "target_lang": "{0}",' -f (ConvertTo-JsonBody $TO))
        ('  "engine": "{0}",' -f $fileEngine)
        ('  "engine_detail": "{0}",' -f (ConvertTo-JsonBody $script:EngineDetail))
        ('  "engine_digest": "{0}",' -f (ConvertTo-JsonBody $script:EngineDigest))
        ('  "engine_options": "{0}",' -f (ConvertTo-JsonBody $engineOptions))
        ('  "pieces": {0},' -f $script:Chunks)
        ('  "output_file": "{0}",' -f (ConvertTo-JsonBody ([System.IO.Path]::GetFileName($out))))
        ('  "output_sha256": "{0}",' -f (Get-Sha256 $out))
        ('  "dropped_text_check": "{0}",' -f (ConvertTo-JsonBody $checkStatus))
        ('  "warnings": [{0}]' -f $warningList)
        '}'
      )
      $stagedSidecar = Join-Path $TMP 'provenance.json'
      [System.IO.File]::WriteAllBytes($stagedSidecar, $UTF8.GetBytes(($record -join $LF) + $LF))
      Publish-New $stagedSidecar $sidecar
      $ownedSidecar = $sidecar
      $reservation.Stream.Dispose()
      [System.IO.File]::Delete($reservation.Lock)
      $reservation = $null
      $ownedOutput = ''; $ownedSidecar = ''
      Info "    wrote $out"
      if ($script:Warnings.Count -gt 0) { Info "    warnings were recorded in $([System.IO.Path]::GetFileName($sidecar))" }
    }
  }
} catch {
  $exitCode = 1
  if ($script:Died) { Info "error: $($_.Exception.Message)" }
  else { Info "error: $($_.Exception.Message)$([Environment]::NewLine)$($_.ScriptStackTrace)" }
} finally {
  if ($ownedOutput) { [System.IO.File]::Delete($ownedOutput) }
  if ($ownedSidecar) { [System.IO.File]::Delete($ownedSidecar) }
  if ($null -ne $reservation) { $reservation.Stream.Dispose(); [System.IO.File]::Delete($reservation.Lock) }
  try { [System.IO.Directory]::Delete($TMP, $true) } catch { }
}
exit $exitCode
