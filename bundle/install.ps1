# Install the offline translation bundle on an airgapped Windows PC.
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
$PREFIX = ''
$DO_VERIFY = $true
$DO_DOCKER = $true
$DO_OLLAMA = $true
$DO_LAUNCH = $true

# So the test translations, which have accents, are read back and shown intact.
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

function Show-Usage {
  @"
Usage: install.cmd [options]

  --port N         Local port for LibreTranslate (default: $PORT)
  --name NAME      Docker container name (default: $NAME)
  --prefix DIR     Where the translate helper goes (default: %USERPROFILE%\translation-tools)
  --skip-verify    Don't check the bundle's checksums first
  --no-docker      Skip LibreTranslate
  --no-ollama      Skip Ollama and its models
  --no-launch      Install Ollama but don't wait for it or test it
                   (its own installer still starts it)
  -h, --help       Show this help
"@
}

$script:Died = $false
function Say([string]$Message) { Write-Host ''; Write-Host "==> $Message" }
function Note([string]$Message) { Write-Host "    $Message" }
function Die([string]$Message) { $script:Died = $true; throw $Message }

function Get-Cfg([string]$Key) {
  foreach ($line in [System.IO.File]::ReadAllLines($ENVFILE)) {
    if ($line.StartsWith("$Key=")) { return $line.Substring($Key.Length + 1).Trim() }
  }
  return ''
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
  if (@('--port', '--name', '--prefix') -ccontains $arg) {
    if ($i + 1 -ge $ARGV.Length -or -not [string]$ARGV[$i + 1]) { $usageError = "$arg needs a value"; break }
    $i++
    $value = [string]$ARGV[$i]
  }
  if ($arg -ceq '--port') { $PORT = $value }
  elseif ($arg -ceq '--name') { $NAME = $value }
  elseif ($arg -ceq '--prefix') { $PREFIX = $value }
  elseif ($arg -ceq '--skip-verify') { $DO_VERIFY = $false }
  elseif ($arg -ceq '--no-docker') { $DO_DOCKER = $false }
  elseif ($arg -ceq '--no-ollama') { $DO_OLLAMA = $false }
  elseif ($arg -ceq '--no-launch') { $DO_LAUNCH = $false }
  elseif ($arg -ceq '-h' -or $arg -ceq '--help') { Show-Usage; exit 0 }
  else { $usageError = "unknown option: $arg" }
}
if (-not $usageError -and $PORT -notmatch '^[0-9]{1,5}$') { $usageError = "--port must be a number, not '$PORT'" }
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
    }
    if (Test-PortInUse ([int]$PORT)) { Die "port $PORT is already in use; pass --port with a free one" }

    Say "Starting LibreTranslate on $LT_URL"
    & docker run -d --name $NAME --label airgapped-translation=1 --pull never --restart unless-stopped -p "127.0.0.1:${PORT}:5000" $LOADED_ID | Out-Null
    if ($LASTEXITCODE -ne 0) { Die 'docker could not start the LibreTranslate container; see the message above' }
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
    $MODELS_DIR = $env:OLLAMA_MODELS
    if (-not $MODELS_DIR) { $MODELS_DIR = Join-Path $env:USERPROFILE '.ollama\models' }
    # robocopy reads a quoted path ending in a backslash as ending in a quote
    if ($MODELS_DIR.Length -gt 3) { $MODELS_DIR = $MODELS_DIR.TrimEnd('\') }
    Say "Copying models into $MODELS_DIR (several minutes)"
    # /FFT: an exFAT drive keeps times to 2 seconds, and without it every file
    # would look changed on a re-run. /XF: bookkeeping files a Mac leaves on
    # the drive, which Ollama would trip over.
    & robocopy (Join-Path $HERE 'ollama\models') $MODELS_DIR /E /FFT /R:2 /W:2 /NJH /NJS /NDL /NC /XF '._*' '.DS_Store'
    if ($LASTEXITCODE -ge 8) { Die "couldn't copy the models into $MODELS_DIR (robocopy code $LASTEXITCODE); see the messages above" }

    $BUNDLED_VERSION = Get-Cfg 'OLLAMA_VERSION'
    $OLLAMA_DIR = Join-Path $env:LOCALAPPDATA 'Programs\Ollama'
    $OLLAMA_EXE = Join-Path $OLLAMA_DIR 'ollama.exe'
    if (-not [System.IO.File]::Exists($OLLAMA_EXE)) {
      $onPath = Get-Command ollama.exe -ErrorAction SilentlyContinue
      if ($onPath) { $OLLAMA_EXE = $onPath.Source; $OLLAMA_DIR = Split-Path -Parent $OLLAMA_EXE }
    }
    if ([System.IO.File]::Exists($OLLAMA_EXE)) {
      $have = 'unknown'
      if ((Get-ToolOutput $OLLAMA_EXE @('--version')).Text -match '([0-9]+\.[0-9]+\.[0-9]+[^\s]*)\s*$') { $have = $Matches[1] }
      Say "Ollama is already in $OLLAMA_DIR (version $have); leaving it as it is"
      if ("v$have" -ne $BUNDLED_VERSION) {
        Note "the bundle carries $BUNDLED_VERSION. To switch: quit Ollama from the system tray, uninstall it in Settings > Apps, re-run."
      }
    } else {
      Say "Installing Ollama $BUNDLED_VERSION (no administrator rights needed)"
      if ([System.Environment]::OSVersion.Version.Build -lt 19045) {
        Note "Ollama asks for Windows 10 22H2 or newer; this PC is older (build $([System.Environment]::OSVersion.Version.Build)). Trying anyway."
      }
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

  # ------------------------------------------------------------ helper script
  Say "Installing the translate helper into $PREFIX"
  [void][System.IO.Directory]::CreateDirectory($PREFIX)
  # not $name: PowerShell names ignore case, so that is $NAME
  foreach ($file in @('translate.ps1', 'translate.cmd', 'languages.tsv', 'bundle.env', 'MANIFEST.txt', 'README.txt')) {
    [System.IO.File]::Copy((Join-Path $HERE $file), (Join-Path $PREFIX $file), $true)
  }
  # A copy to practise on, so translations of it aren't written into the bundle.
  $TEST_FILES = ''
  $testSource = Join-Path $HERE 'test-files'
  if ([System.IO.Directory]::Exists($testSource)) {
    $TEST_FILES = Join-Path $PREFIX 'test-files'
    [void][System.IO.Directory]::CreateDirectory($TEST_FILES)
    foreach ($testFile in [System.IO.Directory]::GetFiles($testSource)) {
      [System.IO.File]::Copy($testFile, (Join-Path $TEST_FILES ([System.IO.Path]::GetFileName($testFile))), $true)
    }
  }
  # Remember non-default settings so the helper finds the services.
  $settings = "LT_URL=$LT_URL`nLT_CONTAINER=$NAME`n"
  if ($DO_DOCKER) { $settings += "LT_IMAGE=$IMAGE`nLT_IMAGE_ID_INSTALLED=$LOADED_ID`n" }
  [System.IO.File]::AppendAllText((Join-Path $PREFIX 'bundle.env'), $settings)

  # ------------------------------------------------------------ launch + test
  $LT_OK = 'not checked'
  if ($DO_DOCKER) {
    $pair = Get-Cfg 'LT_SELFTEST_PAIR'
    $from = $pair.Split(':')[0]
    $to = $pair.Split(':')[1]
    $test = Invoke-TestTranslation 'libre' $from $to
    if (-not $test.Ok) { Die 'LibreTranslate is up but the test translation failed' }
    Note "LibreTranslate test ($from->$to): $($test.Text)"
    $LT_OK = "$LT_URL (open in a browser)"
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
  Write-Host ''
  Write-Host "  LibreTranslate   $LT_OK"
  Write-Host "  Ollama           $OLLAMA_OK"
  Write-Host "  Helper           $(Join-Path $PREFIX 'translate.cmd') --help"
  Write-Host "  What's installed $(Join-Path $PREFIX 'MANIFEST.txt')"
  Write-Host "  How to use it    $(Join-Path $PREFIX 'README.txt')"
  if (-not $TEST_FILES) { $TEST_FILES = 'none in this bundle' }
  Write-Host "  Files to try     $TEST_FILES"
} catch {
  $exitCode = 1
  if ($script:Died) { [Console]::Error.WriteLine("error: $($_.Exception.Message)") }
  else { [Console]::Error.WriteLine("error: $($_.Exception.Message)$([Environment]::NewLine)$($_.ScriptStackTrace)") }
}
exit $exitCode
