#!/bin/sh
# The tvOS tests in tiers, cheapest first, so a failure shows within a minute instead of after the UI suites.
#
#   sh Tools/test.sh fast     contract checks, then the unit tests (~1 min after the build)
#   sh Tools/test.sh push     fast, then the regression UI tests (once per batch: before its review and before the push)
#   sh Tools/test.sh visual   the screenshot and appearance UI tests (before a release or a brand change, ~18 min with the review media)
#   sh Tools/test.sh ios      the unit tests (PigTVTests) on one iPad simulator, then one iPhone simulator, one after the other
#                             (#53). Not part of `all`; PIGTV_IPAD_SIM / PIGTV_IPHONE_SIM name the devices (default: the first
#                             available iPad, and iPhone 17e or else the first available iPhone; the choice is printed)
#   sh Tools/test.sh all      push, then visual: the full UI run. CI does not run it (D-49); Tools/testflight.sh requires it
#                             to have passed for the exact commit it uploads (see the marker below)
#   sh Tools/test.sh perf     the speed tests only (#362): GuidePerfUITests and the 1,000-channel tab switch; prints their
#                             GUIDE-SCROLL / TABSWITCH lines and the host's facts. In no other tier.
#
# PIGTV_TEST_DESTINATION overrides the simulator. The simulator is shut down at the end: a booted tvOS simulator left
# running crash-loops its system daemons and loads the Mac.
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TIER="${1:-push}"
# #362: the Guide speed budgets (PIGTV_GUIDEPERF_*, numbers; unset = record only) reach the UI test runner, which takes
# the variables xcodebuild passes on with the TEST_RUNNER_ prefix.
for v in $(env | sed -n 's/^\(PIGTV_GUIDEPERF_[A-Z_]*\)=[0-9.]*$/\1/p'); do
    eval "export TEST_RUNNER_$v=\"\$$v\""
done
DEST="${PIGTV_TEST_DESTINATION:-platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=27.0}"

# Screenshot/appearance suites. Every other UI suite is a regression test and runs before a push, so a new suite
# is in the push tier unless it is added here.
VISUAL="GuideScreensUITests BrandDepthUITests TabFlashUITests BrandSplashUITests TopShelfCardsUITests PigTVUITests PigTVUITestsLaunchTests"
# Speed suites (#362): minutes long and a record, not a gate; only the perf tier runs them.
PERF="GuidePerfUITests"

# The contract checks run once, in the standalone step below; the unit-test wrapper that runs them again is skipped.
UNIT="-only-testing:PigTVTests -skip-testing:PigTVTests/PigTVTests/testServerContracts"

# `all` leaves this marker (the commit it passed on) for Tools/testflight.sh; any other run removes it first.
MARKER=".ui-full-passed"
rm -f "$MARKER"

# -testPlan PigTV: the full plan. The scheme's default is XcodeCloud, which Xcode Cloud's workflow can only take as "Use
# scheme settings" (Xcode 27 offers no plan choice there, #351).
xc() { xcodebuild -quiet -project PigTV.xcodeproj -scheme PigTV -testPlan PigTV -destination "$DEST" "$@"; }

# #53: the unit tests on iOS. One simulator at a time (an 8 GB Mac): each is shut down before the next one boots.
# $1 = a name the user set (empty: pick), $2 = the pattern to prefer, $3 = the family to fall back to.
pick_sim() {
    if [ -n "$1" ]; then echo "$1"; return; fi
    LIST="$(xcrun simctl list devices available 2>/dev/null | grep -E "^ +$3" | sed -E 's/^ +(.*) \([0-9A-F-]{36}\).*$/\1/')"
    if [ -n "$2" ] && echo "$LIST" | grep -qx "$2"; then echo "$2"; else echo "$LIST" | head -1; fi
}
ios_unit() {
    IPAD="$(pick_sim "${PIGTV_IPAD_SIM:-}" "" iPad)"
    IPHONE="$(pick_sim "${PIGTV_IPHONE_SIM:-}" "iPhone 17e" iPhone)"
    for name in "$IPAD" "$IPHONE"; do
        [ -n "$name" ] || { echo "no iPad / iPhone simulator found (set PIGTV_IPAD_SIM / PIGTV_IPHONE_SIM)" >&2; exit 2; }
        echo "== unit tests on iOS: $name"
        # shellcheck disable=SC2086
        xcodebuild -quiet -project PigTV.xcodeproj -scheme PigTV -testPlan PigTV -destination "platform=iOS Simulator,name=$name" \
            test $UNIT
        xcrun simctl shutdown all >/dev/null 2>&1 || true
    done
}
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
    for s in $VISUAL $PERF; do set -- "$@" "-skip-testing:PigTVUITests/$s"; done
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

perf_facts() {
    echo "-- perf $1: $(sysctl -n hw.model 2>/dev/null) macOS $(sw_vers -productVersion 2>/dev/null)," \
        "$(sysctl -n hw.ncpu 2>/dev/null) CPUs, $(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1073741824 )) GB," \
        "load $(sysctl -n vm.loadavg 2>/dev/null), $(memory_pressure 2>/dev/null | grep -i 'free percentage' | sed 's/.*: //') free"
}
perf_ui() {
    # Not -quiet: the tests' printed lines are the point. Each run keeps its own folder, build/perf-<UTC time>/ (the result
    # bundle and the full output), so a second run neither fails on a used result-bundle path nor overwrites the first's log.
    echo "== perf UI tests"
    RUN="build/perf-$(date -u +%Y%m%dT%H%M%SZ)"
    while [ -e "$RUN" ]; do RUN="$RUN-x"; done
    mkdir -p "$RUN"
    echo "-- perf run folder: $RUN"
    echo "-- perf simulator: $DEST"
    perf_facts before
    RC=0
    xcodebuild -project PigTV.xcodeproj -scheme PigTV -testPlan PigTV -destination "$DEST" -resultBundlePath "$RUN/perf.xcresult" \
        test-without-building -only-testing:PigTVUITests/GuidePerfUITests \
        -only-testing:PigTVUITests/TabSwitchUITests/testSwitchingTabsOnAThousandChannelsIsQuick > "$RUN/perf-output.log" 2>&1 || RC=$?
    xcrun simctl list devices booted 2>/dev/null | grep -i "apple tv" | sed 's/^ */-- perf booted: /'
    perf_facts after
    grep -E "GUIDE-SCROLL|TABSWITCH|measured \[|error:|Test Case .*(passed|failed)" "$RUN/perf-output.log" || true
    echo "-- perf output: $RUN/perf-output.log"
    if [ "$RC" != 0 ]; then tail -40 "$RUN/perf-output.log"; exit "$RC"; fi
}

if [ "$TIER" = ios ]; then ios_unit; echo "== ios: passed"; exit 0; fi
echo "== build for testing"
xc build-for-testing
case "$TIER" in
    fast)   fast ;;
    push)   fast; regression_ui ;;
    visual) visual_ui ;;
    all)    fast; regression_ui; visual_ui ;;
    perf)   perf_ui ;;
    *)      echo "usage: sh Tools/test.sh fast|push|visual|all|perf|ios" >&2; exit 2 ;;
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
