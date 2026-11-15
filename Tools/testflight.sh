#!/bin/sh
# Archive the app (Release) and upload it to App Store Connect for TestFlight. Run ON THE MAC, from its git clone
# (~/Documents/GitHub/PigTV-Swift), over plain SSH: no keychain password. The archive is unsigned
# (CODE_SIGNING_ALLOWED=NO); the export signs it with Apple's cloud-managed distribution certificate, authorised by an
# App Store Connect API key, and creates the profiles it needs (the Top Shelf extension, the App Group). As Piggyback does.
#
#   sh Tools/testflight.sh tvos|ios|both            archive and upload
#   sh Tools/testflight.sh tvos|ios|both --archive  archive only (checks the Release build)
#   sh Tools/testflight.sh tvos|ios|both --export   archive and cloud-sign into build/testflight/<platform>, no upload
#
# Needs an App Store Connect API key with the **Admin** role (an App Manager key fails with "Cloud signing permission
# error"), from the environment or ~/.pigtv-testflight.env (chmod 600); the names are in .env.example. The .p8 stays in
# ~/.appstoreconnect/private_keys/ on the Mac: never in the repository or a chat.
# An upload refuses unless the full UI run (`sh Tools/test.sh all`) passed for exactly this commit on a clean tree
# (D-49): it leaves .ui-full-passed holding the commit. There is no bypass; commit first, then run it again.
# --archive and --export upload nothing, so they need only a clean tree.
# The build number is the project's (Tools/bump-build.sh); every upload needs a new one.
set -eu
cd "$(dirname "$0")/.."
WHICH="${1:-both}"
MODE="${2:-}"
case "$MODE" in ""|--archive|--export) ;; *) echo "usage: sh Tools/testflight.sh tvos|ios|both [--archive|--export]" >&2; exit 2 ;; esac
need="run 'sh Tools/test.sh all' on a clean, committed tree, then try again"
command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1 \
    || { echo "testflight: this is not a git checkout, so the tested commit cannot be known: use the Mac's clone, then $need" >&2; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] \
    || { echo "testflight: uncommitted changes: commit them, then $need" >&2; exit 1; }
if [ -z "$MODE" ]; then
    [ -f .ui-full-passed ] && [ "$(cat .ui-full-passed)" = "$(git rev-parse HEAD)" ] \
        || { echo "testflight: the full UI tests have not passed for this commit: $need" >&2; exit 1; }
fi
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[ -f "$HOME/.pigtv-testflight.env" ] && . "$HOME/.pigtv-testflight.env"
: "${PIGTV_TEAM_ID:?set PIGTV_TEAM_ID}" "${PIGTV_ASC_KEY_ID:?set PIGTV_ASC_KEY_ID}" "${PIGTV_ASC_ISSUER_ID:?set PIGTV_ASC_ISSUER_ID}" "${PIGTV_ASC_KEY_PATH:?set PIGTV_ASC_KEY_PATH}"
[ -f "$PIGTV_ASC_KEY_PATH" ] || { echo "testflight: no API key file at PIGTV_ASC_KEY_PATH" >&2; exit 1; }
AUTH="-allowProvisioningUpdates -authenticationKeyPath $PIGTV_ASC_KEY_PATH -authenticationKeyID $PIGTV_ASC_KEY_ID -authenticationKeyIssuerID $PIGTV_ASC_ISSUER_ID"
BUILD="$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9]*\);.*/\1/p' PigTV.xcodeproj/project.pbxproj | grep -vx 1 | sort -u)"
[ "$(printf '%s\n' "$BUILD" | grep -c .)" -eq 1 ] || { echo "testflight: the app targets disagree on the build number: run Tools/bump-build.sh" >&2; exit 1; }
OUT="build/testflight"
mkdir -p "$OUT"
OPTIONS="$OUT/ExportOptions.plist"
cp Tools/ExportOptions-AppStore.plist "$OPTIONS"
/usr/libexec/PlistBuddy -c "Add :teamID string $PIGTV_TEAM_ID" "$OPTIONS"
[ "$MODE" = "--export" ] && /usr/libexec/PlistBuddy -c "Set :destination export" "$OPTIONS"

one() {
    platform="$1"; name="$2"
    echo "== archive $name, build $BUILD ($(git rev-parse --short HEAD)), unsigned"
    rm -rf "$OUT/PigTV-$name.xcarchive" "$OUT/$name"
    xcodebuild -quiet -project PigTV.xcodeproj -scheme PigTV -configuration Release -destination "generic/platform=$platform" \
        -archivePath "$OUT/PigTV-$name.xcarchive" DEVELOPMENT_TEAM="$PIGTV_TEAM_ID" CODE_SIGNING_ALLOWED=NO archive
    # An unsigned archive carries no entitlements, so the export would sign the app and Top Shelf without the App Group
    # they share (15 Nov 2026: groups None). An ad-hoc signature (no certificate, no keychain) puts them back; the export
    # replaces it with the cloud signature and keeps them. Extensions first, then the app that contains them.
    app="$OUT/PigTV-$name.xcarchive/Products/Applications/PigTV.app"
    for ext in "$app"/PlugIns/*.appex; do
        [ -d "$ext" ] && codesign --force --sign - --entitlements PigTVTopShelf/PigTVTopShelf.entitlements "$ext"
    done
    codesign --force --sign - --entitlements PigTV/PigTV.entitlements "$app"
    [ "$MODE" = "--archive" ] && return 0
    if [ "$MODE" = "--export" ]; then echo "== cloud-sign $name (no upload)"; else echo "== cloud-sign and upload $name"; fi
    # shellcheck disable=SC2086
    xcodebuild -exportArchive -archivePath "$OUT/PigTV-$name.xcarchive" -exportOptionsPlist "$OPTIONS" -exportPath "$OUT/$name" $AUTH
}

case "$WHICH" in
    tvos) one tvOS tvOS ;;
    ios)  one iOS iOS ;;
    both) one tvOS tvOS; one iOS iOS ;;
    *) echo "usage: sh Tools/testflight.sh tvos|ios|both [--archive|--export]" >&2; exit 2 ;;
esac
case "$MODE" in
    --archive) echo "== archived, not uploaded" ;;
    --export) echo "== cloud-signed into $OUT, not uploaded" ;;
    *) echo "== done: App Store Connect processes an upload in 10-30 minutes, then it appears under TestFlight" ;;
esac
