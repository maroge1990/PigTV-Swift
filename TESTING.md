# PigTV client verification

Current scope/status: [blueprint.md](blueprint.md). Run tests from this repository, not the historical Codex/OneDrive copy. Ask Mark before internet access or deployed-server testing. Choose disposable recordings and obtain agreement before tests that stop another viewer/recording or change server data.

Testing ownership (confirmed 21 September): the client agent runs synthetic tests and local Xcode simulator builds/tests; Mark conducts physical Apple TV and multi-device checks. Last user-confirmed deployment: **0086**. Local server is now **0094**; confirm `playbackTerminalStatus` is advertised before takeover acceptance testing. The latest review also permits agent testing on the downstairs Apple TV via Xcode, but no physical-device run has been performed. No network access is implied by this testing assignment.

## Local baseline and change checks

1. Run `sh Tools/test-contracts.sh` without a server. Baseline was 93; review build **1.0 (3)** on 22 September 2026: **133 passed**.
2. Build the shared PigTV scheme for tvOS and iOS using installed SDKs. Record destination, configuration and actual build outcome. Do not download SDKs/dependencies without approval.
3. Add focused fixtures for changed contracts: optional info flags/build, viewer/recording/unknown conflicts, 429, recording 200/202/500 and malformed responses. Fixtures live in `PigTVTests/ContractChecks.swift` and run through the existing script.
4. For C2/C3 add lifecycle tests: one recovery only, repeated failure callbacks, dismiss during resolve/preparation, late response, server/account change, cancellation and explicit retry. Assert request counts and absence of automatic force.
5. Check new-feature and missing-flag legacy paths. Contract checks alone do not verify focus, cancellation UI or AVPlayer behaviour.

## Approved integration and device checks

Before each run record app version/build and source revision, device/OS, server `/api/info` build/display/features, and relevant channel/recording. Keep provider URLs and tokens out of logs/screenshots shared for diagnosis.

| Check | Expected result |
|---|---|
| Setup | Restore, login, pairing/cancel/expiry and unreachable-server retry behave correctly; Settings identity matches the server after C8. |
| C1 viewer conflict | Second device offers takeover/cancel; cancel leaves first device playing; explicit takeover works. Repeat with TV and web exchanging roles. |
| Recording conflict | Keep recording preserves it; only explicit takeover stops an agreed disposable recording. Scheduled prompt decline is honoured. |
| Same-device switching | Channels sheet, Next/Previous/Back switch cleanly without a self-conflict; previous session releases. |
| C2 session recovery | Established playback losing its session tries once, then presents Retry on failure; takeover during recovery asks C1. Dismissal prevents later playback. |
| Pause/background | Observe fetching while paused; test >45 seconds and >6 minutes. Resume handles an expired session. Background cleanup remains correct; returning to the foreground shows the guide and never automatically resumes the last channel. No unexpected playback after dismissal. |
| Server 0085/0086 | Previously juddery and known-good channels stay smooth with lip-sync; finite source 1803789 survives beyond initial segments. Record continuous-play duration and stalls. |
| C3 recordings | Long recording shows Preparing, then plays; cancel/dismiss stops polling. Test terminal preparation failure, missing file, timeout and explicit retry; legacy path still works. |
| HEVC and seeking | Physical Apple TV plays an HEVC recording; seeking, resume, manual Skip break and Auto-skip work. Old hev1 sidecar cleanup, if needed, is a separately approved server action. |
| C4 artwork | Feature-enabled launch makes no proxy EPG index download; playlist/EPG/missing logos render. Missing flag retains legacy fallback; third-party logo requests carry no bearer. |
| C5 waiting | With agreed recording held by a viewer, Upcoming explains Waiting; cancellation works; no duplicate schedule; waiting is not shown as actively recording. |
| C6 rate limit | Use fixtures first; do not deliberately lock a real account without agreement. Check actionable timing and bounded retries. |
| C7 diagnostics | Correlated server events have device identity and useful codes/timings, no query/token; logging failure has no playback effect. |
| Favourites | An agreed test add/remove round-trips between web and client. |

## UI regression on Apple TV, iPad and iPhone

- Guide category strip scrolls; left/right steps once across viewport boundaries; up/down and returning from playback/details preserve sensible focus.
- Finished programmes are dimmed/disabled; programme titles, sticky channel captions, time axis and record badges remain aligned.
- Search, favourites, background page loading, remembered position and cached guide refresh remain usable with hundreds of channels.
- Channels sheet is remote-focusable; now/next system metadata remains current; Go to live appears when behind.
- Transparent/mixed logos have a single readable backing; tabs and guide surfaces remain legible in light/dark mode; playback does not change the selected appearance.
- iPhone header/category controls fit; iPad/touch swipes work; check text scaling, VoiceOver labels and sofa-distance readability.

## Record results

For each check record date, device/OS, client revision/build, server build, steps, expected/actual behaviour and sanitised evidence. Mark **Pass**, **Fail** or **Not run**. Update the matching blueprint item; an unrun device check must not become Verified merely because a build or fixture passed.

## Build 1.0 (14) — device checklist and results (23 September 2026)

**Local results:** tvOS simulator: 18 unit tests + 2 UI tests passed (Settings appearance, new guide Right-navigation). iOS simulator: 18 unit tests passed; the Settings appearance UI test **failed once then passed on rerun** (timed out waiting for "light" to read Selected). That screen's code is unchanged in build 14, so this is treated as a pre-existing flaky test, not a regression. Contract runner: 135 passed.

| Item | Steps and expected result |
|---|---|
| R19 | Describe exactly where Right stops (focus at screen edge? grid moves but focus lost? after how many presses, which category, guide still loading?). |
| R20 | Light mode: play a channel, exit; repeat several times, also after channel changes and after an error screen. Guide, tabs, Recordings and Settings stay fully light. Repeat in Dark and System. |
| HDR (R13) | Settings → Video and Audio → Match Content → Match Dynamic Range on. Sky Sports Main Event: panel switches to HDR, colours normal. Change to an SDR channel: back to SDR. Exit to guide: SDR. |

## Build 1.0 (13) — device checklist and results (23 September 2026)

**Device results (Mark, build 13):** R18 pass; R17 pass; AVKit fallback removal pass; stableId no issues seen; R16/R14 blocked by R19 (guide won't scroll right); R20 light/dark clash after player found.

**Local results:** Xcode 27.0; Apple TV simulator (tvOS 26.5) and iPad Pro 13-inch (M5) simulator (iOS 26.5): **19 tests passed on each** (contract runner + 13 lifecycle + 4 new `GuideModelTests` + the Settings UI test). `sh Tools/test-contracts.sh`: **135 passed**. tvOS and iOS Debug builds succeed with no Swift warnings. The first test run failed two `GuideModelTests` assertions because the test expected the wrong fixture names (a test error, not an app error); corrected and rerun green. `testProgrammeLookupUsesIndexOnLargeGuide` measures 500 lookups on an 18 000-channel guide at ~0.7 ms (after the one-off index build). No simulator UI driving, physical-device or deployed-server test was performed.

Hands-on checks for Mark on the Apple TV (confirm Settings → Version shows **1.0 (13)**):

| Item | Steps and expected result |
|---|---|
| R18 | With the full guide loaded (and once while it is still paging in), flick quickly back and forth across several categories, then stop. The strip stays responsive; the grid settles on the last category about a quarter-second later, back at the top and at the current half-hour. No hang. Also check Favourites and All. |
| R16 | Logo tile → first cell, cell ↔ cell and row ↔ row gaps look identical; logo tile top/bottom line up with the cells; time labels line up with cell edges; now-line still sits at the current time. Light and Dark. |
| R14 | Step Right/Left several times and use Earlier/Later: cells and time labels slide in from off screen as one wide sheet, nothing pops in. Return to live from several windows ahead. Watch for frame drops on a busy category. |
| R17 | In the player with controls hidden, press Left/Right: a slim bottom bar shows ⏪15/⏩15, channel, "m:ss behind live" (or LIVE) and the buffer scrubber — not the full info overlay. Repeated presses keep seeking; Select opens full info; Up/Down/Back hide it; it hides itself after ~4 s. |
| Fallback removal | Settings has no "Live player" section; every channel plays in the PigTV player; Up/Down side list, Back order and takeover prompts unchanged. |
| stableId | Favourite a channel listed in two categories: the heart shows as favourite from either listing; the Favourites filter shows it once. Relaunch: the guide still scrolls to the last focused channel. |

## Review acceptance pass — build 1.0 (3)

Record each as Pass/Fail/Not run in the blueprint. These remain physical-device checks even when a simulator model or Settings test passes.

| Item | Hands-on steps and expected result |
|---|---|
| U01 | Focus empty, short and long programme descriptions: guide rows never shift vertically. Open Details, then Back: full text was available and guide focus/time are retained. |
| U02 | On a server advertising `playbackTerminalStatus`, start device A; on B cancel takeover, then explicitly take over. A stops with a useful message and never reclaims B. Repeat TV→web and web→TV, paired and password clients, including A paused beyond 60 seconds. Allow buffered media to drain. Separately check ordinary session expiry still recovers once and same-device channel switching remains clean. |
| U03 | Categories at left boundary: only right fades. Mid-strip: both fade. Right boundary: only left fades. No overflow: neither fades. Scroll using the remote in both appearances; no coloured edge bands or inaccessible categories. |
| U04 | Recordings and Refresh remain readable focused/unfocused/pressed/disabled in Light and Dark, matching the guide. |
| U05 | In the actual Settings tab select Light→Dark→System several times. Screen and focus remain usable. Leave/revisit the tab, relaunch, play/back: selected appearance persists. |
| U06 | Navigate several screens right, then all the way left, including long shows crossing viewport boundaries. Return to the current half-hour/live baseline every time; no stuck focus, double jumps or stale focus after held input. Compare horizontal motion with vertical; repeat with Reduce Motion. |
| U07 | Inspect Apple TV home-screen icon (and distribution asset preview), plus iOS light/dark/tinted variants. Pig remains sharp and no added pink disc/backplate remains. |
| U08 | Check transparent, opaque and missing provider logos. One dark translucent full-size tile, no app-added nested box; correct aspect ratio and readable fallback in Light/Dark. |
| U09 | Cold launch with no credentials, saved login, expired login and unreachable server. Branded loading hands off without a fixed delay or getting stuck. Ordinary foreground return remains guide-only. |
| U10 | Show native player transport controls: channel, programme, times/progress, description and next show appear directly. First Back hides controls and keeps playing; next Back exits to guide. Repeat from expanded programme panel and channel browser. |
| U11 | Open Channels mid-list: current channel focused/centred and neighbours show now-playing/progress. Browse long lists and edge channels without opening streams. Select once: old session releases before switch. Back closes the panel only. Check bright/dark footage and Reduce Transparency. |

## Latest results — 22 September 2026, app 1.0 (3)

- Standalone script: **133 API/model checks passed** (including three left-navigation boundary checks).
- Xcode 27.0, Apple TV simulator **tvOS 26.5** and iPad Pro 13-inch (M5) simulator **iOS 26.5**: **15 tests passed on each** — 14 contract/lifecycle tests plus one UI test, zero failures in the final runs.
- Settings UI test selects Light → Dark → System → Light → Dark within the actual tab container, asserting each selected value and continued availability of all three controls. Reviewed saved screenshots: [TV Dark](docs/evidence/2026-09-22-settings-tv-dark.png), [TV Light](docs/evidence/2026-09-22-settings-tv-light.png), [iPad Dark](docs/evidence/2026-09-22-settings-ipad-dark.png). No credentials/server are present in this fixture.
- Early runs exposed a non-tappable row interior on iPad and nested Form/focus issues on TV. The final layout/full-row hit target and deterministic adjacent remote presses resolve the test failures. One earlier iOS runner also timed out loading Accessibility; final bounded runs completed. No unresolved failure in the final selected suites.
- Compilation warnings: only skipped App Intents metadata extraction; no Swift compiler warnings. Whitespace check passed.
- Final logs: `/private/tmp/pigtv-review-tv-settings3.log`, `/private/tmp/pigtv-review-ios-settings.log`. Both result bundles are `Logs/Test/Test-PigTV-2026.09.22_08-19-57-+1000.xcresult` under their respective `/private/tmp/pigtv-review-tv` and `/private/tmp/pigtv-review-ios` DerivedData folders.
- Physical Apple TV, multi-device/provider playback and deployed-server verification: **Not run in this review**. Local server 0094 availability does not establish that it is deployed.

Reproduce the offline simulator suites from this repository using installed destinations:

```sh
xcodebuild -project PigTV.xcodeproj -scheme PigTV -configuration Debug -destination 'platform=tvOS Simulator,id=CDF0C871-2FAA-49A6-A586-DC917C67C3F9' -derivedDataPath /private/tmp/pigtv-review-tv -disableAutomaticPackageResolution -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 90 -collect-test-diagnostics never -only-testing:PigTVTests -only-testing:PigTVUITests/PigTVUITests test
xcodebuild -project PigTV.xcodeproj -scheme PigTV -configuration Debug -destination 'platform=iOS Simulator,id=7B0936F6-E5F9-4470-B4B8-D7D045F08CC1' -derivedDataPath /private/tmp/pigtv-review-ios -disableAutomaticPackageResolution -parallel-testing-enabled NO -test-timeouts-enabled YES -default-test-execution-time-allowance 90 -collect-test-diagnostics never -only-testing:PigTVTests -only-testing:PigTVUITests/PigTVUITests test
```

The scheme sets `PIGTV_SYNTHETIC_TESTS=1` for the unit-test host, avoiding saved-session restoration. Fixture URL protocols intercept API requests. The UI tests set the DEBUG-only `PIGTV_UI_TEST_SCREEN=settings` to render offline Settings inside `LibraryView` and repeatedly select appearances, saving screenshots. Normal Run still opens the real app. The Settings fixture does not establish guide/player rendering or real-media behaviour. Simulator service access requires approval outside the sandbox.

The XCTest suite contains one contract runner plus 13 lifecycle tests, including confirmed takeover without release/resolve, normal-expiry recovery and dismissal during terminal-status lookup. The additional UI test checks repeated appearance selection. Build-only success is not equivalent to passing these tests.

Next hands-on pass: install **1.0 (3)**, check U05/U06/U10/U11 on Apple TV, confirm server 0094/capability before U02, then run the remaining rows above and the recording regression matrix.
