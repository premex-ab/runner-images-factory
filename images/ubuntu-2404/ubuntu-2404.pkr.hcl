# Ubuntu 24.04 (Noble) runner image. Boots the official Ubuntu cloud qcow2 in QEMU/KVM,
# cloud-init brings up a throwaway SSH user, and Packer provisions over SSH with a curated
# subset of actions/runner-images' Ubuntu install scripts (pinned to ri_ref). build.sh
# downloads the cloud image + generates the SSH keypair — nothing here ships an OS.

packer {
  required_plugins {
    qemu = {
      source  = "github.com/hashicorp/qemu"
      version = "~> 1"
    }
  }
}

variable "cloud_image" { type = string }
variable "ssh_pubkey" { type = string }
variable "ssh_private_key_file" { type = string }
variable "output_dir" { type = string }
variable "runner_version" {
  type    = string
  default = "2.335.1"
}

locals {
  # actions/runner-images pin — bump to track upstream.
  ri_ref = "ubuntu24/20260615.205"
}

source "qemu" "ubuntu2404" {
  iso_url        = var.cloud_image
  iso_checksum   = "none"
  disk_image     = true
  disk_size      = "90G"
  format         = "qcow2"
  accelerator    = "kvm"
  qemuargs       = [["-cpu", "host"]]
  cpus           = 6
  memory         = 8192
  headless       = true
  net_device     = "virtio-net"
  disk_interface = "virtio"

  # NoCloud seed: cloud-init creates the 'packer' user with our throwaway key (from build.sh).
  cd_label = "cidata"
  cd_content = {
    "meta-data" = "instance-id: ubuntu-2404-build\nlocal-hostname: builder\n"
    "user-data" = <<-EOT
      #cloud-config
      users:
        - name: packer
          sudo: "ALL=(ALL) NOPASSWD:ALL"
          shell: /bin/bash
          lock_passwd: true
          ssh_authorized_keys:
            - ${var.ssh_pubkey}
      ssh_pwauth: false
    EOT
  }

  ssh_username         = "packer"
  ssh_private_key_file = var.ssh_private_key_file
  ssh_timeout          = "15m"
  shutdown_command     = "sudo shutdown -P now"
  output_directory     = var.output_dir
  vm_name              = "ubuntu-2404.qcow2"
}

build {
  sources = ["source.qemu.ubuntu2404"]

  # 1. Stage actions/runner-images @ri_ref into the image (consume, don't fork): their
  #    helpers + build scripts + toolset.json, exactly where the scripts expect them. We
  #    stub invoke_tests (their Pester suite needs test files + infra we don't ship).
  provisioner "shell" {
    inline = [
      "set -ex",
      "sudo mkdir -p /imagegeneration/helpers /imagegeneration/installers",
      "curl -fsSL 'https://github.com/actions/runner-images/archive/refs/tags/${local.ri_ref}.tar.gz' -o /tmp/ri.tar.gz",
      "mkdir -p /tmp/ri && tar -xzf /tmp/ri.tar.gz -C /tmp/ri --strip-components=1",
      "sudo cp -r /tmp/ri/images/ubuntu/scripts/helpers/. /imagegeneration/helpers/",
      "sudo cp -r /tmp/ri/images/ubuntu/scripts/build/. /imagegeneration/installers/",
      "sudo cp /tmp/ri/images/ubuntu/toolsets/toolset-2404.json /imagegeneration/installers/toolset.json",
      # Neutralize their Pester hook (no test files/infra shipped). Scripts source one of the
      # helper libs and call invoke_tests; some resolve it to invoke-tests.sh (pwsh). No-op the
      # function in every helper, and replace invoke-tests.sh itself.
      "for h in /imagegeneration/helpers/*.sh; do printf '\\ninvoke_tests() { return 0; }\\n' | sudo tee -a \"$h\" >/dev/null; done",
      "printf '#!/bin/bash\\ninvoke_tests() { return 0; }\\n' | sudo tee /imagegeneration/helpers/invoke-tests.sh >/dev/null",
      # the install-*.ps1 Import tests/Helpers.psm1 + call Invoke-PesterTests at the end — no-op stub it.
      "sudo mkdir -p /imagegeneration/tests",
      "printf 'function Invoke-PesterTests { param($TestFile,$TestName) }\\nfunction ShouldReturnZeroExitCode { param($Command) $True }\\nfunction ShouldOutputTextMatchingRegex { param($Command,$Regex) $True }\\n' | sudo tee /imagegeneration/tests/Helpers.psm1 >/dev/null",
      "sudo chmod -R 777 /imagegeneration",
      "rm -rf /tmp/ri /tmp/ri.tar.gz",
    ]
  }

  # 2. FULL runner-images toolset (parity with ubuntu-latest) — the complete ordered install
  #    set from their build.ubuntu-24_04 template, minus only configure-apt-mock (Azure build
  #    infra). Discovery mode: NO set -e — run every script, log @@@OK/@@@FAIL, and print
  #    @@@FAILURES at the end, so one build surfaces the whole standalone-failure surface.
  #    .ps1 run via pwsh (installed by install-powershell.sh earlier in the order).
  provisioner "shell" {
    environment_vars = [
      "HELPER_SCRIPTS=/imagegeneration/helpers",
      "INSTALLER_SCRIPT_FOLDER=/imagegeneration/installers",
      "IMAGE_FOLDER=/imagegeneration",
      "IMAGE_VERSION=${local.ri_ref}",
      "IMAGE_OS=ubuntu24",
      "IMAGEDATA_FILE=/imagegeneration/imagedata.json",
      "DEBIAN_FRONTEND=noninteractive",
      "AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache",
    ]
    execute_command = "chmod +x {{ .Path }}; sudo -E bash -c '{{ .Vars }} {{ .Path }}'"
    inline_shebang  = "/bin/bash"   # Packer defaults to "/bin/sh -e"; we need NO -e for discovery
    inline = [
      "set -x",
      "i=$INSTALLER_SCRIPT_FOLDER; fails=''",
      # configure-apt-mock (skipped, Azure infra) is what normally makes apt non-interactive
      # this early; replicate just the assume-yes so install-ms-repos' dist-upgrade won't prompt.
      "printf 'APT::Get::Assume-Yes \"true\";\\nAPT::Get::Fix-Broken \"true\";\\n' > /etc/apt/apt.conf.d/90assumeyes",
      "for s in install-ms-repos.sh configure-apt-sources.sh configure-apt.sh configure-limits.sh configure-image-data.sh configure-environment.sh install-apt-vital.sh install-powershell.sh Install-PowerShellModules.ps1 Install-PowerShellAzModules.ps1 install-actions-cache.sh install-apt-common.sh install-azcopy.sh install-azure-cli.sh install-azure-devops-cli.sh install-bicep.sh install-apache.sh install-aws-tools.sh install-clang.sh install-swift.sh install-cmake.sh install-codeql-bundle.sh install-awf.sh install-container-tools.sh install-dotnetcore-sdk.sh install-microsoft-edge.sh install-gcc-compilers.sh install-firefox.sh install-gfortran.sh install-git.sh install-git-lfs.sh install-github-cli.sh install-google-chrome.sh install-google-cloud-cli.sh install-haskell.sh install-java-tools.sh install-kubernetes-tools.sh install-miniconda.sh install-kotlin.sh install-mysql.sh install-nginx.sh install-nvm.sh install-nodejs.sh install-bazel.sh install-php.sh install-postgresql.sh install-pulumi.sh install-ruby.sh install-rust.sh install-julia.sh install-selenium.sh install-packer.sh install-vcpkg.sh configure-dpkg.sh install-yq.sh install-android-sdk.sh install-pypy.sh install-python.sh install-zstd.sh install-ninja.sh install-docker.sh Install-Toolset.ps1 Configure-Toolset.ps1 install-pipx-packages.sh install-homebrew.sh configure-snap.sh configure-system.sh; do echo \"@@@RUN $s\"; if [ \"$${s##*.}\" = ps1 ]; then pwsh \"$i/$s\" </dev/null; else bash \"$i/$s\" </dev/null; fi; rc=$?; if [ $rc -ne 0 ]; then fails=\"$fails $s($rc)\"; echo \"@@@FAIL $s rc=$rc\"; else echo \"@@@OK $s\"; fi; done",
      "echo \"@@@FAILURES:$fails\"",
    ]
  }

  # 3. Some installs need a reboot to settle (kernel modules, group membership, sysctl).
  provisioner "shell" {
    expect_disconnect = true
    inline            = ["sudo reboot"]
  }

  # 4. Post-reboot: runner-images cleanup, then generalize so each clone boots fresh from
  #    its own cloud-init seed at deploy time (reset cloud-init + machine-id, drop the
  #    throwaway build key).
  provisioner "shell" {
    pause_before        = "30s"
    start_retry_timeout = "10m"
    environment_vars = [
      "HELPER_SCRIPTS=/imagegeneration/helpers",
      "INSTALLER_SCRIPT_FOLDER=/imagegeneration/installers",
      "IMAGE_FOLDER=/imagegeneration",
    ]
    execute_command = "chmod +x {{ .Path }}; sudo -E bash -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "set -x",
      "bash $INSTALLER_SCRIPT_FOLDER/cleanup.sh || true",
      "rm -rf /imagegeneration",
      "cloud-init clean --logs || true",
      "rm -f /home/packer/.ssh/authorized_keys",
      "truncate -s 0 /etc/machine-id",
    ]
  }
}
