#!/bin/bash
# Runs ON the VM (piped to `bash -s` over SSH). The cirruslabs base already ships Xcode,
# Homebrew, git, node, python, ruby, etc., so the overlay is thin: bake the GitHub Actions
# runner so the image is ready for self-hosted use.
set -e
: "${RUNNER_VERSION:=2.335.1}"
mkdir -p ~/actions-runner && cd ~/actions-runner
curl -fsSL --retry 3 -o runner.tar.gz \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"
tar xzf runner.tar.gz && rm runner.tar.gz
echo "provisioned: actions-runner ${RUNNER_VERSION} baked; toolchain from the cirruslabs base"
