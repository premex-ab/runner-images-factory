# Full Xcode is standard. Pin the upstream content and simulator contract together.
BASE_IMAGE="ghcr.io/cirruslabs/macos-sequoia-xcode@sha256:76122670c984f52fbbcb44cf3356001920c4dd881249b52afbd01a837553d22b"
XCODE_VERSION="26.3"
IOS_RUNTIME="26.3"
# Apple publishes this runtime as 26.3.1; simctl identifies it as iOS-26-3.
IOS_RUNTIME_DOWNLOAD_VERSION="26.3.1"
IOS_RUNTIME_BUILD="23D8133"
IOS_DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
RUNNER_VERSION="2.335.1"
