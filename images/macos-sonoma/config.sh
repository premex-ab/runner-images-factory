# Full Xcode is standard. Pin the upstream content and simulator contract together.
BASE_IMAGE="ghcr.io/cirruslabs/macos-sonoma-xcode@sha256:f181b76eede9acd7a6db76438a4cf73e76550c3f9e8104aed16347122e132184"
XCODE_VERSION="16.1"
IOS_RUNTIME="18.1"
IOS_DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro"
RUNNER_VERSION="2.335.1"
