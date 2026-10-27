#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
LAB_BUILD_DIR="${WHATCABLE_LAB_BUILD_DIR:-$PWD/.lab-build}"
LAB_SDK="${WHATCABLE_LAB_SDK:-$(xcrun --show-sdk-path)}"
if [[ -d /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk ]]; then
    LAB_SDK="${WHATCABLE_LAB_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
fi
export WHATCABLE_LAB_CHECKS=1
export CLANG_MODULE_CACHE_PATH="$LAB_BUILD_DIR/clang-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$LAB_BUILD_DIR/swift-cache"
PLUGIN_ARGS=()
LAB_PLUGIN=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
if [[ -f "$LAB_PLUGIN" ]]; then
    PLUGIN_ARGS=(-Xswiftc -load-plugin-library -Xswiftc "$LAB_PLUGIN")
fi
DEVELOPER_DIR=/Library/Developer/CommandLineTools /Library/Developer/CommandLineTools/usr/bin/swift test -c release --scratch-path "$LAB_BUILD_DIR" --disable-sandbox --sdk "$LAB_SDK" \
    --disable-xctest "${PLUGIN_ARGS[@]}" \
    --filter 'ConnectionPersistenceTests|LabArchiveTests|LabWidgetTests|LabTests|RegressionAccumulator|ChargingDiagnostic|DataLinkDiagnostic|DisplayDiagnostic|CableResistanceTier'
