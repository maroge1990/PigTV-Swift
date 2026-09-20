#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BUILD_DIR="${PIGTV_TEST_BUILD_DIR:-$(mktemp -d)}"
mkdir -p "$BUILD_DIR"
xcrun swiftc -parse-as-library -module-name PigTVContractTests \
  -module-cache-path "$BUILD_DIR/module-cache" \
  PigTV/Models.swift PigTV/DVRModels.swift PigTV/APIClient.swift PigTV/PlaybackCapabilities.swift PigTVTests/ContractChecks.swift \
  Tools/RunContractChecks.swift -o "$BUILD_DIR/contracts"
"$BUILD_DIR/contracts"
