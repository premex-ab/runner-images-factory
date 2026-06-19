// Windows Server 2025 runner image — built with Packer's QEMU builder.
// Unlike a hand-rolled FirstLogonCommands script, Packer connects over WinRM and
// runs every provisioning step remotely with full logs + a clean shutdown. The
// Autounattend only bootstraps WinRM; everything else is Packer provisioners.
//
//   PACKER_PLUGIN_PATH=... packer init  windows-2025.pkr.hcl
//   packer build -var windows_iso=/path/win-2025.iso -var virtio_iso=/path/virtio-win.iso windows-2025.pkr.hcl

packer {
  required_plugins {
    qemu = { source = "github.com/hashicorp/qemu", version = ">= 1.1.0" }
  }
}

variable "windows_iso" { type = string }
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

source "qemu" "windows2025" {
  // --- media ---
  iso_url      = "file://${var.windows_iso}"
  iso_checksum = "none"

  // --- firmware / machine (UEFI q35; KVM-accelerated) ---
  efi_boot          = true
  efi_firmware_code = var.ovmf_code
  efi_firmware_vars = var.ovmf_vars
  machine_type      = "q35"
  accelerator       = "kvm"

  // --- sizing ---
  cpus      = 4
  memory    = 8192
  disk_size = "40960"
  format    = "qcow2"
  // IDE system disk + e1000 NIC: both are Windows inbox drivers, so Setup sees the
  // disk natively (no virtio storage-driver injection — the fragile part) and WinRM
  // works right after install. The runtime launcher must match (IDE + e1000).
  disk_interface = "ide"
  net_device     = "e1000"

  // -cpu host is REQUIRED: Windows Server 2025 / 24H2 needs SSE4.2 + POPCNT, which
  // the default qemu64 CPU lacks. We only add -cpu (NOT -drive): a qemuargs -drive
  // overrides ALL of Packer's default -drive switches (the OVMF pflash, system
  // disk, install ISO and Autounattend CD), which is what broke the first attempt.
  qemuargs = [
    ["-cpu", "host"],
  ]

  // The Autounattend.xml is delivered on a small CD that Windows Setup auto-reads.
  cd_files = ["./Autounattend.xml"]
  cd_label = "PROVISION"

  // Get past the UEFI "Press any key to boot from CD or DVD" prompt (no human to
  // press it). The prompt appears ~6-11s after start and times out in ~5s, so we
  // spam Enter once per second from ~3s to ~22s to land inside that first window.
  boot_wait    = "55s"
  boot_command = ["<enter>"]

  // --- communicator: WinRM (enabled by the Autounattend FirstLogonCommands) ---
  communicator   = "winrm"
  winrm_username = "Administrator"
  winrm_password = var.winrm_password
  winrm_timeout  = "45m"
  winrm_use_ssl  = false
  winrm_insecure = true

  // Clean shutdown once provisioning is done → Packer captures the qcow2.
  shutdown_command = "shutdown /s /t 10 /f /d p:4:1 /c \"Packer build complete\""
  shutdown_timeout = "20m"

  headless         = true
  vnc_bind_address = "0.0.0.0"

  output_directory = var.output_dir
  vm_name          = "windows-2025.qcow2"
}

// Env vars the actions/runner-images build scripts assume (their Azure template's
// values, minus the D: scratch disk — qemu has no D:, so TEMP_DIR lives on C:).
locals {
  ri_ref = "45c47de3177549e886163a7763dcd7d651a980e3" // tag win25/20260614.167
  ri_env = [
    "IMAGE_FOLDER=C:\\image",
    "TEMP_DIR=C:\\temp",
    "AGENT_TOOLSDIRECTORY=C:\\hostedtoolcache\\windows",
    "IMAGE_OS=win25",
    "IMAGEDATA_FILE=C:\\imagedata.json",
    "IMAGE_VERSION=runner",
  ]
}

build {
  sources = ["source.qemu.windows2025"]

  // Stage actions/runner-images so our toolchain tracks windows-latest (issue #140).
  // Their Install-*.ps1 aren't standalone: they call helper functions bare and rely
  // on PowerShell module auto-loading, read versions from toolset.json in IMAGE_FOLDER,
  // and end with Invoke-PesterTests validation. We replicate exactly that setup —
  // download the repo at a pinned ref, put the ImageHelpers module on PSModulePath,
  // rename toolset-2025.json -> toolset.json, and stub Invoke-PesterTests to a no-op
  // (skips the Pester + test-file dependency). Then run a curated, ordered subset.
  provisioner "powershell" {
    environment_vars = local.ri_env
    inline = [
      "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12",
      "$ref = '${local.ri_ref}'",
      "New-Item -ItemType Directory -Force -Path C:\\image, C:\\temp | Out-Null",
      "Invoke-WebRequest -UseBasicParsing -Uri \"https://github.com/actions/runner-images/archive/$ref.zip\" -OutFile C:\\ri.zip",
      "Expand-Archive -LiteralPath C:\\ri.zip -DestinationPath C:\\ri -Force",
      "$src = \"C:\\ri\\runner-images-$ref\\images\\windows\"",
      "Copy-Item \"$src\\scripts\" C:\\image\\scripts -Recurse -Force",
      "Copy-Item \"$src\\toolsets\" C:\\image\\toolsets -Recurse -Force",
      "Move-Item C:\\image\\scripts\\helpers 'C:\\Program Files\\WindowsPowerShell\\Modules\\ImageHelpers' -Force",
      "Move-Item C:\\image\\toolsets\\toolset-2025.json C:\\image\\toolset.json -Force",
      "New-Item -ItemType Directory -Force -Path 'C:\\Program Files\\WindowsPowerShell\\Modules\\TestsHelpers' | Out-Null",
      "Set-Content 'C:\\Program Files\\WindowsPowerShell\\Modules\\TestsHelpers\\TestsHelpers.psm1' 'function Invoke-PesterTests {}'",
      "Remove-Item C:\\ri.zip -Force; Remove-Item C:\\ri -Recurse -Force",
      "Write-Host \"runner-images staged at $ref\"",
    ]
  }

  // Curated toolchain from runner-images (one provisioner per script so a failure
  // pinpoints the script). Language-toolchain scripts need no reboot between them.
  provisioner "powershell" {
    environment_vars = local.ri_env
    inline           = ["& C:\\image\\scripts\\build\\Configure-PowerShell.ps1"]
  }
  provisioner "powershell" {
    environment_vars = local.ri_env
    inline           = ["& C:\\image\\scripts\\build\\Install-Chocolatey.ps1"]
  }
  // runner-images' Expand-7ZipArchive helper shells out to 7z.exe (e.g. MinGW ships
  // as a .7z), and there's no Install-7Zip.ps1 — so install 7-Zip via choco before
  // any script that extracts a 7z archive.
  provisioner "powershell" {
    inline = [
      "choco install -y --no-progress 7zip.install",
      "if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 3010) { throw \"7zip install failed: $LASTEXITCODE\" }",
    ]
  }
  provisioner "powershell" {
    environment_vars = local.ri_env
    inline           = ["& C:\\image\\scripts\\build\\Install-PowershellCore.ps1"]
  }
  provisioner "powershell" {
    environment_vars = local.ri_env
    inline           = ["& C:\\image\\scripts\\build\\Install-Git.ps1"]
  }
  provisioner "powershell" {
    environment_vars = local.ri_env
    inline           = ["& C:\\image\\scripts\\build\\Install-NodeJS.ps1"]
  }
  provisioner "powershell" {
    environment_vars = local.ri_env
    inline           = ["& C:\\image\\scripts\\build\\Install-Mingw64.ps1"]
  }

  // WebView2 runtime (Wails) — not a runner-images build script; best-effort via choco
  // (already installed above), tolerant of its non-zero "already present/reboot" codes.
  provisioner "powershell" {
    inline = [
      "choco install -y --no-progress microsoft-edge-webview2-runtime",
      "Write-Host \"webview2 choco exit $LASTEXITCODE\"",
      "exit 0",
    ]
  }

  // 3. The GitHub Actions runner, baked under C:\actions-runner so the agent's
  //    cloudbase-init seed (windowsUserData) skips the download at runtime.
  provisioner "powershell" {
    inline = [
      "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12",
      "New-Item -ItemType Directory -Force -Path C:\\actions-runner | Out-Null",
      "$url = \"https://github.com/actions/runner/releases/download/v${var.runner_version}/actions-runner-win-x64-${var.runner_version}.zip\"",
      "$zip = 'C:\\actions-runner\\runner.zip'",
      "$ok = $false",
      "for ($i = 1; $i -le 5; $i++) { try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 -Uri $url -OutFile $zip; if ((Get-Item $zip).Length -gt 1MB) { $ok = $true; break } } catch { Write-Host \"runner download attempt $i failed: $_\" }; Start-Sleep 10 }",
      "if (-not $ok) { throw 'actions-runner download failed after 5 attempts' }",
      "Expand-Archive -LiteralPath $zip -DestinationPath C:\\actions-runner -Force",
      "Remove-Item $zip -Force",
      "Write-Host 'actions-runner baked'",
    ]
  }

  // 4. cloudbase-init: the Windows cloud-init. Reads the agent's NoCloud cidata
  //    seed each boot — applies the static network-config (isolated bridge has no
  //    DHCP) and runs the #ps1_sysnative userdata (run.cmd --jitconfig).
  provisioner "powershell" {
    inline = [
      "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12",
      "$msi = 'C:\\cloudbase-init.msi'",
      "$url = 'https://github.com/cloudbase/cloudbase-init/releases/download/1.1.6/CloudbaseInitSetup_1_1_6_x64.msi'",
      "$ok = $false",
      "for ($i = 1; $i -le 5; $i++) { try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 120 -Uri $url -OutFile $msi; if ((Get-Item $msi).Length -gt 1MB) { $ok = $true; break } } catch { Write-Host \"cloudbase-init download attempt $i failed: $_\" }; Start-Sleep 10 }",
      "if (-not $ok) { throw 'cloudbase-init MSI download failed after 5 attempts' }",
      "$p = Start-Process msiexec.exe -Wait -PassThru -ArgumentList \"/i $msi /qn /norestart RUN_SERVICE_AS_LOCAL_SYSTEM=1\"",
      "if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw \"cloudbase-init msiexec failed: $($p.ExitCode)\" }",
      "$cbidir = 'C:\\Program Files\\Cloudbase Solutions\\Cloudbase-Init'; if (-not (Test-Path $cbidir) -or @(Get-ChildItem $cbidir -Recurse -File -ErrorAction SilentlyContinue).Count -lt 50) { throw 'cloudbase-init install incomplete (dir missing or sparse)' }",
      "Remove-Item $msi -Force",
      "Write-Host 'cloudbase-init installed'",
    ]
  }

  // cloudbase-init config: NoCloud config-drive (the cidata CD) + the network +
  // userdata plugins. allow_reboot=false / inject_user_password=false so a runtime
  // boot just applies the static IP and runs the JIT userdata.
  provisioner "file" {
    source      = "./scripts/cloudbase-init.conf"
    destination = "C:\\Program Files\\Cloudbase Solutions\\Cloudbase-Init\\conf\\cloudbase-init.conf"
  }
  provisioner "powershell" {
    inline = [
      "Copy-Item 'C:\\Program Files\\Cloudbase Solutions\\Cloudbase-Init\\conf\\cloudbase-init.conf' 'C:\\Program Files\\Cloudbase Solutions\\Cloudbase-Init\\conf\\cloudbase-init-unattend.conf' -Force",
      "Write-Host 'cloudbase-init configured'",
    ]
  }
}
