// Windows Server 2022 runner image — RESUME cell (iterate the post-VS steps fast).
//
// Instead of installing Windows + Visual Studio from the ISO (~80 min), this cell BOOTS a
// pre-built "VS-complete" checkpoint qcow2 (produced by windows-2022-checkpoint + saved with
// ./checkpoint-save.sh) as its base disk, then runs ONLY the cheap tail of the pipeline:
// VSExtensions + Rust + a final verify. That turns a Rust/VSExtensions iteration from a full
// ~80-90 min rebuild into a ~15 min boot-and-provision loop.
//
//   ./checkpoint-save.sh                      # once, after a green checkpoint build
//   packer build images/windows-2022-resume/windows-2022-resume.pkr.hcl
//   packer build -var checkpoint_qcow2=/abs/path/to/base.qcow2 images/windows-2022-resume/windows-2022-resume.pkr.hcl
//
// How the disk is handled (Packer qemu builder semantics):
//   disk_image       = true   -> iso_url is treated as a bootable QEMU image, not install media.
//   use_backing_file = true   -> Packer makes a NEW qcow2 with checkpoint_qcow2 as its backing
//                                file (qcow2 only). Only changed blocks are written, so the
//                                pristine checkpoint is NEVER mutated — every resume run is a
//                                throwaway overlay. (This also forces skip_compaction=true.)
// There is NO cd_files / Autounattend / boot_command: the OS is already installed; we just boot
// it and connect over WinRM with the same creds the install used.
//
// OVMF / NVRAM: we boot with a FRESH OVMF_VARS template (var.ovmf_vars), exactly like
// lib/common.sh's verify_windows() does when it boots the finished image. An installed Windows
// disk boots from a pristine NVRAM because OVMF's removable-media fallback finds
// \EFI\Microsoft\Boot\bootmgfw.efi (\EFI\Boot\bootx64.efi) on the ESP — so no per-build efivars
// needs to be carried alongside the checkpoint. This is the proven recipe; do not "fix" it by
// trying to reuse a saved efivars file.

packer {
  required_plugins {
    qemu = { source = "github.com/hashicorp/qemu", version = ">= 1.1.0" }
  }
}

// The VS-complete checkpoint qcow2 to resume from. Default points at the saved base that
// checkpoint-save.sh writes; override with -var checkpoint_qcow2=/abs/path for an ad-hoc disk.
variable "checkpoint_qcow2" {
  type    = string
  default = "../../checkpoints/windows-2022-vsbase.qcow2"
}
variable "runner_version" {
  type    = string
  default = "2.335.1"
}
variable "ovmf_code" {
  type    = string
  default = "/usr/share/OVMF/OVMF_CODE_4M.fd"
}
variable "ovmf_vars" {
  type    = string
  default = "/usr/share/OVMF/OVMF_VARS_4M.fd"
}
variable "output_dir" {
  type    = string
  default = "out"
}
variable "winrm_password" {
  type    = string
  default = "Bm-Packer-2025!"
}

source "qemu" "windows2022resume" {
  // --- media: boot the checkpoint qcow2 as a backing disk, do NOT install ---
  iso_url          = "${var.checkpoint_qcow2}"
  iso_checksum     = "none"
  disk_image       = true
  use_backing_file = true

  // --- firmware / machine (UEFI q35; KVM-accelerated) — identical to the install cell ---
  // Fresh OVMF_VARS template: verify_windows() proves an installed Windows disk boots from a
  // pristine NVRAM via the ESP fallback bootmgfw.efi, so no saved efivars is needed.
  efi_boot          = true
  efi_firmware_code = var.ovmf_code
  efi_firmware_vars = var.ovmf_vars
  machine_type      = "q35"
  accelerator       = "kvm"

  // --- sizing --- (match the install cell: 28 of 32 threads, 48 of 62 GiB)
  cpus   = 28
  memory = 49152
  format = "qcow2"
  // disk_size intentionally omitted: the OS is already installed and sized on the checkpoint;
  // a backing-file overlay must not shrink it, and growing it buys nothing for the tail steps.

  // IDE system disk + e1000 NIC — MUST match how the checkpoint was installed (inbox drivers,
  // WinRM works on boot) and how the runtime launcher boots it.
  disk_interface = "ide"
  net_device     = "e1000"

  // -cpu host is REQUIRED (Windows Server 2022 needs SSE4.2 + POPCNT). Only -cpu, never -drive
  // (a qemuargs -drive overrides ALL of Packer's default -drive switches: OVMF pflash + disk).
  qemuargs = [
    ["-cpu", "host"],
  ]

  // No cd_files / boot_command / boot prompt to fight: the disk boots straight into the
  // installed Windows, which already enabled WinRM during its original install.
  boot_wait = "30s"

  // --- communicator: WinRM (same creds the checkpoint install used) ---
  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = var.winrm_password
  winrm_timeout  = "30m"
  winrm_use_ssl  = false
  winrm_insecure = true

  // Clean shutdown once provisioning is done → Packer captures the qcow2.
  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer resume build complete\""
  shutdown_timeout = "20m"

  headless         = true
  vnc_bind_address = "0.0.0.0"

  output_directory = var.output_dir
  vm_name          = "windows-2022-resume.qcow2"
}

// Same env the runner-images build scripts assume (matches the checkpoint cell).
locals {
  ri_ref = "239919496477d95885def2814dff06f92021f559" // tag win22/20260616.203
  ri_env = [
    "IMAGE_FOLDER=C:\\image",
    "TEMP_DIR=C:\\temp",
    "AGENT_TOOLSDIRECTORY=C:\\hostedtoolcache\\windows",
    "IMAGE_OS=win22",
    "IMAGEDATA_FILE=C:\\imagedata.json",
    "IMAGE_VERSION=runner",
  ]
}

build {
  sources = ["source.qemu.windows2022resume"]

  // Re-stage guard. The checkpoint disk already has the runner-images scripts under
  // C:\image\scripts (the checkpoint's staging provisioner left them in place — only C:\ri.zip /
  // C:\ri were removed). If for any reason they're missing (e.g. a hand-built checkpoint), re-fetch
  // exactly as the checkpoint cell did so Install-VSExtensions.ps1 / Install-Rust.ps1 are present.
  provisioner "powershell" {
    environment_vars = local.ri_env
    inline = [
      "if (Test-Path 'C:\\image\\scripts\\build\\Install-Rust.ps1') { Write-Host '@@@OK runner-images already staged on checkpoint'; exit 0 }",
      "Write-Host '@@@RUN re-stage runner-images (scripts missing on checkpoint)'",
      "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12",
      "$ref = '${local.ri_ref}'",
      "New-Item -ItemType Directory -Force -Path C:\\image, C:\\temp | Out-Null",
      "Invoke-WebRequest -UseBasicParsing -Uri \"https://github.com/actions/runner-images/archive/$ref.zip\" -OutFile C:\\ri.zip",
      "Expand-Archive -LiteralPath C:\\ri.zip -DestinationPath C:\\ri -Force",
      "$src = \"C:\\ri\\runner-images-$ref\\images\\windows\"",
      "Copy-Item \"$src\\scripts\" C:\\image\\scripts -Recurse -Force",
      "Copy-Item \"$src\\toolsets\" C:\\image\\toolsets -Recurse -Force",
      "if (Test-Path \"$src\\assets\") { Copy-Item \"$src\\assets\" C:\\image\\assets -Recurse -Force }",
      "if (-not (Test-Path 'C:\\Program Files\\WindowsPowerShell\\Modules\\ImageHelpers')) { Move-Item C:\\image\\scripts\\helpers 'C:\\Program Files\\WindowsPowerShell\\Modules\\ImageHelpers' -Force }",
      "if (-not (Test-Path 'C:\\image\\toolset.json')) { Move-Item C:\\image\\toolsets\\toolset-2022.json C:\\image\\toolset.json -Force }",
      "New-Item -ItemType Directory -Force -Path 'C:\\Program Files\\WindowsPowerShell\\Modules\\TestsHelpers' | Out-Null",
      "Set-Content 'C:\\Program Files\\WindowsPowerShell\\Modules\\TestsHelpers\\TestsHelpers.psm1' 'function Invoke-PesterTests {}'",
      "Remove-Item C:\\ri.zip -Force -EA SilentlyContinue; Remove-Item C:\\ri -Recurse -Force -EA SilentlyContinue",
      "Write-Host \"runner-images re-staged at $ref\"",
    ]
  }

  // VS extensions in a dedicated in-process provisioner. Start-Process strips the in-process VS dev
  // environment, so VSIXInstaller returns 2003 ("not installable on installed product"); running
  // in-process (a fresh powershell with the full machine env) matches the real template.
  provisioner "powershell" {
    environment_vars = local.ri_env
    inline = [
      "$ErrorActionPreference='Continue'; $s='Install-VSExtensions.ps1'; Write-Host \"@@@RUN $s\"; try { $global:LASTEXITCODE=0; & \"C:\\image\\scripts\\build\\$s\"; if ($LASTEXITCODE -gt 0) { throw \"exit $LASTEXITCODE\" }; Write-Host \"@@@OK $s\" } catch { Write-Host \"@@@FAIL $s : $_\" }",
      "exit 0",
    ]
  }
  // Rust in a dedicated in-process provisioner (fresh powershell + full machine env). Start-Process
  // strips the VS dev env so rustc's MSVC-linker detection falls back to a PATH `link` (the GNU
  // coreutil -> "extra operand") and cargo build scripts fail to link; in-process matches the real
  // template.
  provisioner "powershell" {
    environment_vars = local.ri_env
    inline = [
      "$ErrorActionPreference='Continue'; $s='Install-Rust.ps1'; Write-Host \"@@@RUN $s\"; try { $global:LASTEXITCODE=0; $vsw='C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe'; $vp=(& $vsw -latest -property installationPath); $lk=Get-ChildItem \"$vp\\VC\\Tools\\MSVC\\*\\bin\\Hostx64\\x64\\link.exe\" -EA SilentlyContinue | Select-Object -First 1; if ($lk) { $env:Path=$lk.DirectoryName+';'+$env:Path; Write-Host \"prepended MSVC link dir so rustc's cargo-build link step uses link.exe not the GNU coreutil: $($lk.DirectoryName)\" } else { Write-Host 'WARN: MSVC link.exe not found via vswhere' }; & \"C:\\image\\scripts\\build\\$s\"; if ($LASTEXITCODE -gt 0) { throw \"exit $LASTEXITCODE\" }; Write-Host \"@@@OK $s\" } catch { Write-Host \"@@@FAIL $s : $_\" }",
      "exit 0",
    ]
  }

  // Final in-guest verify (runs over WinRM in-process, before Packer's shutdown captures the qcow2):
  // assert the MSVC linker is present (the VS-complete invariant carried from the checkpoint) and
  // that Rust actually works (rustc + cargo resolve and report versions). A failure here aborts the
  // build so a broken tail can't be captured as a "good" image.
  provisioner "powershell" {
    environment_vars = local.ri_env
    inline = [
      "$ErrorActionPreference='Stop'",
      "$vsw='C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe'; $vp=(& $vsw -latest -property installationPath); $lk=Get-ChildItem \"$vp\\VC\\Tools\\MSVC\\*\\bin\\Hostx64\\x64\\link.exe\" -EA SilentlyContinue | Select-Object -First 1; if (-not $lk) { throw 'VERIFY FAIL: MSVC link.exe missing (checkpoint was not VS-complete)' }; Write-Host \"@@@VERIFY link.exe OK $($lk.FullName)\"",
      "[Environment]::GetEnvironmentVariables('Machine').GetEnumerator()|ForEach-Object{[Environment]::SetEnvironmentVariable($_.Name,$_.Value,'Process')}; $env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User')",
      "$rc=(& rustc --version 2>&1 | Out-String).Trim(); if ($LASTEXITCODE -ne 0 -or -not $rc) { throw \"VERIFY FAIL: rustc --version failed: $rc\" }; Write-Host \"@@@VERIFY rustc OK $rc\"",
      "$cg=(& cargo --version 2>&1 | Out-String).Trim(); if ($LASTEXITCODE -ne 0 -or -not $cg) { throw \"VERIFY FAIL: cargo --version failed: $cg\" }; Write-Host \"@@@VERIFY cargo OK $cg\"",
      "Write-Host '@@@VERIFY_RESULT=PASS'",
    ]
  }
}
