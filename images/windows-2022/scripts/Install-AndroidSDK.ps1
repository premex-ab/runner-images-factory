################################################################################
##  File:  Install-AndroidSDK.ps1
##  Desc:  runner-images-factory OVERRIDE of the upstream script (issue #14).
##
##  Upstream installs every SDK package by shelling out to sdkmanager.bat, which
##  launches a JVM. The JVM's Parallel GC sizes its mark bitmaps to the host CPU
##  count and fails to allocate them AT STARTUP on a high-vCPU build VM:
##    "Unable to allocate <N>KB bitmaps for parallel garbage collection ..."
##  (capping -Xmx does not help -- it's GC-structure allocation, not heap).
##
##  This override installs the SAME package set the toolset manifest specifies, but
##  via Google's JVM-free `android` CLI (https://developer.android.com/tools/agents),
##  so the GC failure cannot occur. It sets the same machine env vars the upstream
##  script does (ANDROID_HOME / ANDROID_SDK_ROOT / ANDROID_NDK*). Package ids use the
##  CLI's slash form (platforms/android-34, build-tools/34.0.0, ndk/<ver>, cmake/<ver>,
##  extras/google/...) vs sdkmanager's semicolon form.
##
##  Set RIF_ANDROID_DRYRUN=1 to print the resolved package set + env paths and exit
##  without downloading (used to validate resolution via the checkpoint loop).
################################################################################

$ErrorActionPreference = 'Continue'   # native CLI writes progress/notices to stderr; we gate on $LASTEXITCODE
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# android.exe bundles a JVM; on a high-vCPU / large-RAM build VM its default heap (~1/4 RAM) +
# parallel-GC structures (sized to the CPU count) fail to allocate -> System.OutOfMemoryException /
# "paging file too small". Cap the heap and force SerialGC (no per-CPU GC structures) for every JVM
# android.exe spawns. (This is the same class of fix the upstream sdkmanager path needed.)
$env:JAVA_TOOL_OPTIONS = '-XX:+UseSerialGC -Xmx2g -XX:MaxMetaspaceSize=512m'   # bound native metaspace too (#32: the OOM was a native "Failed to commit metaspace", not heap)

$sdkRoot = 'C:\Android\android-sdk'
$cliDir  = 'C:\Android\cli'
$cli     = "$cliDir\android.exe"
New-Item -ItemType Directory -Force -Path $sdkRoot, $cliDir | Out-Null

# Package parameters from the toolset manifest (tracks the pinned ri_ref).
$android = (Get-Content (Join-Path $env:IMAGE_FOLDER 'toolset.json') -Raw | ConvertFrom-Json).android

# --- download the android CLI: direct binary, no winget, no JVM ---
Write-Host 'Downloading android CLI (android.exe)...'
$ok = $false
for ($i = 1; $i -le 5; $i++) {
  try {
    Invoke-WebRequest -UseBasicParsing -TimeoutSec 180 -ErrorAction Stop `
      -Uri 'https://dl.google.com/android/cli/latest/windows_x86_64/android.exe' -OutFile $cli
    if ((Get-Item $cli).Length -gt 1MB) { $ok = $true; break }
  } catch { Write-Host "android.exe download attempt $i failed: $_" }
  Start-Sleep 10
}
if (-not $ok) { throw 'android.exe download failed after 5 attempts' }
& $cli --version *> $null   # first run unpacks the embedded install + accepts ToS; discard output (piping android.exe's streaming download via Out-Host buffers in the WinRM shell -> System.OutOfMemoryException)

# Run the CLI, feeding 'y' for any license prompt (install also writes the licenses dir itself).
# Retry up to 3x — a single package's download can flake transiently (exit 1) and must not fail the
# whole step. Capture ALL streams to a FILE (not Out-Host/Out-Null): piping android.exe's streaming
# download through the WinRM shell buffers it -> System.OutOfMemoryException, but redirecting to disk
# streams without buffering AND keeps the output diagnosable (we print the tail on failure).
function Invoke-AndroidCli {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]] $Arguments)
  $log = Join-Path $env:TEMP ("android-" + (($Arguments -join '_') -replace '[^\w.-]', '_') + ".log")
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    (1..100 | ForEach-Object { 'y' }) | & $cli --sdk=$sdkRoot @Arguments *> $log
    if ($LASTEXITCODE -eq 0) { return }
    Write-Host "android $($Arguments -join ' ') attempt $attempt/3 failed (exit $LASTEXITCODE); log tail:"
    Get-Content $log -Tail 15 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  | $_" }
    Start-Sleep 10
  }
  throw "android $($Arguments -join ' ') failed after 3 attempts (exit $LASTEXITCODE)"
}

# --- resolve concrete package ids from the live catalog (first column of `sdk list --all`) ---
Write-Host 'Querying android package catalog...'
# android.exe routes the listing through stderr, so merge it (2>&1) before parsing.
$raw = (& $cli --sdk=$sdkRoot sdk list --all 2>&1 | Out-String)
Write-Host "catalog raw chars: $($raw.Length)"
$catalog = ($raw -split "`r?`n") | ForEach-Object {
  $t = ($_.Trim() -split '\s+', 3)   # lines are indented; trim so the package id is $t[0]
  if ($t.Count -ge 2 -and $t[0] -match '/') { [pscustomobject]@{ Id = $t[0]; Version = $t[1] } }
} | Where-Object { $_ }
if (-not $catalog) { throw 'android sdk list returned no packages (catalog query failed)' }

function Latest-PerMajor([string] $prefix, [string] $major) {
  # newest STABLE (non-rc) package id under <prefix>/<major>.*
  ($catalog | Where-Object { $_.Id -match "^$([regex]::Escape($prefix))/$major\." -and $_.Version -notmatch 'rc' } |
    Sort-Object Id | Select-Object -Last 1).Id
}

$packages = @('platform-tools', 'emulator')

# cmdline-tools (best-effort): keep sdkmanager available in the image for jobs that call it.
$cmdlineTools = ($catalog | Where-Object { $_.Id -match '^cmdline-tools/' -and $_.Version -notmatch 'rc' } |
  Sort-Object Id | Select-Object -Last 1).Id

# platforms: every platforms/android-NN with NN >= platform_min_version
$minPlat = [int] $android.platform_min_version
$packages += ($catalog | Where-Object { $_.Id -match '^platforms/android-(\d+)$' -and [int] $Matches[1] -ge $minPlat }).Id

# build-tools: every stable build-tools/X.Y.Z with version >= build_tools_min_version
$minBt = [version] $android.build_tools_min_version
$packages += ($catalog | Where-Object { $_.Id -match '^build-tools/(\d+\.\d+\.\d+)$' -and [version] $Matches[1] -ge $minBt }).Id

# NDKs: latest stable of each requested major
foreach ($m in $android.ndk.versions) {
  $ndk = Latest-PerMajor 'ndk' $m
  if ($ndk) { $packages += $ndk } else { Write-Host "WARN: no stable NDK for major $m" }
}

# cmake / extras / add-ons from the manifest (manifest uses ';' SDK-style -> CLI uses '/')
$packages += ($android.additional_tools | ForEach-Object { $_ -replace ';', '/' })          # cmake;X -> cmake/X
$packages += ($android.extras | ForEach-Object { 'extras/' + ($_ -replace ';', '/') })
$packages += ($android.addons | ForEach-Object { 'add-ons/' + ($_ -replace ';', '/') })

$packages = @($packages | Where-Object { $_ } | Select-Object -Unique)

# NDK env paths (default + latest major), computed from the resolved ids
$ndkDefault = Latest-PerMajor 'ndk' $android.ndk.default
$ndkLatest  = Latest-PerMajor 'ndk' ($android.ndk.versions | Select-Object -Last 1)
$ndkDefaultPath = if ($ndkDefault) { "$sdkRoot\ndk\$(($ndkDefault -split '/')[1])" }
$ndkLatestPath  = if ($ndkLatest)  { "$sdkRoot\ndk\$(($ndkLatest  -split '/')[1])" }

Write-Host "Resolved $($packages.Count) packages:`n  $($packages -join "`n  ")"
Write-Host "cmdline-tools (best-effort): $cmdlineTools"
Write-Host "ANDROID_HOME=$sdkRoot  NDK default=$ndkDefaultPath  NDK latest=$ndkLatestPath"

if ($env:RIF_ANDROID_DRYRUN) { Write-Host 'RIF_ANDROID_DRYRUN set - resolution only, not installing.'; exit 0 }

# --- install ---
if ($cmdlineTools) {
  try { Invoke-AndroidCli sdk install $cmdlineTools } catch { Write-Host "WARN: cmdline-tools install failed (non-fatal): $_" }
}
# Install one package per android.exe invocation instead of one giant `sdk install @packages` batch.
# #32: a single batch spins up one long-lived JVM that unpacks every package (incl. 3 multi-GB NDKs)
# in the same process -> its native/metaspace footprint balloons and the OS fails to commit it
# ("Native memory allocation (mmap) failed ... Failed to commit metaspace") under full build memory
# pressure. Per-package installs keep each JVM small and short-lived, so peak native memory stays low.
$i = 0
foreach ($pkg in $packages) {
  $i++
  Write-Host "[$i/$($packages.Count)] android sdk install $pkg"
  Invoke-AndroidCli sdk install $pkg
}

# --- machine env vars (match the upstream script's outcome) ---
[Environment]::SetEnvironmentVariable('ANDROID_HOME', $sdkRoot, 'Machine')
[Environment]::SetEnvironmentVariable('ANDROID_SDK_ROOT', $sdkRoot, 'Machine')
foreach ($v in 'ANDROID_NDK', 'ANDROID_NDK_HOME', 'ANDROID_NDK_ROOT') {
  [Environment]::SetEnvironmentVariable($v, $ndkDefaultPath, 'Machine')
}
if ($ndkLatestPath -and (Test-Path $ndkLatestPath)) {
  [Environment]::SetEnvironmentVariable('ANDROID_NDK_LATEST_HOME', $ndkLatestPath, 'Machine')
} else {
  throw "Latest NDK not found at $ndkLatestPath"
}

# --- sanity ---
if (-not (Test-Path "$sdkRoot\platform-tools\adb.exe")) { throw 'platform-tools\adb.exe missing after install' }
if (-not (Test-Path $ndkDefaultPath)) { throw "default NDK missing at $ndkDefaultPath" }
Write-Host "Android SDK installed at $sdkRoot (ANDROID_HOME); NDK default=$ndkDefaultPath latest=$ndkLatestPath"
