// Windows Server 2022 runner image — CHECKPOINT cell (a "VS-complete" base).
//
// This is the windows-2022 (debug) cell PRUNED to stop right after Visual Studio is
// fully installed: staging -> group 1 (base config) -> group 3a (the 4-pass VS install,
// each pass gating on link.exe) -> group 3a-fix (NativeDesktop completion) -> group 3b
// (vswhere tally + KubernetesTools). The VSExtensions and Rust provisioners are DROPPED —
// they move to windows-2022-resume, which boots THIS image's output as a backing disk so
// those last (cheap) steps can be iterated in ~15 min instead of re-running the ~80-min VS
// install every time.
//
// Save the finished qcow2 as the resume base with: ./checkpoint-save.sh (see repo root).
//
//   packer build -var windows_iso=/path/win-2022.iso images/windows-2022-checkpoint/windows-2022-checkpoint.pkr.hcl
//
// NOTE: install media + machine shape are byte-for-byte the windows-2022 cell so the
// checkpoint disk is the exact same Windows install the full cell would produce — only the
// post-VS provisioners differ.

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

source "qemu" "windows2022checkpoint" {
  // --- media ---
  iso_url      = "file://${var.windows_iso}"
  iso_checksum = "none"

  // --- firmware / machine (UEFI q35; KVM-accelerated) ---
  efi_boot          = true
  efi_firmware_code = var.ovmf_code
  efi_firmware_vars = var.ovmf_vars
  machine_type      = "q35"
  accelerator       = "kvm"

  // --- sizing --- (debug branch: dedicated host, max it out — 28 of 32 threads, 48 of 62 GiB)
  cpus      = 28
  sockets   = 2
  cores     = 14
  threads   = 1
  memory    = 49152
  disk_size = "204800"
  format    = "qcow2"
  // IDE system disk + e1000 NIC: both are Windows inbox drivers, so Setup sees the
  // disk natively (no virtio storage-driver injection — the fragile part) and WinRM
  // works right after install. The runtime launcher must match (IDE + e1000).
  disk_interface = "ide"
  net_device     = "e1000"

  // -cpu host is REQUIRED: Windows Server 2022 needs SSE4.2 + POPCNT, which the
  // default qemu64 CPU lacks. We only add -cpu (NOT -drive): a qemuargs -drive
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
  boot_command = []

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
  vm_name          = "windows-2022-checkpoint.qcow2"
}

// Env vars the actions/runner-images build scripts assume (their Azure template's
// values, minus the D: scratch disk — qemu has no D:, so TEMP_DIR lives on C:).
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
  sources = ["source.qemu.windows2022checkpoint"]

  // Stage actions/runner-images so our toolchain tracks windows-2022 (issue #140).
  // Their Install-*.ps1 aren't standalone: they call helper functions bare and rely
  // on PowerShell module auto-loading, read versions from toolset.json in IMAGE_FOLDER,
  // and end with Invoke-PesterTests validation. We replicate exactly that setup —
  // download the repo at a pinned ref, put the ImageHelpers module on PSModulePath,
  // rename toolset-2022.json -> toolset.json, and stub Invoke-PesterTests to a no-op
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
      "if (Test-Path \"$src\\assets\") { Copy-Item \"$src\\assets\" C:\\image\\assets -Recurse -Force }",
      "Move-Item C:\\image\\scripts\\helpers 'C:\\Program Files\\WindowsPowerShell\\Modules\\ImageHelpers' -Force",
      "Move-Item C:\\image\\toolsets\\toolset-2022.json C:\\image\\toolset.json -Force",
      "$ts = Get-Content C:\\image\\toolset.json -Raw | ConvertFrom-Json; $ts.postgresql.version = '14.19.1'; $ts.visualStudio.vsix = @($ts.visualStudio.vsix | Where-Object { $_ -ne 'SSIS.MicrosoftDataToolsIntegrationServices' }); ($ts | ConvertTo-Json -Depth 100) | Set-Content C:\\image\\toolset.json; Write-Host 'pinned postgresql 14.19.1 (toolset ships bare major 14 -> the installer scrapes git.postgresql.org for the latest minor, which rate-limits; the explicit triple takes the deterministic get.enterprisedb.com direct-download path) + dropped the SSIS vsix (its installer 1603s and, being first in the list, blocks the other 4 VS extensions)'",
      "(Get-Content 'C:\\image\\scripts\\build\\Install-PostgreSQL.ps1' -Raw) -replace 'L=Wilmington, S=Delaware', 'S=Massachusetts' | Set-Content 'C:\\image\\scripts\\build\\Install-PostgreSQL.ps1'; Write-Host 'patched Install-PostgreSQL expected cert subject (EnterpriseDB renewed Delaware -> Massachusetts; the installer is signed with the new cert)'",
      "New-Item -ItemType Directory -Force -Path 'C:\\Program Files\\WindowsPowerShell\\Modules\\TestsHelpers' | Out-Null",
      "Set-Content 'C:\\Program Files\\WindowsPowerShell\\Modules\\TestsHelpers\\TestsHelpers.psm1' 'function Invoke-PesterTests {}'",
      "Remove-Item C:\\ri.zip -Force; Remove-Item C:\\ri -Recurse -Force",
      "Write-Host \"runner-images staged at $ref\"",
    ]
  }

  // FULL runner-images toolset (parity with windows-2022) — the complete ordered install set
  // from build.windows-2022, in reboot-separated discovery groups that mirror the REAL template's
  // windows-restart points. (The earlier flat 6-group layout dropped reboots the real template
  // has → MSI 1603 / VS-dependent failures.) Discovery mode: ErrorActionPreference=Continue, run
  // every script, log @@@OK/@@@FAIL + @@@FAILURES. A $noisy whitelist clears two wrapper
  // false-positives — Configure-BaseImage's benign exec-policy warning and az's stale
  // $LASTEXITCODE. Skips Windows Updates / Cosmos emulator / Post-Build-Validation (Pester).

  // group 1 — base config, Windows features, chocolatey (+ 7zip for 7z extraction). Note: the
  // real build.windows-2022 has no Install-WSL2 (a 2025-only script) — dropped here.
  provisioner "powershell" {
    environment_vars = local.ri_env
    inline = [
      "$ErrorActionPreference='Continue'; $b='C:\\image\\scripts\\build'; $fails=@(); $noisy=@('Configure-BaseImage.ps1','Install-AzureDevOpsCli.ps1')",
      "foreach ($s in @('Configure-WindowsDefender.ps1','Configure-PowerShell.ps1','Install-PowerShellModules.ps1','Install-WindowsFeatures.ps1','Install-Chocolatey.ps1','Configure-BaseImage.ps1','Configure-ImageDataFile.ps1','Configure-SystemEnvironment.ps1','Configure-DotnetSecureChannel.ps1')) { Write-Host \"@@@RUN $s\"; try { $global:LASTEXITCODE=0; [Environment]::GetEnvironmentVariables('Machine').GetEnumerator()|ForEach-Object{[Environment]::SetEnvironmentVariable($_.Name,$_.Value,'Process')};$env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User');$global:LASTEXITCODE=(Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',\"$b\\$s\") -Wait -PassThru -NoNewWindow).ExitCode; if ($LASTEXITCODE -gt 0 -and $s -notin $noisy) { throw \"exit $LASTEXITCODE\" }; Write-Host \"@@@OK $s\" } catch { if ($s -in $noisy) { Write-Host \"@@@OK $s (noisy ignored: $_)\" } else { $fails+=$s; Write-Host \"@@@FAIL $s : $_\" } } }",
      "choco install -y --no-progress 7zip.install 2>&1 | Out-Null; Write-Host '7zip via choco'",
      "Write-Host \"@@@FAILURES: $($fails -join ' ')\"",
      "exit 0",
    ]
  }
  provisioner "windows-restart" { restart_timeout = "60m" }

  // group 3a — Visual Studio. CRITICAL: on Server 2022 the VS installer needs reboots DURING the
  // install — it installs MinShell + the .NET runtime (~1 min), then setup.exe returns 16001
  // (reboot-required-to-continue). A single run + reboot kills setup.exe mid-install, leaving VS
  // INCOMPLETE: vswhere -latest reports nothing, VC\Tools\MSVC is empty (no MSVC linker -> Rust
  // can't link, VSExtensions has no valid product). Fix: run it up to 4x with reboots between, each
  // pass resuming; skip once vswhere -latest reports a COMPLETE instance. The completing pass's
  // bootstrapper returns 0/3010 so Install-VisualStudio.ps1's post-install (Win SDKs) also runs.
  provisioner "powershell" {
    environment_vars = local.ri_env
    valid_exit_codes = [0, 1, 1602, 1603, 1641, 3010, 5007, 16001]
    inline = [
      "$vsw='C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe'; $vp = if (Test-Path $vsw) { & $vsw -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath } else { $null }; if ($vp -and (Get-ChildItem \"$vp\\VC\\Tools\\MSVC\\*\\bin\\Hostx64\\x64\\link.exe\" -EA SilentlyContinue)) { Write-Host '@@@SKIP Install-VisualStudio.ps1 (VC++ link.exe present)'; exit 0 }",
      "Write-Host '@@@RUN Install-VisualStudio.ps1 (resume pass 1/4)'",
      "& 'C:\\image\\scripts\\build\\Install-VisualStudio.ps1'",
    ]
  }
  provisioner "windows-restart" { restart_timeout = "60m" }
  provisioner "powershell" {
    environment_vars = local.ri_env
    valid_exit_codes = [0, 1, 1602, 1603, 1641, 3010, 5007, 16001]
    inline = [
      "$vsw='C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe'; $vp = if (Test-Path $vsw) { & $vsw -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath } else { $null }; if ($vp -and (Get-ChildItem \"$vp\\VC\\Tools\\MSVC\\*\\bin\\Hostx64\\x64\\link.exe\" -EA SilentlyContinue)) { Write-Host '@@@SKIP Install-VisualStudio.ps1 (VC++ link.exe present)'; exit 0 }",
      "Write-Host '@@@RUN Install-VisualStudio.ps1 (resume pass 2/4)'",
      "& 'C:\\image\\scripts\\build\\Install-VisualStudio.ps1'",
    ]
  }
  provisioner "windows-restart" { restart_timeout = "60m" }
  provisioner "powershell" {
    environment_vars = local.ri_env
    valid_exit_codes = [0, 1, 1602, 1603, 1641, 3010, 5007, 16001]
    inline = [
      "$vsw='C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe'; $vp = if (Test-Path $vsw) { & $vsw -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath } else { $null }; if ($vp -and (Get-ChildItem \"$vp\\VC\\Tools\\MSVC\\*\\bin\\Hostx64\\x64\\link.exe\" -EA SilentlyContinue)) { Write-Host '@@@SKIP Install-VisualStudio.ps1 (VC++ link.exe present)'; exit 0 }",
      "Write-Host '@@@RUN Install-VisualStudio.ps1 (resume pass 3/4)'",
      "& 'C:\\image\\scripts\\build\\Install-VisualStudio.ps1'",
    ]
  }
  provisioner "windows-restart" { restart_timeout = "60m" }
  provisioner "powershell" {
    environment_vars = local.ri_env
    valid_exit_codes = [0, 1, 1602, 1603, 1641, 3010, 5007, 16001]
    inline = [
      "$vsw='C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe'; $vp = if (Test-Path $vsw) { & $vsw -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath } else { $null }; if ($vp -and (Get-ChildItem \"$vp\\VC\\Tools\\MSVC\\*\\bin\\Hostx64\\x64\\link.exe\" -EA SilentlyContinue)) { Write-Host '@@@SKIP Install-VisualStudio.ps1 (VC++ link.exe present)'; exit 0 }",
      "Write-Host '@@@RUN Install-VisualStudio.ps1 (resume pass 4/4)'",
      "& 'C:\\image\\scripts\\build\\Install-VisualStudio.ps1'",
    ]
  }
  provisioner "windows-restart" { restart_timeout = "60m" }

  // group 3a-fix — explicitly complete the C++ (NativeDesktop) workload. The 4-pass loop now gates
  // on link.exe (not just instance registration), but as a hard guarantee against Server 2022's
  // mid-install reboots leaving VC.Tools unfinished, run setup.exe modify --add NativeDesktop to a
  // real terminal exit so the MSVC linker is on disk before Rust/VSExtensions.
  provisioner "powershell" {
    environment_vars = local.ri_env
    valid_exit_codes = [0, 1, 1602, 1603, 1641, 3010, 5007, 16001]
    inline = [
      "$vsw='C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe'; $vp=(& $vsw -latest -property installationPath); $inst='C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\setup.exe'",
      "Write-Host '@@@RUN VS-NativeDesktop-complete'; $q=[char]34; $a=\"modify --installPath $q$vp$q --add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended --quiet --norestart --wait --nocache\"; $p=Start-Process $inst -Wait -PassThru -ArgumentList $a; Write-Host \"VS modify exit $($p.ExitCode)\"",
      "$lk=Get-ChildItem \"$vp\\VC\\Tools\\MSVC\\*\\bin\\Hostx64\\x64\\link.exe\" -EA SilentlyContinue | Select-Object -First 1; if ($lk) { Write-Host \"@@@OK VS-NativeDesktop ($($lk.FullName))\" } else { Write-Host '@@@FAIL VS-NativeDesktop : link.exe still missing' }",
      "exit 0",
    ]
  }
  provisioner "windows-restart" { restart_timeout = "60m" }

  // group 3b — confirm VS installed via vswhere (for the @@@OK tally; the bootstrapper's reboot
  // exit code isn't a failure), then kubernetes tools. This is the LAST step of the checkpoint:
  // the disk Packer captures here is "VS-complete" and becomes the windows-2022-resume base.
  provisioner "powershell" {
    environment_vars = local.ri_env
    inline = [
      "$ErrorActionPreference='Continue'; $b='C:\\image\\scripts\\build'; $fails=@()",
      "$vsw='C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe'; if ((Test-Path $vsw) -and (& $vsw -latest -property catalog_productDisplayVersion)) { Write-Host '@@@OK Install-VisualStudio.ps1 (vswhere confirms VS; reboot exit-code handled)' } else { $fails+='Install-VisualStudio.ps1'; Write-Host '@@@FAIL Install-VisualStudio.ps1 : vswhere found no VS' }",
      "foreach ($s in @('Install-KubernetesTools.ps1')) { Write-Host \"@@@RUN $s\"; try { $global:LASTEXITCODE=0; [Environment]::GetEnvironmentVariables('Machine').GetEnumerator()|ForEach-Object{[Environment]::SetEnvironmentVariable($_.Name,$_.Value,'Process')};$env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User');$global:LASTEXITCODE=(Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',\"$b\\$s\") -Wait -PassThru -NoNewWindow).ExitCode; if ($LASTEXITCODE -gt 0) { throw \"exit $LASTEXITCODE\" }; Write-Host \"@@@OK $s\" } catch { $fails+=$s; Write-Host \"@@@FAIL $s : $_\" } }",
      "Write-Host \"@@@FAILURES: $($fails -join ' ')\"",
      "exit 0",
    ]
  }

  // STOP — VSExtensions + Rust intentionally omitted. They live in windows-2022-resume, which
  // boots this image's qcow2 as a backing disk to iterate them fast. See the resume cell + README.
}
