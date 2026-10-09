#!/bin/sh
# Copies the Pig family brand kit (1.6.0) into the app and renders the launch image. Idempotent: running it twice
# changes nothing. There is no brand generator any more; every brand image comes from the kit.
#
#   sh Tools/sync-brand.sh [path to Pig-Branding]     # default ../Pig-Branding
#
# Copies (kit: assets/products/pigtv):
#   mark.svg                           -> PigLogo.imageset (vector)
#   wordmark-light.svg / -dark.svg     -> BrandWordmark.imageset (vector, any + dark)
#   tokens/PigColors.xcassets/Pig{Success,Warning,Danger,Hover}.colorset -> same names in the app catalogue
#   AppleTV/dark/.../*.brandassets     -> "App Icon & Top Shelf Image.brandassets" (tvOS icon and Top Shelf; dark only)
#   Apple/IconComposer/*               -> PigTV/AppIcon.icon/Assets (halo-*.png, body.svg, face.svg, body-mono.svg, face-mono.svg)
# Renders: LaunchBrand.imageset (transparent: static halo + mark) with Tools/render-launch.swift + PigTV/BrandLayout.swift.
# PigTV/AppIcon.icon/icon.json is hand-maintained (Icon Composer) and is never touched.

set -e
cd "$(dirname "$0")/.."
kit=${1:-../Pig-Branding}
src="$kit/assets/products/pigtv"
if [ ! -f "$src/mark.svg" ]; then
    echo "error: $src/mark.svg not found (pass the Pig-Branding path as the first argument)" >&2
    exit 1
fi
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

assets=PigTV/Assets.xcassets
icon=PigTV/AppIcon.icon/Assets

# Vector mark and wordmark.
mkdir -p "$assets/PigLogo.imageset" "$assets/BrandWordmark.imageset"
cp "$src/mark.svg" "$assets/PigLogo.imageset/mark.svg"
cat > "$assets/PigLogo.imageset/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "mark.svg",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "preserves-vector-representation" : true
  }
}
JSON
cp "$src/wordmark-light.svg" "$assets/BrandWordmark.imageset/wordmark-light.svg"
cp "$src/wordmark-dark.svg" "$assets/BrandWordmark.imageset/wordmark-dark.svg"
cat > "$assets/BrandWordmark.imageset/Contents.json" <<'JSON'
{
  "images" : [
    {
      "filename" : "wordmark-light.svg",
      "idiom" : "universal"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "filename" : "wordmark-dark.svg",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "preserves-vector-representation" : true
  }
}
JSON

# Status colours (the kit's PigColors; names match the app's own colour roles).
for colour in PigSuccess PigWarning PigDanger PigHover; do
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
