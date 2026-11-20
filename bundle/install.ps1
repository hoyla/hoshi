# Install the offline translation bundle on an airgapped Windows PC.
# Puts on both engines, the translate helper and the translation web page.
#
# Needs only Docker Desktop and what ships with Windows 10 and 11 (Windows
# PowerShell 5.1, robocopy). Run it through install.cmd, which gets past the
# default policy that blocks scripts. Safe to re-run: every step either
# replaces what an earlier run of this installer put there or leaves existing
# things alone.
#
# Kept to ASCII and to PowerShell 5.1 syntax on purpose; translate.ps1 says why.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path
$ARGV = @($args)
$ENVFILE = Join-Path $HERE 'bundle.env'

$PORT = '5050' # the same as on a Mac, where AirPlay Receiver holds 5000
$NAME = 'libretranslate'
$WEB_PORT = '5080'
$WEB_NAME = 'translation-web'
$PREFIX = ''
$DO_VERIFY = $true
$DO_DOCKER = $true
$DO_OLLAMA = $true
$DO_WEB = $true
$DO_LAUNCH = $true
$DO_OPEN = $true
$DO_SPACE = $true

# So the test translations, which have accents, are read back and shown intact.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

function Show-Usage {
  @"
Usage: install.cmd [options]

  --port N         Local port for LibreTranslate (default: $PORT)
  --name NAME      Docker container name (default: $NAME)
  --web-port N     Local port for the translation page (default: $WEB_PORT)
  --web-name NAME  Docker container name for the page (default: $WEB_NAME)
  --prefix DIR     Where the translate helper goes (default: %USERPROFILE%\translation-tools)
  --skip-verify    Don't check the bundle's checksums first
  --no-space-check Install even if the disk looks too full for it
  --no-docker      Skip LibreTranslate and, with it, the translation page
  --no-ollama      Skip Ollama and its models
  --no-web         Skip the translation page. LibreTranslate then shows its
                   own page, which keeps no record and makes no checks
  --no-launch      Install Ollama but don't wait for it or test it
                   (its own installer still starts it)
  --no-open        Don't open the translation page in a browser at the end
  -h, --help       Show this help
"@
}

$script:Died = $false
$script:Step = 'checking this PC and the bundle' # what the closing lines of a failed run name
$script:Transcribing = $false
$LOG = ''
$SUPPORT = ''
function Say([string]$Message) { $script:Step = $Message; Write-Host ''; Write-Host "==> $Message" }
function Note([string]$Message) { Write-Host "    $Message" }
function Die([string]$Message) { $script:Died = $true; throw $Message }

function Get-Cfg([string]$Key) {
  foreach ($line in [System.IO.File]::ReadAllLines($ENVFILE)) {
    if ($line.StartsWith("$Key=")) { return $line.Substring($Key.Length + 1).Trim() }
  }
  return ''
}

# The same from the bundle.env an earlier install left in the prefix. It is
# read into memory before anything is replaced.
$script:OldLines = @()
function Get-Old([string]$Key) {
  foreach ($line in $script:OldLines) {
    if ($line.StartsWith("$Key=")) { return $line.Substring($Key.Length + 1).Trim() }
  }
  return ''
}

function Format-Gb([double]$Bytes) {
  return ($Bytes / 1GB).ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Get-FileBytes([string]$Path) {
  if ([System.IO.File]::Exists($Path)) { return (New-Object System.IO.FileInfo($Path)).Length }
  return [long]0
}

# Free bytes on the drive a folder is on, or -1 where that can't be told (a
# network share).
function Get-FreeBytes([string]$Path) {
  try {
    $drive = Get-PSDrive -Name ([System.IO.Path]::GetPathRoot($Path).Substring(0, 1))
    return [long]$drive.Free
  } catch {
    return [long]-1
  }
}

function Test-VersionOlder([string]$Have, [string]$Want) {
  try {
    $a = [version](($Have -replace '^v', '') -replace '[^0-9.].*$', '')
    $b = [version](($Want -replace '^v', '') -replace '[^0-9.].*$', '')
    return ($a -lt $b)
  } catch {
    return $false
  }
}

# Runs a program and returns @{ Code; Text } with what it printed on stdout.
# Windows PowerShell 5.1 turns anything a program prints on stderr into a
# terminating error under 'Stop' once stderr is redirected, so that is relaxed
# for the call.
function Get-ToolOutput([string]$Exe, [string[]]$Arguments) {
  $ErrorActionPreference = 'Continue'
  $lines = @(& $Exe @Arguments 2>$null | ForEach-Object { "$_" })
  return @{ Code = $LASTEXITCODE; Text = ($lines -join "`n").Trim() }
}

function Test-Url([string]$Url) {
  try {
    $request = [System.Net.WebRequest]::Create($Url)
    $request.Proxy = $null
    $request.Timeout = 5000
    $request.GetResponse().Close()
    return $true
  } catch {
    return $false
  }
}

function Wait-Url([string]$Url, [int]$Tries, [int]$PauseSec) {
  for ($n = 0; $n -lt $Tries; $n++) {
    if (Test-Url $Url) { return $true }
    Start-Sleep -Seconds $PauseSec
  }
  return $false
}

function Test-PortInUse([int]$Number) {
  $client = New-Object System.Net.Sockets.TcpClient
  try { $client.Connect('127.0.0.1', $Number); return $true } catch { return $false } finally { $client.Close() }
}

# A container from an earlier install holds its port and is replaced further on.
function Test-PortHeldByAnother([string]$Number, [string]$Container) {
  if (-not (Test-PortInUse ([int]$Number))) { return $false }
  return ((Get-ToolOutput 'docker' @('container', 'inspect', '--format', '{{json .Config.Labels}}', $Container)).Code -ne 0)
}

# One test translation through the installed helper. Returns @{ Ok; Text; Seconds }.
function Invoke-TestTranslation([string]$Engine, [string]$From, [string]$To) {
  $ErrorActionPreference = 'Continue' # as in Get-ToolOutput
  $powershell = (Get-Process -Id $PID).Path
  $watch = [System.Diagnostics.Stopwatch]::StartNew()
  # stderr is left alone so the helper's own error message shows
  $lines = @(& $powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PREFIX 'translate.ps1') `
      --engine $Engine --from $From --to $To --text 'The documents arrived this morning.')
  $ok = ($LASTEXITCODE -eq 0)
  return @{ Ok = $ok; Text = (($lines | ForEach-Object { "$_" }) -join ' ').Trim(); Seconds = [int]$watch.Elapsed.TotalSeconds }
}

# ------------------------------------------------------------------ arguments
$usageError = ''
for ($i = 0; $i -lt $ARGV.Length -and -not $usageError; $i++) {
  $arg = [string]$ARGV[$i]
  $value = ''
  if (@('--port', '--name', '--web-port', '--web-name', '--prefix') -ccontains $arg) {
    if ($i + 1 -ge $ARGV.Length -or -not [string]$ARGV[$i + 1]) { $usageError = "$arg needs a value"; break }
    $i++
    $value = [string]$ARGV[$i]
  }
  if ($arg -ceq '--port') { $PORT = $value }
  elseif ($arg -ceq '--name') { $NAME = $value }
  elseif ($arg -ceq '--web-port') { $WEB_PORT = $value }
  elseif ($arg -ceq '--web-name') { $WEB_NAME = $value }
  elseif ($arg -ceq '--prefix') { $PREFIX = $value }
  elseif ($arg -ceq '--skip-verify') { $DO_VERIFY = $false }
  elseif ($arg -ceq '--no-space-check') { $DO_SPACE = $false }
  elseif ($arg -ceq '--no-docker') { $DO_DOCKER = $false }
  elseif ($arg -ceq '--no-ollama') { $DO_OLLAMA = $false }
  elseif ($arg -ceq '--no-web') { $DO_WEB = $false }
  elseif ($arg -ceq '--no-launch') { $DO_LAUNCH = $false }
  elseif ($arg -ceq '--no-open') { $DO_OPEN = $false }
  elseif ($arg -ceq '-h' -or $arg -ceq '--help') { Show-Usage; exit 0 }
  else { $usageError = "unknown option: $arg" }
}
if (-not $usageError -and $PORT -notmatch '^[0-9]{1,5}$') { $usageError = "--port must be a number, not '$PORT'" }
if (-not $usageError -and $WEB_PORT -notmatch '^[0-9]{1,5}$') { $usageError = "--web-port must be a number, not '$WEB_PORT'" }
if ($usageError) {
  [Console]::Error.WriteLine((Show-Usage))
  [Console]::Error.WriteLine("error: $usageError")
  exit 1
}

$exitCode = 0
try {
  # ---------------------------------------------------------------- preflight
  if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Die 'this installer is for Windows. On a Mac, run ./install.sh instead.'
  }
  if (-not [System.IO.File]::Exists($ENVFILE)) { Die 'bundle.env not found; run this from inside the bundle folder' }
  if (-not $PREFIX) { $PREFIX = Join-Path $env:USERPROFILE 'translation-tools' }
  $PREFIX = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PREFIX)
  $SUPPORT = Get-Cfg 'SUPPORT'

  # Keep a record of the run, a new file each time. It holds what this script
  # prints; what docker and robocopy print themselves may be missing from it.
  try {
    [void][System.IO.Directory]::CreateDirectory($PREFIX)
    $LOG = Join-Path $PREFIX ('install-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '.log')
    Start-Transcript -LiteralPath $LOG | Out-Null
    $script:Transcribing = $true
  } catch {
    $LOG = ''
  }

  $MEMORY_GB = 0
  try { $MEMORY_GB = [int][Math]::Round((Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory / 1GB) } catch { }
  $NEW_BUILT = Get-Cfg 'BUNDLE_BUILT_UTC'
  Say 'Offline translation installer'
  $options = 'none'
  if ($ARGV.Length -gt 0) { $options = $ARGV -join ' ' }
  Note "started $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')), options: $options"
  Note "bundle built $NEW_BUILT from commit $(Get-Cfg 'SOURCE_COMMIT')"
  Note "this PC: Windows $([System.Environment]::OSVersion.Version), $MEMORY_GB GB memory"
  if ($LOG) { Note "log: $LOG" }

  # What an earlier install left, read now: its bundle.env is replaced further on.
  $oldEnv = Join-Path $PREFIX 'bundle.env'
  if ([System.IO.File]::Exists($oldEnv)) { $script:OldLines = @([System.IO.File]::ReadAllLines($oldEnv)) }
  $OLD_BUILT = Get-Old 'BUNDLE_BUILT_UTC'
  $OLD_IMAGE_ID = Get-Old 'LT_IMAGE_ID_INSTALLED'
  $OLD_IMAGE_IDS = @(("$OLD_IMAGE_ID $(Get-Old 'LT_IMAGE_ID_PREVIOUS')").Split(' ') | Where-Object { $_ })
  $OLD_MODELS = @(("$(Get-Old 'GEMMA_MODELS'),$(Get-Old 'GEMMA_MODELS_PREVIOUS')").Split(',') | Where-Object { $_ })
  $OLD_OLLAMA_APP = Get-Old 'OLLAMA_APP'
  $OLD_OLLAMA_OURS = Get-Old 'OLLAMA_APP_BY_INSTALLER'
  $OLD_WEB_URL = Get-Old 'WEB_URL'
  $OLD_WEB_CONTAINER = Get-Old 'WEB_CONTAINER'
  $CLOSING = New-Object System.Collections.ArrayList # lines for the end of the run, where they are still on screen
  if ($OLD_BUILT) {
    Say 'This PC already has an install'
    Note "installed now:    bundle built $OLD_BUILT from commit $(Get-Old 'SOURCE_COMMIT')"
    Note "being installed:  bundle built $NEW_BUILT from commit $(Get-Cfg 'SOURCE_COMMIT')"
    $order = [string]::CompareOrdinal($NEW_BUILT, $OLD_BUILT)
    if ($order -eq 0) {
      Note 'They are the same bundle. Running it again repairs the install; nothing is updated.'
    } elseif ($order -lt 0) {
      Note 'THE BUNDLE BEING INSTALLED IS OLDER than the one this PC has. Carrying on'
      Note 'puts the older one in its place. To keep the newer one, close this window now.'
      [void]$CLOSING.Add("This run put an OLDER bundle (built $NEW_BUILT) in place of a newer one (built $OLD_BUILT).")
    } else {
      Note 'The bundle being installed is newer: this run updates the install.'
    }
  }

  $LT_URL = "http://127.0.0.1:$PORT"
  if (-not $env:OLLAMA_HOST) { $OLLAMA_API = 'http://127.0.0.1:11434' }
  elseif ($env:OLLAMA_HOST -match '^https?://') { $OLLAMA_API = $env:OLLAMA_HOST }
  else { $OLLAMA_API = "http://$($env:OLLAMA_HOST)" }

  # Which LibreTranslate image fits: Docker's Linux is ARM on a Snapdragon PC.
  $ARCH = 'amd64'
  if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { $ARCH = 'arm64' }

  if ($DO_DOCKER) {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
      Die 'docker was not found. Is Docker Desktop installed? If it was only just installed, open a new window and try again.'
    }
    $info = Get-ToolOutput 'docker' @('info', '--format', '{{.OSType}}/{{.Architecture}}')
    if ($info.Code -ne 0) { Die "Docker isn't running. Start Docker Desktop, wait until it says it is running, and re-run." }
    if ($info.Text -match '^windows/') {
      Die "Docker Desktop is set to Windows containers. Right-click the Docker whale in the system tray, choose 'Switch to Linux containers', and re-run."
    }
    if ($info.Text -match '/(aarch64|arm64)$') { $ARCH = 'arm64' } elseif ($info.Text -match '/(x86_64|amd64)$') { $ARCH = 'amd64' }
    $IMAGE = Get-Cfg "LT_IMAGE_$($ARCH.ToUpperInvariant())"
    $LT_TAR = Get-Cfg "LT_TAR_$($ARCH.ToUpperInvariant())"
    if (-not $IMAGE -or -not $LT_TAR) {
      Die "this bundle has no LibreTranslate image for Docker on $ARCH. Rebuild it with a --targets list that covers this machine, or re-run with --no-docker."
    }
  }
  if ($DO_OLLAMA -and -not (Get-Cfg 'OLLAMA_SETUP')) {
    Die 'this bundle was built without the Windows version of Ollama. Rebuild it with --targets windows, or re-run with --no-ollama.'
  }
  # The page runs on the LibreTranslate image, so there is none without Docker.
  if (-not $DO_DOCKER) { $DO_WEB = $false }
  $WEB_INSTALLER = Join-Path $HERE 'install-web.ps1'
  if ($DO_WEB -and -not ([System.IO.File]::Exists($WEB_INSTALLER) -and [System.IO.File]::Exists((Join-Path $HERE 'web\app.py')))) {
    Die "the translation page's files (install-web.ps1 and the web folder) are missing from the bundle. Copy them again from the original, or re-run with --no-web."
  }

  # Everything else that can be found out without installing anything, before
  # the checksums and the image load, which take a while.
  Say 'Checking this PC before anything is installed'
  if ($DO_DOCKER) {
    if (Test-PortHeldByAnother $PORT $NAME) { Die "port $PORT is already in use; pass --port with a free one" }
    if ($DO_WEB -and (Test-PortHeldByAnother $WEB_PORT $WEB_NAME)) {
      Die "port $WEB_PORT, which the translation page uses, is already in use; pass --web-port with a free one"
    }
    Note 'the ports are free'
  }

  $MODELS_DIR = $env:OLLAMA_MODELS
  if (-not $MODELS_DIR) { $MODELS_DIR = Join-Path $env:USERPROFILE '.ollama\models' }
  # robocopy reads a quoted path ending in a backslash as ending in a quote
  if ($MODELS_DIR.Length -gt 3) { $MODELS_DIR = $MODELS_DIR.TrimEnd('\') }
  $OLLAMA_DIR = Join-Path $env:LOCALAPPDATA 'Programs\Ollama'
  $OLLAMA_EXE = Join-Path $OLLAMA_DIR 'ollama.exe'
  if (-not [System.IO.File]::Exists($OLLAMA_EXE)) {
    $onPath = Get-Command ollama.exe -ErrorAction SilentlyContinue
    if ($onPath) { $OLLAMA_EXE = $onPath.Source; $OLLAMA_DIR = Split-Path -Parent $OLLAMA_EXE }
  }
  if ($DO_OLLAMA -and -not [System.IO.File]::Exists($OLLAMA_EXE) -and [System.Environment]::OSVersion.Version.Build -lt 19045) {
    Note "Ollama asks for Windows 10 22H2 or newer; this PC is older (build $([System.Environment]::OSVersion.Version.Build)). Trying anyway."
  }

  # Disk space, from the sizes of this bundle's own files. A model file the PC
  # already has in full is not counted, nor the image of a bundle already
  # installed, so a re-run asks for next to nothing.
  $need = [long]0
  if ($DO_OLLAMA) {
    $modelSource = Join-Path $HERE 'ollama\models'
    if ([System.IO.Directory]::Exists($modelSource)) {
      foreach ($file in [System.IO.Directory]::GetFiles($modelSource, '*', [System.IO.SearchOption]::AllDirectories)) {
        $leaf = [System.IO.Path]::GetFileName($file)
        if ($leaf.StartsWith('._') -or $leaf -eq '.DS_Store') { continue }
        $size = Get-FileBytes $file
        if ((Get-FileBytes (Join-Path $MODELS_DIR $file.Substring($modelSource.Length).TrimStart('\'))) -ne $size) { $need += $size }
      }
    }
    # installed, Ollama is about four times its setup file
    if (-not [System.IO.File]::Exists($OLLAMA_EXE)) {
      $need += 4 * (Get-FileBytes (Join-Path $HERE (Get-Cfg 'OLLAMA_SETUP').Replace('/', '\')))
    }
  }
  if ($DO_DOCKER -and ($NEW_BUILT -ne $OLD_BUILT -or -not $OLD_IMAGE_ID)) {
    $need += Get-FileBytes (Join-Path $HERE $LT_TAR.Replace('/', '\'))
  }
  $need += 1GB # and a gigabyte to work in
  $free = Get-FreeBytes $env:USERPROFILE
  if ($free -ge 0) {
    Note "disk: $(Format-Gb $free) GB free, about $(Format-Gb $need) GB needed"
    if ($free -lt $need) {
      if ($DO_SPACE) {
        Die "not enough free disk space: this PC has $(Format-Gb $free) GB free and the install needs about $(Format-Gb $need) GB. Free some space (empty the Recycle Bin, move large files to another drive) and run the installer again. To install only part: --no-ollama leaves out TranslateGemma, --no-docker leaves out LibreTranslate. If you are sure there is room, --no-space-check skips this check."
      }
      Note 'that is too little by this check, which --no-space-check has turned off'
    }
  }

  if ($DO_OLLAMA -and $MEMORY_GB -gt 0 -and $MEMORY_GB -lt 16) {
    Note "WARNING: this PC has $MEMORY_GB GB of memory. TranslateGemma's standard model (12b)"
    Note 'is meant for 16 GB or more: here it may be very slow, or fail to load.'
    Note 'LibreTranslate is not affected. The install carries on.'
    [void]$CLOSING.Add("This PC has $MEMORY_GB GB of memory, less than the 16 GB TranslateGemma's standard model wants.")
    if (((Get-Cfg 'GEMMA_MODELS') -split ',') -ccontains 'translategemma:4b') {
      [void]$CLOSING.Add('If it is too slow, choose translategemma:4b in the Model list on the translation page.')
    }
  }

  # ---------------------------------------------------------------- checksums
  if ($DO_VERIFY) {
    Say "Verifying the bundle's checksums (a few minutes for the large files)"
    $failed = New-Object System.Collections.ArrayList
    $checked = 0
    foreach ($line in [System.IO.File]::ReadAllLines((Join-Path $HERE 'SHA256SUMS'))) {
      if ($line -notmatch '^([0-9a-f]{64})  \./(.+)$') { continue }
      $want = $Matches[1]
      $rel = $Matches[2]
      # The other platform's payload isn't used here and may have been left off the drive.
      if ($rel -match '^docker/.*\.tar$' -and -not $rel.EndsWith("-$ARCH.tar")) { continue }
      if ($rel -eq 'ollama/Ollama-darwin.zip' -or $rel -eq 'docker/Docker.dmg') { continue }
      $path = Join-Path $HERE $rel.Replace('/', '\')
      if (-not [System.IO.File]::Exists($path)) { [void]$failed.Add("$rel (missing)"); continue }
      if ((New-Object System.IO.FileInfo($path)).Length -gt 500MB) { Note "checking $rel" }
      if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $want) { [void]$failed.Add($rel) }
      $checked++
    }
    if ($failed.Count -gt 0) {
      foreach ($item in $failed) { Note "FAILED: $item" }
      Die 'checksum verification failed: the bundle was damaged or changed in transit'
    }
    if ($checked -eq 0) { Die 'SHA256SUMS lists no files; the bundle is incomplete' }
    Note "all $checked files match SHA256SUMS"
  }

  # ----------------------------------------------------------- LibreTranslate
  if ($DO_DOCKER) {
    Say "Loading $IMAGE into Docker"
    & docker load -i (Join-Path $HERE $LT_TAR.Replace('/', '\'))
    if ($LASTEXITCODE -ne 0) {
      Die "docker load failed. If the message above says 'no space left on device', the disk Docker keeps its images on is full. Free some space on that drive (usually C:), or remove an image you no longer need ('docker image ls', 'docker image rm NAME'), then re-run. Take care: nothing removed can be downloaded again on this PC."
    }
    # Sidecars record the image by the ID Docker gives it on this PC, which can
    # differ from the manifest's depending on how each Docker stores images.
    $loaded = Get-ToolOutput 'docker' @('image', 'inspect', '--format', '{{.Id}}', $IMAGE)
    if ($loaded.Code -ne 0 -or -not $loaded.Text) { Die "couldn't read the loaded LibreTranslate image ID; re-run the installer" }
    $LOADED_ID = $loaded.Text
    if ($LOADED_ID -ne (Get-Cfg "LT_IMAGE_ID_$($ARCH.ToUpperInvariant())")) {
      Note "Docker here knows the image as $LOADED_ID; recorded in bundle.env beside the manifest's ID"
    }

    $existing = Get-ToolOutput 'docker' @('container', 'inspect', '--format', '{{json .Config.Labels}}', $NAME)
    if ($existing.Code -eq 0) {
      $ours = $false
      try { $ours = (($existing.Text | ConvertFrom-Json).PSObject.Properties['airgapped-translation'].Value -eq '1') } catch { }
      if (-not $ours) { Die "a container named '$NAME' exists that this installer didn't create; remove it or pass --name" }
      Note "replacing the '$NAME' container from an earlier install"
      & docker rm -f $NAME | Out-Null
      if ($LASTEXITCODE -ne 0) {
        Die "Docker couldn't remove the '$NAME' container from the earlier install; its message is above. Quit Docker Desktop from the whale near the clock, open it again, wait until it says it is running, then run the installer again."
      }
    }
    if (Test-PortInUse ([int]$PORT)) { Die "port $PORT is already in use; pass --port with a free one" }

    # Where the translation page goes on, LibreTranslate's own page is turned
    # off: it keeps no record of a translation and makes no check of one. The
    # service still answers the translation page and translate.cmd.
    $ltOptions = @()
    if ($DO_WEB) {
      $ltOptions = @('-e', 'LT_DISABLE_WEB_UI=true')
      Say "Starting LibreTranslate on $LT_URL, without its own web page"
    } else {
      Say "Starting LibreTranslate on $LT_URL"
    }
    & docker run -d --name $NAME --label airgapped-translation=1 --pull never --restart unless-stopped -p "127.0.0.1:${PORT}:5000" @ltOptions $LOADED_ID | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Die "Docker couldn't start LibreTranslate; its message is above. If it speaks of a port, run the installer again with --port 5051. Otherwise quit Docker Desktop, open it again, wait until it says it is running, then run the installer again."
    }
    if (-not (Wait-Url "$LT_URL/languages" 150 2)) {
      & docker logs --tail 30 $NAME
      Die 'LibreTranslate did not start; log above'
    }
  }

  # ------------------------------------------------------------------- Ollama
  if ($DO_OLLAMA) {
    # Models go in before Ollama first starts: at startup it clears out any
    # model data that no complete model refers to, which a half-finished copy
    # would look like.
    Say "Copying models into $MODELS_DIR (several minutes)"
    # /FFT: an exFAT drive keeps times to 2 seconds, and without it every file
    # would look changed on a re-run. /XF: bookkeeping files a Mac leaves on
    # the drive, which Ollama would trip over.
    & robocopy (Join-Path $HERE 'ollama\models') $MODELS_DIR /E /FFT /R:2 /W:2 /NJH /NJS /NDL /NC /XF '._*' '.DS_Store'
    if ($LASTEXITCODE -ge 8) {
      Die "couldn't copy the TranslateGemma models into $MODELS_DIR (robocopy code $LASTEXITCODE); the messages above say why. If the disk is full, free some space; if the drive was unplugged, plug it back in. Then run the installer again: it picks up where the copy stopped. To do without TranslateGemma, re-run with --no-ollama."
    }

    $BUNDLED_VERSION = Get-Cfg 'OLLAMA_VERSION'
    $OLLAMA_OURS = ($OLD_OLLAMA_OURS -eq '1' -and $OLD_OLLAMA_APP -eq $OLLAMA_EXE)
    $runSetup = $false
    if ([System.IO.File]::Exists($OLLAMA_EXE)) {
      $have = 'unknown'
      if ((Get-ToolOutput $OLLAMA_EXE @('--version')).Text -match '([0-9]+\.[0-9]+\.[0-9]+[^\s]*)\s*$') { $have = $Matches[1] }
      if ("v$have" -eq $BUNDLED_VERSION) {
        Say "Ollama is already in $OLLAMA_DIR (version $have); leaving it as it is"
      } elseif ($OLLAMA_OURS -and (Test-VersionOlder $have $BUNDLED_VERSION)) {
        # Only an Ollama an earlier run of this installer put there is replaced.
        # Its own setup program updates it in place.
        Say "Replacing Ollama $have, which an earlier install put in $OLLAMA_DIR, with $BUNDLED_VERSION"
        $runSetup = $true
      } else {
        Say "Ollama is already in $OLLAMA_DIR (version $have); leaving it as it is"
        Note "the bundle carries $BUNDLED_VERSION. To switch: quit Ollama from the system tray, uninstall it in Settings > Apps, re-run."
      }
    } else {
      Say "Installing Ollama $BUNDLED_VERSION (no administrator rights needed)"
      $runSetup = $true
      $OLLAMA_OURS = $true
    }
    if ($runSetup) {
      $setup = Join-Path $HERE (Get-Cfg 'OLLAMA_SETUP').Replace('/', '\')
      # Informational only. A PC that has never been online may lack the root
      # certificate to confirm a publisher; the checksum above is what vouches
      # for the file.
      $signature = Get-AuthenticodeSignature -LiteralPath $setup
      $signer = ''
      if ($signature.SignerCertificate) { $signer = $signature.SignerCertificate.Subject }
      Note "publisher signature: $($signature.Status) $signer"
      $installer = Start-Process -FilePath $setup -ArgumentList '/SP-', '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/LOG' -PassThru
      $null = $installer.Handle # without this the exit code can't be read afterwards
      # Not Start-Process -Wait: that also waits for the Ollama app the installer starts.
      $installer.WaitForExit()
      if ($installer.ExitCode -ne 0 -or -not [System.IO.File]::Exists($OLLAMA_EXE)) {
        Die "the Ollama installer did not finish (exit code $($installer.ExitCode)). Its log is the newest 'Setup Log' file in $env:TEMP. Re-run with --no-ollama to keep LibreTranslate only."
      }
    }
  }

  # Models an earlier bundle installed that this one doesn't carry stay where
  # they are: they may be wanted, and .ollama is not this installer's alone.
  $LEFT_MODELS = New-Object System.Collections.ArrayList
  $carried = @((Get-Cfg 'GEMMA_MODELS') -split ',')
  foreach ($model in $OLD_MODELS) {
    if (($carried -ccontains $model) -or ($LEFT_MODELS -ccontains $model)) { continue }
    $modelName = $model.Split(':')[0]
    if ($modelName -notmatch '/') { $modelName = "library/$modelName" }
    $modelFile = Join-Path $MODELS_DIR ("manifests\registry.ollama.ai\$modelName\" + $model.Split(':')[-1]).Replace('/', '\')
    if (-not [System.IO.File]::Exists($modelFile)) { continue } # removed since
    [void]$LEFT_MODELS.Add($model)
    $modelBytes = [double]0
    foreach ($found in [regex]::Matches([System.IO.File]::ReadAllText($modelFile), '"size":\s*([0-9]+)')) {
      $modelBytes += [double]$found.Groups[1].Value
    }
    [void]$CLOSING.Add("$model, from an earlier bundle, is still on this PC and holds about $(Format-Gb $modelBytes) GB.")
    [void]$CLOSING.Add("  This bundle doesn't carry it. It still works; to remove it, with Ollama running, run in Command Prompt:")
    [void]$CLOSING.Add("  `"$OLLAMA_EXE`" rm $model")
  }

  # ------------------------------------------------------------ helper script
  Say "Installing the translate helper into $PREFIX"
  $copyAdvice = 'If the disk is full, free some space; if the drive was unplugged, plug it back in. Then run the installer again.'
  $TEST_FILES = ''
  try {
    [void][System.IO.Directory]::CreateDirectory($PREFIX)
    # not $name: PowerShell names ignore case, so that is $NAME
    foreach ($file in @('translate.ps1', 'translate.cmd', 'languages.tsv', 'bundle.env', 'MANIFEST.txt', 'README.txt',
        'Start Translation.cmd', 'start-translation.ps1')) {
      # the last two are not in a bundle put together by an older build
      if ($file -like '*start*' -and -not [System.IO.File]::Exists((Join-Path $HERE $file))) { continue }
      [System.IO.File]::Copy((Join-Path $HERE $file), (Join-Path $PREFIX $file), $true)
    }
    # A copy to practise on, so translations of it aren't written into the bundle.
    $testSource = Join-Path $HERE 'test-files'
    if ([System.IO.Directory]::Exists($testSource)) {
      $TEST_FILES = Join-Path $PREFIX 'test-files'
      [void][System.IO.Directory]::CreateDirectory($TEST_FILES)
      foreach ($testFile in [System.IO.Directory]::GetFiles($testSource)) {
        [System.IO.File]::Copy($testFile, (Join-Path $TEST_FILES ([System.IO.Path]::GetFileName($testFile))), $true)
      }
    }
  } catch {
    Die "couldn't copy the translate helper into $PREFIX ($($_.Exception.Message)). $copyAdvice"
  }
  # The images of earlier installs, to be removed once this one is working. Kept
  # on record until then, so a run that stops before that doesn't lose them.
  $PREVIOUS_IDS = New-Object System.Collections.ArrayList
  if ($DO_DOCKER) {
    foreach ($id in $OLD_IMAGE_IDS) {
      if ($id -ne $LOADED_ID -and -not ($PREVIOUS_IDS -ccontains $id)) { [void]$PREVIOUS_IDS.Add($id) }
    }
  }
  # Remember non-default settings so the helper finds the services, and what
  # this install put on the PC so the next one knows what is its to replace.
  $settings = "LT_URL=$LT_URL`nLT_CONTAINER=$NAME`n"
  if ($DO_DOCKER) {
    $settings += "LT_IMAGE=$IMAGE`nLT_IMAGE_ID_INSTALLED=$LOADED_ID`n"
    if ($PREVIOUS_IDS.Count -gt 0) { $settings += "LT_IMAGE_ID_PREVIOUS=$($PREVIOUS_IDS -join ' ')`n" }
    # --no-web leaves an earlier install's page running; keep its address.
    if (-not $DO_WEB -and $OLD_WEB_URL) {
      $oldPage = $OLD_WEB_CONTAINER
      if (-not $oldPage) { $oldPage = $WEB_NAME }
      if ((Get-ToolOutput 'docker' @('container', 'inspect', '--format', '{{json .Config.Labels}}', $oldPage)).Code -eq 0) {
        $settings += "WEB_URL=$OLD_WEB_URL`nWEB_CONTAINER=$oldPage`n"
      }
    }
  }
  if ($DO_OLLAMA) {
    $ours = '0'
    if ($OLLAMA_OURS) { $ours = '1' }
    $settings += "OLLAMA_APP=$OLLAMA_EXE`nOLLAMA_APP_BY_INSTALLER=$ours`n"
  } elseif ($OLD_OLLAMA_APP -and [System.IO.File]::Exists($OLD_OLLAMA_APP)) {
    $ours = '0'
    if ($OLD_OLLAMA_OURS -eq '1') { $ours = '1' }
    $settings += "OLLAMA_APP=$OLD_OLLAMA_APP`nOLLAMA_APP_BY_INSTALLER=$ours`n"
  }
  if ($LEFT_MODELS.Count -gt 0) { $settings += "GEMMA_MODELS_PREVIOUS=$($LEFT_MODELS -join ',')`n" }
  try {
    [System.IO.File]::AppendAllText((Join-Path $PREFIX 'bundle.env'), $settings)
  } catch {
    Die "couldn't write this install's settings into $(Join-Path $PREFIX 'bundle.env') ($($_.Exception.Message)). $copyAdvice"
  }

  # --------------------------------------------------------- translation page
  # install-web.ps1 is also how the page is replaced later, from a small folder
  # of its own. Its files were checked above with the rest of the bundle.
  $WEB_URL = "http://127.0.0.1:$WEB_PORT"
  if ($DO_WEB) {
    & $WEB_INSTALLER --prefix $PREFIX --port $WEB_PORT --name $WEB_NAME --skip-verify --part-of-install
    if ($LASTEXITCODE -ne 0) {
      Die 'the translation page did not start; the lines above say why. LibreTranslate and the translate helper are installed. Run install.cmd again once that is put right, or with --no-web to have LibreTranslate''s own page instead.'
    }
  }

  # ------------------------------------------------------------ launch + test
  $LT_OK = 'not checked'
  if ($DO_DOCKER) {
    $pair = Get-Cfg 'LT_SELFTEST_PAIR'
    $from = $pair.Split(':')[0]
    $to = $pair.Split(':')[1]
    $test = Invoke-TestTranslation 'libre' $from $to
    if (-not $test.Ok) { Die 'LibreTranslate is up but the test translation failed' }
    Note "LibreTranslate test ($from->$to): $($test.Text)"
    if ($DO_WEB) { $LT_OK = 'running; use it from the translation page or translate.cmd' }
    else { $LT_OK = "$LT_URL (open in a browser)" }

    # Each bundle's image is 9 to 11 GB of the disk Docker keeps images on. The
    # one an earlier install recorded goes now that the new LibreTranslate has
    # translated and the page has moved to the new image, and only if no
    # container still uses it.
    $saidRemoving = $false
    foreach ($id in $PREVIOUS_IDS) {
      $size = Get-ToolOutput 'docker' @('image', 'inspect', '--format', '{{.Size}}', $id)
      if ($size.Code -ne 0) { continue } # gone already
      if (-not $saidRemoving) { Say 'Removing the LibreTranslate image of the earlier install'; $saidRemoving = $true }
      $users = (Get-ToolOutput 'docker' @('ps', '-a', '--filter', "ancestor=$id", '--format', '{{.Names}}')).Text -replace '\s+', ' '
      if ($users) {
        Note "left in place: a container still uses it ($users)"
        [void]$CLOSING.Add("The earlier install's LibreTranslate image is still in Docker, in use by: $users")
      } elseif ((Get-ToolOutput 'docker' @('image', 'rm', $id)).Code -eq 0) {
        $bytes = [double]0
        try { $bytes = [double]$size.Text } catch { }
        Note "removed $id, about $(Format-Gb $bytes) GB of Docker's disk"
      } else {
        Note "Docker wouldn't remove it; it does no harm. To remove it by hand: docker image rm $id"
      }
    }
  }

  $OLLAMA_OK = 'not checked'
  if ($DO_OLLAMA -and $DO_LAUNCH) {
    Say 'Waiting for Ollama'
    if (-not (Wait-Url "$OLLAMA_API/api/version" 20 1)) {
      $app = Join-Path $OLLAMA_DIR 'ollama app.exe'
      if ([System.IO.File]::Exists($app)) { Start-Process -FilePath $app }
    }
    if (Wait-Url "$OLLAMA_API/api/version" 60 1) {
      $model = Get-Cfg 'DEFAULT_MODEL'
      Note "running a test translation with $model (the first run loads the model, allow a few minutes)"
      $test = Invoke-TestTranslation 'gemma' 'en' 'fr'
      if ($test.Ok) {
        Note "test (en->fr): $($test.Text)"
        Note "that took $($test.Seconds) seconds, model loading included"
        if ((((Get-Cfg 'GEMMA_MODELS') -split ',') -ccontains 'translategemma:4b') -and ($model -cne 'translategemma:4b')) {
          Note 'if TranslateGemma proves too slow on this PC, the smaller translategemma:4b is installed too:'
          Note 'choose it in the Model list on the translation page, or add --model translategemma:4b to the helper'
        }
        $OLLAMA_OK = 'working'
      } else {
        $OLLAMA_OK = 'installed, but the test translation failed (see above)'
      }
    } else {
      $OLLAMA_OK = 'installed, but not answering yet. Open Ollama from the Start menu, then try the helper'
    }
  }

  Say 'Done'
  if (-not $DO_DOCKER) { $LT_OK = 'skipped' }
  if (-not $DO_OLLAMA) { $OLLAMA_OK = 'skipped' }
  if ($DO_WEB) { $WEB_OK = "$WEB_URL (open in a browser)" }
  elseif ($DO_DOCKER -and (Get-ToolOutput 'docker' @('container', 'inspect', '--format', '{{json .Config.Labels}}', $WEB_NAME)).Code -eq 0) {
    $WEB_OK = 'skipped; the one an earlier install started was left as it is'
  } else { $WEB_OK = 'skipped' }
  Write-Host ''
  Write-Host "  Translation page $WEB_OK"
  Write-Host "  LibreTranslate   $LT_OK"
  Write-Host "  Ollama           $OLLAMA_OK"
  Write-Host "  Helper           $(Join-Path $PREFIX 'translate.cmd') --help"
  Write-Host "  What's installed $(Join-Path $PREFIX 'MANIFEST.txt')"
  Write-Host "  How to use it    $(Join-Path $PREFIX 'README.txt')"
  if (-not $TEST_FILES) { $TEST_FILES = 'none in this bundle' }
  Write-Host "  Files to try     $TEST_FILES"
  if ($LOG) { Write-Host "  Log of this run  $LOG" }
  if ([System.IO.File]::Exists((Join-Path $PREFIX 'Start Translation.cmd'))) {
    Write-Host ''
    Write-Host '  After the PC restarts, double-click "Start Translation" in'
    Write-Host "  $PREFIX to start everything again."
  }
  if ($CLOSING.Count -gt 0) {
    Write-Host ''
    foreach ($line in $CLOSING) { Write-Host "  $line" }
  }
  if ($DO_WEB -and $DO_OPEN) { try { Start-Process -FilePath $WEB_URL } catch { } }
} catch {
  $exitCode = 1
  $failure = New-Object System.Collections.ArrayList
  if ($script:Died) { [void]$failure.Add("error: $($_.Exception.Message)") }
  else { [void]$failure.Add("error: $($_.Exception.Message)$([Environment]::NewLine)$($_.ScriptStackTrace)") }
  # What a failed run ends with, whatever stopped it.
  [void]$failure.Add('')
  [void]$failure.Add('==> The install did not finish')
  [void]$failure.Add("    It stopped at this step: $($script:Step)")
  [void]$failure.Add('    The lines just above say why.')
  [void]$failure.Add('    Nothing that was already on this PC has been harmed: no document and no')
  [void]$failure.Add('    translation was touched. It is safe to run the installer again.')
  if ($LOG) { [void]$failure.Add("    A record of this run is in: $LOG") }
  if ($SUPPORT) { [void]$failure.Add("    For help: $SUPPORT") }
  $text = $failure -join [Environment]::NewLine
  # The record is closed first, then given these lines directly: it does not
  # take in what is written to the error stream.
  if ($script:Transcribing) {
    $script:Transcribing = $false
    try { Stop-Transcript | Out-Null } catch { }
  }
  [Console]::Error.WriteLine($text)
  if ($LOG) { try { [System.IO.File]::AppendAllText($LOG, $text + [Environment]::NewLine) } catch { } }
}
if ($script:Transcribing) { try { Stop-Transcript | Out-Null } catch { } }
exit $exitCode
