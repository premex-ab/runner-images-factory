#!/bin/bash
# Functional gate, run again after reboot before promoting the image.
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
xcrun --sdk iphoneos --show-sdk-version
xcrun --sdk iphonesimulator --show-sdk-version
xcrun simctl list runtimes -j | python3 -c '
import json, os, sys
runtime = "com.apple.CoreSimulator.SimRuntime.iOS-" + os.environ["IOS_RUNTIME"].replace(".", "-")
assert any(r["identifier"] == runtime and r.get("isAvailable") and
           (not os.environ["IOS_RUNTIME_BUILD"] or r.get("buildversion") == os.environ["IOS_RUNTIME_BUILD"])
           for r in json.load(sys.stdin)["runtimes"]), "The pinned iOS runtime/build is missing"
'
probe=$(mktemp -d)
device=''
cleanup() {
  if [[ -n "$device" ]]; then
    xcrun simctl shutdown "$device" >/dev/null 2>&1 || true
    xcrun simctl delete "$device" >/dev/null 2>&1 || true
  fi
  rm -rf "$probe"
}
trap cleanup EXIT
# Import UIKit and link for BOTH destinations: clang/swift --version also pass on CLT.
printf 'import UIKit\nprint(UIDevice.current.systemName)\n' > "$probe/main.swift"
for sdk in iphoneos iphonesimulator; do
  target=arm64-apple-ios16.0
  [[ "$sdk" != iphonesimulator ]] || target="$target-simulator"
  xcrun --sdk "$sdk" swiftc -sdk "$(xcrun --sdk "$sdk" --show-sdk-path)" -target "$target" "$probe/main.swift" -o "$probe/$sdk"
done
device=$(xcrun simctl create 'image-verification' "$IOS_DEVICE_TYPE" "com.apple.CoreSimulator.SimRuntime.iOS-${IOS_RUNTIME//./-}")
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
xcrun simctl spawn "$device" "$probe/iphonesimulator" | grep -x iOS >/dev/null
echo "CHECK xcode-ios OK: device + simulator compiled; iOS $IOS_RUNTIME booted and executed UIKit"
