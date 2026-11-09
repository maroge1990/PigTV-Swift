#!/bin/sh
# The tvOS tests in tiers, cheapest first, so a failure shows within a minute instead of after the UI suites.
#
#   sh Tools/test.sh fast     contract checks, then the unit tests (~1 min after the build)
#   sh Tools/test.sh push     fast, then the regression UI tests (once per batch: before its review and before the push)
#   sh Tools/test.sh visual   the screenshot and appearance UI tests (before a release or a brand change, ~18 min with the review media)
#   sh Tools/test.sh all      push, then visual: the full UI run. CI does not run it (D-49); Tools/testflight.sh requires it
#                             to have passed for the exact commit it uploads (see the marker below)
#
# PIGTV_TEST_DESTINATION overrides the simulator. The simulator is shut down at the end: a booted tvOS simulator left
# running crash-loops its system daemons and loads the Mac.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TIER="${1:-push}"
DEST="${PIGTV_TEST_DESTINATION:-platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=27.0}"

# Screenshot/appearance suites. Every other UI suite is a regression test and runs before a push, so a new suite
# is in the push tier unless it is added here.
VISUAL="GuideScreensUITests BrandDepthUITests TabFlashUITests BrandSplashUITests TopShelfCardsUITests PigTVUITests PigTVUITestsLaunchTests"

# The contract checks run once, in the standalone step below; the unit-test wrapper that runs them again is skipped.
UNIT="-only-testing:PigTVTests -skip-testing:PigTVTests/PigTVTests/testServerContracts"

# `all` leaves this marker (the commit it passed on) for Tools/testflight.sh; any other run removes it first.
MARKER=".ui-full-passed"
rm -f "$MARKER"

xc() { xcodebuild -quiet -project PigTV.xcodeproj -scheme PigTV -destination "$DEST" "$@"; }
trap 'xcrun simctl shutdown all >/dev/null 2>&1 || true' EXIT

fast() {
    echo "== contract checks"
    sh Tools/test-contracts.sh
    echo "== unit tests"
    # shellcheck disable=SC2086
    xc test-without-building $UNIT
}
regression_ui() {
    echo "== regression UI tests"
    set --
    for s in $VISUAL; do set -- "$@" "-skip-testing:PigTVUITests/$s"; done
    xc test-without-building -only-testing:PigTVUITests "$@"
}
visual_ui() {
    # BrandDepthUITests' player checks need a local review movie; make it when ffmpeg is here, else they skip.
    if [ ! -f /private/tmp/pig-deep-media/review.mp4 ] && command -v ffmpeg >/dev/null 2>&1; then
        zsh Tools/generate-brand-review-media.sh >/dev/null 2>&1 || echo "(review media not generated; the player checks will skip)"
    fi
    echo "== visual UI tests"
    set --
    for s in $VISUAL; do set -- "$@" "-only-testing:PigTVUITests/$s"; done
    xc test-without-building "$@"
}

echo "== build for testing"
xc build-for-testing
case "$TIER" in
    fast)   fast ;;
    push)   fast; regression_ui ;;
    visual) visual_ui ;;
    all)    fast; regression_ui; visual_ui ;;
    *)      echo "usage: sh Tools/test.sh fast|push|visual|all" >&2; exit 2 ;;
esac
# The full UI run counts for TestFlight only on a clean, committed tree (tracked files; build/ is ignored).
if [ "$TIER" = all ] && command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1 \
    && [ -z "$(git status --porcelain --untracked-files=no)" ]; then
    git rev-parse HEAD > "$MARKER"
    echo "== full UI run recorded for $(git rev-parse --short HEAD)"
elif [ "$TIER" = all ]; then
    echo "== note: the tree is dirty or not a git checkout, so this run does not unlock Tools/testflight.sh"
fi
echo "== $TIER: passed"
