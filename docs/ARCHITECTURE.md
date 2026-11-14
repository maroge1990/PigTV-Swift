# PigTV Apple client: architecture

The client's structure: targets, screens, the guide grid and focus model, the players, Top Shelf, sport, performance,
branding, and the crash lessons. What the server promises is the server's
[`docs/CLIENT-CONTRACT.md`](https://github.com/maroge1990/PigTV/blob/main/docs/CLIENT-CONTRACT.md); how the server works
is its [`docs/ARCHITECTURE.md`](https://github.com/maroge1990/PigTV/blob/main/docs/ARCHITECTURE.md); decisions are its
[`docs/DECISIONS.md`](https://github.com/maroge1990/PigTV/blob/main/docs/DECISIONS.md). The bullets are the durable
detail, oldest feature first within each area; a later build's paragraph overrides an earlier one where they differ.

## Project and targets

| Item | Reference |
|---|---|
| Project | `PigTV.xcodeproj`, shared scheme `PigTV`; deployment targets iOS/iPadOS 17.0 and tvOS 26.5 (#262: any API newer than iOS 17 goes through a fallback modifier in `PigBackDeploy.swift`; Liquid Glass falls back to bordered buttons and material; tests run on the 27 simulators, iOS 17 is compile-checked only); Xcode 27. Targets: `PigTV` (app, **Swift 6 language mode**, default MainActor isolation), `PigTVTopShelf` (tvOS extension, Swift 6), `PigTVTests`, `PigTVUITests` (Swift 5). Synchronized folders: `PigTV/`, `Shared/` (app + extension), `PigTVTopShelf/`, tests. If Xcode is open while `project.pbxproj` is edited by hand, it may re-save the file: check `platformFilters = (tvos)` on the extension's dependency and embed entry survived (it dropped a singular `platformFilter = tvos` once). |
| Contract runner | `sh Tools/test-contracts.sh` (synthetic API/model fixtures, no simulator, no server) |
| Server requests | Raised in the server repo, described by what the screen needs (`../PigTV/AGENTS.md`). The old request log is `docs/archive/SERVER-REQUESTS-2026-09-26.md` (SR-1, SR-2, both resolved). |

## Screens

**At a glance.** Tabs (the system `TabView`, D-44): **Sport** (with the server's `sportsEvents`; opens first) · **TV Guide**
(opens first without sport) · **Recordings** · **Settings**, on tvOS, iPad and iPhone.

| Surface | tvOS | iPad | iPhone |
|---|---|---|---|
| Guide | UIKit grid (`GuideGrid*`), remote focus | the same grid, free touch scrolling | **On now list** (`OnNowList`) |
| Sport | C-O (59): Today sport shelves, rolling 72h league filters, per-account spoiler/delay settings; C-I fallback preserves previous rows | shared initial layout, device adaptation pending | shared initial layout + visible options, device adaptation pending |
| Live player | `CustomPlayerView` (no AVKit UI): info/scrub/channels/tracks overlays | `NativePlayer` (AVPlayerViewController, controls off) + PigTV's `TouchPlayerChrome` | same, bottom-sheet channel list |
| Recording player | `RecordingPlayerView` (custom; Skip break, Auto-skip) | AVKit (`RecordingNativePlayer`) | AVKit |
| Top Shelf | `PigTVTopShelf` extension: favourites as rendered 16:9 cards, `pigtv://play` links | — | — |
| Settings | a menu beside its page (D-44): Sport (C-U), Account, Appearance, Labs, **Diagnostics** (Top Shelf), About | the system split view (menu in the sidebar); no Diagnostics | the menu, each row pushing its page; versions under it |

The bullets below are the durable detail, oldest feature first within each area; a later build's paragraph overrides an
earlier one where they differ.

**iOS player since build 41 (correction, 30 Oct 2026).** The table's iPad/iPhone player cells above were written before
build 41 (`72beb6f`). Since then iOS plays live TV in a bare `AVPlayerLayer` with PigTV's own touch controls
(`TouchPlayerChrome`), PigTV's own Picture in Picture (`ContentView.swift`) and background audio
(`AppConfiguration-iOS.plist`); recordings on iOS use `RecordingTouchChrome`. `AVPlayerViewController` and AVKit's
controls are not used for live play.

- **Screens:** `ContentView` → launch/onboarding/unreachable → `LibraryView` tab container (**Sport** (build 30, only with `sportsEvents`; the tab the app opens on), Guide (opens first without sport), Recordings, Settings; tabs are tagged `sport`/`guide`/`recordings`/`settings` (`LibraryView.tabOrder`), `LibraryView.initialTab` lets the fixtures pick one; a requested tab the bar lacks lands on the opening tab (`LibraryView.tab(for:)`), so `pigtv://home` from older Top Shelf snapshots opens Sport, or the Guide; #214: the Sport tab's pushed sport pages are the session's `SportNavigation` (`BrowseModel.sportNavigation`), and any selection of Sport through the tab bar's binding (coming back from another tab) shows its front page (`LibraryView.tabSelected`); tvOS 27 does not report Select on the already-selected tab, so that returns nothing; #49 groundwork (Apple 105): `AppPresenter` (`AppModel.presenter`, @Observable) is one app-level presentation layer: an `AppPresentation` at a time, hosted by LibraryView (`appPresentations`, a `detailCover`), presenting while one is open closes it first, `dismiss(then:)` acts once it has gone; it also holds the Undo toast (`UndoToast` over ContentView: an action commits after 10 s or when the app goes to the background, Undo cancels it; since Apple 122 an action can also say what Undo puts back, `offerUndo(undone:)`). Player is presented full screen via `PlayerHost` → `PlayerScreen` → `CustomPlayerView` (tvOS) or `NativePlayer` (iOS).

- **iPhone/iPad (A4.4, build 22):** on iOS with a **compact horizontal size class** (iPhone), `GuideView` shows the **On now list** (`OnNowList.swift`) instead of the one-hour grid: a plain `List` of the filtered rows (logo, number, name, flaky dot, programme on now with a progress bar, next start time and title); tapping a row plays it (with the row order as the zap list), the trailing ⓘ opens `ChannelScheduleView`. Filters and Search stay; Earlier/Later/Jump to… are hidden there (no time axis). Per-row data is the pure `OnNowRow.make` (tests `OnNowRowTests`), computed per visible row. iPad (regular width) keeps the grid. (Superseded by build 31's `TouchPlayerChrome`:) the iOS player's top controls (`iOSControls` in `ContentView.swift`) were one row — close on the left; **Last channel** (`returnToPreviousChannel`, only when one is remembered and differs), channel down/up, Go to number, Channels sheet on the right — with the number and name in a capsule below, so a long name never squeezes the buttons.

- **Tab bar (build 27, tvOS, `TabBarStyle.swift`).** Mark: the selected tab, once focus moved into the page, was pink text on the system's light grey pill. tvOS draws the focused pill and the selected-unfocused pill from the same `UITabBarAppearance.selectionIndicatorTintColor` (checked by screenshot: setting it solid pink hid the pink selected text; faint made the focused pill faint), and moving focus along the bar selects the tab, so the two never coexist. `TabBarStyle.apply()` (from `PigTVApp.init`) sets `UITabBar.appearance()` and watches `UIFocusSystem.didUpdateNotification`: focus in the bar → solid pink pill, white text and icon (`item.focused`); focus in the page → selected tab pink text over a faint pink pill (22 % dark / 12 % light), others system colours; in light mode the bar is near-white (`backgroundColor` 85 % white) instead of mid grey. The guide fixture honours `PIGTV_UI_TEST_APPEARANCE=light|dark` (`simctl ui appearance` is unsupported on the tvOS runtime), which is how both modes were checked.

- **Home (builds 28–101) is retired (#216, D-44, Apple 102).** No "TV" tab: Favourites on now is the TV Guide's Favourites filter, Recently watched and the "Continue watching" hero were dropped. Its `CardBadge` and `tvFocusSection` live in `CardStyles.swift` (its card style went with brand 1.8's one focus treatment, `PigFocus.swift`); its minute and foreground refresh moved to the app root (`AppFreshness`, below). The offline library fixture keeps the name `PIGTV_UI_TEST_SCREEN=home` and opens on Sport.

- **Tab switch flash (build 32, `PageBackdrop.swift`).** Mark saw a white flash moving between the top tabs on device. SwiftUI's
  tvOS `TabView` is a `UIKitTabBarController` whose switch slides and cross-fades the two pages; every UIKit layer behind them
  (window, root hosting controller, tab bar controller, each tab's `UIKitNavigationController`) had a nil background, so
  mid-fade tvOS's own backdrop showed through: a light blurred grey veil in light appearance and a dark grey one in dark
  (the white flash on the TV). Found by recording the simulator at up to 60 fps (`simctl io recordVideo`) during
  `TabFlashUITests` and measuring every frame (`Tools/analyse-tab-flash.py`); frames in
  `docs/evidence/2026-09-25-b32-tabswitch-{before,after}-{light,dark}.jpg`. Before: light-mode switches dipped from mean
  luminance 93 % to 86 % (a grey veil), dark rose from 6 % to 13 %. After: every switch passes through the page colour
  (light rises towards 97 %, dark falls towards 2 %), no grey. Fix: `UIColor.pigPage` (dynamic: black dark, white light, so
  it follows the window's appearance override); `WindowBackdrop` (behind the scene's root in `PigTVApp`) paints the
  window; every tab root uses **`.pigPageBackdrop()`** instead of `.background(PigPageBackground())`, which adds
  `PageBackdropPainter`: when the page enters the window (before its first frame) it paints each view controller up its
  responder chain, the root, tab bar and navigation controllers below the root, and the tab bar controller's loaded children
  (presented covers and the player are never touched); `GuideGridViewController`'s view and collection view are `.pigPage`
  instead of clear. The tab bar's own glass capsule was left as it is: it is not part of the cross-fade, and it now samples
  the painted page instead of the backdrop. Fixtures honour `PIGTV_UI_TEST_APPEARANCE` on the window too (as
  `ContentView.syncWindowStyle` does). `TabFlashUITests` switches Home→Settings and back in dark then light, screenshotting
  as fast as XCUITest can (~70–90 shots) and failing if any is over half the wrong colour; it cannot see every display
  frame, which is what the recording is for. Device check: switch tabs quickly in Light, Dark and System appearance.

- **Detail pages (build 28 consistency pass, `DetailComponents.swift`, `DetailScreens.swift`, `GuideSheets.swift`).** Shared parts: `DetailPage` (page background, scroll view, TVActionStyle applied explicitly because covers do not always inherit it; iOS Done button), `ChannelLogoTile`, `Eyebrow`, `StatusPill`, `PigProgressBar`, `PigSectionHeader`, `DetailActions` (a focus-section row of the app's buttons), `FavouriteButton` (BrowseModel favourites, so the guide filter and Home update at once), `pigField()` (a guideCell well for tvOS text fields, which draw unfocused as bare text), `detailCover` (full-screen cover on tvOS — a tvOS `.sheet` is a narrow panel — sheet on iOS). **ProgrammeDetails** (moved out of GuideView): hero with channel line and status badge (Recording scheduled / Recording now / Waiting to record / Recorded), eyebrow (On now · Starts in 12 min · Today/Tomorrow/day · Ended), title 52 pt, time range and duration, live progress and minutes left; description at reading width; actions Watch live (when on now) · Record (opens `RecordSheet`: Start early / Finish late chips, the one-stream note, Schedule recording — the sheet replaces the old pickers and confirmation dialog) · Channel schedule (`openSchedule`, shown when the caller can open it after closing the page) · Favourite. **ChannelScheduleView:** hero with what is on now, Watch live and Favourite, then programmes grouped by day (`ScheduleDays.group`, pure, tests `DetailTextTests`) as surface rows (time and duration column, title, On now/REC badges, description, progress). **ChannelDetails** (the grid's "Channel and favourites"): now/next from the loaded guide (it used to read the Channel's own now/next, which the guide never fills, so it always said "Programme information unavailable"), Watch live · Favourite · Channel schedule, an Up next card. **View recording** (Apple 121, `RecordingView`, replaced RecordingDetails): see Recordings below. **Search** and **Jump to…** are `GuideSearchSheet`/`GuideJumpSheet`: section headings, field wells, programme results as rows with the channel's logo tile; Jump to… uses day chips and a 24-hour chip grid on tvOS (DatePicker on iOS). **Unreachable** and **Onboarding** use the page background, the pink wash and the shared parts (onboarding is two columns on tvOS). **Settings:** page background, `PigSectionHeader`, a red Sign out with an icon; system confirmation dialogs (sign out, cancel recording, delete) keep the system look (not customisable on tvOS) but now show their title and a cancel choice. **Fixtures:** `PIGTV_UI_TEST_SCREEN=programme | programme-later | record | schedule | channel | recording | search | jump | unreachable | onboarding` (`DesignTestScreen`, Home fixture data), each with `PIGTV_UI_TEST_APPEARANCE`; the settings fixture now honours the appearance variable too. Screenshots: `docs/evidence/2026-09-25-details-*.jpg`.
- **Page header placement (build 46).** `PigPageHeader` owns its placement: it insets itself by
  `PigPageHeaderMetrics.edge` (tvOS 0 from the safe area, iOS 20) and is always `rowHeight` (48) tall, taller trailing
  controls overflowing instead of re-centring the row. A page puts it at its top-leading corner with **no padding of its
  own** and outside any padded content stack (Home and Sport wrap their `LazyVStack` in a `VStack` for it).
  `PageHeaderPlacementUITests` checks the title's x, y and height on all five tabs.

- **TV Guide, D-44 (Apple 106–110, R5-Guide-*).** Above the grid (`GuideChrome.swift`): the page header (mark, title,
  the grid's day), a slim **focus strip** (`GuideFocusStrip`, `GuideStripText`: the focused programme's title with a red
  dot and a word when it records, its times, channel and number, status and description on one line; "Long press for
  options" and Details on the TV; on the iPad it reads the programme last touched, `didHighlightItemAt`), then one row of
  **chips** (`GuideChips`: All, Favourites, Sport — every category an admin marked sport, a lone one not listed twice —
  then the data's categories) and the **tools** Now · Earlier · Later · Search · Jump to… at its end, where Up from the
  grid's top row lands (Now). The iPhone keeps the On now list upright and the slim bar sideways. Tests:
  `GuideChromeTests`, `GuidePagesUITests`; screenshots `GuideScreensUITests` (visual tier).
  **One long-press menu (Apple 107, `ProgrammeMenu.swift`):** the system context menu is gone from the grid. A
  `UILongPressGestureRecognizer` (Select held on the TV, touch and hold on the iPad; recognising it cancels the press,
  so the cell is not also selected) reports the programme and its visible frame (`GuideGridActions.menu`); GuideView
  draws `ProgrammeMenuOverlay`, a card beside it (`ProgrammeMenuPlacement`), the page dimmed. While it is open the
  grid's cells refuse focus (`menuOpen`) and the chrome is disabled, so focus stays in the card; Back closes it and the
  grid's restore token puts focus back on the programme. Items (`ProgrammeMenu.items`, pure): RECORD — Record this
  programme (the server's own padding: the buffers are left out of the schedule), or Change recording (Apple 114: the
  record page on its schedule); Record every new episode (a series rule, `newOnly`), or for a Sport card (`isGame`,
  Apple 115) Record this game / Record every <team> game; More options… (the record page through
  `AppPresenter.record`) — then Watch from start
  (C-L, `AppPresenter.recordingPlayer`, full screen), Programme details, Channel schedule, Add/Remove favourites. The
  caller supplies what each does (`ProgrammeMenuActions`). The iPhone's On now rows use the system context menu with a
  preview, built from the same items; the iPad strip's … opens the card.
  **The record page (Apple 114, `RecordPage.swift`, R5-Record-*)** replaces `RecordSheet` and every Sport recording
  dialog ("Record on which channel?", "Record every game of"): one centred card on the page canvas, presented through
  `AppPresenter.record(RecordRequest)`. A `RecordRequest`
  is a guide programme on its channel (`BrowseModel.recordRequest(channel:programme:)`) or a Sport event with its card
  (`recordRequest(event:game:)`: every channel not yet ended, best first, each on its own airing; the card's `id` as
  `gameId`, its two teams and cached logos, the followed side, the league's sport). What, When it stops and Record on
  are pure (`RecordPlan`, `RecordPageTests`): What is this one, then the rules (every new episode / every episode; every
  <team> game as a `team` rule, else a keyword rule; every <league> game); padding chips start on "Usual" (left out, so
  the server's defaults apply); When it stops reads "When the game ends (ESPN)" when a `gameId` is sent (or the schedule
  says `endsWith: "event"`), else the guide end; Record on is drawn only for Sport with several channels. A scheduled
  programme opens it as **Change recording**: its own padding (`pre_buffer_min`/`post_buffer_min`, decoded leniently
  with `endsWith`), Save changes sends only what changed (`PUT recordings/scheduled/:id`, C-M since
  0444; Start early not once it records), the server's words for a refused value are shown (APIClient passes the 400
  and 409 `error` of that route), an older server's 404/405 reads "This server can't change recordings yet"; Cancel
  recording closes the page and offers the 10 s Undo (`cancelCommitted`). Sport screens reach it through
  `SportRecordFlow` (attached to the app); a Sport game card's long press (Apple 115, `SportRecordMenu`) puts the menu's
  RECORD items first in its system context menu (the TV Guide's card overlay needs the grid's focus restore, which the
  sport rails do not have). The event page's and its channel rows' Record close that page first, then open the record
  page. Fixtures `record`, `record-sport`, `record-change` (`DesignTestScreen`, with the Undo toast); tests
  `RecordPageUITests`, `GuidePagesUITests`, `SportFrontUITests`.
  **Recordings (D-44 batch 5, Apple 119–122, R5-Recordings/Scheduled/View/Undo).** No library: `RecordingsView` draws
  the featured recording (the newest partly watched, else the newest finished; `RecordingsHome`, pure) with Resume /
  Watch from start, Details and Delete, the rest as large cards, and Coming up as a strip whose chips and All › push
  Scheduled on the tab's `NavigationStack(path:)` (`RecordingsRoute`). The iPad pins the strip at the bottom; the
  iPhone shows the recordings as a paged card stack and Coming up as a fixed card at the bottom that opens Scheduled
  (the board's card wins over D-44's "pull-up sheet" wording). A game recording ("A v B") draws its two teams
  (`RecordingTeams`: the loaded C-R cards' competitors, only cached `/api/logo/` logos, else monogram discs). Failed
  recordings are on Scheduled only. **Scheduled** (`ScheduledPage.swift`): Coming up (every active schedule with its
  day, the rule's chip, Cancel/Stop, the clash reason and Record this one instead, which still confirms), the recording
  rules (`RecordingsStore.rules`, `reloadRules`; on/off and Remove) and Needs attention (missed/failed with Delete); on
  the iPhone the rules and Needs attention are tiles that push their own pages. **View recording** (`RecordingView`):
  full-width art, a state pill, the info bar (eyebrow, title, where it was left, Resume / Find breaks / Delete, the
  facts) pushed on the same stack (and hosted by `AppPresenter.recording`). **Undo:** Delete, Cancel, Remove and
  Needs attention's Delete act at once (`BrowseModel.deleteWithUndo`/`cancelWithUndo`/`removeRuleWithUndo`/
  `deleteScheduleWithUndo`): the item is hidden through `RecordingsStore.pendingRemovals` (the lists and the guide's
  `ScheduleMarks` filter it), the server call waits for the 10 s or the app going to the background, then for any change
  in flight, and runs as `BackgroundWork`; Undo or a refused call puts the item back. The record page's Cancel recording
  uses the same path.
  **Pages, not covers (#49, Apple 108–110, `GuidePages.swift`):** GuideView's `NavigationStack(path:)` pushes
  `GuideRoute`s (stable ids: the channel's id and the programme's start, resolved against the loaded guide when drawn;
  a route that has left the guide says so). Back pops, and the UIKit grid keeps its focus underneath, so nothing has to
  claim it back. **Programme details** (`ProgrammeDetails`, `pushedFrom:` on `DetailPage`, R5-Programme-*): a hero card
  (`PigHeroCard`: logo, channel · number, the recording state as a word in its colour (`StatusPill`), ON NOW / STARTS
  IN / the day, the title, date · times · length, progress while on, the description), then the actions that apply —
  Watch live (the rose primary while on), Watch from start, Record (the primary otherwise; the record page through
  `AppPresenter`) or Change recording (the record page on its schedule), Record series, Channel schedule, the
  favourite — and "Also
  on <channel> tonight" (`AlsoOn`: the next four that evening, until 6 am), each opening its own page. A page's Watch
  pops to the grid, then plays.
  **The channel page** (`ChannelPageView`, Apple 109, R5-Channel-*) replaces Channel schedule and "Channel and favourites"
  (`ChannelScheduleView`, `ChannelDetails` deleted): a hero (logo; name · number; ON NOW, with REC as a word while it
  records; the title, times and what is left, progress; Watch live (the rose primary), Watch from start, the favourite)
  with UP NEXT beside it (below it on iOS), then the days (`ScheduleDays.upcoming`: everything after the programme on
  now), each row opening its programme's page. The menu's Channel schedule, a programme page's and the iPhone row's ⓘ
  push it.
  **Search and Jump to** (`GuideSearchPage`, Apple 110, #57's Apple half, R5-Search-*) are one pushed page, side by side
  (stacked on the iPhone, which has no Jump to upright): Search looks through the loaded guide (`GuideSearch`, pure:
  channels by name, each listing once; programmes not ended that start in the next 24 hours, soonest first; two letters
  at least), debounced 300 ms and run off the main actor, results keyed by the channel's id and the programme's start;
  a channel opens its page, a programme its page. Jump to: seven day chips and 24 hour chips (`GuideJump`), then Show
  guide pops to the grid and moves it there. The rows are no longer filtered by channel name, and the server's search is
  not used. With every Guide page pushed, GuideView has no covers, and `claimGridFocus` moves SwiftUI focus into the
  grid once, with no timed retries; after Show guide that happens when the pop has put focus back on the tool that opened
  the page (claimed earlier, the pop's own focus restoration wins). Tests: `GuidePagesTests`, `GuidePagesUITests`,
  `GuideGridNavigationUITests.testJumpToOpensFullyAndReturnsFocusToTheGrid`.

## Guide grid and focus model

- **UIKit guide grid (A2.1, build 20; the only tvOS grid since build 27, and the iPad's since build 29):** `GuideView` shows `GuideGridView` on tvOS and on iPad (regular width; the SwiftUI grid — `timelineGrid`, `GuideTimelineRow` — was **deleted in build 29**, so there is one grid) (`UIViewControllerRepresentable` → `GuideGridViewController`), keeping its header, filters, summary area and all sheets/covers; the Now button sits in the header next to Earlier/Later (build 22). One `UICollectionView` with a custom `GuideGridLayout`: section = channel row, item 0 = the channel tile (pinned left via the content offset), items 1…n = programmes at `x = (start − model.window) × pointsPerSecond` over the whole loaded 24 h (2 h = the timeline width), or one day-wide "no programme information" placeholder; a now-line decoration; cells clipped at the channel column with the clipped amount passed to the cell (`GuideGridAttributes.leadingClip`) so titles stay visible. The time header is a separate strip view above the rows that follows `contentOffset.x` (so rows never scroll under it). Horizontal position is owned by the grid: `GuideGridCollectionView` locks `bounds.origin.x`, so the focus engine's own scroll-into-view cannot move it sideways; the grid moves by whole half-hour columns with its own 0.2 s ease-in-out display-link animation (none with Reduce Motion). Focus is the collection view's own: `canFocusItemAt` makes finished programmes unfocusable and, in rows other than the focused one, only the Up/Down target (the programme under the time anchor) focusable; `shouldUpdateFocus` plans the column move for Left/Right and redirects Left-onto-the-tile ahead of the live baseline (step back / return to live) via `indexPathForPreferredFocusedView`. Pure maths (positions, clipping, sticky tile, column reveal, vertical target, left step) is in `GuideGridMath.swift`; the row filter is `GuideRowFilter` (shared with the SwiftUI grid). Rows are applied with a plain data source (append → `insertSections`, anything else → `reloadData` + focus restored by identity), not diffable snapshots, because the real guide has ~18 000 channels × ~30 programmes. Files: `GuideGridMath.swift`, `GuideGridLayout.swift`, `GuideGridCells.swift`, `GuideGridView.swift`; tests `GuideGridMathTests`, `GuideGridNavigationUITests` (no launch argument since build 27; `GuideNavigationUITests`, the SwiftUI grid's test, was deleted).
  **Build 21 follow-ups:** (a) when the player or a details cover closes, GuideView bumps `focusRestoreToken` and the grid refocuses its last programme or tile (what is on now in that row if the programme finished meanwhile); (b) Now, Earlier, Later and Jump to move focus with the grid, to the programme under the new anchor in the last focused row (else the first visible row). In both, the grid makes the target its preferred focus (`claimFocus`) and GuideView moves SwiftUI focus into the representable (`.focused($gridHasFocus)`, `claimGridFocus`, retried at 0/0.4/0.8 s while a cover dismisses) — **`UIFocusSystem.requestFocusUpdate` is refused while a SwiftUI control holds focus**, so this must go through SwiftUI. (c) The long-press menu (`contextMenuConfigurationForItemsAt`) already offered the old grid's items; now covered by a UI test (menu items are exposed as `otherElements`). (d) Programme cells rebuild their SwiftUI content only when `GuideGridMath.clipAppearance` (clipped or not, the title's whole-point shift) changes, not on every frame the clipped amount changes; off-screen/unclipped cells get no `apply` during a slide (their attributes are unchanged). Rasterising was not needed. UI tests: Now after moving right; long-press menu and focus back after details. (Superseded in build 22:) on the remote, Up from the grid goes to the header's right-hand buttons (Details, Jump to…), so Now is only reached via the category chips (All → Down).
  **Build 22:** Now moved into the header's button row (before Earlier/Later, new guide only). Up from the grid's top row lands on it: the grid's `shouldUpdateFocus` refuses the engine's move out of the top (no next index path, heading up) and calls `GuideGridActions.leaveUp`, which sets GuideView's `headerNowFocused`. Only Now and Jump to… pull focus into the grid (`GuideGridRequest.focus`); Earlier/Later leave focus on their button so repeated presses work, and claim no grid target. UI tests: `testNowAfterMovingRight` (Up → Now → Select), `testLaterAndEarlierKeepFocusOnTheHeader`.
  **Build 33 — the guide no longer hits a wall moving forward (Mark, live testing: "as if it hasn't loaded any further").**
  Root cause: `GuideGridLayout.loadedDuration` (the grid's content width) was never fed from the model and stayed at the
  hard-coded `GuideNavigation.loadedDuration` (24 h) forever, so the grid could not scroll or focus past it regardless of how
  much programme data existed; `GuideNavigation.needsReload` compared the viewport to the same fixed `window + 24 h`, and a
  reload it did trigger (e.g. the header's Later button) ran `loadGuide()` with `keepVisible: false`, blanking every row.
  Now: `BrowseModel.guideLoadedUntil` (published) tracks how far programme data actually reaches, starting at
  `window + loadedDuration` and pushed forward by `extendGuideForward()`; `GuideGridView` carries it down as
  `loadedDuration` (`guideLoadedUntil − origin`), so the layout's content width grows with it — `GuideGridViewController.
  update(from:)` treats a duration-only change as layout-only (`invalidateLayout`, no reload, no scroll/focus change).
  `GuideView.setViewport` calls `GuideNavigation.needsExtension` (true within `extendThreshold`, 6 h, of the loaded edge) to
  kick off `extendGuideForward()` in the background well before the grid could run out of columns; `needsReload` now takes an
  explicit `until:` (`guideLoadedUntil`, not always `window + 24 h`) for a genuine jump outside the loaded range (Jump to…),
  which still reloads but always with `keepVisible: true`. `extendGuideForward()` pages through every channel exactly like
  the initial load, for the next `loadedDuration` slice, and merges the results into existing rows
  (`GuideNavigation.mergeProgrammes`, deduped by start time — `GuideChannel.withProgrammes` swaps just the programme list) —
  never replacing them — while trimming programmes older than `GuideNavigation.pastTrimMargin` (24 h) to keep memory bounded
  over a long session; `GuideGridViewController.apply(rows:)` gained a third case (`extendedOnly`, alongside `appendOnly` and
  the full reload) that only `reloadSections` for the channels whose programme count actually changed. Ends for good
  (`guideEnded`), with nothing left to retry, once a slice comes back with no programmes — the provider's guide has ended.
  `GuideRowsInput` gained `programmesVersion` (from `BrowseModel.guideProgrammesVersion`, bumped on every merge) since a
  channel's identity/count alone does not change when its programmes are extended in place, so the existing row-filter
  memoisation would otherwise never notice. A failed guide page (initial load or an extension) is retried with backoff
  (`GuideNavigation.guidePageRetryDelays`, 8 s then 12 s — 3 attempts across ~20 s) before it surfaces; the error banner's
  Retry (`BrowseModel.retryGuide`) resumes from `guideCursor` — wherever paging stopped — instead of
  restarting the whole guide. The on-disk guide cache is unchanged (`saveCache` still runs once, right when the initial
  load's paging finishes, before any extension, so it stays about one day). Measured on 1 000 channels (offline fixture,
  `PIGTV_UI_TEST_CHANNELS=1000`): merging one 24 h slice into every row took **~200 ms** end to end (network round trip +
  JSON decode + the single rebuilt-array `guide` assignment), well under the UI's stall budget; tab-switch and grid-navigation
  perf tests (`TabSwitchUITests`, `GuideGridNavigationUITests`) show no regression. Pure functions and tests:
  `GuideNavigation.needsExtension`/`mergeProgrammes`/`trimmed`/`needsReload(until:)`/`guidePageRetryDelays` (`ContractChecks.
  swift`); `BrowseModel.extendGuideForward`/`retryGuide` against a fake paged/flaky guide endpoint, including the 1 000-channel
  timing (`GuideModelTests.swift`); a UI test on the offline fixture (`GuideFixtures.forwardHorizon`, 26 h, so there is real
  next-day data with no server to extend from) moves right past 24 h and confirms real programmes keep appearing
  (`testMovingRightPast24HoursReachesTheNextDaysProgrammes` — on the old code this hangs the app: "process main thread busy
  for 30.0 s", confirming the wall).
- **Guide focus model:** `GuideFocus(channel, start)`; `start == nil` is the channel tile, `-1` the no-EPG placeholder (the old tvOS edge targets −2/−3 are gone). The grid reports it (`gridFocus`); nothing in GuideView assigns it. `viewport` (half-hour aligned) drives the header date and 24-hour data loads (`model.window`).
- **iPad guide (build 29; Mark: a swipe moved the old SwiftUI grid by one step, not with the finger).** The same `GuideGridView` with **free touch scrolling**: `GuideGridCollectionView.locksX = false` on iOS, `isDirectionalLockEnabled`, a normal pan with deceleration; `scrollViewWillEndDragging` moves the target to the nearest half hour (`GuideGridMath.snappedOffsetX`, pure: half hours are clock times, so it holds when the loaded window starts off the half hour; the nearest inside the content otherwise), and the viewport is committed when scrolling stops (`commitScrolledViewport` → header date, day loading, Earlier/Later). A new pan stops a header button's animation. The channel column stays pinned and the time header follows `contentOffset.x` as on the TV (header 34 pt, caption-sized labels on iOS). Taps: a live programme plays, a later one opens details, the tile/placeholder plays (`didSelectItemAt`, deselected at once); touch and hold opens the TV's long-press menu; a pressed cell takes the focus look (`state.isHighlighted`). Focus claims (`claimFocus`, `restoreFocus`, `claimGridFocus`) are tvOS-only. The header gains Now on iPad; the summary line reads "Tap a programme on now to watch, a later one for details • Touch and hold for options". iPhone (compact width) keeps the On now list. Tests: `testFreeScrollSnapsToTheNearestHalfHour`. Screenshots `docs/evidence/2026-09-25-b29-ipad-guide-{dark,light}.jpg`.

- **tvOS fast swipe in the guide grid (build 46).** A fast swipe drops focus, scrolls the collection view itself, then
  lands focus on a visible cell with no `shouldUpdateFocus` call. Anything the grid plans in `shouldUpdateFocus`
  (`plannedRow`) must be cleared in `didUpdateFocus`, or `scrollViewWillEndDragging` clamps the landing scroll back to the
  stale row (the "snaps back to where I started" bug). `GuideFastScrollUITests` holds Down/Up on 300 channels.

## Player

- **Player exit (58):** `PlaybackModel.stopping` is published before item teardown. `PlayerScreen` keeps its black
  background while `AppModel.endPlayback` awaits release; clearing `ready` during exit cannot show the tuning card again.
- **Player layering:** conflict/error/reconnecting states replace the player. **tvOS:** `CustomPlayerView` (`CustomPlayer.swift`) is the only player — `PlayerLayerView` video + one overlay switching between hidden / info / scrub / channels / tracks chrome, driven by in-view remote handlers, no AVKit. **iOS/iPadOS:** `NativePlayer` (AVPlayerViewController with **`showsPlaybackControls = false`** since build 31, so it only draws the picture) + PigTV's touch controls (`TouchPlayerChrome`, below). A1.2: the "Preparing…"/reconnecting states in `ContentView.swift`'s `PlayerScreen` show a `TuningCard` (channel `LogoTile`, name, current/next programme from cached guide data, a "Tuning…"/"Reconnecting…" spinner), not a bare `ProgressView` — **on iOS too since build 29**.
- **iPhone/iPad player parity (build 29; Mark on iPad: no "Tuning…", the old channel sheet). The AVKit-controls and `TouchInfoOverlay` parts of this paragraph are superseded by build 31's touch controls (next bullet); the shared pieces remain.** Shared pieces live in `PlayerShared.swift` (both platforms, sizes in `PlayerMetrics`): `LogoTile` and `TuningCard` (moved out of `CustomPlayer.swift`/`ContentView.swift`), `PlayerChannelRow` (the TV side list's row: logo tile, name + muted number, now title, progress, pink outline on the current channel — the tvOS `channelRow` now draws it), `PlayerCommands` (Favourite and Record-now with their notices, used by the TV action row and iOS), `PlayerInfoText` (time range, progress, minutes left, "Next: …"; pure) and `AppModel.playerChannels` (zap list, else the guide). iOS-only in `PlayerExtras.swift` (the old `QuickGuidePanel` sheet is gone): `PlayerChannelPanel` (current channel highlighted and scrolled to; a tap calls `switchPlayback`), shown as `PlayerSidePanel` on iPad (regular width: 420 pt translucent panel from the leading edge, header with close, tap beside it closes) or as a bottom sheet on iPhone (`.medium`/`.large` detents, ultra-thin material, dark); and `TouchInfoOverlay` (logo, channel and muted number, programme, times · minutes left, progress with LIVE/BEHIND LIVE, next, **Favourite**, **Record**, **Last channel**), bottom-leading above AVKit's transport bar. **Chrome visibility:** AVKit has no public signal for its controls' visibility on iOS, so the top controls and the info overlay show/hide together on the same taps: `NativePlayer` adds an observe-only tap recogniser (`cancelsTouchesInView = false`, simultaneous) reporting whether the touch landed on a `UIControl` (AVKit's buttons/scrubber → keep up) or the picture (toggle), and they hide after 4 idle seconds unless paused, the panel or Go to number is open, or VoiceOver is running (`PlayerChromeTimer`, pure; the first tap after a channel starts keeps them up, since AVKit's controls are hidden then). The top row no longer repeats the channel name (the overlay has it). Tests `PlayerSharedTests`. **Fixture:** `PIGTV_UI_TEST_SCREEN=player` (with `PIGTV_UI_TEST_MEDIA=<local movie path>`, played via the DEBUG `PlaybackModel.playFixtureMedia`) · `player-channels` (panel open) · `player-tuning` (resolve to TEST-NET 192.0.2.1, so it stays on the card); `AppModel.injectPlayerFixture`. Screenshots `docs/evidence/2026-09-25-b29-{ipad,iphone}-*.jpg`.
- **iOS/iPadOS touch controls (build 31; Mark: "clashing between the new player and avkit, there are controls for both on screen … the new player controls are a bit small … (tv guide in particular)").** AVKit's controls are off; `TouchPlayerChrome` (`PlayerExtras.swift`) is the only control layer, shown and hidden as a whole: a tap on the picture (a clear tap layer under the controls in `PlayerScreen.touchPlayer`) toggles it, and it hides after 4 idle seconds unless paused, the channel panel or Go to number is open, or VoiceOver runs (`PlayerChromeTimer`, simplified to `afterTap(visible:)` = toggle; the old AVKit tap watcher is gone). Layout: **top bar** — Close (44 pt circle), channel name and muted number (own line on an upright iPhone), and a prominent labelled pill **Channels** (the channel panel: side panel on iPad, sheet on iPhone; build 46 removed the **TV Guide** pill beside it: it only closed the player onto the Guide tab, which Close already does); **centre** — −15 s / play-pause (92 pt on iPad) / +15 s circles (the skips only when there is a seekable window); **bottom panel** (replaces the separate floating `TouchInfoOverlay`, deleted) — logo, programme, times · minutes left, Next, a **draggable scrub bar** (`TouchScrubBar`: 44 pt touch height, 6 pt track, 22 pt knob; drag follows the finger and seeks on release via `PlaybackModel.seek(toFraction:)`; VoiceOver adjusts ±15 s) over the seekable window (`PlaybackModel.seekWindow()` → `PlayerSeekWindow`, pure: fraction ↔ time, behind-live, "LIVE" within 20 s (40 s since build 56), readout "30:00 behind live"), a left readout (clock time when live; else "−2:15"), LIVE or a **Go to live** pill; without a window, the programme's progress with LIVE. Actions: Favourite, Record, Last channel, channel down/up, Go to number (labels on iPad, 44 pt icon circles on iPhone; beside the programme on iPad landscape, their own row otherwise via `ViewThatFits`). White glyphs on dark translucent circles/pills, gradient shades top and bottom, opaque with Reduce Transparency. AirPlay/PiP stay out of scope. Tests: `testSeekWindowMapsPositionsFractionsAndReadouts`, updated `testChromeFollowsTapsAndHidesWhenIdle`. Screenshots `docs/evidence/2026-09-25-b31-{ipad-player-landscape,ipad-player-portrait,ipad-player-channels,iphone-player-portrait,iphone-player-landscape}.jpg` (fixture `player` with a local 5-minute test movie, so the window reads "−4:57 · Go to live"; the "Recording notifications are temporarily unavailable" line is the fixture's offline coordination warning).

- **Timeshift / Start over (C-E, build 21): removed in build 39** with the server's tuner model; `PlayerTimeMath` (`PlayerTimeMath.swift`) keeps the programme fraction and the behind-live readout (`m:ss` under an hour, `h h mm min` from an hour).

- **Display mode without waiting (build 27).** Device log: first picture − resolve ≈ 3.0 s on every start, because `PlaybackModel.start` awaited `loadDisplayCriteria(item.asset)` (bounded by 3 s) before `replaceCurrentItem`, and on the device the live master playlist's criteria never arrived in time. Now `DisplayMode` (`DisplayMode.swift`, pure, tests `DisplayModeTests`) builds the criteria from the resolve decision: `PlaybackDecision.info` (decoded tolerantly as `ResolveStreamInfo`: `fps`, `videoRange`, `video`, `width`, `height`) → refresh rate (the server's `parseFrameRate` rules, 1…240 fps) and range (PQ/HLG only when the video is not encoded, else SDR) → a `CMVideoFormatDescription` whose extensions carry the transfer function (SMPTE ST 2084 / ITU-R 2100 HLG / ITU-R 709), primaries and matrix (BT.2020 for HDR) → `AVDisplayCriteria(refreshRate:formatDescription:)` (AVFoundation, tvOS 17+, not an AVKit category). `installItem` sets it and plays immediately. With no usable `fps` (older server, direct route) the asset's criteria are loaded in the background and applied if the item is still current. Recordings do the same (background load, never awaited). **Rule: nothing may await before `replaceCurrentItem`/`play()` except the resolve and the audio session.**
- **Device-error fallbacks (build 27).** `PlaybackFallback.for(_:)` classifies the failed item's error chain (`PlayerErrorCode`s from the item's error and its underlying errors, or the failed-to-play-to-end notification's error). **-11868** in `AVFoundationErrorDomain` (no compatible alternates for the display: the HDR master playlist on a non-HDR TV) → play the same session's `stream.m3u8` (same directory and token, `PlaybackModel.streamPlaylistURL`) with no display criteria and a fresh play-start event; no new resolve. **1718449215 = `'fmt?'`** (copied audio the device cannot decode) → release and resolve again with `ResolveBody.audioEncode = true` (absent otherwise; the server re-encodes only the audio) and remember the channel's `identityKey` in `AudioEncodeMemory` (UserDefaults `pigtv.audioEncode.channels`), so later plays request it from the first resolve. Either fallback uses up the one C2 recovery (`recoveryUsed`), happens at most once per user-initiated attempt, never forces, and a repeat of the error goes to the normal error/Retry path. Tests in `PlaybackLifecycleTests` (synthetic failures; the media host is TEST-NET-1 so the real item never fails first).

- **Live plays are held 30 s behind the edge (build 56), built at 0.97× (build 72, #7, server D-36).** A play starts with no
  fixed offset (build 56's `configuredTimeOffsetFromLive` froze the picture ~26 s through a new play's first delivery pause)
  and plays at `LiveCatchUp.slowRate` (0.97, `audioTimePitchAlgorithm` `.timeDomain`) until it is
  `PlayerSeekWindow.liveOffset` behind the edge, then at 1.0 (`updateCatchUp`, its own 2 s time observer; at once on a
  source that ends); measured in the server's `docs/evidence/2026-10-30-live-hold-variants/`. Go to live, a forward skip
  and a scrub release return to the held offset, not the very edge, and neither a skip nor a scrub release moves a play
  that is still building back (`PlaybackModel.skip`/`seek(toFraction:)` use `PlayerSeekWindow.skipTarget`/`scrubTarget`,
  build 73, #159); only on a live playlist (indefinite duration): a source that ends keeps its whole range (build 57). Some providers pause 3-16 s while healthy
  (server `docs/archive/FINDINGS-2026-10-30.md` FR-8); the server calls a shared feed lost at 24 s behind real time (R7, 0282). Preserving the
  offset after a stall (`automaticallyPreservesTimeOffsetFromLive`) is off: it would skip content.

- **Where playback starts, and its channel list (builds 79–81, batch 6).** #13: the player's channel list is the list
  the play set (a guide row, a Home shelf, a sport event's channels), else the whole guide (`AppModel.playerChannels`):
  Home's hero and a Top Shelf channel set none (the guide), and `endPlayback` forgets the list, so a later play never
  inherits a one-item or stale one. #14: a play started from outside the screen (a Top Shelf link, a "watch when it
  starts" timer) posts `.pigCloseCovers`, which every `detailCover` answers by closing, and starts after
  `AppModel.coverCloseDelay` (0.7 s); a play whose `PlayerScreen` never appears within `playerAppearDeadline` (6 s; off
  in the synthetic test host) is ended with "The player could not open. Try again." instead of leaving the app
  "playing" with no player. #46, #216: while the app is active and signed in, the root (`ContentView`, `AppFreshness`)
  loads the guide when none is loaded, else brings a stale one up to date (`refreshGuideIfStale`), refreshes favourites
  and exports the Top Shelf, at once and every minute, whichever tab shows; returning to the foreground restarts it, so
  the Top Shelf is current the next day. Tests `ZapListTests`, `PlayOverCoversTests`, `AppFreshnessTests`.

## Recording player

- **Recordings on tvOS (A4.3, build 21): one player.** `RecordingPlayerScreen` shows `RecordingPlayerView` (`RecordingPlayer.swift`) once ready: `PlayerLayerView` video plus a recording overlay built from the live player's shared parts in `PlayerControls.swift` (`PlayerActionRow`, `PlayerScrubTrack`, `playerBottomShade`, `BlankButtonStyle`): channel and date, title, scrub bar with elapsed and remaining, Left/Right ±15 s, Play/Pause, a **Skip break** pill while inside a break (Select skips; also first in the action row), an **Auto-skip breaks** toggle in the action row (only when the recording has breaks), Back hides chrome then closes. `RecordingPlayerModel` keeps lifecycle, resume and markers, and gains `timeline()` (`RecordingTimeline`, pure, in `DVRModels.swift`), `skip`, `togglePause` and display criteria (from the asset's `preferredDisplayCriteria`, applied whenever that load finishes and never awaited before playing — build 27 — since a bare layer does not switch HDR/frame rate). The tvOS `AVPlayerViewController` path (contextual action / transport-bar menu) is deleted. **iOS keeps AVKit** (`RecordingNativePlayer`, iOS only) for recordings, because touch scrubbing is AVKit's strength. Only a completed recording plays (`Recording.playLabel`).

## Labs and stream info

- **Labs (C-F, build 19):** Settings has a "Labs" section (`LabsToggleRow` in `SettingsView.swift`) of persistent `@AppStorage` switches, all off by default. Keys and wording live only in the `Labs` enum (`Labs.swift`): `pigtv.labs.streamInfo` (A4.2 stream info overlay) is the only one left (`pigtv.labs.newGuide` and `pigtv.labs.heaac` were removed in build 27). Later work reads `Labs.isOn(…)`; add new switches to `Labs.toggles`. **HE-AAC passthrough (C-C) left Labs in build 27:** `PlaybackCapabilities.current()` always sends `"heaac": true` (Mark accepted it); the 'fmt?' → `audioEncode` fallback is the safety net.
- **Stream info overlay (A4.2, build 22, Labs → Stream info overlay, tvOS):** with the switch on, the custom player's info overlay adds one line (`StreamInfoLine` in `CustomPlayer.swift`, refreshed every second only while the overlay is up): codec from the video track's format description (H.264/HEVC/…; Dolby Vision from a `dvh1`/`dvhe` entry or a `dvcC`/`dvvC` box, else HDR10/HLG from the transfer function), `presentationSize` @ `nominalFrameRate` (else `currentVideoFrameRate`), indicated bitrate (observed) from the access log's last event, dropped frames summed over access-log events, stalls this session, the resolve route (strategy · video copy/encode) and `ServerInfo.identity`. Gathering is `PlaybackModel.streamStats()`; naming/formatting is pure (`StreamInfo.swift`, tests `StreamInfoTests`). `play-end` events also carry `droppedFrames` and `observedBitrate` (the server's client-event route logs named fields and ignores unknown ones, checked in `routes/playback.js`).

## Top Shelf

- **Top Shelf (A4.1, build 22, tvOS):** a TV Top Shelf extension target **`PigTVTopShelf`** (`PigTVTopShelf/ContentProvider.swift`, `TVTopShelfContentProvider`, sectioned content; bundle `au.markrogers.PigTV.TopShelf`; tvOS only, embedded in the app's "Embed Foundation Extensions" phase and depended on with `platformFilters = (tvos)` so the iOS build skips it — keep that filter, an iOS build fails without it). One section ("Favourites", else "Channels" = the lineup's first rows) of up to 12 items: logo from its absolute URL (`.hdtv` shape), title `Fox Footy — <programme on now>` (no number since build 29) (sectioned items have no subtitle, so the programme follows the channel), play/display action `pigtv://play?sourceId=…&id=…&name=…&number=…`. Data: the app writes `topshelf-snapshot.json` into the **App Group `group.au.markrogers.PigTV`** (under `Library/Caches` since build 29) (`Shared/TopShelfSnapshot.swift`, a synchronized folder compiled into both targets; `PigTV/TopShelfExport.swift` builds it from favourites or guide rows with now/next and absolute, credential-free logo URLs) after favourites load, after the guide's first and last page and after the cached guide loads; unchanged content is not rewritten; `topShelfContentDidChange()` is posted; sign-out deletes it. The extension never uses the network. Deep links (`PigTVLink`): `ContentView.onOpenURL` → `AppModel.open(_:)`: signed in → play (switch if already playing) the guide's channel, else a favourite, else one built from the link's fields; a link arriving before the launch restore finishes is held and played only if that restore succeeds within a minute. Entitlements: `PigTV/PigTV.entitlements`, `PigTVTopShelf/PigTVTopShelf.entitlements` (App Group only); URL scheme `pigtv` in `AppConfiguration.plist`. Tests `TopShelfTests`. **Signing:** automatic signing; Mark's first device build may need Xcode to register the App Group for both bundle IDs (target → Signing & Capabilities; confirm App Groups lists `group.au.markrogers.PigTV` ticked for PigTV and PigTVTopShelf). Until it is registered, the snapshot write fails and the Top Shelf shows the static image.
  **Build 32 — rendered cards (Mark: the logos were "very pixelated when blown up to that size … worse than nothing").**
  Items were logo URLs (mostly the server's 320 px thumbnails) stretched to the 16:9 shape. Now the app renders its own
  cards (`PigTV/TopShelfCards.swift`) and items point at their **file URLs** in the App Group; confirmed in the tvOS
  simulator that `TVTopShelfSectionedItem.setImageURL` loads a file URL from the shared container
  (`docs/evidence/2026-09-26-b32-topshelf-sim.jpg`; fixture `docs/evidence/2026-09-26-b32-topshelf-cards-fixture.jpg`).
  **Size:** Apple's sectioned 16:9 size, 908×512 pt, rendered with `ImageRenderer` at scale 2 → **1816×1024 px PNG**
  (`TopShelfCardLayout`). **Design** (`TopShelfCardView`): dark gradient card with a faint radial wash of the logo's
  saturation-weighted dominant colour (`TopShelfLogoLook`; pink when the logo has none); the logo centred in the upper part
  at **no more than its native pixel size** (1 logo px = 1 card px, capped to a 520×210 pt box, never enlarged; a small
  logo stays small), on a light plate only when it is a dark mark on a transparent background; programme title 44 pt bold,
  2 lines; a LIVE capsule and "7:30 – 9:00 pm"; a thin pink progress bar (the only pink). No logo: the pig and the name.
  **Cards per channel:** the programme on now (progress at render time, in 5 % steps) and the next (drawn as it will look
  while on); a channel card without programme data. `Entry.cards` (`[Card(file, start, end)]`, optional so older
  snapshots decode) and `Entry.imageURL(at:)` (Shared) pick the card whose programme covers the time, else the channel card,
  else the logo URL (old behaviour); the extension just calls it. **Logos:** `BrowseModel.topShelfLogoImage`: the server's
  full size `GET /api/logo/:key?size=full` for `/api/logo/` paths (`fullSizeLogo`; an older server ignores the query),
  else the plain URL (8 s timeout each), else the guide's decoded thumbnail (`ChannelArtwork.cachedImage`); decoded at
  native size (≤ 2048 px). **Files:** `<group>/Library/Caches/topshelf/<sourceId_id>-<hash>.png` (`TopShelfCards`); the
  name hashes everything drawn (and `TopShelfCardLayout.version`), so tvOS never shows an older card from its URL cache,
  and an existing file is reused without rendering. **Flow (tvOS):** `exportTopShelf()` → `TopShelfCardExport.schedule`
  (cancels a run in progress) renders on the main actor after each guide/favourites load, yielding between cards and
  encoding off-main → `TopShelfExport.save` writes the snapshot if changed, **prunes** unreferenced card files, posts
  `topShelfContentDidChange()`; on iOS/iPadOS `exportTopShelf()` does nothing (no guide scan, no snapshot). Sign-out removes the folder. **Diagnostics:** "Written <date>, 12
  items, 24 cards rendered · App Group OK". **Fixture:** `PIGTV_UI_TEST_SCREEN=topshelf-cards` renders the Home fixture's
  cards through the real export (also into the simulator's App Group) with a 1200 px, a 160 px and a transparent dark logo,
  and shows four at the 852×480 focused size. `TopShelfCardsUITests` screenshots it, then focuses PigTV on the Home Screen
  and screenshots the shelf (`TEST_RUNNER_PIGTV_SCREENSHOT_DIR=<dir>` saves both). Device check: favourites' cards look
  sharp; logos from `size=full` once the server has it; the item title still reads "Channel — Programme".
  **Build 31 — the real cause (Mark: still only the pig in build 30).** `topShelfContentDidChange()` was already posted after every write; the extension never ran at all. Reproduced in the tvOS simulator (a UI test pressing Home and focusing PigTV: HeadBoard logged "Connection to plugin interrupted while in use", the extension process logged nothing) and traced with lldb: the `tv-app-extension` product type links the entry point **`_TVExtensionMain`, which the current tvOS runtime implements as an empty function (`ret`)**, so `main` returned immediately (exit status 3) and tvOS fell back to the static image. Fix: the extension links with **`OTHER_LDFLAGS = -e _NSExtensionMain`** (both configurations); the simulator's Top Shelf then shows the "Favourites" section from the snapshot (`docs/evidence/2026-09-25-b31-topshelf-sim.jpg`, placeholder art because that test snapshot had no logos). `testTopShelfExtensionEntryPoint` checks the embedded binary references `_NSExtensionMain` and not `_TVExtensionMain`. Principal class (`$(PRODUCT_MODULE_NAME).ContentProvider` → `PigTVTopShelf.ContentProvider`) and deployment target (26.5, same as the app) were correct. **Diagnostics:** the extension records each request (`TopShelfExtensionStatus`, `topshelf-extension-status.json` in the group's `Library/Caches`: time, items, note), and **Settings → Diagnostics (tvOS)** shows "Top Shelf: Written <date>, N items · App Group OK" (or "Not written yet" / "no App Group") and "Top Shelf extension: Last asked <date>: returned N items" (or "Not asked yet"), read by `TopShelfDiagnostics.lines` (tested with a temporary container). On device (R4.4) the shelf then worked, but the 320 px logos looked stretched and pixelated; build 32's rendered cards (above) replace them with file URLs in the App Group.
  **Build 29 (device console: `write: failed at …/AppGroup/<uuid>/topshelf-snapshot.json: … Code=513 … POSIX 1 "Operation not permitted"`).** On tvOS the **root of an App Group container is not writable**; apps may write only under `Library/Caches` inside it (no persistent Documents on tvOS; Caches is purgeable, fine for data rewritten on every guide/favourites load). `AppGroupStorage` (`Shared/TopShelfSnapshot.swift`) is the one path helper: `directory(in:)` = `<container>/Library/Caches`, `fileURL(_:in:)`, `createDirectory(for:)` (writers create it; readers only look). The snapshot (app writer, extension reader) uses it; sign-out also removes any root-level copies an older iOS build left. The simulator's container root is writable, so only the device showed the failure. Tests: `testSnapshotFileRoundTripThroughTheSharedPath` (path ends in `Library/Caches`, the writer creates it), `testAppGroupPathsEndInLibraryCaches` (directory round trip; on tvOS a real write under the real group's Library/Caches).
  **Build 27 (Mark: the Top Shelf showed only the pig on device).** End-to-end review: both targets reference their entitlements (`group.au.markrogers.PigTV`) in Debug and Release; the extension's built Info.plist has `com.apple.tv-top-shelf` and `PigTVTopShelf.ContentProvider`; the app writes after favourites load, after the guide's first/last page and after the cached guide loads (verified in the simulator's App Group). **Found:** the extension's Info.plist had **no App Transport Security exception**, while every logo URL is plain `http://<LAN server>/api/logo/…` (the app's `NSAllowsArbitraryLoads` does not cover an extension), so the logos could not load and the shelf fell back to the static image — the probable cause, to be confirmed on the TV. Fixed: `NSAllowsArbitraryLoads` + `NSAllowsLocalNetworking` in `PigTVTopShelf/Info.plist`. Also: a failed snapshot write is no longer remembered as written (the next export retries). **Diagnostics:** `TopShelfLog` (os `Logger`, subsystem `au.markrogers.PigTV.TopShelf`, category = process bundle id) logs the app's export/write (`write: N favourites channels to …`, or `no App Group container`), `topShelfContentDidChange posted`, and the extension's `loadTopShelfContent called`, `read: … bytes, N channels` / `no snapshot` / `no App Group container`, each item's logo URL (debug) and `returning N items`. Storage goes through `TopShelfSnapshot.fileURL(in:)`, `read(container:)`, `write(container:)` (tests: temp-dir round trip; the app's container exists; the embedded appex has the ATS exception and principal class).

## Sport

- **The Sport tab is the front page (C-R, `SportFrontView`), always.** `SportsLandingView` draws it whatever the server's
  flags say; a server without `sports/front` gets the page's own error or empty state. The tab itself shows only with
  `sportsEvents`.
- **Sport events (C-I; flag `sportsEvents`).** `SportModels.swift` decodes `GET sports/events?hours=72` tolerantly
  (`SportEventsResponse`/`SportEvent`/`SportEventChannel`; `LossyList` drops events or channels that do not decode, events
  without channels are dropped, ids may be numbers, a missing league reads "Sport", `quality` is `SportQuality` UHD/HD/SD
  case-insensitively and anything else nil, `kind` is `event` or `replay` with anything else an event; times are
  **milliseconds**). `SportModel` (`BrowseModel.sport`, one per session) loads it (a 404 means no events); the Guide's
  "Watch on…" reads `events`, and `live`/`soon` are plain filters over them (replays left out). Pure helpers `SportRows`:
  `progress`, `startsIn`/`endsIn`, `timing` ("Live · ends in 40 min" / "8:30 pm · in 25 min" / "Sat 1:30 pm").
- **Sport channel choice.** `SportRows.channelAction`/`playsChannelNow` is the one rule the event page's primary action,
  its channel list and the channel picker share: live, or starting within `watchNowWindow` (5 min), plays on select;
  otherwise select offers **Record on `<channel>`** and **Watch `<channel>` when it starts** (`AppModel.watchWhenStarts`
  holds a `PendingWatch` that plays at the start while the app stays foregrounded; cancelled on background and sign-out).
  `SportChannelList` (shared by `SportEventDetails` and `SportChannelPicker`, owned by the screen's `SportPresenter`)
  draws it. Fixtures `sport-event` · `sport-channels`; tests `SportTests.swift`, the harness test
  `testSelectingASportEventPlaysItsBestChannel`.

### Sport pages: Formula 1 (C-P, builds 74–75)

- **Per-channel airing times (build 74, #20).** `SportEventChannel` decodes C-I's per-channel `start`/`end` (server 0337);
  `SportEvent.airing(on:)` answers the chosen channel's times, else the event's (an older server). The Watch-now rule
  (`SportRows.playsChannelNow(_:on:now:)`), `watchWhenStarts`, `recordingRow`/`isScheduled` and every `RecordSheet` use it,
  so a channel showing a session late is never played or recorded on another channel's hour.
- **F1 and NFL data (C-P, C-Q).** `F1PageModels.swift` decodes C-P tolerantly (`F1Page`, sessions in time order, a
  broken session or row dropped) and holds the pure rules (`F1PageText`: the focus session, "Sat 31 Oct · 5:30 am", the
  session as a C-I `SportEvent`); `NFLPageModels.swift` does the same for C-Q. `F1PageModel` (`BrowseModel.f1Page`)
  also loads the household's preferences (`sports/pages/preferences`) every 60 s while visible. Both are drawn only by
  the D-43/D-44 sport pages (`SportF1Content`, `SportFixtureContent(.nfl)`); the standalone `F1PageView` and
  `NFLPageView` were retired in build 168 (#243). Fixtures: `PIGTV_UI_TEST_FRONT_F1=1 | live` and
  `PIGTV_UI_TEST_NFL_JSON` / `_NFL_FOLLOW` with the pages fixture; tests `F1PageTextTests`, `F1PageModelTests`, the
  NFL and F1 cases in `SportPagesUITests`, and `StagingF1UITests` (iPad against the Unraid staging server; skipped
  unless `TEST_RUNNER_PIGTV_STAGING_URL`, `_USER`, `_PASS` are given).

### Apple TV front page and sport pages (C-R, D-43, build 97)

- **One banner** (`SportBanner.swift`; pure parts `SportBannerModels.swift`): 250 pt under the tabs, the hero on the left
  (kicker, title, one line, `SportHeroButtons`: Watch or Remind me, Record, and on the front page "Open <sport>") over the
  faded badge or the circuit map (C-P `info.map`, `mapDark` in dark mode), and a list on the right behind a thin line:
  four rows in a fixed-height scroll view, then "N more · …" (`SportBannerWindow`: focus moving past the window scrolls
  it one row, the banner never grows). One item or none: full width, no list (`SportBannerLayout.fullWidth`). Rows are
  drawn in the order sent (C-R since 0427: playing now first); the client never re-sorts.
- **Front page (tvOS, `SportFrontTVPage`)**: no tiles. The banner's list is `follows[]`, selecting one flips the hero
  (`SportFrontModel.select`, the C-R hero rule unchanged; a long press on a row offers its sport's page). Below, a section
  per sport (`SportFrontLayout.sections`: rails grouped by C-U's `sport`, in the rails' order) with a header button
  ("Football ›", `sport.rail.header.<sport>`) and its leagues' rails of `SportGameCard`s (334 × 132; a followed team is
  marked by its star alone on the television and by the pink outline and star on touch, brand 1.8). Sports with no rail: "Also in your sports" buttons
  (`sport.also.<sport>`). The iPad (regular width) draws this page too (D-44).
- **iPhone front page (`SportFrontPhonePage`, D-44, R5-Front-iPhone, Apple 139)**: the header (pig, "Sport", a "Scores
  shown / hidden" chip), a 212 pt carousel of `follows[]` in the order sent (#215: playing now, then soonest; one card
  each with the teams' 48 pt badges, the score, the clock and channel, Watch or Remind me and Record every game; dots and
  "1 of 7 follows"), then one card per sport (`SportFrontLayout.sections`) under its "Football ›" header (opens the sport
  page) with its first three games as `SportFixtureRow`s: logo · Team v Team · logo, the score on the right, the state
  (red while live), time and channel beneath; a session's row has its league's square badge. Words: `SportPhoneLayout`
  (pure, tests `SportPhoneLayoutTests`), spoiler-free applied (unknown counts as on, #192; nothing hidden is read out).
- **iPhone sport pages (`SportPhonePage`, D-44, R5-*-iPhone, #177, #186, Apple 142)**: the front page's pattern. "‹ Sport",
  the sport and the scores chip; the sport's leagues as chips (only with more than one); a 212 pt carousel of the
  selected league's games (`SportPhoneCarousel`, shared with the front page: the league's follows in the order sent, each
  recording its own team, #49, then its other live games; with neither, the next to start; "1 of 4 · yours, then live");
  its games as `SportFixtureRow`s under Live, Later today, Coming up and Earlier. The league's own content (what the
  Apple TV shows under its banner: rounds and standings, Formula 1's weekend, the cricket scoreboard and tour, a
  leaderboard, order of play or fight card) is a page of its own behind that header (`SportRoute(sport:league:)`,
  `SportPhoneLeaguePage` around `SportLeagueContent`, #177). Words: `SportPhonePageLayout` (pure, tests
  `SportPhonePageTests`). A league with no server page has no such header.
- **Narrow sport pages (Apple 142)**: below 1100 pt (an iPad in portrait; the iPhone's league page) the environment's
  `sportNarrow` (set from the Sport tab's width, never the content's) stacks a league's panels (`SportColumns`): the
  standings under the round, F1's lists one under another and its session tiles scrolling sideways, golf's side column
  and the UFC card under each other, the cricket tour under its scoreboard. On the iPhone the cricket columns and actions
  are compact and golf's leaderboard drops the rounds (R5-Golf-iPhone). The Apple TV is unchanged.
- **One spoiler decision per sport page (#192, Apple 143)**: the page's (the preference, unknown counting as on, OR the
  answer's `spoilerFree`) goes to every league panel as `sportHidesSpoilers`, and each panel ORs it with its own
  preference, on the Apple TV, iPad and iPhone alike (`testLeaguePagesHideScoresWhenTheAnswerIsSpoilerFree`).
- **Shared words (Apple 137–138)**: a next-round card (C-R `nextRound`, #218) reads "Next round · Sat 15 Nov" with no
  channel, Watch or Remind me (`SportFrontText.isNextRound`/`startLine`/`channelLine`); a live card's clock is short
  (`cardClock`: "Q4 0:17", "OT1 10:00", #211), the down and distance stay in the banner; C-T's `%` is one decimal
  (`FixtureText.standingValue`); standings values are never cut. Cricket files a match under C-S's own `league` first
  (#210); Follow a driver lists C-P's whole grid (`drivers`, #202).
- **Sport page (`SportPageView`, pushed in the front page's `NavigationStack` by `SportRoute`)**: the banner with the
  sport's leagues (`sports[]` of that `sport`, as sent) and a back button; hero by `SportPageRules.hero` (a follow live →
  the sport's league live → a follow's soonest next → the league's soonest scheduled game, Remind me → the sport's quiet
  words). The selected league's content below: F1, NFL and cricket embed their pages (`embedded: true`: no header, no F1
  weekend hero, no scroll view of their own); any other league its C-R games as cards. Fixture: `PIGTV_UI_TEST_SCREEN=front`
  with `PigTVTests/Fixtures/sport-front-0427.json` (`PIGTV_UI_TEST_FRONT_F1=1` embeds the F1 fixture); tests
  `SportBannerTests`, `SportFrontLayoutTests`, `SportPageTests`, `SportBannerUITests`.

### Settings, Sign in and Offline (D-44 batch 6, Apple 129–133, R5-Settings/SetSport/Account/SignIn/Offline)

- **Settings** (`SettingsView.swift`): `SettingsMenu` (pure) lists Sport (only with `sportFollows`), Account, Appearance,
  Labs, Diagnostics (tvOS only) and About, each with a summary ("2 sports · 3 follows", "mark · pigtv.local", "App 129 ·
  Server 0444"). The iPad (regular width) uses `NavigationSplitView`, the menu in its sidebar and the page in a
  `NavigationStack` beside it; the iPhone (compact) a `NavigationStack` whose list rows push the pages. On tvOS 27
  `NavigationSplitView` inside the tab bar drew only its sidebar, full width, so the TV lays the menu (460 pt) and the
  page side by side as two focus sections (`defaultFocus` lands on the selected item). Since Apple 201 (#279, the owner's
  choice; brand 1.8: moving focus never selects) focus shows the section's read-only summary beside the menu
  (`SettingsSummaryView`: title, the menu's line, a few facts the app already holds; nothing focusable, no request), a
  press opens the real page and moves focus into it (each page's first control carries `settingsFirstFocus()`, which
  takes focus when the press asks), and Menu returns to that row and
  its summary (`SettingsTVDetail`, pure). About (in the tab) and Diagnostics have nothing to focus: a press opens them and
  focus stays on the row. The selected item is 14 % pink with a short bar. `PIGTV_UI_TEST_SETTINGS_PAGE` opens a page in the fixtures.
- **Account** (`SettingsAccountPage`): Signed in as, Server, Use a different server, Sign out. Sign out confirms inside its
  own row (D-44's one confirmation, never a dialog): "Sign out of PigTV?" with Stay signed in (the rose primary, focused on
  the TV; Menu does the same) and Sign out. Use a different server opens the same row and then Sign in at its server step
  (`AppModel.signInAtServer`).
- **Settings › Sport** (`SportSettingsSection`, `SettingsSport.swift`): Hide scores and Score delay side by side (a Form
  section on iOS), then the followed sports in order (leagues, the first two followed names with the cached `/api/logo/`
  logo the loaded C-R front page gives each, `SettingsSportLogos`, else a monogram `SportBadge`), suggestions, Add a sport.
  Score delay (`ScoreDelaySetting`) is C-O's `sports/preferences` `scoreDelaySeconds`, hidden when that answers 404 (scores off): −10 / +10 within 0–300, sent with the revision read; a refused save reads it again and says so.
- **Sign in** (`SignInView.swift`, `OnboardingView`): the stacked lockup, then step 1, the server's address, whose Continue
  reaches `/api/info` (`AppModel.checkServer`), and step 2, the server as a chip (a check once reached) with Change and two
  tiles: Pair with browser (recommended, the one rose primary, focused) and
  Username and password (the fields, Sign in, Back/Menu). A saved server opens on the tiles (`SignInStep.opening`).
- **Offline** (`UnreachableView`): the pig inside a ring that empties over the 20 s to the next automatic retry
  (`RetryCountdown`, pure; restarted after each attempt), "Trying again in N seconds", the reason, the address, Try now
  (the rose primary) and Use a different server.

### Settings › Sport (C-U, #200)

- **What the account follows, synced through the server (D-41).** Only with `sportFollows`: a Sport section after
  Appearance (`SportSettingsSection`, `SportFollowSettingsView.swift`) with league suggestions (Add / No thanks), "Hide
  scores", a row per followed sport (its leagues and names) and "Add a sport". A sport's page (`SportFollowScreen`, a
  `detailCover` on tvOS, a NavigationLink on iOS): its place in the order, Stop following, its leagues (Move up / Move down /
  Remove, Add a league under the catalogue's headings; none for a one-league sport), its teams or players with "Record every
  game" (a C-M `team` rule; only with `recordingRules` and for team sports) and Unfollow, and "Follow a team…" (a search over
  the followed leagues' `sports/names`, 30 at most). `SportFollowLogic` (`SportFollowModels.swift`) is the web's
  `SportFollowModel` rule for rule; `SportFollowSettingsModel` (`BrowseModel.sportFollows`) loads the follows, catalogue,
  rules, suggestions and names each time the section appears, and sends each change as a whole-list `PUT sports/follows`
  one after another, each built from the state its turn finds; the server's answer is what shows ("Not saved: …" and a
  re-read otherwise). Unfollowing asks whether to keep a "Record every game" (`forgetRules`). Questions are alerts on the
  screen that asked (`SportQuestionPresenter`). A spoiler-free change makes the sport pages' preferences
  (`BrowseModel.f1Page`) unknown until read again. The last answer is kept per server and account (`UserDefaults`, key
  `sportFollows.lastCopy.<CacheScope digest>`): offline it is shown read-only. Fixture `PIGTV_UI_TEST_SCREEN=settings-sport`
  (`SportFollowFixtures`); tests `SportFollowLogicTests`, `SportFollowSettingsModelTests`, `SportSettingsUITests`.

## Concurrency (Swift 6)

- **Swift 6 (A4.5, build 22; reverted in build 23; back for good in build 28):** the app and Top Shelf targets build in the Swift 6 language mode. **Build 28 callback audit:** every AVFoundation/KVO/notification callback is explicitly `@Sendable` (nonisolated) — `PlaybackModel`'s item-status and `timeControlStatus` KVO handlers, its failed-to-play-to-end and stalled notifications, the Start over seek completion, `RecordingPlayerModel`'s status KVO — and hops to the main actor with `Task { @MainActor in … }`; only where the queue is guaranteed main (`addPeriodicTimeObserver(queue: .main)` in the recording player, `TabBarStyle`'s `queue: .main` focus notification) is `MainActor.assumeIsolated` used. The URLSession delegates (`NoRedirects`, `ArtworkRedirects`) are `nonisolated` (URLSession calls them on its own queue; with the default main-actor isolation a redirect would have trapped). UIKit delegates, `DispatchQueue.main.async` and the display link run on main. The real-playback harness runs these KVO/notification/time-observer paths for real (including the recording player's periodic observer and a real -11868 status failure) and passes under Swift 6. Build 22's notes: The switch needed nine small changes, none behavioural: pure value types/helpers marked `nonisolated` (`ServerAddress`, `Labs`, `Category`, `PlayerTimeMath`, `StreamStats`, `StreamInfoFormat`); `GuideGridAttributes.isEqual` `nonisolated` with `leadingClip` `nonisolated(unsafe)` (NSObject's `isEqual` is nonisolated; UIKit uses attributes on the main thread); (`PlaybackModel.loadDisplayCriteria` was removed in build 27, see below). New code should keep pure helpers `nonisolated` so the Swift 5 test targets can call them.

## Caches

- **Caches (R14):** private data is scoped by `CacheScope` (normalised server URL + user id + schema version, `PrivateCaches.swift`): the guide cache is `Caches/PigTVGuide/guide-v2-<digest>.json`. Sign-out, and replacing the session with another server/account, call `BrowseModel.retirePrivateCaches()`: the file is deleted and a save still in flight is dropped. Artwork (not private) is keyed by `ArtworkKey` (absolute URL resolved against the server, `token` removed) in the decoded cache (`ChannelArtwork`, 32 MB cost budget) and on disk (`Caches/PigTVArtwork-v2/`, SHA-256 of the key; LRU by modification date, refreshed on read; 50 MB / 30 days, pruned off-main at first use). One task per key fetches (`APIClient.artworkData`) and decodes (`ChannelArtwork.decodedLogo`); responses stream and are abandoned past 4 MB (Content-Length checked first); disk I/O and decoding are off the main actor. Home rebuilds on whole-value changes of favourites/recent/recordings, not id lists. Tests `CacheTests`.

## Performance

- **Tab switching (build 31; Mark: "switching between the five tabs is slow … stuck loading the one you moved from").** Found: every tab reloaded on each appearance — Guide `loadFavourites` + `loadRecordings` + the artwork index (again after every failure), Home recent + favourites + recordings, Recordings its list — and each load published 3–4 changes (busy, data, error, busy) that re-rendered **all five tabs** (they all observe `BrowseModel`); recordings, schedules and favourites were decoded on the main actor (`APIClient` is main-actor isolated); GuideView refiltered every row on each appearance. No `onDisappear` work was found in the tabs. Changes: `BrowseModel.load{Favourites,Recordings}IfStale(maxAge: 60 s)` for appearances (Refresh/Retry and the periodic refreshes still call the plain loads; the attempt time counts, so a failing server is not hammered); unchanged data, errors and busy-cleared errors are not re-assigned (`Recording`/`ScheduledRecording` are now `Equatable`); recordings and schedules decode off the main actor (`APIClient.decodedOffMain`); GuideView keeps a `GuideRowsInput` signature (count, first/last id, load time, cache flag, filter, search, favourites, categories) and refilters only when it changes, off the main actor (detached task, published if still current) once the guide has ≥ 3,000 channels. Home's rebuild measured 0.2–2 ms and stays on the main actor. **Measurement:** fixture option `PIGTV_UI_TEST_CHANNELS=<n>` (Home and Guide fixtures, copies of the 14 channels) and a DEBUG `TabSwitchProbe` (`PIGTV_UI_TEST_TABPROBE=1`, in `TabBarStyle.swift`: a display link for 1.5 s after each switch, longest stall and frame time lost, exposed as `debug.tabSwitch`); `TabSwitchUITests` walks Home→…→Settings and back twice on 1,000 channels (fails on a stall over 1 s). tvOS simulator, 16 switches: **before** mean longest stall 150 ms, worst 482 ms (first Guide visit), repeat Sport→Recordings up to 435 ms; **after** mean 120 ms, worst 459 ms (first Guide visit: building the UIKit grid), repeat visits 60–120 ms (≈ the tab bar's own transition; Settings, which does nothing, costs 55–115 ms). The fixture makes no successful requests, so the real saving on a device (skipped requests, publishes and main-thread JSON) is larger than the simulator shows. Test `AppearLoadTests` (FakePigTVServer request counts).

From the 3 Oct audit (`../PigTV/docs/archive/audit-2026-10-03/ROADMAP.md`) and the multi-provider work.

- **Every API request says what it is (84, #19).** `APIClient.response` sets `X-PigTV-Client: PigTV/<CFBundleVersion>
  (<OS> <version>; <model>)` from `ClientIdentity.current` (tvOS, iPadOS or iOS; the model from `uname`, a simulator's
  from `SIMULATOR_MODEL_IDENTIFIER`). The server keeps it on the paired device for Status and Settings → Devices; media
  and artwork requests do not send it, and the server keeps the last value it had.

- **Screens observe only what they show (R05).** `BrowseModel` publishes nothing itself; its state lives in small stores
  (`BrowseStores.swift`): `GuideStore` (channels, window, paging), `RecordingsStore`, `LibraryStore` (favourites),
  `ScheduleMarks` (republished only when the sets change) and `ActionState`. The old `BrowseModel` properties
  forward to them, so **each view lists the stores it observes in its `init`**: a view that reads `model.guide` without
  observing `guideStore` never updates. Home draws from `HomeModel`, which publishes only a different `HomeContent`.
  `.whileVisible` (`WhileVisible.swift`) runs Home's minute loop and the Guide's clocks and refresh only while on screen. Background recordings refreshes are `quietly:`. `ObservationTests` counts publishes per screen.
- **The first TV Guide visit doesn't stall (R03).** The shell shows first and the grid is made a frame later (`gridReady`,
  `NextFrame`); programme lists are ordered off the main actor (`GuideGridStore.orderedLists`); rows are revealed 0–2, 0–5,
  then all (`GuideGridLayout.revealedRows`); tvOS skips the header's `ViewThatFits`. `GuideGridStore` keys its lists by
  `GuideGridRevision` (`guideProgrammesVersion` + `guideLoadedAt`), so a same-shape EPG correction is not served stale.
  Simulator, 1,000 channels: first visit ~170–180 ms (was 0.5–1.6 s).
- **Caches are per server and account (R14).** Guide cache `Caches/PigTVGuide/guide-v2-<sha256(v2|server|user)>.json`, deleted
  on sign-out or when another session replaces it (`retirePrivateCaches()`). Artwork keyed by canonical absolute URL (token
  removed); one fetch per logo in flight; decoded cache 32 MB; disk `PigTVArtwork-v2/` LRU 50 MB / 30 days; responses over
  4 MB refused; disk work off the main actor.
- **Recordings** start without waiting for break markers (loaded beside playback with a 3 s budget, applied on arrival;
  "Loading recording…" until actually playing). "Preparing for playback…" shows while the server's background preparation
  (`native_status` pending/preparing) runs. Resume positions are the server's, per login; the device's own saved position
  is read only when the server's cannot be (`RecordingResume.source`).
- **Warming the next channel (R11; the server's switch, off by default).** `ChannelWarmer`: only while the player is open,
  one target at a time after 1.5 s settled: the channel channel-up/down would most likely go to (the previous one after a
  switch, else the next), refreshed every 60 s. Browsing and focus never warm anything. Cancelled by a real play's start, a
  new target, closing the player or backgrounding; silent on 204 and errors. A play that
  adopts a warm stream sends `warm: true` on `play-start`.

## Using the server contract

- **Channel numbers (C-A, build 19):** `Channel.number`/`GuideChannel.number` decode the optional server number; `BrowseModel.number(for:)` shows it, and `asChannel` carries it into player channels. **Build 29 (Mark: numbers are not very relevant to him, and the dark number sometimes covered the logo): never drawn over artwork.** The number badge was removed from the guide `ChannelTile` (UIKit grid cells and the On now list), Home card art and the Top Shelf title (now "Fox Footy — AFL Live"; the snapshot still stores the number for the play link). Where it remains it is `ChannelNumberText` (`DetailComponents.swift`): small, muted text *after* the channel name (Home hero, tvOS player info overlay and side list rows, iOS player, On now list), via `Text(verbatim:)` so it is never locale-grouped. Screenshots `docs/evidence/2026-09-25-b29-numbers-*.jpg`. Channel up/down follows guide row order (the provider's order: numbers are labels only since server 0139). iOS only: a "Go to number" control in the player (alert with a number field) calls `AppModel.goToChannel(numberText:)`, which looks in the zap list, then the guide. tvOS has no number entry.
- **Channel health (C-G, build 19):** `GuideChannel.health` decodes `"ok" | "flaky" | null`; `BrowseModel.isFlaky` is true only for `"flaky"`. The guide tile then shows a small amber dot top-trailing, left of the red recording dot when both apply (accessibility label "Unreliable channel", also spoken as the tile button's value).

- **Provider on resolve (C-J).** `ResolveProvider` decodes tolerantly (malformed → nil). The Labs stream info line adds
  "Provider: Trex (backup)" for a backup and "switched from primary" when `failover` is true; a primary play adds nothing.
- **Licence reminders (C-K).** `AppModel.checkProviderReminders()` runs once signed in, on `scenePhase == .active` and when the
  player closes; never runs while `playerPresented`, at most one banner per local day per device
  (`pigtv.providerReminderDay`, set only when one is shown). The banner is an **overlay** on the root view (no cover, so no
  W6 focus trap), dismissed after 15 s, by OK (iOS) or when playback starts; **on tvOS it is deliberately not focusable**.
- **Recovery window (build 66, #5).** Once a play has shown a picture, up to three automatic re-resolves in any 10 minutes
  (`recoveryWindow`, `recoveries`; `clock` injectable), the first at once, then after 3 and 10 s (`recoveryDelays`), with
  the Reconnecting card and Back meanwhile; a reconnect whose resolve fails for a passing reason (network, HTTP 5xx/408,
  including a C-B sentence the server sent with one, `PigTVError.serverMessage`, build 69, #147, except a channel that is
  gone, "This channel is not available" without "right now", whatever its status, build 71, #153; a 429 after its
  retry-after, up to 30 s) tries again inside the same window, any other error shows at once
  (`retryWait(after:)`, build 67, #139), and the retry is scheduled after cleanup with any session it could not release,
  so its takeover is still checked (#140). Only
  failures count (stalls do not); simultaneous signals are one failure; never forced; Retry starts a fresh window. The
  build-27 fallbacks use a slot too. Replaces one recovery per 120 s of stall-free play, which a bursty feed never renewed.
- **Removed with the server's tuner model (build 39):** Start over, the dated timeshift scrub, growing recordings. An older
  server's `timeshift` and `recordingHls` flags are ignored. Siri / App Shortcuts were removed in build 37.

The contract itself (flags, frozen shapes, C-A…C-N) is [`../PigTV/docs/CLIENT-CONTRACT.md`](https://github.com/maroge1990/PigTV/blob/main/docs/CLIENT-CONTRACT.md).
How this client applies it:
- **Minimum server: build 0476** (D-53, `ServerInfo.minimumBuild`). `ServerInfo.validate()` requires `apiVersion == 1`,
  `library` and `playbackResolve`, and refuses a server whose build parses below 476 ("This PigTV server is too old for
  this app…"; a build that does not parse is accepted), at restore, sign-in, pairing and Sign in's Continue. Every flag
  that is `true` on all servers from 0476 on is no longer read. The flags still read are those a current server may send
  as false (`channelQuality`, the sport flags) and treat a missing flag as off.
  On servers 0476 to 0502 with scores switched off the Sport front page shows its error state (from 0503 the server
  serves it with scores off). With scores off, `sports/preferences` answers 404 and Settings › Sport has no Score delay.
- **Resolve errors (C-B):** a non-2xx resolve whose `error` starts with a C-B prefix becomes `PigTVError.message` (trimmed to
  300 characters); any other text, any text containing `://`, and any non-resolve path keep the generic mapping
  (`APIClient.displayableResolveError`).
- **Media URLs:** only `/api/proxy/stream`, `/api/transcode/…` and `/api/recordings/…`, token as `?token=`, bearer on session
  DELETE. Do not broaden URL acceptance to fix playback. `APIClient.requestURL` rejects `?` in paths: use query items.
- Resolve always sends `capabilities.segmentedDelivery = true` and `heaac = true`; once per channel after a `'fmt?'` failure,
  `audioEncode`. A "transcode" strategy usually means a copy into HLS, not a re-encode.
- Guide and marker times are **milliseconds**; favourites are written with the bare id and read from `library/favourites`.
- Watch from start follows a row's `watch_live` (C-L); recording rules (C-M) are always offered; a row's `image` (C-N) is
  drawn when present. The watch route's 409 is read by `recordingWatch` (`finished` → play the file).
- A new endpoint this client calls needs a matching entry in the server's `test/api-404.test.js` → `APPLE_CLIENT_ROUTES`.

## Branding implementation

The rules are in the Pig family PigBrand kit (`~/code/PigBrand`; guide 1.8.1, token files 1.7.0) and the server's
[`docs/DESIGN.md`](https://github.com/maroge1990/PigTV/blob/main/docs/DESIGN.md); this is how the client takes them in.

The "Spotlight" look (plum plate, `#FF2E94` halo, generated bitmaps, `Tools/make-brand-assets.swift`) is **retired**. Every brand image
now comes from the kit (`../PigBrand`, product `assets/products/pigtv`; rules in its `docs/integration.md` "Apple and Apple TV" and
`docs/pig-family-brand-guide.md` §8 and §10). The app uses the **PigTV product pig** (pig-shaped screen) everywhere.
**Sync:** `sh Tools/sync-brand.sh [path to PigBrand]` (default `../PigBrand`; idempotent, running it twice changes nothing).
Against kit 1.8.1 it changes nothing (checked 11 Nov 2026, Apple 202): the app's Apple TV icon is the kit's source as of 1.8.1.
It copies `mark.svg` → `PigLogo.imageset` (vector), `lockup-horizontal-*/lockup-stacked-*.svg` → `LockupHorizontal`/`LockupStacked.imageset`
(vector, any + dark; drawn by `PigLockup`, never rebuilt from a pig and the wordmark), the kit's PigColors status colours, the kit's
`AppleTV/dark` brandassets → `App Icon & Top Shelf Image.brandassets` (tvOS icon + Top Shelf; one appearance only, asset names are shared),
the Icon Composer layers → `PigTV/AppIcon.icon/Assets` (`background-*.png` → `halo-*.png`, `layer-1-body.svg` → `body.svg`, `layer-2-face.svg`
→ `face.svg`, `mono/*` → `body-mono.svg`/`face-mono.svg`), and renders `LaunchBrand.imageset` with `Tools/render-launch.swift` (compiled
with `PigTV/BrandLayout.swift`). `AppIcon.icon/icon.json` is hand-maintained in Icon Composer and is never touched. The Top Shelf extension
(dynamic content) references no brand asset.
- **iOS icon:** `PigTV/AppIcon.icon` (Icon Composer; iOS only, `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`). There is no `AppIcon.appiconset`.
  The tvOS build is unaffected by it.
- **`BrandLayout.swift` is hand-maintained** and shared by the render helper and SwiftUI: pig size (0.42 S wide; S = 1080 pt on tvOS, 600 pt
  elsewhere), halo radius (1.35 × the pig's visible size), the lockups' canvas and pig ink boxes, and the radiance stops from the kit's `pig-radiance.css`
  (halo, bloom core and wide, corner bloom). mark.svg is a 1024 square with the pig optically centred (ink 669.5 wide), so the optical
  centre is the square's centre; `PigBrandMark` sizes its square frame by the ink fraction so the pig keeps its on-screen size.
- **Launch screen:** `UILaunchScreen` in `AppConfiguration.plist` (colour `LaunchEdge` = the PigCanvas colours, `#FBF8FA` / `#15111A`, + image
  `LaunchBrand`): a **transparent** PNG (any/dark; tv @2x, phone @2x/@3x) holding the static halo as an alpha radial gradient and the mark. No text.
  (The kit's square icon art is not canvas-coloured at its edges, which would seam.)
- **Splash:** `BrandSplashView` (`ContentView` while `!initialRestoreFinished`). First frame = launch screen (halo at full opacity, no bloom, no
  name). Then the kit's stacked lockup fades in over 250 ms, its pig exactly on the launch pig (same drawing and ink width), and the halo breathes: halo opacity 1 → 0.25, bloom (core 0.75 r + wide 1.6 r radial
  gradients) opacity 0 → 1 and scale 0.9 → 1.12, `.easeInOut(duration: 4).repeatForever(autoreverses: true)`. The pig never moves or scales.
  It ends exactly when start-up ends (never waits for a cycle); progress spinner after 2 s. Reduce Motion: static halo, wordmark shown, no
  animation. Reduce Transparency: plain canvas, no glow. Fixture: `PIGTV_UI_TEST_SCREEN=splash` (+ `PIGTV_UI_TEST_APPEARANCE`).
- **Canvas:** `PigPageBackground` = canvas colour + one rose (`#EF7AAE`) radial gradient from the top **leading** corner (mirrored for
  right-to-left), alpha 0.16 → 0.067 at 27.9% → 0 at 62% of the diagonal (light; 0.13/0.055 dark); plain canvas with Reduce Transparency. The
  UIKit guide grid (`GuideGridViewController` view and collection view) is clear over that SwiftUI background; the UIKit containers painted by
  `PageBackdrop` stay flat canvas behind it.
- **Onboarding/sign-in:** the stacked lockup (`PigLockup(trimmedToInk:)`, pig 130 pt on the TV, 96 pt on iOS, centred). Radiance never sits behind forms: `PigIdentityBackdrop` is a
  static halo behind the lockup's pig only, over the page canvas.
- **Apple TV focus (brand 1.8 §6/§15, #279, Apple 198):** one treatment, `pigFocus(_:in:lift:)` in `PigFocus.swift`, used by
  every tvOS button style (secondary, surface, primary, chips, menu rows, Settings menu, sign-in tiles) and the guide grid's
  cells: a drawn lift (scale, capped in points per edge by `PigFocusLift`, plus a shadow; 0.15 s; no scale or animation under
  Reduce Motion), the accent ring outside the control (outer edge `PigFocus.ringOutset` 4 pt, `ringWidth` 3 pt), and the focus
  fill (`PigFocus.fill`, accent 22 %; the primary keeps its rose). Apple's `hoverEffect(.lift/.highlight)` does run inside these
  styles on tvOS 27 but its glass rim covered the ring (simulator, 11 Nov 2026), so the lift is drawn. A guide cell stops
  clipping only while focused, so its ring shows in the 8 pt gap. `BrandRulesTests` fails on a tvOS style that draws focus
  itself, and on `focusEffectDisabled` outside the two players. On the television followed sport cards carry the star
  only (touch keeps the pink outline). On touch the shared styles keep their pre-1.8 keyboard-focus ring (an `#else` in
  each). The guide's cells carry the focus modifier only while focused (`pigFocusWhenFocused`).
- **Television text is 23 pt or more (brand 1.8 §15, #279, Apple 199):** `PigType.caption`, `kicker` and `secondary` are
  23 on tvOS (touch unchanged) and keep their rank by weight, colour and case; the player's tuning card and channel rows,
  the guide's time line and time header are 23 too. A scale factor goes through `pigMinimumScale(_:size:)`, which never
  shrinks television text under `PigType.minimum`. Guide cells: the time line above one title line cut with an ellipsis
  (row pitch 80). The Sport banner lists three 56 pt rows on the television (`SportBannerWindow.visible`), four on touch.
  `BrandRulesTests` reads the tvOS values from the source and fails on any under 23.
- **Television focus targets are 56 x 56 pt or more (brand 1.8 §15, #279, Apple 200):** every focus style applies
  `pigTarget()` (`PigFocus.minTarget`) before drawing its surface, so chips, secondary and primary buttons, menu rows and
  the score-delay steppers (now buttons with their own `pigSurface` on the raised tile) are at least 56 pt. A row inside
  a sport list card is not a focus stop (the card is). `BrandRulesTests` fails on a focus style without the minimum.
- **Roles, not literals (#190, kit §4–§7):** colours are catalog roles (`Color.pig*`); playback uses the kit's `media` tokens as
  `PigMediaAccent` (rose `#EF7AAE`, the live dot), `PigMediaPanel` (black 82 %, every panel over video), `PigMediaSolidPanel` (`#15111A`,
  the Reduce Transparency fallback), `PigMediaCanvas`/`PigMediaText`; shadows use `PigShadow` (the kit's glass shadow colours). These and
  the shared radii (`PigRadius`, `PigBrandRoles.swift`: TV compact 10 / card 18 / hero 32, touch 10 / 16 / 22, nested 6) are app-owned;
  the one content colour (a logo's tint) is `Color(artworkRGB:)`. Figures use `.fontDesign(.rounded).monospacedDigit()` (§5).
  Since Apple 104 black and white are roles too: labels on a status fill (LIVE on `pigDanger`) or a team disc are `pigOnStatus` (the
  kit has no on-danger role; it is `PigMediaText`), on the accent `pigOnAccent`; the player host uses the media roles (player files
  keep their literals until their own pass). `BrandRulesTests` scans `PigTV/` for literals (black/white too, outside the player
  files and fixtures), checks every tab root draws the page canvas and corner bloom, and checks the lockup assets.

## Implementation map

| Files | Responsibility / things to preserve |
|---|---|
| `Models.swift`, `APIClient.swift` | Info/errors/resolve payloads, status decoding, URL/auth rules. Optional conflict envelope preserves the strict recording type. Status-aware responses support bounded recording polling. Diagnostics strip queries and retain bearer authentication. |
| `AppModel.swift` | Auth and model construction, channel switching. Validated info is retained on the authenticated APIClient through restore/login/pairing and exposed in Settings; logout clears it. Rate-limit cooldown stops immediate repeat auth attempts. |
| `PlaybackModel.swift`, `ContentView.swift`, `CustomPlayer.swift`, `PlayerShared.swift` (both platforms), `PlayerExtras.swift` (iOS channel panel and info overlay) | Player lifecycle, presentation, prompts and controls. `ready` means item installed; actual `.playing` supplies prior-play evidence (`hasPlayed`). Since build 64 (#6) the tuning card covers the installed player until that first `.playing` (the player stays underneath so it loads; since 65 it is disabled meanwhile and the card's Cancel holds focus and Menu, #132, and the player takes focus at the picture); a mid-play `waitingToPlayAtSpecifiedRate` shows a "Buffering…" pill after 1.5 s (`buffering`, `BufferingPill`); 20 s with no picture after install sends `start-timeout` and fails the start (Retry; a pause before the picture suspends that deadline, #131); a 35 s mid-play wait is a failure (`StallTimeout` media error) that goes to the recovery. A pause times nothing. Fixtures `player-starting` (installed, no picture) and `player-buffering`. Recovery clears the item without permanently ending the model; `stop()` is terminal. Guards coalesce failures and reject stale callbacks/repeated appearances. Late resolve sessions still get released. A1.2: `AppModel.previousChannel` remembers the channel `switchPlayback(to:)` last switched away from; `returnToPreviousChannel()` swaps back to it. Exposed in the tvOS info overlay's action row as "Last channel" (hidden when there is none, or it equals the current channel); no remote shortcut — a long-press-Select alternative was considered and rejected as too fragile against the Button's own Select handling (see the comment in `CustomPlayer.swift`). |
| `RecordingPlayback.swift`, `RecordingPlayer.swift` | Recording preparation/playback and skip/resume (tvOS custom recording player; iOS AVKit). Startup Task is retained/cancelled, checked after suspension points, and awaited before audio teardown. Generation checks reject stale callbacks after retry. **C-L (build 44):** `RecordingPlayerModel(fromStart:)` asks `recordings/{id}/watch` (polls its 202), plays the live master from the beginning with no resume question and the display mode from the answer (never awaited from the asset); when the live playlist fails or goes away it asks again and carries on in the finished file at the same position (≤ 3 times, then Retry). `handleLiveStreamEnded()` is the test seam. |
| `GuideGrid*.swift` (A2.1) | UIKit guide grid, the only grid (tvOS since build 27; iPad since build 29, unlocked for touch). Keep navigation rules in `GuideGridMath` (unit-tested); horizontal offset changes only through `GuideGridCollectionView.setX` / the grid's animator. |
| `BrowseModel.swift`, `GuideView.swift`, `ChannelArtwork.swift` | Guide/cache/artwork; avoid cross-row scroll feedback (previous rendering instability) and full guide reloads while navigating forward — the loaded window now **extends** in the background (`extendGuideForward`, build 33) instead. Preserve lightweight logo fetching. A1.1: guide paging is cursor-based (`limit=500`+`cursor`); pages merge into `guide` via a persistent id set, not a per-page rebuild. `refreshGuideIfStale` and the cached-guide launch path fetch `GET /api/library/guide/version` and skip the full reload when it matches the version saved with the guide (captured before that load started) and the loaded window still covers the next 12 hours (`GuideNavigation.guideStillCovers`, a pure function). |
| `DVRModels.swift`, `RecordingsView.swift`, `ScheduledPage.swift`, `RecordingView.swift`, `RecordingsHome.swift` | Recording states/actions and guide schedule identity; preserve milliseconds versus seconds. Build 45: `RecordingRule`/`RuleBody`, `RuleChoices.sport` (league + both sides of "A v B", pure), the rules (since Apple 120 inline on Scheduled), and `image` artwork filling recording art (channel logo as fallback). "Watch from start" (44) is on the recording's page and the programme page while it records; "Record series" on the programme page and "Record every game" on a Sport event (45). Build 68 (server 0324, #12): a scheduled row shows `conflictsWith` as "Clashes with … : one will wait or be missed" (`ScheduledRecording.clashText`), Record's message says the clash at once (the player's Record too, `BrowseModel.scheduleClash`, build 69, #148), and a wait for the recording slot reads "Waiting — another recording has the slot". |
| `PigTVTests/ContractChecks.swift`, `Tools/test-contracts.sh` | Synthetic contract fixtures and local runner. Targeted simulator lifecycle tests live in `PigTVTests/PlaybackLifecycleTests.swift`; the standalone runner covers API/model fixtures. The scheme sets `PIGTV_SYNTHETIC_TESTS=1` so the test host cannot restore a saved real-server session. |

C2 recovery uses actual playing evidence, allows one automatic attempt per user-initiated playback attempt, and coalesces failure callbacks. A second failure or failed resolve requires Retry; a 409 still requires explicit takeover. Mark confirmed return-to-guide behaviour on 21 September: background cleanup ends playback; foreground return must not automatically resume or reconnect the last channel. Automatic recovery applies only while the player remains active. A stream idle ≥60 seconds can be reclaimed on demand; the idle sweep is five minutes. Confirm AVPlayer paused-fetch behaviour on a real device.

C3: `APIClient.requestURL` rejects `?` in paths; use structured query items. A terminal 500 must stop polling because another request starts a new transcode attempt. Continue using the recording list's duration for resume bounds; playback `durationSec` is wall-clock length.

## Crash lessons

**Crash on channel start (builds 21–23), fixed in builds 24–25.** The real cause, from the device console (Mark, test 1.9):
`-[AVPlayerItem setExternalMetadata:]: unrecognized selector`. `externalMetadata` is an AVKit category on AVPlayerItem.
Once build 21 retired the last AVKit player on tvOS, AVKit was no longer loaded, and setting it crashed the moment a
channel started. `PlaybackModel.setExternalMetadata` now sets it only when the selector exists, and a test reproduces the
crash on the old code. Build 25 also **links AVKit explicitly for tvOS** (`OTHER_LDFLAGS[sdk=appletv*] = -framework AVKit`): `UIWindow.avDisplayManager` (HDR/50 Hz switching) is an AVKit category too and would have crashed next. `testAVKitCategoriesAreAvailableOnTV` guards both. **Lesson:** never call AVKit-only API on tvOS without checking it exists; the simulator tests
missed this because no test started a real player item.

Build 23 also moved the app target back to Swift 5 on a wrong diagnosis (the KVO-isolation theory). **Build 28 returned to
Swift 6** (Mark approved) with every KVO/AVFoundation callback explicitly `@Sendable`/nonisolated (see §2 Swift 6) and the
real-playback harness exercising them. Verified on the TV (R2.15: no crashes across live channels, switching, Last channel and
a recording).

## Known limitations

- The artwork disk cap (50 MB) is kept during use: every write, replacement and prune removal runs alone under
  `ArtworkBudget` and is counted with what it did (53), so the count is the folder's size. A prune pass repeats while
  over the cap if it removed something or a write added bytes during it (54); one that removed nothing with nothing
  written stops, so undeletable files never loop. The folder is listed once per pass, never per image. What a change
  counts is the file's size read from the file system then, never a listed URL's prefetched `fileSizeKey` (55).
- Top Shelf files (snapshot, cards, clear) change only on `TopShelfPublication`'s serial queue. Saves and cards run
  under the session's generation (48); the sign-out clear is put on the queue before `clear()` returns (52), because the
  next session shares the generation the clear leaves: queue order, not a generation check, keeps the clear off what that
  session publishes.

- **W6: stacked full-screen covers can strand tvOS focus** (Mark, 28 Sept, screen never named). A `fullScreenCover`/
  `detailCover` presented from inside another sometimes needs Back before anything is focusable: a SwiftUI/tvOS focus-engine
  quirk. Prefer an in-page choice (`confirmationDialog`, or the page switching its own state) over another cover layer.
- **Top Shelf cards are only as fresh as the app's last refresh**: the app renders them (5 % progress steps) and the extension
  never uses the network.
- **Channel health** depends on `play-end` for plays of 10 s or more; a killed app sends nothing, so stalls are under-counted.
- Provider behaviour the client can't fix (server `docs/PRODUCT.md` › Known limitations): some channels are cut ~38 s in and ~19 s resent (a short
  repeat); a channel may still fail during an outage after the server's retries and this client's three recoveries in 10 minutes.
- `docs/evidence` screenshots use offline fixture data, not the real feed.
- A0.2 (a SwiftUI "Environment accessed outside a View" warning seen only in an accessibility-heavy UI test) is parked.

Never checked on a device: [#101](https://github.com/maroge1990/PigTV/issues/101) (track selection, AVPlayer while paused)
and [#31](https://github.com/maroge1990/PigTV/issues/31) (an HEVC recording).
