# Start the translation web page on a Windows PC where the offline translation
# bundle is installed. The bundle's install.ps1 runs this as its last step; it
# is also run through install-web.cmd from a page update, the small folder
# build-web-patch.sh makes.
#
# The page runs in a second container made from the LibreTranslate image that
# is already in Docker, with the files in web\ handed to it from the PC. So
# this needs nothing large: no image, no models. Safe to re-run: it replaces
# the page's files and its container, and never touches a translation or the
# LibreTranslate container.
#
# Kept to ASCII and to PowerShell 5.1 syntax on purpose; translate.ps1 says why.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path
$ARGV = @($args)

$PORT = '5080' # the same as on a Mac
$NAME = 'translation-web'
$PREFIX = ''
$FOLDER = ''
$DO_VERIFY = $true
$DO_OPEN = $true
$STANDALONE = $true

function Show-Usage {
  @"
Usage: install-web.cmd [options]

  --port N         Local port for the page (default: $PORT)
  --name NAME      Docker container name (default: $NAME)
  --prefix DIR     Where the bundle's installer put translate.cmd (default: %USERPROFILE%\translation-tools)
  --folder DIR     Where the page saves translations (default: PREFIX\translations)
  --skip-verify    Don't check the files' checksums first
  --no-open        Don't open the page in a browser at the end
  --part-of-install
                   Leave the closing summary and the opening of the page to
                   install.ps1, which passes this
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
# install.ps1 says why the error preference is relaxed for the call.
function Get-ToolOutput([string]$Exe, [string[]]$Arguments) {
  $ErrorActionPreference = 'Continue'
  $lines = @(& $Exe @Arguments 2>$null | ForEach-Object { "$_" })
  return @{ Code = $LASTEXITCODE; Text = ($lines -join "`n").Trim() }
}

# What a local address answers with, or '' if it doesn't answer.
function Get-UrlText([string]$Url) {
  try {
    $request = [System.Net.WebRequest]::Create($Url)
    $request.Proxy = $null
    $request.Timeout = 30000
    $response = $request.GetResponse()
    try {
      $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
      return $reader.ReadToEnd()
    } finally {
      $response.Close()
    }
  } catch {
    return ''
  }
}

function Test-PortInUse([int]$Number) {
  $client = New-Object System.Net.Sockets.TcpClient
  try { $client.Connect('127.0.0.1', $Number); return $true } catch { return $false } finally { $client.Close() }
}

# The port an address ends with, as the page's container needs only that.
function Get-Port([string]$Address, [string]$Default) {
  if ($Address -match ':([0-9]{1,5})/?$') { return $Matches[1] }
  return $Default
}

# ------------------------------------------------------------------ arguments
$usageError = ''
for ($i = 0; $i -lt $ARGV.Length -and -not $usageError; $i++) {
  $arg = [string]$ARGV[$i]
  $value = ''
  if (@('--port', '--name', '--prefix', '--folder') -ccontains $arg) {
    if ($i + 1 -ge $ARGV.Length -or -not [string]$ARGV[$i + 1]) { $usageError = "$arg needs a value"; break }
    $i++
    $value = [string]$ARGV[$i]
  }
  if ($arg -ceq '--port') { $PORT = $value }
  elseif ($arg -ceq '--name') { $NAME = $value }
  elseif ($arg -ceq '--prefix') { $PREFIX = $value }
  elseif ($arg -ceq '--folder') { $FOLDER = $value }
  elseif ($arg -ceq '--skip-verify') { $DO_VERIFY = $false }
  elseif ($arg -ceq '--no-open') { $DO_OPEN = $false }
  elseif ($arg -ceq '--part-of-install') { $STANDALONE = $false; $DO_OPEN = $false }
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
    Die 'this installer is for Windows. On a Mac, run install-web.sh instead.'
  }
  if (-not [System.IO.File]::Exists((Join-Path $HERE 'web\app.py'))) {
    Die 'web\app.py not found; run this from inside the folder it came in'
  }
  if (-not $PREFIX) { $PREFIX = Join-Path $env:USERPROFILE 'translation-tools' }
  $PREFIX = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PREFIX)
  $ENVFILE = Join-Path $PREFIX 'bundle.env'
  if (-not [System.IO.File]::Exists($ENVFILE)) {
    Die "the offline translation bundle isn't installed in $PREFIX. Run the bundle's install.cmd first, or pass --prefix."
  }
  if (-not $FOLDER) { $FOLDER = Join-Path $PREFIX 'translations' }
  $FOLDER = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FOLDER)

  $BUILD = 'not recorded'
  $buildFile = Join-Path $HERE 'web\BUILD'
  if ([System.IO.File]::Exists($buildFile)) { $BUILD = [System.IO.File]::ReadAllText($buildFile).Trim() }
  if ($STANDALONE) {
    Say 'Translation web page installer'
    $options = 'none'
    if ($ARGV.Length -gt 0) { $options = $ARGV -join ' ' }
    Note "started $([DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')), options: $options"
    Note "page files: $BUILD"
  } else {
    Say 'Installing the translation page'
    Note "page files: $BUILD"
  }

  $IMAGE = Get-Cfg 'LT_IMAGE'
  $IMAGE_ID = Get-Cfg 'LT_IMAGE_ID_INSTALLED'
  $LT_CONTAINER = Get-Cfg 'LT_CONTAINER'
  if (-not $LT_CONTAINER) { $LT_CONTAINER = 'libretranslate' }
  $LT_URL = Get-Cfg 'LT_URL'
  if (-not $IMAGE -or -not $LT_URL) {
    Die "$ENVFILE doesn't say which LibreTranslate image is installed. The page needs it: re-run the bundle's install.cmd without --no-docker."
  }
  if ($IMAGE_ID -notmatch '^sha256:.') {
    Die "$ENVFILE has no installed image ID. Re-run the bundle's install.cmd without --no-docker before installing the page."
  }
  $URL = "http://127.0.0.1:$PORT"

  # ---------------------------------------------------------------- checksums
  if ($DO_VERIFY) {
    Say "Verifying the page's files"
    $sums = Join-Path $HERE 'SHA256SUMS'
    if (-not [System.IO.File]::Exists($sums)) { Die 'SHA256SUMS not found beside this script; pass --skip-verify to install anyway' }
    $failed = New-Object System.Collections.ArrayList
    $listed = @{}
    foreach ($line in [System.IO.File]::ReadAllLines($sums)) {
      if ($line -notmatch '^([0-9a-f]{64})  \./(web/.+)$') { continue }
      $want = $Matches[1]
      $rel = $Matches[2]
      $listed[$rel] = $true
      $path = Join-Path $HERE $rel.Replace('/', '\')
      if (-not [System.IO.File]::Exists($path)) { [void]$failed.Add("$rel (missing)"); continue }
      if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $want) { [void]$failed.Add($rel) }
    }
    if (-not $listed.ContainsKey('web/app.py')) { Die "SHA256SUMS doesn't list the page's files" }
    if ($failed.Count -gt 0) {
      foreach ($item in $failed) { Note "FAILED: $item" }
      Die 'checksum verification failed: the files were damaged or changed in transit'
    }
    Note 'all files match SHA256SUMS'
  }

  # ------------------------------------------------------------------- Docker
  if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Die "the docker command wasn't found. Run the bundle's install.cmd first."
  }
  $info = Get-ToolOutput 'docker' @('info', '--format', '{{.OSType}}/{{.Architecture}}')
  if ($info.Code -ne 0) { Die "Docker isn't running. Start Docker Desktop, wait until it says it is running, and re-run." }
  if ($info.Text -match '^windows/') {
    Die "Docker Desktop is set to Windows containers. Right-click the Docker whale in the system tray, choose 'Switch to Linux containers', and re-run."
  }
  # A build can move the tag to an image with other language models. Use the
  # installed ID even if its tag has moved or disappeared; never fall back to it.
  if ((Get-ToolOutput 'docker' @('image', 'inspect', '--format', '{{.Id}}', $IMAGE_ID)).Code -ne 0) {
    Die "Docker here has no image with the installed ID $IMAGE_ID ($IMAGE). Re-run the bundle's install.cmd first."
  }
  $service = Get-ToolOutput 'docker' @('container', 'inspect', '--format', '{{.Image}}', $LT_CONTAINER)
  if ($service.Code -eq 0 -and $service.Text -and $service.Text -ne $IMAGE_ID) {
    Die "LibreTranslate container '$LT_CONTAINER' uses a different image ($($service.Text)) from the installed ID ($IMAGE_ID). Re-run the bundle's install.cmd, then install the page again."
  }

  $existing = Get-ToolOutput 'docker' @('container', 'inspect', '--format', '{{json .Config.Labels}}', $NAME)
  if ($existing.Code -eq 0) {
    $ours = $false
    try { $ours = (($existing.Text | ConvertFrom-Json).PSObject.Properties['airgapped-translation'].Value -eq '1') } catch { }
    if (-not $ours) { Die "a container named '$NAME' exists that this installer didn't create; remove it or pass --name" }
    Note "replacing the '$NAME' container from an earlier install"
    & docker rm -f $NAME | Out-Null
    if ($LASTEXITCODE -ne 0) {
      Die "Docker couldn't remove the '$NAME' container from the earlier install; its message is above. Quit Docker Desktop, open it again, wait until it says it is running, then run this again."
    }
  }
  if (Test-PortInUse ([int]$PORT)) { Die "port $PORT is already in use; pass --port with a free one" }

  # ---------------------------------------------------------------- the files
  $WEB = Join-Path $PREFIX 'web'
  $source = Join-Path $HERE 'web'
  if ($source.TrimEnd('\') -ne $WEB.TrimEnd('\')) {
    Say "Copying the page into $WEB"
    foreach ($file in [System.IO.Directory]::GetFiles($source, '*', [System.IO.SearchOption]::AllDirectories)) {
      $leaf = [System.IO.Path]::GetFileName($file)
      # bookkeeping files a Mac leaves on the drive
      if ($leaf.StartsWith('._') -or $leaf -eq '.DS_Store') { continue }
      $target = Join-Path $WEB $file.Substring($source.Length).TrimStart('\')
      [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target))
      [System.IO.File]::Copy($file, $target, $true)
    }
  }
  [void][System.IO.Directory]::CreateDirectory($FOLDER)

  # ---------------------------------------------------------------- container
  # The page's files and the language list are handed over read-only; the only
  # place on the PC it can write is the translations folder. Documents being
  # translated are held in memory (/uploads), not on disk. Like LibreTranslate,
  # it answers on this PC only.
  Say "Starting the page on $URL"
  $run = @('run', '-d', '--name', $NAME, '--label', 'airgapped-translation=1',
    '--pull', 'never',
    '--restart', 'unless-stopped', '-p', "127.0.0.1:${PORT}:8080",
    '-v', "${WEB}:/opt/translation-web:ro",
    '-v', "$(Join-Path $PREFIX 'languages.tsv'):/opt/languages.tsv:ro",
    '-v', "${FOLDER}:/data",
    '--tmpfs', '/uploads:rw,mode=1777',
    '-e', 'PYTHONDONTWRITEBYTECODE=1',
    '-e', 'LANGFILE=/opt/languages.tsv',
    '-e', 'DATA_DIR=/data', '-e', "HOST_DATA_DIR=$FOLDER", '-e', 'UPLOAD_DIR=/uploads',
    '-e', 'HOST_OS=windows',
    '-e', "LT_URL=http://host.docker.internal:$(Get-Port $LT_URL '5050')",
    '-e', "OLLAMA_API=http://host.docker.internal:$(Get-Port ([string]$env:OLLAMA_HOST) '11434')",
    '-e', "LT_IMAGE=$IMAGE", '-e', "LT_IMAGE_ID=$IMAGE_ID",
    '-e', "GEMMA_MODELS=$(Get-Cfg 'GEMMA_MODELS')", '-e', "DEFAULT_MODEL=$(Get-Cfg 'DEFAULT_MODEL')",
    '--entrypoint', '/app/venv/bin/python', $IMAGE_ID, '-u', '/opt/translation-web/app.py')
  & docker @run | Out-Null
  if ($LASTEXITCODE -ne 0) { Die 'docker could not start the page; see the message above' }

  $config = ''
  for ($n = 0; $n -lt 30 -and -not $config; $n++) {
    $config = Get-UrlText "$URL/api/config"
    if (-not $config) { Start-Sleep -Seconds 1 }
  }
  if (-not $config) {
    & docker logs --tail 30 $NAME
    Die 'the page did not start; log above'
  }
  # Where the page is, for "Start Translation" to find after a restart.
  $kept = @([System.IO.File]::ReadAllLines($ENVFILE) | Where-Object { $_ -notmatch '^(WEB_URL|WEB_CONTAINER)=' })
  [System.IO.File]::WriteAllText($ENVFILE, (($kept + @("WEB_URL=$URL", "WEB_CONTAINER=$NAME")) -join "`n") + "`n")

  if ($STANDALONE) {
    $states = @{}
    foreach ($engine in @('gemma', 'libre')) { # whether the page can reach it
      $ok = $false
      try { $ok = [bool]($config | ConvertFrom-Json).$engine.ok } catch { }
      if ($ok) { $states[$engine] = 'ready' }
      else { $states[$engine] = 'NOT answering. The page will say so; start it and reload the page' }
    }

    Say 'Done'
    Write-Host ''
    Write-Host "  Translation page  $URL"
    Write-Host "  TranslateGemma    $($states['gemma'])"
    Write-Host "  LibreTranslate    $($states['libre'])"
    Write-Host "  Translations in   $FOLDER"
    Write-Host ''
    Write-Host "  The page starts with Docker Desktop. To remove it:  docker rm -f $NAME"
    if ($DO_OPEN) { try { Start-Process -FilePath $URL } catch { } }
  }
} catch {
  $exitCode = 1
  if ($script:Died) { [Console]::Error.WriteLine("error: $($_.Exception.Message)") }
  else { [Console]::Error.WriteLine("error: $($_.Exception.Message)$([Environment]::NewLine)$($_.ScriptStackTrace)") }
}
exit $exitCode
