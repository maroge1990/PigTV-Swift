# PigTV client verification

Current scope/status: [blueprint.md](blueprint.md). Run tests from this repository, not the historical Codex/OneDrive copy. Ask Mark before internet access or deployed-server testing. Choose disposable recordings and obtain agreement before tests that stop another viewer/recording or change server data.

Testing ownership (confirmed 21 September): the client agent runs synthetic tests and local Xcode simulator builds/tests; Mark conducts physical Apple TV and multi-device checks. Target server: build **0086**, confirmed by Mark as matching the local PigTV folder. No network access is implied by this testing assignment.

## Local baseline and change checks

1. Run `sh Tools/test-contracts.sh` without a server. Baseline was 93; build **1.0 (2)** on 21 September 2026: **123 passed**.
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

## Latest results — 21 September 2026, app 1.0 (2)

- Standalone script: **123 contract checks passed**.
- Xcode 27.0, Apple TV simulator, tvOS 26.5: **11 XCTest tests passed, zero failures**.
- Xcode 27.0, iPad Pro 13-inch (M5) simulator, iOS 26.5: **11 XCTest tests passed, zero failures**.
- Each XCTest run includes the contract suite plus **10 lifecycle tests**: explicit takeover, bounded recovery, recovery conflict, initial failure, late-session release, stopped recovery, preparation cancellation, late recording response, explicit recording retry, and artwork/waiting behaviour.
- Build warnings: only skipped App Intents metadata extraction. No Swift compiler warnings in final runs. Both repository whitespace checks pass.
- Physical Apple TV, iPhone layouts, multi-device/provider playback, HEVC recordings and the deployed server: **Not run by the agent**; Mark owns these checks.
- Server companion change: added client-event to `APPLE_CLIENT_ROUTES`; **server test not run** because Node is not on PATH and dependencies are absent. No server runtime changes or dependency downloads.

Reproduce simulator validation from the client repository using installed destinations:

```sh
xcodebuild -project PigTV.xcodeproj -scheme PigTV -configuration Debug -destination 'platform=tvOS Simulator,id=CDF0C871-2FAA-49A6-A586-DC917C67C3F9' -derivedDataPath /private/tmp/pigtv-0086-tv -disableAutomaticPackageResolution test
xcodebuild -project PigTV.xcodeproj -scheme PigTV -configuration Debug -destination 'platform=iOS Simulator,id=7B0936F6-E5F9-4470-B4B8-D7D045F08CC1' -derivedDataPath /private/tmp/pigtv-0086-ios -disableAutomaticPackageResolution test
```

The shared scheme sets `PIGTV_SYNTHETIC_TESTS=1` for Test only. The app host shows an inert view instead of restoring saved credentials, and fixture URL protocols intercept all API requests. Normal Run still opens the real app. These runs test models/lifecycle and compilation; they do not constitute rendered UI or real-media validation. Simulator service access required approval outside the sandbox.

Final logs: `/private/tmp/pigtv-final-tv.log` and `/private/tmp/pigtv-final-ios.log`; Xcode result bundles are under the corresponding DerivedData `Logs/Test` directories.

Next hands-on pass: install **1.0 (2)**, confirm Settings reports server **0086**, test TV/web takeover in both directions, pause for six minutes and resume, background/return to guide, then play a long and an HEVC recording. Record observations before expanding to the rest of the matrix.
