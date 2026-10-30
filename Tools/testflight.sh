#!/bin/sh
# Archive the app (Release) and upload it to App Store Connect for TestFlight. Run on the Mac.
#
#   sh Tools/testflight.sh tvos|ios|both            archive and upload
#   sh Tools/testflight.sh tvos|ios|both --archive  archive only (check signing without uploading)
#
# Needs the paid team and an App Store Connect API key (Users and Access → Integrations → App Store Connect API,
# role Admin or App Manager), from the environment or ~/.pigtv-testflight.env:
#   PIGTV_TEAM_ID       the developer program team (10 characters)
#   PIGTV_ASC_KEY_ID    the key's ID
#   PIGTV_ASC_ISSUER_ID the issuer ID shown above the keys
#   PIGTV_ASC_KEY_PATH  the downloaded AuthKey_<id>.p8 (kept outside the repository)
# Signing is automatic: the key lets xcodebuild register the bundle ids, the App Group and a distribution certificate.
# The build number is the project's (Tools/bump-build.sh); every upload needs a new one.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[ -f "$HOME/.pigtv-testflight.env" ] && . "$HOME/.pigtv-testflight.env"
: "${PIGTV_TEAM_ID:?set PIGTV_TEAM_ID}" "${PIGTV_ASC_KEY_ID:?set PIGTV_ASC_KEY_ID}" "${PIGTV_ASC_ISSUER_ID:?set PIGTV_ASC_ISSUER_ID}" "${PIGTV_ASC_KEY_PATH:?set PIGTV_ASC_KEY_PATH}"
WHICH="${1:-both}"
MODE="${2:-}"
AUTH="-allowProvisioningUpdates -authenticationKeyPath $PIGTV_ASC_KEY_PATH -authenticationKeyID $PIGTV_ASC_KEY_ID -authenticationKeyIssuerID $PIGTV_ASC_ISSUER_ID"
OUT="build/testflight"
mkdir -p "$OUT"
OPTIONS="$OUT/ExportOptions.plist"
cp Tools/ExportOptions-AppStore.plist "$OPTIONS"
/usr/libexec/PlistBuddy -c "Add :teamID string $PIGTV_TEAM_ID" "$OPTIONS"

one() {
    platform="$1"; name="$2"
    echo "== archive $name ($(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9]*\);.*/\1/p' PigTV.xcodeproj/project.pbxproj | grep -vx 1 | head -1))"
    # shellcheck disable=SC2086
    xcodebuild -quiet -project PigTV.xcodeproj -scheme PigTV -configuration Release -destination "generic/platform=$platform" \
        -archivePath "$OUT/PigTV-$name.xcarchive" DEVELOPMENT_TEAM="$PIGTV_TEAM_ID" $AUTH archive
    [ "$MODE" = "--archive" ] && return 0
    echo "== upload $name"
    # shellcheck disable=SC2086
    xcodebuild -exportArchive -archivePath "$OUT/PigTV-$name.xcarchive" -exportOptionsPlist "$OPTIONS" -exportPath "$OUT/$name" $AUTH
}

case "$WHICH" in
    tvos) one tvOS tvOS ;;
    ios)  one iOS iOS ;;
    both) one tvOS tvOS; one iOS iOS ;;
    *) echo "usage: sh Tools/testflight.sh tvos|ios|both [--archive]" >&2; exit 2 ;;
esac
echo "== done: App Store Connect processes an upload in 10-30 minutes, then it appears under TestFlight"
