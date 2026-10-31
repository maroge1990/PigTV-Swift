# PigTV Apple client: agent guide

The native PigTV client for Apple TV (first), iPad and iPhone: SwiftUI, a UIKit guide grid, AVFoundation playback, a Top Shelf
extension. The server is `../PigTV`, and its [`AGENTS.md`](../PigTV/AGENTS.md) is the home of everything shared by both
repos: the session checklist, work tracking in [GitHub Issues](https://github.com/maroge1990/PigTV/issues) (label
`apple`), reviews, and the test tiers. `docs/archive/` is frozen history, not instructions.

## Map of the docs

| File | Holds |
|---|---|
| [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) | Targets, screens, guide grid and focus model, players, Top Shelf, sport, performance, branding, crash lessons, known limitations |
| [`TESTING.md`](TESTING.md) | What each suite covers, offline fixtures, measuring on the Apple TV |
| [`../PigTV/docs/CLIENT-CONTRACT.md`](../PigTV/docs/CLIENT-CONTRACT.md) | What the server promises: `/api/info` flags, frozen shapes, contracts |
| [`../PigTV/ROADMAP.md`](../PigTV/ROADMAP.md) | The joint roadmap and current state; open work is in the server repo's issues |
| [`../PigTV/docs/TESTING.md`](../PigTV/docs/TESTING.md) | Test tiers T1–T5, who runs what, device checks, evidence rules |
| `../PigTV/docs/` | Product, design, decisions and architecture shared by both apps |

## Commands

`xcode-select` on the MacBook points at the Command Line Tools, so every Xcode command needs `DEVELOPER_DIR` (don't change the
system setting). Simulators are named, not UDIDs (they differ per Mac); the 26.5 runtimes are gone, so tests run on tvOS 27.

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

sh Tools/test.sh fast      # contract checks, then the unit tests: while developing (~1 min after the build)
sh Tools/test.sh push      # fast, then the regression UI tests: before every commit
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

## Installing on Mark's devices (until TestFlight)

When Mark asks for a build on a device, sync this tree to `mac:~/pigtv-build/b3-swift` (only when no test run uses it),
then run the installer **in the Claude desktop app's Terminal panel** (`run_in_terminal`), never through Bash:
`ssh -t mac 'cd ~/pigtv-build/b3-swift && sh Tools/install-device.sh "iPad"'`. Signing needs the Mac's login keychain,
which a plain SSH session cannot unlock (`errSecInternalComponent`): the script asks for the Mac password in that tab,
and Mark types it there (tell him: open the tab, type the password, nothing shows, press Return). Never ask for the
password in chat or store it. Devices by name: `iPad`, `PiGPhone`, `Downstairs Living Room`, `Upstairs Living Room`,
`Mark Office`; on, awake, on the home network. Quote the `~` (else the local shell expands it). On the free team a
build stops opening after 7 days; installing again renews it. TestFlight (`Tools/testflight.sh`) replaces this.

## How changes ship

**Commit to `main`; push once the batch has passed its reviews** (server D-34). Work on `main`; `git pull --rebase`
first, push with `git push origin main` after the tests and Codex rounds, then watch CI. Never force-push. Work in
batches by area (server D-35, its `AGENTS.md` › Work in batches): a batch is Swift-only where possible, each fix its own
commit and build number, `Tools/test.sh push` once before the first review round and again before the push. Session start and end follow the
server's `AGENTS.md` › Session checklist (issues first; the end-of-session docs check; ask Mark about pushed-but-open issues).

1. Before every commit: `sh Tools/test.sh push` passes, plus the iOS build when shared code changed. If something
   can't be run, say so in the commit message and to Mark.
2. A commit that changes app code runs `sh Tools/bump-build.sh` (`CURRENT_PROJECT_VERSION`, both app targets) and its
   subject starts with the build number (`63: what changed`); Settings → Version identifies the installed copy.
3. Commits write `Refs maroge1990/PigTV#n`, never `Fixes`/`Closes`; issues are closed only after Mark confirms.
4. CI (`.github/workflows/ci.yml`) builds for iOS and runs the tvOS tests on every push and PR; a red run is fixed or
   reverted at once.
5. Device-dependent work ends with numbered T5 steps for Mark; nothing is *Verified* until he reports it. A simulator pass
   is not a device pass.

## Rules

- **Never call an AVKit-only API on tvOS without checking it exists** (a category on an AVFoundation class, e.g.
  `AVPlayerItem.externalMetadata`, `UIWindow.avDisplayManager`); AVKit is linked explicitly for tvOS
  ([`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) › Crash lessons).
- **Nothing may await before `replaceCurrentItem`/`play()` except the resolve and the audio session.**
- Every AVFoundation/KVO/notification callback is `@Sendable`/nonisolated and hops to the main actor (Swift 6). Keep pure
  helpers `nonisolated` so the Swift 5 test targets can call them.
- **New playback code gets a test in the real-playback harness** (`PigTVTests/RealPlaybackTests.swift`).
- A view that reads a `BrowseModel` property must observe the store that holds it ([`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) › Performance).
- Never send `force: true` automatically: a takeover needs an explicit choice. Browsing and focus must never acquire a provider
  stream. Preserve same-origin auth, media URL allow-listing and capability negotiation. Release-before-switch is being
  removed (server D-27, [#36](https://github.com/maroge1990/PigTV/issues/36)): the server already ends a device's previous
  stream first; change it only with that issue's fake-provider proof.
- **Test, don't ask:** builds, unit and UI tests, and driving the simulators (attach, screenshots, input) touch no real
  provider, so run them (server `docs/TESTING.md`, tiers T1–T3). Ask Mark before downloading SDKs or dependencies,
  changing the production server, or opening a real provider connection.
- Server changes are made in `../PigTV` under its `AGENTS.md`; a new endpoint this client calls needs an entry in the server's
  `APPLE_CLIENT_ROUTES`.
- The lead session may delegate to sub-agents (never Haiku) and reviews every diff before it's committed.
- **Adversarial review:** the server's `AGENTS.md` › Reviews (Claude launches Codex itself; at most two rounds; findings
  become issues). For this repo the threshold is any functional change to playback, the caches or other shared
  ownership/accounting, the Top Shelf, pairing/auth, or anything the server's `docs/CLIENT-CONTRACT.md` covers; any fix
  for a review finding; or more than ~150 changed non-test lines. Docs-only and test-only commits are exempt.
- Docs describe the present and are edited in place; open work goes in issues, never in a doc.

## Gotchas

- Physical devices need development signing and the App Group `group.au.markrogers.PigTV` registered for both `PigTV` and
  `PigTVTopShelf`; without it the Top Shelf shows the static image.
- If Xcode re-saves `project.pbxproj` while you edit it by hand, check `platformFilters = (tvos)` survived on the extension's
  dependency and embed entries (the iOS build fails without it). Xcode also re-saves it with reordered lines after test runs:
  restore it, but not over an uncommitted build bump (re-run `bump-build.sh <n>`).
- The scheme sets `PIGTV_SYNTHETIC_TESTS=1`, so the test host never restores a saved real-server session.
- The simulators can overload the MacBook; then timing tests (e.g. `ChannelWarmerTests`) fail spuriously: rerun them
  alone, shut simulators down after a run, and don't run the server suite at the same time. `xcodebuild` can sit idle
  after a UI run while it collects diagnostics; the results are already in the log.
- In zsh, a `$VAR` holding several `-skip-testing:` arguments is not word-split.
- No secrets live in this repo; the server address and pairing are entered in the app.
