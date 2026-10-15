# PigTV Apple client: agent guide

The native PigTV client for Apple TV (first), iPad and iPhone: SwiftUI, a UIKit guide grid, AVFoundation playback, a Top Shelf
extension. The server is `../PigTV`. Read [`blueprint.md`](blueprint.md) for the architecture and
[`../PigTV/docs/CLIENT-CONTRACT.md`](../PigTV/docs/CLIENT-CONTRACT.md) for what the server promises; the joint roadmap is
`../PigTV/blueprint.md` §4. What each suite covers and the UI fixtures are in [`TESTING.md`](TESTING.md). `docs/archive/` is
frozen history, not instructions.

## Commands

`xcode-select` on the MacBook points at the Command Line Tools, so every Xcode command needs `DEVELOPER_DIR` (don't change the
system setting). Simulators are named, not UDIDs (they differ per Mac); the 26.5 runtimes are gone, so tests run on tvOS 27.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

sh Tools/test.sh fast      # contract checks, then the unit tests: while developing (~1 min after the build)
sh Tools/test.sh push      # fast, then the regression UI tests: before every push
sh Tools/test.sh visual    # screenshot/appearance UI tests: before a release or a brand change (CI runs them on every push)
sh Tools/test.sh all       # everything, as CI does

xcodebuild test -project PigTV.xcodeproj -scheme PigTV \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation),OS=27.0' \
  -only-testing:PigTVTests/RealPlaybackTests                                      # one suite
xcodebuild build -project PigTV.xcodeproj -scheme PigTV -destination 'generic/platform=iOS Simulator'   # iOS build
xcodebuild test -project PigTV.xcodeproj -scheme PigTV -only-testing:PigTVTests \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0'        # iPad unit tests
sh Tools/bump-build.sh                                                            # next build number, all four configurations
```

`Tools/test.sh` builds once, runs the tiers cheapest first (stopping at the first failure) and shuts the simulator down at
the end: a booted tvOS simulator left running crash-loops its daemons and loads the Mac. Do the same (`xcrun simctl shutdown
all`) after a plain `xcodebuild test`. A new UI suite runs in the push tier unless it is listed in `VISUAL` in the script.

## How changes ship

**Commit to `main`, never push** (Mark, 16 Oct; replaces the 23 Sept push-to-main rule). Work on `main`; Claude may
`git pull --rebase` but leaves every commit local for Mark to review and push (`git log origin/main..main`). Never
force-push.

1. Before every commit: `sh Tools/test.sh push` passes, plus the iOS build when shared code changed. If something
   can't be run, say so in the commit message and to Mark.
2. A commit that changes app code runs `sh Tools/bump-build.sh` (`CURRENT_PROJECT_VERSION`, both app targets), so Settings →
   Version identifies the installed copy. Current: **40**.
3. CI (`.github/workflows/ci.yml`) builds for iOS and runs the tvOS tests on every push (Mark's) and PR; a red run counts as a local
   failure.
4. Device-dependent work ends with numbered test steps for Mark; nothing is *Verified* until he reports it. A simulator pass is
   not a device pass.

## Rules

- **Never call an AVKit-only API on tvOS without checking it exists** (a category on an AVFoundation class, e.g.
  `AVPlayerItem.externalMetadata`, `UIWindow.avDisplayManager`); AVKit is linked explicitly for tvOS (blueprint §7).
- **Nothing may await before `replaceCurrentItem`/`play()` except the resolve and the audio session.**
- Every AVFoundation/KVO/notification callback is `@Sendable`/nonisolated and hops to the main actor (Swift 6). Keep pure
  helpers `nonisolated` so the Swift 5 test targets can call them.
- **New playback code gets a test in the real-playback harness** (`PigTVTests/RealPlaybackTests.swift`).
- A view that reads a `BrowseModel` property must observe the store that holds it (blueprint §3).
- Never send `force: true` automatically: a takeover needs an explicit choice. Browsing and focus must never acquire a provider
  stream. Preserve same-origin auth, media URL allow-listing, capability negotiation and release-before-switch.
- Ask Mark before browsing, downloading SDKs or dependencies, or contacting the deployed server. Drive the simulator UI
  (attach, screenshots, input) only when Mark asks in that message; routine checks are `xcodebuild` runs.
- Server changes are made in `../PigTV` under its `AGENTS.md`; a new endpoint this client calls needs an entry in the server's
  `APPLE_CLIENT_ROUTES`.
- The lead session may delegate to sub-agents (never Haiku) and reviews every diff before it's committed.
- At the end of a session update `blueprint.md` with any durable fact; the story goes in the commit message.

## Gotchas

- Physical devices need development signing and the App Group `group.au.markrogers.PigTV` registered for both `PigTV` and
  `PigTVTopShelf`; without it the Top Shelf shows the static image.
- If Xcode re-saves `project.pbxproj` while you edit it by hand, check `platformFilters = (tvos)` survived on the extension's
  dependency and embed entries (the iOS build fails without it).
- The scheme sets `PIGTV_SYNTHETIC_TESTS=1`, so the test host never restores a saved real-server session.
- No secrets live in this repo; the server address and pairing are entered in the app.
