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
  disk_size      = "60G"
  format         = "qcow2"
  accelerator    = "kvm"
  qemuargs       = [["-cpu", "host"]]
  cpus           = 4
  memory         = 4096
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
      "sudo chmod -R 777 /imagegeneration",
      "rm -rf /tmp/ri /tmp/ri.tar.gz",
    ]
  }

  # 2. Configure + install the curated common-CI toolchain in dependency order. Runs as
  #    root with the env every runner-images script assumes; set -e → any failure fails the
  #    build, set -x → the log shows which script ran. Bump the list to go fatter.
  provisioner "shell" {
    environment_vars = [
      "HELPER_SCRIPTS=/imagegeneration/helpers",
      "INSTALLER_SCRIPT_FOLDER=/imagegeneration/installers",
      "IMAGE_FOLDER=/imagegeneration",
      "IMAGE_VERSION=${local.ri_ref}",
      "IMAGE_OS=ubuntu24",
      "DEBIAN_FRONTEND=noninteractive",
      "AGENT_TOOLSDIRECTORY=/opt/hostedtoolcache",
    ]
    execute_command = "chmod +x {{ .Path }}; sudo -E bash -c '{{ .Vars }} {{ .Path }}'"
    inline = [
      "set -ex",
      "i=$INSTALLER_SCRIPT_FOLDER",
      "bash $i/configure-apt-sources.sh",
      "bash $i/configure-apt.sh",
      "bash $i/configure-limits.sh",
      "bash $i/install-ms-repos.sh",
      "bash $i/install-apt-vital.sh",
      "bash $i/install-apt-common.sh",
      "bash $i/configure-environment.sh",
      "bash $i/install-powershell.sh",
      "bash $i/install-git.sh",
      "bash $i/install-gcc-compilers.sh",
      "bash $i/install-container-tools.sh",
      "bash $i/install-docker.sh",
      "bash $i/install-nodejs.sh",
      "bash $i/install-python.sh",
      "bash $i/install-dotnetcore-sdk.sh",
      "bash $i/install-cmake.sh",
      "bash $i/install-clang.sh",
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
