#!/bin/bash
# Runs in the guest. No account credentials or project signing keys belong here.
set -euo pipefail
eval "$(/opt/homebrew/bin/brew shellenv)"
DEVELOPER_DIR="$(xcode-select -p)"
export DEVELOPER_DIR
: "${XCODE_VERSION:?Set XCODE_VERSION}"
: "${IOS_RUNTIME:?Set IOS_RUNTIME}"
: "${IOS_DEVICE_TYPE:?Set IOS_DEVICE_TYPE}"
export IOS_RUNTIME IOS_DEVICE_TYPE
export IOS_RUNTIME_BUILD="${IOS_RUNTIME_BUILD:-}"
xcodebuild -version | grep -Fx "Xcode $XCODE_VERSION" >/dev/null
sudo xcodebuild -license accept
sudo xcodebuild -runFirstLaunch
xcrun --sdk iphoneos --show-sdk-version
xcrun --sdk iphonesimulator --show-sdk-version
# Keep the runtime stable for consumers' snapshot tests, independent of the SDK.
if ! xcrun simctl list runtimes -j | python3 -c '
import json, os, sys
sys.exit(not any(r["identifier"] == "com.apple.CoreSimulator.SimRuntime.iOS-" + os.environ["IOS_RUNTIME"].replace(".", "-") and r.get("isAvailable") and (not os.environ["IOS_RUNTIME_BUILD"] or r.get("buildversion") == os.environ["IOS_RUNTIME_BUILD"]) for r in json.load(sys.stdin)["runtimes"]))
'; then
  if [[ -n "${IOS_RUNTIME_DMG:-}" ]]; then
    xcrun simctl runtime add "$IOS_RUNTIME_DMG"
  elif ! xcodebuild -downloadPlatform iOS -buildVersion "${IOS_RUNTIME_DOWNLOAD_VERSION:-$IOS_RUNTIME}"; then
    echo 'Apple does not offer the pinned runtime. Supply IOS_RUNTIME_DMG on the build host.' >&2
    exit 1
  fi
fi
# simctl imports its own copy. Do not leave the upload in the sealed image.
[[ -z "${IOS_RUNTIME_DMG:-}" ]] || rm -f "$IOS_RUNTIME_DMG"
device_name=$(xcrun simctl list devicetypes -j | python3 -c '
import json, os, sys
print(next(d["name"] for d in json.load(sys.stdin)["devicetypes"] if d["identifier"] == os.environ["IOS_DEVICE_TYPE"]))
')
export device_name
if ! xcrun simctl list devices available -j | python3 -c '
import json, os, sys
runtime = "com.apple.CoreSimulator.SimRuntime.iOS-" + os.environ["IOS_RUNTIME"].replace(".", "-")
sys.exit(not any(d["name"] == os.environ["device_name"] for d in json.load(sys.stdin)["devices"].get(runtime, [])))
'; then
  xcrun simctl create "$device_name" "$IOS_DEVICE_TYPE" "com.apple.CoreSimulator.SimRuntime.iOS-${IOS_RUNTIME//./-}"
fi
: "${RUNNER_VERSION:=2.335.1}"
mkdir -p ~/actions-runner
cd ~/actions-runner
curl -fsSL --retry 3 -o runner.tar.gz "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-osx-arm64-${RUNNER_VERSION}.tar.gz"
tar xzf runner.tar.gz
rm runner.tar.gz
