# Start the offline translation services on a Windows PC after a restart, or
# whenever the translation page doesn't answer. Run through "Start
# Translation.cmd", which the installer puts beside the translate helper.
#
# Opens Docker Desktop and Ollama if they aren't running, waits for
# LibreTranslate, TranslateGemma and the translation page, and opens the page.
# It installs nothing and changes nothing: it reads the settings the install
# left in bundle.env beside it.
#
# Kept to ASCII and to PowerShell 5.1 syntax on purpose; translate.ps1 says why.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$HERE = Split-Path -Parent $MyInvocation.MyCommand.Path
$ENVFILE = Join-Path $HERE 'bundle.env'

function Say([string]$Message) { Write-Host ''; Write-Host "==> $Message" }
function Note([string]$Message) { Write-Host "    $Message" }

function Get-Cfg([string]$Key) {
  if (-not [System.IO.File]::Exists($ENVFILE)) { return '' }
  foreach ($line in [System.IO.File]::ReadAllLines($ENVFILE)) {
    if ($line.StartsWith("$Key=")) { return $line.Substring($Key.Length + 1).Trim() }
  }
  return ''
}

# As in install.ps1: Windows PowerShell 5.1 turns anything a program prints on
# stderr into a terminating error under 'Stop' once stderr is redirected.
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

$script:HaveDocker = [bool](Get-Command docker -ErrorAction SilentlyContinue)
function Test-Docker {
  if (-not $script:HaveDocker) { return $false }
  return ((Get-ToolOutput 'docker' @('info', '--format', '{{.OSType}}')).Code -eq 0)
}

$exitCode = 0
try {
  $LT_URL = Get-Cfg 'LT_URL'
  if (-not $LT_URL) {
    Write-Host "Offline translation isn't installed from this folder yet."
    Write-Host 'Run the installer first (double-click install.cmd in the bundle folder).'
    Write-Host 'It puts a copy of this file in the translation-tools folder in your user'
    Write-Host 'folder: that copy is the one to double-click after a restart.'
    exit 1
  }
  $WEB_URL = Get-Cfg 'WEB_URL'
  $LT_CONTAINER = Get-Cfg 'LT_CONTAINER'
  if (-not $LT_CONTAINER) { $LT_CONTAINER = 'libretranslate' }
  $WEB_CONTAINER = Get-Cfg 'WEB_CONTAINER'
  if (-not $WEB_CONTAINER) { $WEB_CONTAINER = 'translation-web' }
  $OLLAMA_EXE = Get-Cfg 'OLLAMA_APP'
  $SUPPORT = Get-Cfg 'SUPPORT'
  $wantDocker = [bool](Get-Cfg 'LT_IMAGE_ID_INSTALLED')
  if (-not $env:OLLAMA_HOST) { $OLLAMA_API = 'http://127.0.0.1:11434' }
  elseif ($env:OLLAMA_HOST -match '^https?://') { $OLLAMA_API = $env:OLLAMA_HOST }
  else { $OLLAMA_API = "http://$($env:OLLAMA_HOST)" }

  Say 'Starting offline translation'

  # Both apps are opened first and waited for afterwards, so they start together.
  $dockerReady = $true
  if ($wantDocker -and -not (Test-Docker)) {
    $dockerReady = $false
    $dockerApp = Join-Path $env:ProgramFiles 'Docker\Docker\Docker Desktop.exe'
    if ([System.IO.File]::Exists($dockerApp)) {
      Note 'opening Docker Desktop'
      try { Start-Process -FilePath $dockerApp } catch { Note "Windows couldn't open Docker Desktop" }
    } else {
      Note "Docker Desktop isn't in its usual place; open it from the Start menu"
    }
  }
  if ($OLLAMA_EXE -and -not (Test-Url "$OLLAMA_API/api/version")) {
    $ollamaApp = Join-Path (Split-Path -Parent $OLLAMA_EXE) 'ollama app.exe'
    if ([System.IO.File]::Exists($ollamaApp)) {
      Note 'opening Ollama'
      try { Start-Process -FilePath $ollamaApp } catch { Note "Windows couldn't open Ollama" }
    }
  }

  $libre = ''
  $gemma = ''
  $page = ''
  $advice = New-Object System.Collections.ArrayList
  if ($wantDocker) {
    if (-not $dockerReady) {
      Note 'waiting for Docker Desktop (up to 5 minutes)'
      for ($n = 0; $n -lt 150 -and -not $dockerReady; $n++) {
        # A window opened before Docker was installed can't find its command;
        # LibreTranslate answering shows Docker is up all the same.
        if ((Test-Docker) -or (Test-Url "$LT_URL/languages")) { $dockerReady = $true } else { Start-Sleep -Seconds 2 }
      }
    }
    if ($dockerReady) {
      # They start with Docker by themselves, unless someone stopped them by hand.
      if ($script:HaveDocker) {
        [void](Get-ToolOutput 'docker' @('start', $LT_CONTAINER))
        if ($WEB_URL) { [void](Get-ToolOutput 'docker' @('start', $WEB_CONTAINER)) }
      }
      Note 'waiting for LibreTranslate (it takes a minute or two to load its languages)'
      if (Wait-Url "$LT_URL/languages" 150 2) {
        $libre = 'ready'
      } else {
        $libre = 'NOT answering'
        [void]$advice.Add("LibreTranslate: Docker is running but LibreTranslate didn't answer on $LT_URL.")
        [void]$advice.Add("  Open Docker Desktop, look under Containers for '$LT_CONTAINER', and press its start button.")
      }
      if ($WEB_URL) {
        if (Wait-Url "$WEB_URL/api/config" 30 2) {
          $page = 'ready'
        } else {
          $page = 'NOT answering'
          [void]$advice.Add("The translation page: Docker is running but the page didn't answer on $WEB_URL.")
          [void]$advice.Add("  Open Docker Desktop, look under Containers for '$WEB_CONTAINER', and press its start button.")
        }
      }
    } else {
      $libre = 'NOT answering'
      if ($WEB_URL) { $page = 'NOT answering' }
      [void]$advice.Add("LibreTranslate and the translation page run inside Docker Desktop, which didn't become ready.")
      [void]$advice.Add('  Open Docker Desktop from the Start menu, answer anything it asks (skip signing in and')
      [void]$advice.Add('  updates), wait until it says it is running, then double-click this again.')
    }
  }
  if ($OLLAMA_EXE) {
    if (Wait-Url "$OLLAMA_API/api/version" 30 2) {
      $gemma = 'ready'
    } else {
      $gemma = 'NOT answering'
      [void]$advice.Add("TranslateGemma: Ollama, which runs it, didn't answer.")
      [void]$advice.Add('  Open Ollama from the Start menu, finish anything it asks, then double-click this again.')
    }
  }

  Write-Host ''
  if ($page) { Write-Host "  Translation page  $page  $WEB_URL" }
  if ($libre) { Write-Host "  LibreTranslate    $libre" }
  if ($gemma) { Write-Host "  TranslateGemma    $gemma" }

  # The page is worth opening with one engine down: it says which, and the other works.
  $openUrl = ''
  if ($page -eq 'ready') { $openUrl = $WEB_URL }
  elseif (-not $WEB_URL -and $libre -eq 'ready') { $openUrl = $LT_URL } # an install made with --no-web
  if ($openUrl) {
    try { Start-Process -FilePath $openUrl } catch { }
    Write-Host ''
    Write-Host "  Opened $openUrl in your browser."
  }
  if ($advice.Count -eq 0) {
    if (-not $openUrl) { Write-Host ''; Write-Host "  Ready. Use $(Join-Path $HERE 'translate.cmd')" }
  } else {
    $exitCode = 1
    Write-Host ''
    Write-Host 'Not everything started:'
    foreach ($line in $advice) { Write-Host "  $line" }
    if ($SUPPORT) { Write-Host ''; Write-Host "  For help: $SUPPORT" }
  }
} catch {
  $exitCode = 1
  [Console]::Error.WriteLine("error: $($_.Exception.Message)")
}
exit $exitCode
