################################################################################
##  Install-Rust-Machine.ps1
##  Install the rustup stable toolchain to a MACHINE location so the GitHub
##  runner (which runs as LocalSystem / the machine account) sees rustc + cargo.
##  Mirrors actions/runner-images Install-Rust.ps1 (download-only: rustup-init +
##  rustup target/component add) but installs to C:\Rust with CARGO_HOME /
##  RUSTUP_HOME + C:\Rust\cargo\bin set MACHINE-wide.
##
##  Why this exists (factory deviation from upstream): upstream Install-Rust.ps1
##  installs rust under the *interactive build user's* profile and only edits that
##  user's PATH. On a self-hosted runner the agent runs as the **SYSTEM / machine
##  account**, which never sees a per-user PATH, so `rustc`/`cargo` resolve to
##  nothing in a job even though the binaries are on disk. Installing machine-wide
##  (C:\Rust + Machine PATH) is what makes Rust actually usable in CI.
##
##  No `cargo install` of crates here -> does not trigger the nested-KVM rustc
##  crash that the windows-2022 cell works around (that crash is in crate builds,
##  not in rustup's prebuilt-toolchain download). win25's upstream crate-build
##  block is gated off on win25 anyway, so a download-only install is full parity.
################################################################################
$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

$RustRoot   = "C:\Rust"
$CargoHome  = Join-Path $RustRoot "cargo"
$RustupHome = Join-Path $RustRoot "rustup"
$CargoBin   = Join-Path $CargoHome "bin"

New-Item -ItemType Directory -Force -Path $RustRoot | Out-Null

# rustup/cargo honor these env vars at install + runtime; set for THIS process so
# rustup-init installs into C:\Rust, and MACHINE-wide so every future session/service
# (incl. the SYSTEM-account runner) resolves the same home.
$env:CARGO_HOME  = $CargoHome
$env:RUSTUP_HOME = $RustupHome
[Environment]::SetEnvironmentVariable("CARGO_HOME",  $CargoHome,  "Machine")
[Environment]::SetEnvironmentVariable("RUSTUP_HOME", $RustupHome, "Machine")

$rustArch = "x86_64"
$initUrl  = "https://static.rust-lang.org/rustup/dist/${rustArch}-pc-windows-msvc/rustup-init.exe"
$initExe  = Join-Path $env:TEMP "rustup-init.exe"

Write-Host "Downloading rustup-init.exe ..."
Invoke-WebRequest -Uri $initUrl -OutFile $initExe -UseBasicParsing

# Supply-chain: verify the published SHA256 (matches upstream Install-Rust.ps1).
$expected = (Invoke-RestMethod -Uri "$initUrl.sha256").Trim().Split(" ")[0].ToLower()
$actual   = (Get-FileHash $initExe -Algorithm SHA256).Hash.ToLower()
if ($actual -ne $expected) { throw "rustup-init.exe checksum mismatch: expected $expected got $actual" }
Write-Host "Checksum OK: $actual"

Write-Host "Running rustup-init (stable, minimal) ..."
& $initExe -y --default-toolchain stable --profile minimal --no-modify-path
if ($LASTEXITCODE -ne 0) { throw "rustup-init failed with exit code $LASTEXITCODE" }

# Make cargo/rustc resolvable for the rest of THIS script.
$env:Path = "$CargoBin;$env:Path"

# Mirror upstream targets + components (all downloads, no crate builds).
& "$CargoBin\rustup.exe" target add i686-pc-windows-msvc
if ($LASTEXITCODE -ne 0) { throw "rustup target add i686 failed ($LASTEXITCODE)" }
& "$CargoBin\rustup.exe" target add x86_64-pc-windows-gnu
if ($LASTEXITCODE -ne 0) { throw "rustup target add gnu failed ($LASTEXITCODE)" }
& "$CargoBin\rustup.exe" component add rustfmt clippy
if ($LASTEXITCODE -ne 0) { throw "rustup component add failed ($LASTEXITCODE)" }

# Put C:\Rust\cargo\bin on the MACHINE PATH (idempotent) so SYSTEM/runner sees it.
$machPath = [Environment]::GetEnvironmentVariable("Path","Machine")
if (($machPath -split ";") -notcontains $CargoBin) {
    $machPath = ($machPath.TrimEnd(";")) + ";" + $CargoBin
    [Environment]::SetEnvironmentVariable("Path", $machPath, "Machine")
    Write-Host "Added $CargoBin to Machine PATH"
} else {
    Write-Host "$CargoBin already on Machine PATH"
}

Write-Host "=== installed versions ==="
& "$CargoBin\rustc.exe" --version
& "$CargoBin\cargo.exe" --version
& "$CargoBin\rustup.exe" --version

Write-Host "@@@OK Install-Rust-Machine.ps1"
