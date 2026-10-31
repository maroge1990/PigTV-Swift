#!/bin/sh
# Install this tree's app on one of Mark's own devices, until TestFlight is available. Run ON THE MAC, in a terminal
# Mark can type into (signing needs his login keychain, which is locked to a plain SSH session):
#
#   ssh -t mac 'cd ~/pigtv-build/b3-swift && sh Tools/install-device.sh "iPad"'
#
# from the Claude desktop app's Terminal panel (run_in_terminal), so the password prompt appears where Mark can answer
# it. The device is named as `xcrun devicectl list devices` shows it ("iPad", "PiGPhone", "Downstairs Living Room",
# "Upstairs Living Room", "Mark Office"); it must be on, awake and on the home network. The Release build is signed
# with the project's team: on the free team the app stops opening after 7 days, and running this again renews it.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
NAME="${1:?usage: sh Tools/install-device.sh \"<device name>\"}"

LIST="$(mktemp)"
trap 'rm -f "$LIST"' EXIT
xcrun devicectl list devices --json-output "$LIST" >/dev/null
# The device's UDID and platform, from the paired physical devices with that name.
INFO="$(python3 - "$LIST" "$NAME" <<'EOF'
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
for d in devices:
    props, hw = d.get("deviceProperties", {}), d.get("hardwareProperties", {})
    if props.get("name") == sys.argv[2] and hw.get("reality") == "physical":
        print(hw.get("udid", ""), hw.get("platform", ""))
        break
EOF
)"
UDID="${INFO% *}"
PLATFORM="${INFO#* }"
if [ -z "$UDID" ]; then
    echo "No paired device called \"$NAME\". These are:" >&2
    xcrun devicectl list devices | sed -n '3,$p' | grep physical >&2 || true
    exit 1
fi
case "$PLATFORM" in
    tvOS) PRODUCTS=Release-appletvos ;;
    *)    PRODUCTS=Release-iphoneos ;;
esac
APP="$HOME/pigtv-build/dd-device/Build/Products/$PRODUCTS/PigTV.app"

echo "Unlocking the keychain (the Mac's login password; nothing shows while you type):"
security unlock-keychain "$HOME/Library/Keychains/login.keychain-db"
echo "Building PigTV for $NAME ($PLATFORM, a few minutes)..."
xcodebuild -quiet -project PigTV.xcodeproj -scheme PigTV -configuration Release -destination "id=$UDID" \
    -derivedDataPath "$HOME/pigtv-build/dd-device" -allowProvisioningUpdates build
echo "Installing on $NAME..."
xcrun devicectl device install app --device "$UDID" "$APP" >/dev/null
echo "Done: PigTV build $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist") is on $NAME."
