#!/bin/bash
# Local, independent MIT build. Does not publish, install, or activate Pro.
set -euo pipefail
cd "$(dirname "$0")/.."
OUTPUT="${1:-$PWD/dist-lab}"
LAB_BUILD_DIR="${WHATCABLE_LAB_BUILD_DIR:-$PWD/.lab-build}"
# CLT 27 currently omits SwiftUIMacros. Its bundled 26.5 SDK supports the
# ordinary SwiftUI property wrappers used here without that missing plugin.
LAB_SDK="${WHATCABLE_LAB_SDK:-$(xcrun --show-sdk-path)}"
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    LAB_SDK="${WHATCABLE_LAB_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
fi
export CLANG_MODULE_CACHE_PATH="$LAB_BUILD_DIR/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$LAB_BUILD_DIR/swift-cache"
LAB_SWIFT="${WHATCABLE_LAB_SWIFT:-/Library/Developer/CommandLineTools/usr/bin/swift}"
LAB_HOST_DEVELOPER="${WHATCABLE_LAB_DEVELOPER_DIR:-/Library/Developer/CommandLineTools}"
if [[ ! -x "$LAB_SWIFT" ]]; then
    LAB_SWIFT="$(xcrun --find swift)"; LAB_HOST_DEVELOPER="$(xcode-select -p)"
fi
DEVELOPER_DIR="$LAB_HOST_DEVELOPER" "$LAB_SWIFT" build -c release --scratch-path "$LAB_BUILD_DIR" --disable-sandbox --sdk "$LAB_SDK"
LAB_PRODUCTS="$(DEVELOPER_DIR="$LAB_HOST_DEVELOPER" "$LAB_SWIFT" build -c release --scratch-path "$LAB_BUILD_DIR" --disable-sandbox --sdk "$LAB_SDK" --show-bin-path)"
python3 scripts/build-lab-widget.py "$LAB_BUILD_DIR"
python3 scripts/package-lab.py "$LAB_PRODUCTS" "$OUTPUT" "$LAB_BUILD_DIR/widget-products/Release/LabDesktopWidget.appex"
