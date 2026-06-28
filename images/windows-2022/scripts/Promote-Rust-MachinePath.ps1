################################################################################
##  Promote-Rust-MachinePath.ps1  (#15)
##  Upstream Install-Rust.ps1 installs rustup under a per-user profile (the
##  Default profile) and edits only that user's PATH. A self-hosted GitHub runner
##  runs as the SYSTEM / machine account, which never sees a per-user PATH — so
##  `rustc`/`cargo` resolve to nothing inside a job even though the binaries are
##  on disk. (The toolset *is* installed; it's invisible to the runner.)
##
##  Run AFTER Install-Rust.ps1: locate the cargo home it produced and put cargo\bin
##  (+ CARGO_HOME / RUSTUP_HOME) on the MACHINE environment so the runner resolves
##  them. Promotion (not reinstall) keeps win22's upstream crate builds intact and
##  is a no-op-fast registry change — usable both at build time and as a checkpoint
##  step against an already-built image.
################################################################################
$ErrorActionPreference = "Stop"

# Where upstream may have put it: the build user's profile, or the Default profile
# (runner-images installs into Default so freshly-created users inherit it).
$cands = @("$env:USERPROFILE\.cargo", "C:\Users\Default\.cargo")
$cargoHome = $cands | Where-Object { Test-Path (Join-Path $_ "bin\cargo.exe") } | Select-Object -First 1
if (-not $cargoHome) { throw "Promote-Rust-MachinePath: no cargo.exe under: $($cands -join ', ')" }

$cargoBin   = Join-Path $cargoHome "bin"
$rustupHome = Join-Path (Split-Path $cargoHome -Parent) ".rustup"

[Environment]::SetEnvironmentVariable("CARGO_HOME", $cargoHome, "Machine")
if (Test-Path $rustupHome) { [Environment]::SetEnvironmentVariable("RUSTUP_HOME", $rustupHome, "Machine") }

$mp = [Environment]::GetEnvironmentVariable("Path", "Machine")
if (($mp -split ";") -notcontains $cargoBin) {
    [Environment]::SetEnvironmentVariable("Path", ($mp.TrimEnd(";")) + ";" + $cargoBin, "Machine")
    Write-Host "Added $cargoBin to Machine PATH"
} else {
    Write-Host "$cargoBin already on Machine PATH"
}

Write-Host ("CARGO_HOME(Machine)  = " + [Environment]::GetEnvironmentVariable("CARGO_HOME","Machine"))
Write-Host ("RUSTUP_HOME(Machine) = " + [Environment]::GetEnvironmentVariable("RUSTUP_HOME","Machine"))
& (Join-Path $cargoBin "rustc.exe") --version
& (Join-Path $cargoBin "cargo.exe") --version
Write-Host "@@@OK Promote-Rust-MachinePath.ps1"
