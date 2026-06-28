# Ubuntu 24.04 (Noble) arm64 runner image — built with Tart on an Apple Silicon Mac.
# The arm64 analog of the x86 `ubuntu-2404` cell (Packer/QEMU/qcow2): there's no arm64
# KVM host here, so we clone the cirruslabs Ubuntu Tart base (a maintained arm64 Linux
# image, the "consume" analog) and bake a broad runner toolset over SSH — the Linux
# sibling of the `macos-*` Tart cells. Result is the local Tart image `rif-ubuntu-2404-arm64`.
BASE_IMAGE="ghcr.io/cirruslabs/ubuntu:latest"
RUNNER_VERSION="2.335.1"
RUNNER_ARCH="arm64"
