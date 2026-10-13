# Checks that every script in this repository is encoded the way Windows PowerShell reads it.
#
# Windows PowerShell decodes a UTF-8 file WITHOUT a byte order mark as the local ANSI page, so
# any script containing Thai text silently turns into mojibake and stops parsing. This check
# exists because the whole tree once lost its BOMs and two modules stopped parsing.
#
# Run with:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Check-Encoding.ps1
#      fix:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\Check-Encoding.ps1 -Fix
param([switch]$Fix)
$root = Split-Path -Parent $PSScriptRoot
$utf8 = New-Object Text.UTF8Encoding($false)
$utf8Bom = New-Object Text.UTF8Encoding($true)
$bad = 0
$repaired = 0
$files = @(Get-ChildItem (Join-Path $root 'src') -Filter *.ps1) +
         @(Get-ChildItem $root -Filter *.ps1) +
         @(Get-ChildItem (Join-Path $root 'tests') -Filter *.ps1) +
         @(Get-ChildItem (Join-Path $root 'installer') -Filter *.ps1)
foreach ($f in $files) {
  $bytes = [IO.File]::ReadAllBytes($f.FullName)
  if ($bytes.Length -eq 0) { continue }
  $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
  # Decode exactly like Windows PowerShell: the BOM decides UTF-8 versus the local ANSI page.
  $text = if ($bom) { $utf8.GetString($bytes,3,$bytes.Length-3) } else { $utf8.GetString($bytes) }
  $ansiView = if ($bom) { $text } else { [Text.Encoding]::GetEncoding(1252).GetString($bytes) }
  $hasNonAscii = $false
  foreach ($ch in $text.ToCharArray()) { if ([int]$ch -gt 127) { $hasNonAscii = $true; break } }

  if ($hasNonAscii -and -not $bom) {
    if ($Fix) {
      [IO.File]::WriteAllBytes($f.FullName, $utf8Bom.GetPreamble() + $utf8.GetBytes($text))
      $repaired++
      Write-Host ("BOM restored: {0}" -f $f.FullName.Substring($root.Length+1))
      $ansiView = $text
    } else {
      $bad++
      Write-Host ("BOM MISSING but has non-ASCII text: {0}" -f $f.FullName.Substring($root.Length+1))
    }
  }

  # Parse it the way PowerShell would read it from disk.
  $tokens=$null; $errors=$null
  [void][Management.Automation.Language.Parser]::ParseInput($ansiView,[ref]$tokens,[ref]$errors)
  if (@($errors).Count -gt 0) {
    $bad++
    Write-Host ("PARSE FAIL {0} errors={1}" -f $f.Name, @($errors).Count)
    $errors | Select-Object -First 3 | ForEach-Object { Write-Host ("    line {0}: {1}" -f $_.Extent.StartLineNumber,$_.Message) }
  }
}
Write-Host ""
Write-Host ("scripts checked: {0}   problems: {1}   repaired: {2}" -f $files.Count, $bad, $repaired)
if ($bad -eq 0) { Write-Host "ALL SCRIPTS PARSE AND ARE CORRECTLY ENCODED"; exit 0 }
Write-Host "Run again with -Fix to restore missing byte order marks."
exit 1
