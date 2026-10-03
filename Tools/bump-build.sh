#!/bin/sh
# Bump the app's build number (CURRENT_PROJECT_VERSION of the PigTV app and the
# Top Shelf extension, Debug and Release). Every commit that changes the app
# runs this, so no two distributed builds share a number.
#
#   sh Tools/bump-build.sh        # current + 1
#   sh Tools/bump-build.sh 40     # set to 40
#
# The test targets keep CURRENT_PROJECT_VERSION = 1; the shipping number is the
# other value, and every line holding it must agree or nothing is changed.

set -e
cd "$(dirname "$0")/.."
pbxproj="PigTV.xcodeproj/project.pbxproj"

values=$(sed -n 's/.*CURRENT_PROJECT_VERSION = \([0-9][0-9]*\);.*/\1/p' "$pbxproj" | grep -vx 1 | sort -u)
count=$(printf '%s\n' "$values" | grep -c . || true)
if [ "$count" -ne 1 ]; then
    echo "error: expected one shipping build number in $pbxproj, found: $(echo $values)" >&2
    exit 1
fi
current=$values

new=${1:-$((current + 1))}
if ! printf '%s' "$new" | grep -qE '^[0-9]+$' || [ "$new" -le 1 ]; then
    echo "error: invalid build number: $new" >&2
    exit 1
fi

lines=$(grep -c "CURRENT_PROJECT_VERSION = $current;" "$pbxproj")
sed -i '' "s/CURRENT_PROJECT_VERSION = $current;/CURRENT_PROJECT_VERSION = $new;/" "$pbxproj"
if [ "$(grep -c "CURRENT_PROJECT_VERSION = $new;" "$pbxproj")" -ne "$lines" ]; then
    echo "error: not every shipping line was updated" >&2
    exit 1
fi
echo "build $current -> $new"
