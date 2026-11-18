# Run an unmodified installer with temporary files and mocked system boundaries.
# This harness runs natively on Windows PowerShell 5.1 or PowerShell 7.
param([string]$Installer, [string]$ArgumentsFile)

$ErrorActionPreference = 'Stop'
$testRoot = $env:HOSHI_INSTALL_TEST_ROOT
$testSettings = Get-Content -Raw -LiteralPath (Join-Path $testRoot 'settings.json') | ConvertFrom-Json

function Test-Setting([string]$Key) {
  $prop = $testSettings.PSObject.Properties[$Key]
  if ($null -eq $prop) { return $false }
  return $prop.Value
}

function Write-TestCall([string]$Command, $Values) {
  $line = ConvertTo-Json -Compress -InputObject @{ command = $Command; arguments = @($Values) }
  [System.IO.File]::AppendAllText((Join-Path $testRoot 'calls.jsonl'), $line + "`n")
}

function docker {
  Write-TestCall 'docker' $args
  $global:LASTEXITCODE = 0
  $stateFile = Join-Path $testRoot 'state.json'
  $state = Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json
  if ($args[0] -eq 'info') {
    if (Test-Setting 'docker_down') { $global:LASTEXITCODE = 1; return }
    if (Test-Setting 'windows_containers') { 'windows/x86_64'; return }
    if (Test-Setting 'arm64') { 'linux/aarch64'; return }
    'linux/x86_64'
  } elseif ($args[0] -eq 'load') {
    if (Test-Setting 'load_fails') { $global:LASTEXITCODE = 1; return }
    if (-not [System.IO.File]::Exists($args[-1])) { throw 'test image missing' }
    'Loaded image'
  } elseif ($args[0] -eq 'image' -and $args[1] -eq 'inspect') {
    'sha256:test-loaded-image'
  } elseif ($args[0] -eq 'container' -and $args[1] -eq 'inspect') {
    if (-not $state.container -and -not (Test-Setting 'foreign_container')) { $global:LASTEXITCODE = 1; return }
    if (Test-Setting 'foreign_container') { '{"airgapped-translation":"0"}' }
    else { '{"airgapped-translation":"1"}' }
  } elseif ($args[0] -eq 'rm') {
    $state.container = $false
    [System.IO.File]::WriteAllText($stateFile, (ConvertTo-Json $state))
  } elseif ($args[0] -eq 'run') {
    if (Test-Setting 'run_fails') { $global:LASTEXITCODE = 1; return }
    $state.container = $true
    [System.IO.File]::WriteAllText($stateFile, (ConvertTo-Json $state))
    'test-container-id'
  } elseif ($args[0] -eq 'logs') {
    'test container log'
  } else { throw "unexpected docker arguments: $args" }
}

function robocopy {
  Write-TestCall 'robocopy' $args
  if (Test-Setting 'copy_fails') { $global:LASTEXITCODE = 8; return }
  $source = [string]$args[0]
  $target = [string]$args[1]
  foreach ($file in [System.IO.Directory]::GetFiles($source, '*', [System.IO.SearchOption]::AllDirectories)) {
    $relative = $file.Substring($source.Length).TrimStart('\', '/')
    $output = Join-Path $target $relative
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($output))
    [System.IO.File]::Copy($file, $output, $true)
  }
  $global:LASTEXITCODE = 1 # robocopy's success status when files were copied
}

function Get-AuthenticodeSignature {
  param([string]$LiteralPath)
  Write-TestCall 'signature' @($LiteralPath)
  return New-Object PSObject -Property @{ Status = 'Valid'; SignerCertificate = $null }
}

function Start-Process {
  param([string]$FilePath, $ArgumentList, [switch]$PassThru)
  Write-TestCall 'Start-Process' (@($FilePath) + @($ArgumentList))
  $code = 0
  if (Test-Setting 'setup_fails') { $code = 1 }
  elseif ($FilePath.EndsWith('OllamaSetup.exe')) {
    $installed = Join-Path $env:LOCALAPPDATA 'Programs\Ollama\ollama.exe'
    [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($installed))
    [System.IO.File]::Copy((Join-Path $testRoot 'fake-ollama.exe'), $installed, $true)
  }
  $process = New-Object PSObject -Property @{ Handle = 1; ExitCode = $code }
  $process | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { }
  if ($PassThru) { return $process }
}

function Start-Sleep { param($Seconds) }

# Test-Url still executes its real .NET request code. Its transport is replaced
# in this process so no network service or occupied listening port is needed.
Add-Type -IgnoreWarnings -TypeDefinition @'
using System;
using System.Net;
public sealed class HoshiTestResponse : WebResponse { public override void Close() { } }
public sealed class HoshiTestRequest : WebRequest {
    readonly Uri uri;
    public HoshiTestRequest(Uri value) { uri = value; }
    public override int Timeout { get; set; }
    public override IWebProxy Proxy { get; set; }
    public override WebResponse GetResponse() {
        string variable = uri.AbsolutePath == "/api/version" ? "HOSHI_TEST_OLLAMA_DOWN" : "HOSHI_TEST_LIBRE_DOWN";
        if (Environment.GetEnvironmentVariable(variable) == "1") throw new WebException("test service is down");
        return new HoshiTestResponse();
    }
}
public sealed class HoshiTestRequests : IWebRequestCreate {
    public WebRequest Create(Uri uri) { return new HoshiTestRequest(uri); }
}
'@
$null = [System.Net.WebRequest]::RegisterPrefix('http://127.0.0.1', (New-Object HoshiTestRequests))
$installerArguments = @(Get-Content -Raw -LiteralPath $ArgumentsFile | ConvertFrom-Json)
& $Installer @installerArguments
exit $LASTEXITCODE
