# Parse each PowerShell file named on the command line and report syntax
# errors. Run by tests/check.sh; needs PowerShell 7 or Windows PowerShell 5.1.
# It runs nothing in the files. Exit status: how many files failed to parse.
$bad = 0
foreach ($path in $args) {
  $tokens = $null
  $errors = $null
  [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $path).Path, [ref]$tokens, [ref]$errors)
  if ($errors.Count -gt 0) {
    $bad++
    foreach ($problem in $errors) {
      Write-Output "${path}:$($problem.Extent.StartLineNumber): $($problem.Message)"
    }
  }
}
exit $bad
