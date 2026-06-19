# macOS 14 (sonoma) runner image — built with Tart (Apple Silicon Mac only).
# The cirruslabs base is a maintained macOS CI image (Xcode + Homebrew + the common
# toolchain) — the macOS analog of "consume runner-images". We clone it + bake the runner.
BASE_IMAGE="ghcr.io/cirruslabs/macos-sonoma-base:latest"
RUNNER_VERSION="2.335.1"
