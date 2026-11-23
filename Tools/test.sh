#!/bin/sh
# The tvOS tests in tiers, cheapest first, so a failure shows within a minute instead of after the UI suites.
#
#   sh Tools/test.sh fast     contract checks, then the unit tests (~1 min after the build)
#   sh Tools/test.sh push     fast, then the regression UI tests (once per batch: before its review and before the push)
#   sh Tools/test.sh visual   the screenshot and appearance UI tests (before a release or a brand change, ~18 min with the review media)
#   sh Tools/test.sh ios      the unit tests (PigTVTests) and TouchPlayerButtonsUITests on one iPad simulator, then one iPhone simulator, one after the other
#                             (#53). Not part of `all`; PIGTV_IPAD_SIM / PIGTV_IPHONE_SIM name the devices (default: the first
#                             available iPad, and iPhone 17e or else the first available iPhone; the choice is printed)
#   sh Tools/test.sh all      push, then visual: the full UI run. CI does not run it (D-49); Tools/testflight.sh requires it
#                             to have passed for the exact commit it uploads (see the marker below)
#   sh Tools/test.sh perf     the speed tests only (#362): GuidePerfUITests and the 1,000-channel tab switch; prints their
#                             GUIDE-SCROLL / TABSWITCH lines and the host's facts. In no other tier.
#   sh Tools/test.sh profile  #360 (E1): a Time Profiler trace of the app while GuidePerfUITests.testProfileScenarios presses
#                             down, up and right, summarised by Tools/profile-summary.py (main-thread ms per press by
#                             phase and symbol). The trace is deleted after the summary. In no other tier.
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
        # Codex review of 406: and the touch players' button checks (TouchPlayerButtonsUITests; they skip without the
        # review movie), which no other tier runs on iOS.
        xcodebuild -quiet -project PigTV.xcodeproj -scheme PigTV -testPlan PigTV -destination "platform=iOS Simulator,name=$name" \
            test $UNIT -only-testing:PigTVUITests/TouchPlayerButtonsUITests
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
    grep -E "GUIDE-SCROLL|GUIDE-SIGNPOST|TABSWITCH|measured \[|error:|Test Case .*(passed|failed)" "$RUN/perf-output.log" || true
    echo "-- perf output: $RUN/perf-output.log"
    if [ "$RC" != 0 ]; then tail -40 "$RUN/perf-output.log"; exit "$RC"; fi
}

# #360 (E1): the profile tier. The UI test launches the app and waits before its presses; xctrace attaches to the app's
# process as soon as it exists and records until the app quits (the test's end).
profile_ui() {
    echo "== profile UI test"
    RUN="build/profile-$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$RUN"
    perf_facts before
    export TEST_RUNNER_PIGTV_GUIDEPERF_PROFILE=1
    xcodebuild -project PigTV.xcodeproj -scheme PigTV -testPlan PigTV -destination "$DEST" -resultBundlePath "$RUN/profile.xcresult" \
        test-without-building -only-testing:PigTVUITests/GuidePerfUITests/testProfileScenarios > "$RUN/profile-output.log" 2>&1 &
    XPID=$!
    APP=""
    i=0
    while [ -z "$APP" ] && [ $i -lt 600 ]; do
        APP="$(pgrep -n -x PigTV || true)"
        [ -n "$APP" ] || { sleep 0.2; i=$((i + 1)); }
    done
    SIM="$(xcrun simctl list devices booted 2>/dev/null | grep -i "apple tv" | grep -oE '[0-9A-F-]{36}' | head -1)"
    echo "-- profile app pid: ${APP:-none}, simulator: ${SIM:-none}"
    if [ -n "$APP" ] && [ -n "$SIM" ]; then
        # A simulator app is attached through its simulator device (a host-side attach does not find it).
        xcrun xctrace record --template 'Time Profiler' --instrument os_signpost --device "$SIM" --attach "$APP" --time-limit 240s \
            --no-prompt --output "$RUN/guide.trace" > "$RUN/xctrace.log" 2>&1 || echo "-- xctrace record exited $?"
        tail -5 "$RUN/xctrace.log"
    fi
    RC=0
    wait $XPID || RC=$?
    grep -E "GUIDE-SCROLL|PROFILE-|error:|Test Case .*(passed|failed|skipped)" "$RUN/profile-output.log" || true
    if [ -d "$RUN/guide.trace" ]; then
        xcrun xctrace export --input "$RUN/guide.trace" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
            --output "$RUN/time-profile.xml" > /dev/null 2>&1 || echo "-- time-profile export failed"
        xcrun xctrace export --input "$RUN/guide.trace" --xpath '/trace-toc/run[@number="1"]/data/table[@schema="os-signpost"]' \
            --output "$RUN/signposts.xml" > /dev/null 2>&1 || echo "-- signpost export failed"
        PRESSES="$(sed -n 's/.*PROFILE-PRESSES \([0-9,]*\).*/\1/p' "$RUN/profile-output.log" | tail -1)"
        /usr/bin/python3 Tools/profile-summary.py "$RUN/time-profile.xml" "$RUN/signposts.xml" "$PRESSES" "$RUN/samples.json.gz" \
            || echo "-- summary failed"
        # The main thread's samples (time, weight, stack), compressed, for summarising again off the Mac.
        if [ -s "$RUN/samples.json.gz" ]; then echo "PROFILE-DATA-BEGIN"; base64 < "$RUN/samples.json.gz"; echo "PROFILE-DATA-END"; fi
        du -sh "$RUN/guide.trace" "$RUN"/*.xml 2>/dev/null | sed 's/^/-- size /'
        rm -rf "$RUN/guide.trace" "$RUN/time-profile.xml" "$RUN/signposts.xml" "$RUN/samples.json.gz"
    else
        echo "-- no trace recorded"; cat "$RUN/xctrace.log"
    fi
    perf_facts after
    if [ "$RC" != 0 ]; then tail -40 "$RUN/profile-output.log"; exit "$RC"; fi
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
    profile) profile_ui ;;
    *)      echo "usage: sh Tools/test.sh fast|push|visual|all|perf|profile|ios" >&2; exit 2 ;;
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
