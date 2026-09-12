# Full Xcode is standard. Pin the upstream content and simulator contract together.
BASE_IMAGE="ghcr.io/cirruslabs/macos-ventura-xcode@sha256:ca83d14f4399a6587e828a18bfe2392f9f61d62692d03781fdd3e0083cafc502"
XCODE_VERSION="14.3.1"
IOS_RUNTIME="16.4"
IOS_DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-14-Pro"
RUNNER_VERSION="2.335.1"
