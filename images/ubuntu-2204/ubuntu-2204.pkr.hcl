# Ubuntu 22.04 (Jammy) runner image — FULL actions/runner-images toolset (parity with
# ubuntu-22.04). Boots the official Ubuntu cloud qcow2 in QEMU/KVM, cloud-init brings up a
# throwaway SSH user, and Packer runs the complete runner-images install set (pinned to
# ri_ref). build.sh downloads the cloud image + generates the SSH keypair — nothing ships an OS.

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
  ri_ref = "ubuntu22/20260617.186"
}

source "qemu" "ubuntu2204" {
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
    "meta-data" = "instance-id: ubuntu-2204-build\nlocal-hostname: builder\n"
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
  vm_name              = "ubuntu-2204.qcow2"
}

build {
  sources = ["source.qemu.ubuntu2204"]

  # 1. Stage actions/runner-images @ri_ref (consume, don't fork): helpers + build scripts +
  #    toolset.json where the scripts expect them. Neutralize the Pester hook, and ship the
  #    real tests/Helpers.psm1 so the install-*.ps1 resolve Get-ToolsetContent (Common.Helpers
  #    chain) — only Invoke-PesterTests is no-op'd.
  provisioner "shell" {
    inline = [
      "set -ex",
      "sudo mkdir -p /imagegeneration/helpers /imagegeneration/installers",
      "curl -fsSL 'https://github.com/actions/runner-images/archive/refs/tags/${local.ri_ref}.tar.gz' -o /tmp/ri.tar.gz",
      "mkdir -p /tmp/ri && tar -xzf /tmp/ri.tar.gz -C /tmp/ri --strip-components=1",
      "sudo cp -r /tmp/ri/images/ubuntu/scripts/helpers/. /imagegeneration/helpers/",
      "sudo cp -r /tmp/ri/images/ubuntu/scripts/build/. /imagegeneration/installers/",
      "sudo cp /tmp/ri/images/ubuntu/toolsets/toolset-2204.json /imagegeneration/installers/toolset.json",
      "for h in /imagegeneration/helpers/*.sh; do printf '\\ninvoke_tests() { return 0; }\\n' | sudo tee -a \"$h\" >/dev/null; done",
      "printf '#!/bin/bash\\ninvoke_tests() { return 0; }\\n' | sudo tee /imagegeneration/helpers/invoke-tests.sh >/dev/null",
      "sudo mkdir -p /imagegeneration/tests",
      "sudo cp /tmp/ri/images/ubuntu/scripts/tests/Helpers.psm1 /imagegeneration/tests/Helpers.psm1",
      "printf '\\nfunction Invoke-PesterTests { param($TestFile,$TestName) }\\n' | sudo tee -a /imagegeneration/tests/Helpers.psm1 >/dev/null",
      "sudo chmod -R 777 /imagegeneration",
      "rm -rf /tmp/ri /tmp/ri.tar.gz",
    ]
  }

  # 2. FULL runner-images toolset (parity with ubuntu-22.04) — the complete ordered install set
  #    from build.ubuntu-22_04, minus only configure-apt-mock (Azure build infra). Discovery
  #    mode: NO set -e — run every script, log @@@OK/@@@FAIL, print @@@FAILURES at the end.
  #    .ps1 run via pwsh (installed earlier in the order). inline_shebang avoids Packer's -e.
  provisioner "shell" {
    environment_vars = [
      "HELPER_SCRIPTS=/imagegeneration/helpers",
      "INSTALLER_SCRIPT_FOLDER=/imagegeneration/installers",
      "IMAGE_FOLDER=/imagegeneration",
      "IMAGE_VERSION=${local.ri_ref}",
      "IMAGE_OS=ubuntu22",
      "IMAGEDATA_FILE=/imagegeneration/imagedata.json",
      "DEBIAN_FRONTEND=noninteractive",
      "AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache",
    ]
    execute_command = "chmod +x {{ .Path }}; sudo -E bash -c '{{ .Vars }} {{ .Path }}'"
    inline_shebang  = "/bin/bash"
    inline = [
      "set -x",
      "i=$INSTALLER_SCRIPT_FOLDER; fails=''",
      "printf 'APT::Get::Assume-Yes \"true\";\\nAPT::Get::Fix-Broken \"true\";\\n' > /etc/apt/apt.conf.d/90assumeyes",
      "for s in install-ms-repos.sh configure-apt-sources.sh configure-apt.sh configure-limits.sh configure-image-data.sh configure-environment.sh install-apt-vital.sh install-powershell.sh Install-PowerShellModules.ps1 Install-PowerShellAzModules.ps1 install-actions-cache.sh install-apt-common.sh install-azcopy.sh install-azure-cli.sh install-azure-devops-cli.sh install-bicep.sh install-aliyun-cli.sh install-apache.sh install-aws-tools.sh install-clang.sh install-swift.sh install-cmake.sh install-codeql-bundle.sh install-container-tools.sh install-dotnetcore-sdk.sh install-firefox.sh install-microsoft-edge.sh install-gcc-compilers.sh install-gfortran.sh install-git.sh install-git-lfs.sh install-github-cli.sh install-google-chrome.sh install-google-cloud-cli.sh install-haskell.sh install-heroku.sh install-java-tools.sh install-kubernetes-tools.sh install-oc-cli.sh install-leiningen.sh install-miniconda.sh install-mono.sh install-kotlin.sh install-mysql.sh install-mssql-tools.sh install-sqlpackage.sh install-nginx.sh install-nvm.sh install-nodejs.sh install-bazel.sh install-oras-cli.sh install-php.sh install-postgresql.sh install-pulumi.sh install-ruby.sh install-rlang.sh install-rust.sh install-julia.sh install-sbt.sh install-selenium.sh install-terraform.sh install-packer.sh install-vcpkg.sh configure-dpkg.sh install-yq.sh install-android-sdk.sh install-pypy.sh install-python.sh install-zstd.sh install-ninja.sh install-docker.sh Install-Toolset.ps1 Configure-Toolset.ps1 install-pipx-packages.sh install-homebrew.sh configure-snap.sh configure-system.sh; do echo \"@@@RUN $s\"; if [ \"$${s##*.}\" = ps1 ]; then pwsh \"$i/$s\" </dev/null; else bash \"$i/$s\" </dev/null; fi; rc=$?; if [ $rc -ne 0 ]; then fails=\"$fails $s($rc)\"; echo \"@@@FAIL $s rc=$rc\"; else echo \"@@@OK $s\"; fi; done",
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
