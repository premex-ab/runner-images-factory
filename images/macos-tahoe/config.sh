# Full Xcode is standard. Pin the upstream content and simulator contract together.
BASE_IMAGE="ghcr.io/cirruslabs/macos-tahoe-xcode@sha256:61f6e857a3d65dd2f8daf9c51c7b837fa458bcc9181ae8556e645b534dab6bf6"
XCODE_VERSION="26.5"
IOS_RUNTIME="26.3"
# Apple publishes this runtime as 26.3.1; simctl identifies it as iOS-26-3.
IOS_RUNTIME_DOWNLOAD_VERSION="26.3.1"
IOS_RUNTIME_BUILD="23D8133"
IOS_DEVICE_TYPE="com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
RUNNER_VERSION="2.335.1"
