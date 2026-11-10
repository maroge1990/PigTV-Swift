#!/bin/sh
# Copies the Pig family brand kit (PigBrand: guide 1.8.1, token files 1.7.0) into the app and renders the launch image. Idempotent: running it twice
# changes nothing. There is no brand generator any more; every brand image comes from the kit.
#
#   sh Tools/sync-brand.sh [path to PigBrand]     # default ../PigBrand (~/code/PigBrand)
#
# Copies (kit: assets/products/pigtv):
#   mark.svg                           -> PigLogo.imageset (vector)
#   lockup-horizontal-light/-dark.svg  -> LockupHorizontal.imageset (vector, any + dark)
#   lockup-stacked-light/-dark.svg     -> LockupStacked.imageset (vector, any + dark)
#   tokens/PigColors.xcassets/Pig{Success,Warning,Danger,Hover}.colorset -> same names in the app catalogue
#   AppleTV/dark/.../*.brandassets     -> "App Icon & Top Shelf Image.brandassets" (tvOS icon and Top Shelf; dark only)
#   Apple/IconComposer/*               -> PigTV/AppIcon.icon/Assets (halo-*.png, body.svg, face.svg, body-mono.svg, face-mono.svg)
# Renders: LaunchBrand.imageset (transparent: static halo + mark) with Tools/render-launch.swift + PigTV/BrandLayout.swift.
# PigTV/AppIcon.icon/icon.json is hand-maintained (Icon Composer) and is never touched. So are the playback and shadow
# colours (PigMedia*.colorset, PigShadow.colorset): the kit has them as tokens (media.*, glass shadows), not as PigColors.

set -e
cd "$(dirname "$0")/.."
kit=${1:-../PigBrand}
src="$kit/assets/products/pigtv"
if [ ! -f "$src/mark.svg" ]; then
    echo "error: $src/mark.svg not found (pass the PigBrand path as the first argument)" >&2
    exit 1
fi
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

assets=PigTV/Assets.xcassets
icon=PigTV/AppIcon.icon/Assets

# Vector mark and lockups.
vector_set() { # name, light file, dark file (or "" for one file)
    rm -rf "$assets/$1.imageset"
    mkdir -p "$assets/$1.imageset"
    cp "$src/$2" "$assets/$1.imageset/$2"
    if [ -n "$3" ]; then
        cp "$src/$3" "$assets/$1.imageset/$3"
        dark=$(printf ',\n    {\n      "appearances" : [\n        {\n          "appearance" : "luminosity",\n          "value" : "dark"\n        }\n      ],\n      "filename" : "%s",\n      "idiom" : "universal"\n    }' "$3")
    else
        dark=""
    fi
    printf '{\n  "images" : [\n    {\n      "filename" : "%s",\n      "idiom" : "universal"\n    }%b\n  ],\n  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  },\n  "properties" : {\n    "preserves-vector-representation" : true\n  }\n}\n' "$2" "$dark" > "$assets/$1.imageset/Contents.json"
}
vector_set PigLogo mark.svg ""
vector_set LockupHorizontal lockup-horizontal-light.svg lockup-horizontal-dark.svg
vector_set LockupStacked lockup-stacked-light.svg lockup-stacked-dark.svg
rm -rf "$assets/BrandWordmark.imageset"

# Status colours (the kit's PigColors; names match the app's own colour roles).
for colour in PigSuccess PigWarning PigDanger; do
    rm -rf "$assets/$colour.colorset"
    cp -R "$kit/tokens/PigColors.xcassets/$colour.colorset" "$assets/$colour.colorset"
done

# tvOS icon and Top Shelf (one appearance only: asset names are shared).
brand="App Icon & Top Shelf Image.brandassets"
rm -rf "$assets/$brand"
cp -R "$src/AppleTV/dark/PigTVAssets.xcassets/$brand" "$assets/$brand"

# iOS icon layers (Icon Composer document PigTV/AppIcon.icon).
mkdir -p "$icon"
cp "$src/Apple/IconComposer/background-light.png" "$icon/halo-light.png"
cp "$src/Apple/IconComposer/background-dark.png" "$icon/halo-dark.png"
cp "$src/Apple/IconComposer/layer-1-body.svg" "$icon/body.svg"
cp "$src/Apple/IconComposer/layer-2-face.svg" "$icon/face.svg"
cp "$src/Apple/IconComposer/mono/layer-1-body.svg" "$icon/body-mono.svg"
cp "$src/Apple/IconComposer/mono/layer-2-face.svg" "$icon/face-mono.svg"

# Launch image: static halo + mark on a transparent background, sized from PigTV/BrandLayout.swift.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cp Tools/render-launch.swift "$tmp/main.swift"
swiftc -O PigTV/BrandLayout.swift "$tmp/main.swift" -o "$tmp/render-launch"
mkdir -p "$assets/LaunchBrand.imageset"
rm -f "$assets/LaunchBrand.imageset"/*.png
"$tmp/render-launch" "$src/mark.svg" "$assets/LaunchBrand.imageset"

echo "brand kit synced from $src"
