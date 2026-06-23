# Report-Toolset.ps1 — emit '@@@TOOL <category> <name> <version|MISSING>' for the installed image.
# Pure reporter: facts only, no verdict. Consumed by lib/toolset_parity.py on the host. Run over
# WinRM via winrm_run.py run mode, which preloads the machine PATH so freshly-installed tools resolve.
$ErrorActionPreference = 'Continue'

function Emit($cat, $name, $ver) {
  if ($ver) { Write-Host "@@@TOOL $cat $name $ver" } else { Write-Host "@@@TOOL $cat $name MISSING" }
}
function Ver([string] $text) { if ($text -match '(\d+\.\d+(\.\d+)*)') { return $Matches[1] } else { return '' } }

# toolcache: one line per installed version directory
$tc = 'C:\hostedtoolcache\windows'
foreach ($name in 'Ruby', 'Python', 'PyPy', 'node', 'go') {
  $dir = Join-Path $tc $name
  $vers = if (Test-Path $dir) { Get-ChildItem $dir -Directory -EA SilentlyContinue | ForEach-Object { $_.Name } } else { @() }
  if ($vers) { foreach ($v in $vers) { Emit 'toolcache' $name $v } } else { Emit 'toolcache' $name '' }
}

# dotnet SDKs (one line per installed SDK)
$sdks = & dotnet --list-sdks 2>$null
if ($sdks) { foreach ($l in $sdks) { $v = Ver $l; if ($v) { Emit 'dotnet' 'sdk' $v } } } else { Emit 'dotnet' 'sdk' '' }

# node (default on PATH)
Emit 'node' 'node' (Ver ((& node --version 2>$null) | Out-String))

# java majors via JAVA_HOME_<major>_X64 machine env vars
foreach ($m in 8, 11, 17, 21, 25) {
  $h = [Environment]::GetEnvironmentVariable("JAVA_HOME_${m}_X64", 'Machine')
  if ($h -and (Test-Path $h)) { Emit 'java' "$m" "$m" } else { Emit 'java' "$m" '' }
}

# scalar PATH tools: category -> version command
$probes = [ordered]@{
  php     = { & php --version 2>$null | Out-String }
  mongodb = { & mongod --version 2>$null | Out-String }
  mysql   = { & mysql --version 2>$null | Out-String }
  llvm    = { & clang --version 2>$null | Out-String }
  kotlin  = { & kotlinc -version 2>&1 | Out-String }
  openssl = { & openssl version 2>$null | Out-String }
  maven   = { & mvn --version 2>$null | Out-String }
  pwsh    = { & pwsh --version 2>$null | Out-String }
}
foreach ($cat in $probes.Keys) { Emit $cat $cat (Ver (& $probes[$cat])) }

# postgresql: install-dir major (no PATH binary by default)
$pg = Get-ChildItem 'C:\Program Files\PostgreSQL' -Directory -EA SilentlyContinue | Select-Object -First 1
Emit 'postgresql' 'postgresql' $(if ($pg) { $pg.Name } else { '' })

# nsis: makensis /VERSION
$nsis = 'C:\Program Files (x86)\NSIS\makensis.exe'
Emit 'nsis' 'nsis' $(if (Test-Path $nsis) { Ver ((& $nsis '/VERSION') 2>$null | Out-String) } else { '' })

Write-Host '@@@REPORT-DONE'
