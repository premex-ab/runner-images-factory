# macOS (Tahoe / macOS 26) runner image — built with Tart, not Packer/QEMU.
# The cirruslabs base is a maintained macOS CI image (Xcode + Homebrew + the common
# toolchain) — the macOS analog of "consume runner-images". We clone it + bake the runner.
BASE_IMAGE="ghcr.io/cirruslabs/macos-tahoe-base:latest"
RUNNER_VERSION="2.335.1"
