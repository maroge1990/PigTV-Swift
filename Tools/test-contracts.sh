#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
BUILD_DIR="${PIGTV_TEST_BUILD_DIR:-$(mktemp -d)}"
mkdir -p "$BUILD_DIR"
xcrun swiftc -parse-as-library -module-name PigTVContractTests \
  -module-cache-path "$BUILD_DIR/module-cache" \
  PigTV/Models.swift PigTV/DVRModels.swift PigTV/APIClient.swift PigTV/PrivateCaches.swift PigTV/PlaybackCapabilities.swift PigTV/Labs.swift PigTV/ProviderReminders.swift \
  PigTV/SportModels.swift PigTV/SportsGameModels.swift PigTV/F1PageModels.swift PigTV/SportBannerModels.swift PigTV/SportFrontModels.swift PigTV/CricketPageModels.swift \
  PigTV/SportFollowModels.swift PigTV/NFLPageModels.swift PigTV/LeaguePageModels.swift PigTV/SportEventsModels.swift \
  PigTV/SportFixtureModels.swift PigTV/SportMotorModels.swift \
  PigTVTests/ContractChecks.swift PigTVTests/GoldenChecks.swift \
  Tools/RunContractChecks.swift -o "$BUILD_DIR/contracts"
"$BUILD_DIR/contracts"
