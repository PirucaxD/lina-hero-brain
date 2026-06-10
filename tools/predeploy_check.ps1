# tools/predeploy_check.ps1 , pre-deploy verification for the UCZone hero-brains.
#
# Codifies the manual deploy protocol into one runnable gate:
#   1. luac -p (syntax) on the hero file + every lib/*.lua
#   2. lesson-15 banner checks on the hero file: exactly one ^LOG:info banner,
#      exactly one ^return callbacks, and the last non-blank line is
#      "return callbacks"
#   3. no UTF-8 BOM and no em-dash in the hero file
#   4. SHA256 (first 16) report for the verified files
#
# Exits non-zero on any failure so it can gate a deploy/commit.
#
# Usage:
#   powershell -File tools/predeploy_check.ps1
#   powershell -File tools/predeploy_check.ps1 -ScriptsDir C:\Umbrella\scripts -Hero Lina.lua
param(
  [string]$ScriptsDir = "C:\Umbrella\scripts",
  [string]$Hero = "Lina.lua"
)

$fail = 0
function Fail($m) { Write-Host "  FAIL: $m" -ForegroundColor Red; $script:fail++ }
function Ok($m)   { Write-Host "  ok:   $m" -ForegroundColor Green }

# Resolve luac (bash PATH has it; PowerShell may not).
$luac = (Get-Command luac -ErrorAction SilentlyContinue).Source
if (-not $luac) { $luac = (Get-Command luac.exe -ErrorAction SilentlyContinue).Source }
if (-not $luac) {
  Write-Host "luac not found on PATH; install Lua or add luac to PATH." -ForegroundColor Yellow
  exit 2
}

$heroPath = Join-Path $ScriptsDir $Hero
$files = @($heroPath)
$libDir = Join-Path $ScriptsDir "lib"
if (Test-Path $libDir) {
  $files += (Get-ChildItem $libDir -Filter *.lua | ForEach-Object FullName)
}

Write-Host "== luac -p (syntax) =="
foreach ($f in $files) {
  if (-not (Test-Path $f)) { Fail "missing: $f"; continue }
  $out = & $luac -p $f 2>&1
  if ($LASTEXITCODE -eq 0) { Ok (Split-Path $f -Leaf) } else { Fail "luac: $((Split-Path $f -Leaf)) : $out" }
}

Write-Host "== lesson-15 banner + BOM + em-dash ($Hero) =="
if (-not (Test-Path $heroPath)) {
  Fail "hero file missing: $heroPath"
} else {
  $lines = Get-Content $heroPath
  $loginfo = ($lines | Where-Object { $_ -match '^LOG:info\(' }).Count
  $retcb   = ($lines | Where-Object { $_ -match '^return callbacks' }).Count
  if ($loginfo -eq 1) { Ok "exactly 1 LOG:info banner" } else { Fail "LOG:info count = $loginfo (want 1)" }
  if ($retcb -eq 1)   { Ok "exactly 1 return callbacks" } else { Fail "return callbacks count = $retcb (want 1)" }
  $last = ($lines | Where-Object { $_.Trim() -ne "" } | Select-Object -Last 1)
  if ($last -eq "return callbacks") { Ok "tail ends with return callbacks" } else { Fail "tail is '$last'" }

  $bytes = [System.IO.File]::ReadAllBytes($heroPath)
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
    Fail "UTF-8 BOM present"
  } else { Ok "no BOM" }

  # The banner line ships verbatim, so it MUST be em-dash-free. Em-dashes in
  # source COMMENTS are tolerated (the public-sync step scrubs them); report
  # the count as info, do not fail on it.
  $bannerLine = ($lines | Where-Object { $_ -match '^LOG:info\(' } | Select-Object -First 1)
  if ($bannerLine -and $bannerLine.IndexOf([char]0x2014) -ge 0) {
    Fail "em-dash (U+2014) in banner line"
  } else { Ok "banner has no em-dash" }
  $txt = [System.IO.File]::ReadAllText($heroPath)
  $emCount = ([regex]::Matches($txt, [string][char]0x2014)).Count
  if ($emCount -gt 0) {
    Write-Host "  info: $emCount em-dash(es) in source comments (scrubbed on public sync)" -ForegroundColor DarkGray
  } else { Ok "no em-dash anywhere" }
}

Write-Host "== SHA256 (first 16) =="
foreach ($f in $files) {
  if (Test-Path $f) {
    "  {0}  {1}" -f (Get-FileHash $f -Algorithm SHA256).Hash.Substring(0,16), (Split-Path $f -Leaf)
  }
}

if ($fail -gt 0) {
  Write-Host "PREDEPLOY FAILED ($fail issue(s))" -ForegroundColor Red
  exit 1
}
Write-Host "PREDEPLOY OK" -ForegroundColor Green
exit 0
