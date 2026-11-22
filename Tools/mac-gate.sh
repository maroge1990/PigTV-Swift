#!/bin/sh
# Push gate for the Apple client (D-77), run on the MacBook from here: Tools/test.sh <tier> there, then clean up.
#
#   sh Tools/mac-gate.sh [tier]              tier = fast | push (default) | visual | all | perf | ios; tests the commit (HEAD, via git archive)
#   sh Tools/mac-gate.sh [tier] --worktree   test the working tree (tracked + untracked) for a pre-commit run
#   sh Tools/mac-gate.sh push --only "PigTVTests/CacheTests"   rerun just those tests (xcodebuild -only-testing ids)
#
# PIGTV_MAC_HOST (default mac) and PIGTV_MAC_SSH_OPTS (e.g. "-o HostName=<ip>") say how to reach the Mac.
# PIGTV_GUIDEPERF_* (numeric Guide speed budgets, #362) are passed on to the tests there (unset: record only).
# Output goes to .gate-logs/; one record line per run is appended to .gate-log. Exit 0 only on PASS, 3 if the Mac is unreachable.
# The build folders and DerivedData the run created are deleted at the end, and the simulators are shut down.
set -u
cd "$(dirname "$0")/.."
REPO=apple; MODE=commit; ONLY=""; TIER=push
while [ $# -gt 0 ]; do
    case "$1" in
        --worktree) MODE=worktree ;;
        --only) ONLY="${2:-}"; shift ;;
        fast|push|visual|all|perf|ios) TIER="$1" ;;
        *) echo "usage: sh Tools/mac-gate.sh [fast|push|visual|all|perf|ios] [--worktree] [--only \"Target/Suite ...\"]" >&2; exit 2 ;;
    esac
    shift
done
HOST="${PIGTV_MAC_HOST:-mac}"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=10 ${PIGTV_MAC_SSH_OPTS:-}"
# shellcheck disable=SC2086
mac() { ssh $SSH_OPTS "$HOST" "$@"; }

if ! mac true 2>/dev/null; then echo "mac-gate: cannot reach the Mac (host '$HOST'; set PIGTV_MAC_HOST / PIGTV_MAC_SSH_OPTS)" >&2; exit 3; fi

if [ "$MODE" = worktree ]; then WHAT="worktree (dirty)"; else WHAT="$(git rev-parse --short HEAD)"; fi
[ -n "$ONLY" ] && TIER="$TIER+only"
mkdir -p .gate-logs
LOG=".gate-logs/$(date -u +%Y%m%dT%H%M%SZ)-$REPO-${TIER%%+*}.log"
B='$HOME/pigtv-build'; G="$B/gate-$REPO"

# One gate at a time on the Mac: a lock folder; a lock older than 3 h is reported, not taken over.
if ! mac "mkdir -p $B && mkdir $B/gate.lock 2>/dev/null && echo \"$REPO \$(date -u +%FT%TZ)\" > $B/gate.lock/owner"; then
    OWNER="$(mac "cat $B/gate.lock/owner 2>/dev/null")"
    if [ -n "$(mac "find $B/gate.lock -maxdepth 0 -mmin +180 2>/dev/null")" ]; then
        echo "mac-gate: STALE lock (older than 3 h, owner: $OWNER). Check the Mac, then: ssh $HOST 'rm -rf ~/pigtv-build/gate.lock'" >&2
    else
        echo "mac-gate: another gate run is in progress on the Mac (owner: $OWNER)" >&2
    fi
    exit 4
fi
KEEP_BUILD=0
cleanup() {
    # the build folders and DerivedData this run made, the simulators, then the lock; build/ stays when it holds a perf
    # output that could not be copied back (KEEP_BUILD=1)
    KEEP=""; [ "$KEEP_BUILD" = 1 ] || KEEP="$G/src/build"
    mac "export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer; xcrun simctl shutdown all >/dev/null 2>&1; rm -rf $KEEP $G/src/DerivedData $G/dd; for d in \$HOME/Library/Developer/Xcode/DerivedData/PigTV-*; do grep -q \"$G/src\" \"\$d/info.plist\" 2>/dev/null && rm -rf \"\$d\"; done; rm -rf $B/gate.lock" >/dev/null 2>&1
}
trap cleanup EXIT

START=$(date +%s)
{
    echo "== export $WHAT -> Mac"
    mac "mkdir -p $G && rm -rf $G/src && mkdir -p $G/src"
    if [ "$MODE" = worktree ]; then
        rsync -a -e "ssh $SSH_OPTS" --exclude .git --exclude build --exclude DerivedData --exclude xcuserdata --exclude .gate-log \
            --exclude .gate-logs --exclude .claude --exclude node_modules ./ "$HOST:pigtv-build/gate-apple/src/" || exit 1
    else
        git archive HEAD | mac "tar -x -C $G/src"
    fi
    echo "== run on the Mac: ${ONLY:+only $ONLY, else }Tools/test.sh ${TIER%%+*}"
    # Numbers only, so they need no quoting on the way.
    BUDGETS="$(env | grep -E '^PIGTV_GUIDEPERF_[A-Z_]+=[0-9.]+$' | tr '\n' ' ')"
    mac "$BUDGETS REPO_G=$G ONLY='$ONLY' T='${TIER%%+*}' sh -s" <<'REMOTE'
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
for v in $(env | sed -n 's/^\(PIGTV_GUIDEPERF_[A-Z_]*\)=[0-9.]*$/\1/p'); do eval "export TEST_RUNNER_$v=\"\$$v\""; done
export PATH=/opt/homebrew/bin:$PATH
cd "$REPO_G/src" || exit 1
RC=0
if [ -n "$ONLY" ]; then
    # same destination and plan as Tools/test.sh, only the named tests
    ARGS=""; for t in $ONLY; do ARGS="$ARGS -only-testing:$t"; done
    xcodebuild -quiet -project PigTV.xcodeproj -scheme PigTV -testPlan PigTV \
        -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=27.0' test $ARGS || RC=1
    xcrun simctl shutdown all >/dev/null 2>&1
else
    sh Tools/test.sh "$T" || RC=1
fi
[ $RC = 0 ] && echo "GATE-RESULT PASS" || echo "GATE-RESULT FAIL"
exit $RC
REMOTE
} >"$LOG" 2>&1
RC=$?
SECS=$(( $(date +%s) - START ))
# perf: the run's full output comes back next to the log, before the cleanup deletes build/; the GUIDE-SCROLL lines are in
# the log already. Copied from the exact folder Tools/test.sh printed ("-- perf run folder: build/perf-<UTC time>"), and
# checked: a copy that fails or comes back empty is said loudly, and the Mac's copy (and build/) is left in place.
PERF_NOTE=""
if [ "${TIER%%+*}" = perf ] && [ -z "$ONLY" ]; then
    RUN_DIR="$(sed -n 's/^-- perf run folder: //p' "$LOG" | tail -1)"
    PERF_LOCAL="${LOG%.log}-perf-output.log"
    REMOTE_PERF="$G/src/$RUN_DIR/perf-output.log"
    if [ -z "$RUN_DIR" ]; then
        PERF_NOTE="mac-gate: NO PERF OUTPUT: Tools/test.sh printed no run folder (the run stopped before the perf tests)"
    elif mac "cat \"$REMOTE_PERF\"" > "$PERF_LOCAL" 2>/dev/null && [ -s "$PERF_LOCAL" ]; then
        echo "perf output: $PERF_LOCAL" >> "$LOG"
    else
        rm -f "$PERF_LOCAL"
        KEEP_BUILD=1
        # Out of the export folder too, which the next gate run replaces (if the Mac answers; else build/ is all there is).
        KEPT="$B/perf-kept/$(basename "${LOG%.log}")-perf-output.log"
        if mac "mkdir -p $B/perf-kept && cp \"$REMOTE_PERF\" \"$KEPT\"" 2>/dev/null; then WHERE="$KEPT"; else WHERE="$REMOTE_PERF (until the next gate run)"; fi
        PERF_NOTE="mac-gate: PERF OUTPUT NOT COPIED BACK. It is still on the Mac: $HOST:$(echo "$WHERE" | sed 's|^\$HOME|~|')"
    fi
    [ -n "$PERF_NOTE" ] && echo "$PERF_NOTE" >> "$LOG"
fi

if [ $RC = 0 ] && grep -q "^GATE-RESULT PASS" "$LOG"; then RES=PASS; else RES=FAIL; RC=1; fi
# failed tests: the "Failing tests:" block xcodebuild ends with (tab-indented names), else per-test failure lines
FAILED="$(awk '/^Failing tests:/{f=1;next} f&&/^\t/{sub(/^\t+/,"");print;next} f{f=0}' "$LOG" | awk '!s[$0]++' | head -10 | paste -sd'|' -)"
if [ -z "$FAILED" ]; then
    FAILED="$(grep -E "(Test [Cc]ase .* failed|^[[:space:]]*✘ Test)" "$LOG" | sed -E "s/^.*Test [Cc]ase '?//; s/^[[:space:]]*✘ Test //; s/'? failed.*$//" \
        | awk '!s[$0]++' | head -10 | paste -sd'|' -)"
fi
echo "$(date -u +%FT%TZ) $REPO $WHAT $TIER $RES ${SECS}s ${FAILED:--}" >> .gate-log
# -quiet output carries no counts; show which steps ran instead
COUNTS="$(grep -E '^== ' "$LOG" | sed 's/^== //' | paste -sd',' -)"
echo "mac-gate $REPO $WHAT $TIER: $RES in ${SECS}s ${COUNTS:+($COUNTS)}"
[ -n "$FAILED" ] && echo "failed: $FAILED"
echo "log: $LOG"
[ -n "$PERF_NOTE" ] && echo "$PERF_NOTE" >&2
exit $RC
