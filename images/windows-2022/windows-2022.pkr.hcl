// Windows Server 2022 runner image — built with Packer's QEMU builder.
// Unlike a hand-rolled FirstLogonCommands script, Packer connects over WinRM and
// runs every provisioning step remotely with full logs + a clean shutdown. The
// Autounattend only bootstraps WinRM; everything else is Packer provisioners.
//
//   PACKER_PLUGIN_PATH=... packer init  windows-2022.pkr.hcl
//   packer build -var windows_iso=/path/win-2022.iso -var virtio_iso=/path/virtio-win.iso windows-2022.pkr.hcl

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

source "qemu" "windows2022" {
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
  vm_name          = "windows-2022.qcow2"
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
  sources = ["source.qemu.windows2022"]

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
      "foreach ($s in @('Configure-WindowsDefender.ps1','Configure-PowerShell.ps1','Install-PowerShellModules.ps1','Install-WindowsFeatures.ps1','Install-Chocolatey.ps1','Configure-BaseImage.ps1','Configure-ImageDataFile.ps1','Configure-SystemEnvironment.ps1','Configure-DotnetSecureChannel.ps1')) { Write-Host \"@@@RUN $s\"; try { $global:LASTEXITCODE=0; [Environment]::GetEnvironmentVariables('Machine').GetEnumerator()|%{[Environment]::SetEnvironmentVariable($_.Name,$_.Value,'Process')};$env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User');$global:LASTEXITCODE=(Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',\"$b\\$s\") -Wait -PassThru -NoNewWindow).ExitCode; if ($LASTEXITCODE -gt 0 -and $s -notin $noisy) { throw \"exit $LASTEXITCODE\" }; Write-Host \"@@@OK $s\" } catch { if ($s -in $noisy) { Write-Host \"@@@OK $s (noisy ignored: $_)\" } else { $fails+=$s; Write-Host \"@@@FAIL $s : $_\" } } }",
      "choco install -y --no-progress 7zip.install 2>&1 | Out-Null; Write-Host '7zip via choco'",
      "Write-Host \"@@@FAILURES: $($fails -join ' ')\"",
      "exit 0",
    ]
  }
  provisioner "windows-restart" { restart_timeout = "30m" }

  // group 2 — docker + powershell core + TortoiseSVN (2022-only — its sibling 2025 build drops it)
  provisioner "powershell" {
    environment_vars = local.ri_env
    inline = [
      "$ErrorActionPreference='Continue'; $b='C:\\image\\scripts\\build'; $fails=@()",
      "foreach ($s in @('Install-Docker.ps1','Install-DockerWinCred.ps1','Install-DockerCompose.ps1','Install-PowershellCore.ps1','Install-WebPlatformInstaller.ps1','Install-TortoiseSvn.ps1')) { Write-Host \"@@@RUN $s\"; try { $global:LASTEXITCODE=0; [Environment]::GetEnvironmentVariables('Machine').GetEnumerator()|%{[Environment]::SetEnvironmentVariable($_.Name,$_.Value,'Process')};$env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User');$global:LASTEXITCODE=(Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',\"$b\\$s\") -Wait -PassThru -NoNewWindow).ExitCode; if ($LASTEXITCODE -gt 0) { throw \"exit $LASTEXITCODE\" }; Write-Host \"@@@OK $s\" } catch { $fails+=$s; Write-Host \"@@@FAIL $s : $_\" } }",
      "Write-Host \"@@@FAILURES: $($fails -join ' ')\"",
      "exit 0",
    ]
  }
  provisioner "windows-restart" { restart_timeout = "30m" }

  // group 3a — Visual Studio in its own provisioner (mirrors the real build.windows-2022 template).
  // Server 2022's VS bootstrapper signals reboot-required by calling exit 3010/16001; run it bare
  // with valid_exit_codes so packer accepts that instead of aborting, then a windows-restart.
  provisioner "powershell" {
    environment_vars = local.ri_env
    valid_exit_codes = [0, 3010, 16001]
    inline = [
      "Write-Host '@@@RUN Install-VisualStudio.ps1'",
      "& 'C:\\image\\scripts\\build\\Install-VisualStudio.ps1'",
    ]
  }
  provisioner "windows-restart" { restart_timeout = "30m" }

  // group 3b — confirm VS installed via vswhere (for the @@@OK tally; the bootstrapper's reboot
  // exit code isn't a failure), then kubernetes tools.
  provisioner "powershell" {
    environment_vars = local.ri_env
    inline = [
      "$ErrorActionPreference='Continue'; $b='C:\\image\\scripts\\build'; $fails=@()",
      "$vsw='C:\\Program Files (x86)\\Microsoft Visual Studio\\Installer\\vswhere.exe'; if ((Test-Path $vsw) -and (& $vsw -latest -property catalog_productDisplayVersion)) { Write-Host '@@@OK Install-VisualStudio.ps1 (vswhere confirms VS; reboot exit-code handled)' } else { $fails+='Install-VisualStudio.ps1'; Write-Host '@@@FAIL Install-VisualStudio.ps1 : vswhere found no VS' }",
      "foreach ($s in @('Install-KubernetesTools.ps1')) { Write-Host \"@@@RUN $s\"; try { $global:LASTEXITCODE=0; [Environment]::GetEnvironmentVariables('Machine').GetEnumerator()|%{[Environment]::SetEnvironmentVariable($_.Name,$_.Value,'Process')};$env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User');$global:LASTEXITCODE=(Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',\"$b\\$s\") -Wait -PassThru -NoNewWindow).ExitCode; if ($LASTEXITCODE -gt 0) { throw \"exit $LASTEXITCODE\" }; Write-Host \"@@@OK $s\" } catch { $fails+=$s; Write-Host \"@@@FAIL $s : $_\" } }",
      "Write-Host \"@@@FAILURES: $($fails -join ' ')\"",
      "exit 0",
    ]
  }
  provisioner "windows-restart" { restart_timeout = "30m" }

  // group 4 — Wix, WDK (2022-only), VS extensions, cloud CLIs, java, kotlin, openssl. pause_before
  // lets VS servicing settle after the group-3 reboot (real template's pause_before=2m0s) so the
  // VSExtensions MSI doesn't hit a pending-reboot 1603. Service Fabric SDK is split out below.
  provisioner "powershell" {
    environment_vars = local.ri_env
    pause_before     = "2m0s"
    inline = [
      "$ErrorActionPreference='Continue'; $b='C:\\image\\scripts\\build'; $fails=@(); $noisy=@('Configure-BaseImage.ps1','Install-AzureDevOpsCli.ps1')",
      "foreach ($s in @('Install-Wix.ps1','Install-WDK.ps1','Install-VSExtensions.ps1','Install-AzureCli.ps1','Install-AzureDevOpsCli.ps1','Install-ChocolateyPackages.ps1','Install-JavaTools.ps1','Install-Kotlin.ps1','Install-OpenSSL.ps1')) { Write-Host \"@@@RUN $s\"; try { $global:LASTEXITCODE=0; [Environment]::GetEnvironmentVariables('Machine').GetEnumerator()|%{[Environment]::SetEnvironmentVariable($_.Name,$_.Value,'Process')};$env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User');$global:LASTEXITCODE=(Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',\"$b\\$s\") -Wait -PassThru -NoNewWindow).ExitCode; if ($LASTEXITCODE -gt 0 -and $s -notin $noisy) { throw \"exit $LASTEXITCODE\" }; Write-Host \"@@@OK $s\" } catch { if ($s -in $noisy) { Write-Host \"@@@OK $s (noisy ignored: $_)\" } else { $fails+=$s; Write-Host \"@@@FAIL $s : $_\" } } }",
      "Write-Host \"@@@FAILURES: $($fails -join ' ')\"",
      "exit 0",
    ]
  }

  // group 4b — Service Fabric SDK in its own provisioner with execution_policy=remotesigned,
  // then a reboot — exactly what the real template does (must install after VS, with a clean
  // reboot, or its installer returns exit 1).
  provisioner "powershell" {
    environment_vars = local.ri_env
    execution_policy = "remotesigned"
    inline = [
      "$ErrorActionPreference='Continue'; $b='C:\\image\\scripts\\build'; $fails=@()",
      "$s='Install-ServiceFabricSDK.ps1'; Write-Host \"@@@RUN $s\"; try { $global:LASTEXITCODE=0; [Environment]::GetEnvironmentVariables('Machine').GetEnumerator()|%{[Environment]::SetEnvironmentVariable($_.Name,$_.Value,'Process')};$env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User');$global:LASTEXITCODE=(Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',\"$b\\$s\") -Wait -PassThru -NoNewWindow).ExitCode; if ($LASTEXITCODE -gt 0) { throw \"exit $LASTEXITCODE\" }; Write-Host \"@@@OK $s\" } catch { $fails+=$s; Write-Host \"@@@FAIL $s : $_\" }",
      "Write-Host \"@@@FAILURES: $($fails -join ' ')\"",
      "exit 0",
    ]
  }
  provisioner "windows-restart" { restart_timeout = "30m" }

  // group 5a — the big batch: hosted-toolcache, every language, browsers + selenium, build tools
  // (Mercurial + NSIS + AliyunCli are 2022-only — 2025's build drops them). Up to RootCA; the
  // DB/MSI-heavy tail is split into 5b after a reboot so its MSIs don't hit a pending-reboot 1603
  // (MongoDB) left by the toolcache/SQL/DACFx installer churn here.
  provisioner "powershell" {
    environment_vars = local.ri_env
    inline = [
      "$ErrorActionPreference='Continue'; $b='C:\\image\\scripts\\build'; $fails=@()",
      "foreach ($s in @('Install-ActionsCache.ps1','Install-Ruby.ps1','Install-PyPy.ps1','Install-Toolset.ps1','Configure-Toolset.ps1','Install-NodeJS.ps1','Install-AndroidSDK.ps1','Install-PowershellAzModules.ps1','Install-Pipx.ps1','Install-Git.ps1','Install-GitHub-CLI.ps1','Install-PHP.ps1','Install-Rust.ps1','Install-Sbt.ps1','Install-Chrome.ps1','Install-EdgeDriver.ps1','Install-Firefox.ps1','Install-Selenium.ps1','Install-IEWebDriver.ps1','Install-Apache.ps1','Install-Nginx.ps1','Install-Msys2.ps1','Install-WinAppDriver.ps1','Install-R.ps1','Install-AWSTools.ps1','Install-DACFx.ps1','Install-MysqlCli.ps1','Install-SQLPowerShellTools.ps1','Install-SQLOLEDBDriver.ps1','Install-DotnetSDK.ps1','Install-Mingw64.ps1','Install-Haskell.ps1','Install-Stack.ps1','Install-Miniconda.ps1','Install-Mercurial.ps1','Install-Zstd.ps1','Install-NSIS.ps1','Install-Vcpkg.ps1','Install-Bazel.ps1','Install-AliyunCli.ps1','Install-RootCA.ps1')) { Write-Host \"@@@RUN $s\"; try { $global:LASTEXITCODE=0; [Environment]::GetEnvironmentVariables('Machine').GetEnumerator()|%{[Environment]::SetEnvironmentVariable($_.Name,$_.Value,'Process')};$env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User');$global:LASTEXITCODE=(Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',\"$b\\$s\") -Wait -PassThru -NoNewWindow).ExitCode; if ($LASTEXITCODE -gt 0) { throw \"exit $LASTEXITCODE\" }; Write-Host \"@@@OK $s\" } catch { $fails+=$s; Write-Host \"@@@FAIL $s : $_\" } }",
      "Write-Host \"@@@FAILURES: $($fails -join ' ')\"",
      "exit 0",
    ]
  }
  provisioner "windows-restart" { restart_timeout = "30m" }

  // group 5b — databases + final build tools after a reboot (MongoDB/LLVM clear their 1603s).
  // CodeQL pulls its bundle tag from the GitHub API unauthenticated and PostgreSQL probes
  // EnterpriseDB — both can rate-limit/403 from one build IP; tracked as known-flaky externals.
  provisioner "powershell" {
    environment_vars = local.ri_env
    inline = [
      "$ErrorActionPreference='Continue'; $b='C:\\image\\scripts\\build'; $fails=@()",
      "foreach ($s in @('Install-MongoDB.ps1','Install-CodeQLBundle.ps1','Configure-Diagnostics.ps1','Install-PostgreSQL.ps1','Configure-DynamicPort.ps1','Configure-GDIProcessHandleQuota.ps1','Configure-Shell.ps1','Configure-DeveloperMode.ps1','Install-LLVM.ps1')) { Write-Host \"@@@RUN $s\"; try { $global:LASTEXITCODE=0; [Environment]::GetEnvironmentVariables('Machine').GetEnumerator()|%{[Environment]::SetEnvironmentVariable($_.Name,$_.Value,'Process')};$env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User');$global:LASTEXITCODE=(Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',\"$b\\$s\") -Wait -PassThru -NoNewWindow).ExitCode; if ($LASTEXITCODE -gt 0) { throw \"exit $LASTEXITCODE\" }; Write-Host \"@@@OK $s\" } catch { $fails+=$s; Write-Host \"@@@FAIL $s : $_\" } }",
      "Write-Host \"@@@FAILURES: $($fails -join ' ')\"",
      "exit 0",
    ]
  }
  provisioner "windows-restart" { restart_timeout = "30m" }

  // group 6 — finalize (skip Install-WindowsUpdatesAfterReboot + Post-Build-Validation)
  provisioner "powershell" {
    environment_vars = local.ri_env
    inline = [
      "$ErrorActionPreference='Continue'; $b='C:\\image\\scripts\\build'; $fails=@(); $noisy=@('Configure-User.ps1')",
      "foreach ($s in @('Invoke-Cleanup.ps1','Install-NativeImages.ps1','Configure-System.ps1','Configure-User.ps1')) { Write-Host \"@@@RUN $s\"; try { $global:LASTEXITCODE=0; [Environment]::GetEnvironmentVariables('Machine').GetEnumerator()|%{[Environment]::SetEnvironmentVariable($_.Name,$_.Value,'Process')};$env:Path=[Environment]::GetEnvironmentVariable('Path','Machine')+';'+[Environment]::GetEnvironmentVariable('Path','User');$global:LASTEXITCODE=(Start-Process powershell -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-File',\"$b\\$s\") -Wait -PassThru -NoNewWindow).ExitCode; if ($LASTEXITCODE -gt 0 -and $s -notin $noisy) { throw \"exit $LASTEXITCODE\" }; Write-Host \"@@@OK $s\" } catch { if ($s -in $noisy) { Write-Host \"@@@OK $s (noisy ignored: $_)\" } else { $fails+=$s; Write-Host \"@@@FAIL $s : $_\" } } }",
      "Write-Host \"@@@FAILURES: $($fails -join ' ')\"",
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
