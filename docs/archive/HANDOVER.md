# PigTV Apple app handover

## Location and delivery

The implementation is in this working project, `work/PigTV-Apple`, under the Codex workspace. The user's original OneDrive project remains unchanged: direct write access still failed in this running task after the access-setting change. The working copy has been opened in Xcode. No native files have been published to GitHub and no backend files were changed.

The initial delegated draft was reviewed and corrected directly after the user requested that delegation stop. The current code is the directly revised implementation.

## What changed and why

- Added tvOS support to the existing app/test project, while retaining iPhone/iPad support, bundle identity and development team. A shared scheme makes the intended targets reproducible.
- Added origin-only server setup, `/api/info` compatibility checks, password login, and cancellable/expiring device pairing. Pair approval does not return a user, so `/api/auth/me` completes sign-in.
- Added Keychain storage scoped to normalized server origins with write-error handling. Passwords are cleared after login. API redirects are refused and only approved same-server media paths receive playback tokens.
- Added source-qualified channel/category identities, real now/next programme data, progress bars, paging and safe search encoding. Request generations stop stale results overwriting a newer search.
- Added native AVKit playback and session cleanup on dismissal/background, including a resolve that finishes after the viewer has cancelled. The server keeps responsibility for preparing streams.
- Corrected the initial fixed HEVC=false assumption. Native AVFoundation capability checks now report HEVC and surround-codec support so supported video need not be unnecessarily re-encoded.
- Added actionable handling for the known server startup-timeout response, without echoing arbitrary upstream errors or credential-bearing URLs.
- Integrated the deployed recording conflict contract: poll while watching, ask once per schedule, post a decline when continuing, and stop playback when the user agrees. HTTP 409 when starting playback requires explicit confirmation before force=true is sent. This is polling-based foreground UI, not push notifications.
- Added provisional pink accents and native light/dark surfaces. Full branding, artwork and final layout polish are pending.

## Evidence

The user confirmed successful pairing. Read-only server inspection reports version 3.5.0 at `http://192.168.1.235:3000`; the conflict endpoint exists and returned null. GitHub main was already 3.6.0 with additional recording/ad-detection work, so deployment differs from latest source.

Forty synthetic contract checks pass (`sh Tools/test-contracts.sh`). App sources type-check for tvOS and iOS 26.5. Full tvOS and iOS simulator builds succeeded through Xcode before the latest capability/conflict patch, with zero errors/warnings recorded. The final capability/conflict patch has compiler and contract-test validation; its full GUI rebuild needs confirmation because Xcode automation became unresponsive. Do not describe the final patch as end-to-end tested.

No live stream was started by the agent. The user's playback attempt failed on the server while waiting for its initial playlist. There is not yet a successful real-playback result, and live recording conflict decisions have not been exercised.

## Next manual check

1. Open this working copy's `PigTV.xcodeproj`, not the unchanged OneDrive starter. Choose PigTV and the intended Apple TV/iPad/iPhone simulator, then Build/Run. The OS targets remain 26.5 for now.
2. The existing paired token should remain in that simulator's Keychain for this bundle/server. If needed, pair again through browser Settings → Devices.
3. With web playback stopped and no recording active, try the same channel once. Check whether the server now copies supported video rather than re-encoding. If it still times out, use the server findings document; do not disable stream authentication as a workaround.
4. After server startup/cleanup issues are addressed, test a short scheduled recording: keep watching once, stop playback later, and confirm the partial recording starts. During a recording, attempt live playback, first keep the recording, then explicitly test takeover on a disposable test recording.
5. Review remote focus, cancellation, light/dark appearance and touch navigation. Ad skipping/recording playback UI remains a later milestone.

The separate `PigTV-server-playback-findings.md` in the output folder gives exact server code references for readiness, cleanup and media-token issues, and can be handed to the server agent.


## Follow-up: remux disconnect diagnostics
Native failure screens now include sanitized strategy and Apple error codes. This is not a confirmed playback fix. See outputs/PigTV-native-remux-handover.md for the proposed server HLS delivery change.


## Simulator follow-up
Fixed RecordingConflict isolation for error equality by explicitly declaring this immutable value nonisolated and Sendable. Swift 6 strict-concurrency simulator typechecks pass for tvOS and iOS with warnings as errors; all 40 contract checks pass. Playback error -11850 points to HTTP server configuration; native HLS server work is still outstanding.


## Live browser UI milestone
Replaced the initial channel list with adaptive channel cards, a category sidebar, current-time display, search, refresh and pagination. Cards use native tvOS card buttons and a responsive iOS grid. Selecting a channel opens programme details; Watch live closes the sheet before presenting the player, avoiding competing presentations. Browsing never starts a provider stream.

Added On now and Up next details with times and progress. Current programme display checks timestamps, promoting the supplied next programme when applicable and showing unavailable metadata after expiry. This is not a complete timeline guide or automatic EPG refresh.

Added settings with System/Light/Dark appearance saved locally and account sign-out confirmation. Pink remains provisional pending logo and palette. Channel symbols are intentional placeholders; no invented artwork or recommendations.

Validation: both tvOS and iOS simulator Swift 6 strict-concurrency typechecks pass with warnings as errors; 40 existing API/model checks pass. Actual rendered layout, remote focus traversal and sheet-to-player transition still need simulator/device testing. No live provider stream or backend changes were made.

Next milestones: full guide API integration and timeline, recordings library and server-supported ad-skip controls, branded assets, and physical-device interaction/accessibility validation. Native playback remains blocked on coordinated server HLS delivery.


## Large client build — 15 September 2026

This section supersedes earlier statements that guide, favourites and recordings browsing are absent, or that segmented delivery has not been requested.

### Implemented
- Native tabs for Live TV, Guide, Favourites and Recordings.
- Three-hour EPG timeline, half-hour headings, current-time line, previous/next windows, category selection and channel pagination. Source-qualified IDs and request generations prevent mixed-source identity collisions and stale guide responses.
- Programme details with descriptions and times. Current programmes can open the live player; future/current programmes can be scheduled with explicit pre/post padding and confirmation. Past programmes cannot be scheduled or played as catch-up.
- Account-backed favourites using the verified favorites/check and POST/DELETE favorites contracts.
- Recording library/search, upcoming schedules, status/partial-recording metadata, cancellation/stop and deletion confirmations. Cancellation decodes the returned scheduled-recording object rather than assuming a success wrapper; an active returned status is not reported as successful cancellation.
- Commercial-break metadata and explicit analysis requests. Malformed intervals are omitted. No automatic skipping is claimed because native recording playback is not yet integrated.
- Full-screen details with opaque light/dark presentation backgrounds. Native tvOS button focus retained with explicit contrasting labels. Category choice uses a separate list rather than squeezing a large segmented picker into the toolbar.
- Existing light/dark/system setting retained.

### Server handover review
Read the user-supplied PigTV-Swift-client-handover.md covering deployed patches 0034–0039.
PlaybackCapabilities now always sends capabilities.segmentedDelivery=true. HEVC/AC3/EAC3 capability detection is unchanged. Existing token query attachment for the top-level media URL and bearer-authenticated cleanup already meet the described client requirements. Existing decision decoding accepts stream-copy sessions labelled strategy=transcode/container=hls, including extra videoMode/audioMode fields.

GitHub connector reads still return main commit 1bad94fb3a8385efab8bd169e5964d43554b0684, which lacks these patches. Deployment is reported by the supplied handover, not independently verified against server source. No server code or configuration was changed.

The handover concerns live playback only. The inspected recording endpoint serves video/x-matroska; no native recording-resolve API was provided. Recording details therefore clearly direct users to web playback until an Apple-compatible recorded-media endpoint is agreed. Do not expose a broken native Play button or construct FFmpeg/provider URLs in the client.

### Verification
- 63 synthetic API/model checks pass, including guide identity and clipping, EPG time boundaries, optional recording fields, marker validation, scheduling payload units, favourites deletion, schedule-cancellation response, segmentedDelivery payload, token on HLS URL and bearer cleanup.
- Swift 6 strict-concurrency typechecks with warnings treated as errors pass for tvOS and iOS simulator targets.
- Full tvOS GUI build succeeded in Xcode; the new app launched with the saved pairing and loaded real channels, guide rows, favourites empty state and recording library.
- Visual/remote checks covered tabs, live-channel details, guide timeline and readable actions. Detected and corrected pink-label contrast, narrow detail sheet and transparency issues.
- No provider playback, test recording, deletion, favourite mutation or server-setting change was performed. Actual HLS media playback and mutations remain user testing items.
- iOS/iPad layout and physical Apple TV have not been visually validated in this build.

### Remaining server integration questions
- Confirm patches 0034–0039 are reflected in the running container and eventually GitHub.
- Add/document native recorded-media resolve with authenticated HLS or a compatible seekable MP4, lifecycle and seeking semantics; markers are already available in milliseconds.
- Older inspected server listUpcoming excludes waiting schedules, and cancelScheduled does not cancel waiting status. If not covered by the current server patches, include waiting in listing/cancellation; the client already understands waiting.
- Continue enforcing one provider stream on the server; the app never resolves merely from focus/browsing.

### Files
New DVRModels.swift, BrowseModel.swift, GuideView.swift, RecordingsView.swift, FavouritesView.swift, TVActionStyle.swift; updated AppModel, LibraryView, ContentView, PlaybackCapabilities, contract fixtures/test runner. Working copy only, not published to GitHub and not copied over the original OneDrive starter.


## Authoritative status update — 15 September 2026, after user playback testing

The user reports that server updates are complete and all video playback is now confirmed working. The historical -12642/-11850 debugging work is closed. Earlier statements that playback is blocked or needs error diagnosis are superseded. Preserve the working media pipeline.

The next phase is continued app development for everyday usage, with usability as the priority. The user finds the current UI too large, with excessive scrolling across hundreds of channels. Reduce unnecessary spacing/card size and improve navigation while retaining sofa-distance legibility and native tvOS focus behavior. Expand the current three-hour EPG view for 55/65-inch TV usage; evaluate a six-hour default and adjustable time span/density rather than simply shrinking text. Integrate the real channel images already supplied by server/EPG data (logo fields are decoded but currently unused), with caching, bounded requests and graceful fallbacks. Preserve fluorescent pink branding and light/dark support.

See outputs/PigTV-next-chat.md for the compact continuation brief. Recording playback contracts described earlier may also have changed; inspect current capabilities before assuming an old limitation persists. The user's broad video-playback confirmation is the latest authoritative testing status.


# PigTV usability update — 15 September 2026

## Implemented
- Denser Live TV and Favourites cards with smaller padding and spacing.
- Channel logos in Live TV, Favourites, channel details and Guide rows, with aspect-fit sizing and a TV fallback.
- Per-client 16 MB memory artwork cache, 200-entry ceiling, 2 MB download limit, 256-pixel decoded thumbnails, timeouts and four connections per host. Only HTTP(S), no embedded credentials, no redirects; bearer authentication only on the configured server origin. Unsupported images, including unsupported SVGs, use fallback icons.
- Six-hour Guide default; selectable 3/6/12 hours. Earlier/Later advance by the selected span; Now remains available. Hour labels and programme positions scale with the chosen span. Guide rows reduced from 110 to 86 points.
- Watch live moved above programme information in channel details.

## Verification
- 68 synthetic API/model contract checks passed, including five new artwork URL/authentication checks.
- tvOS simulator and iOS simulator Xcode builds succeeded.
- Signed tvOS app launched using saved sign-in. Real-data Live TV screenshot inspected: five cards across, logos and fallbacks rendered.
- Initial unsigned simulator build could not access Keychain. Rebuilding with normal simulator signing restored saved sign-in without source changes.
- Server reachable; unauthenticated guide request returns 401. Available server source documents a 24-hour guide cap, but the deployed guide response and logo URL contracts were not independently inspected. Real logo rendering was observed through the authenticated app.

## Physical-TV checks
1. Browse several pages from the sofa; assess channel-name legibility and focused-card spacing.
2. Open details, watch, then return; check focus and scroll position.
3. Test Guide at 3, 6 and 12 hours, Earlier/Later and Now, including short programmes and long titles.
4. Check light and dark appearance; missing, transparent and white logos; fast scrolling.
5. Search and change categories; confirm later pages and favourites remain easy to reach.
6. Verify iPad/iPhone layout and text scaling.

## Remaining usability work
Guide remote navigation, light/dark layouts and iPad/iPhone visuals were not inspected in this pass: the UI-control tool cannot access Simulator. Automatic pagination, explicit focus restoration, source filtering and date/time jump controls remain future work. Manual Load More remains. Guide span is session-only. Playback resolution, capability negotiation, stream authentication, cleanup and recording-conflict handling are unchanged.

## Working source
/Users/markrogers/Documents/Codex/2026-09-13/i-ve/work/PigTV-Apple

The accompanying archive contains updated source, not a signed device build. Open PigTV.xcodeproj to build/install. This working copy is not a Git checkout.


# PigTV guide-first build — 15 September 2026

## Changes
- Main navigation is TV Guide, Recordings, Settings. TV Guide is the initial screen.
- Ninety-minute viewport with a pinned time header and channel column. Programme widths follow their durations; programme cells do not repeat start/end times.
- tvOS directional navigation selects adjacent programmes, shifts the time viewport to reveal offscreen programmes, and uses a time anchor when moving between channels.
- Earlier/Later move thirty minutes; Now and Jump to day/time are available. The server request covers twenty-four hours, separate from the ninety-minute viewport.
- All, Favourites, category filters, More and channel-name search live within the guide. Filter and last channel are saved. Channel pages load automatically; filtering/searching continues through pages as needed. Search is over loaded channel names, with further pages fetched as the filtered list reaches its end.
- Selecting a live programme or channel starts playback. Selecting a future programme opens the existing programme/recording screen. Missing guide information does not block channel playback.
- Options and context menus provide programme details, recording actions and channel/favourite controls. Focus is retained for return from details/playback.
- Fixed-size cells use a focus outline without enlarging the grid. The guide uses a solid background and subdued filter controls, respecting light/dark appearance.
- Supplied pig logo included unchanged as an asset and displayed in the guide header and sign-in screen. This is in-app branding; the home-screen app icon has not been redesigned.

## Verification
- 74 synthetic contract checks passed, including ninety-minute viewport boundaries, unequal programme lengths and gaps, plus the existing media/authentication checks.
- Final tvOS and iOS simulator builds succeeded. The only final build warnings were skipped App Intents metadata extraction, because the app does not use that framework.
- Final signed tvOS build launched on the available tvOS 27 Apple TV simulator; saved sign-in and real server guide data worked. The final dark guide screenshot was visually inspected and is included separately.
- The previous tvOS simulator identifier no longer exists. The active simulator is 46A0FD09-3E3E-41BF-B249-6CC94EEA2FF5.
- Device Hub UI control timed out, so physical remote navigation, focus return, light-mode visuals and iPhone/iPad visuals still require hands-on validation. The directional model checks are not a substitute for a remote interaction test.

## Test on your Apple TV
1. Open TV Guide; confirm category selection and logo appearance.
2. Move right across successive programmes until the time axis advances. Move left again.
3. While browsing future programmes, move up/down across different programme lengths; check the selected time stays consistent.
4. Select an on-air programme, then return from playback. Check channel, filter and position.
5. Open Options for programme details/recording and channel favourites; verify returning keeps position.
6. Select Favourites, search channel names, and browse beyond the first page.
7. Try Now, Earlier/Later, Jump to a future day/hour, missing EPG and long programme titles.
8. Check light appearance and legibility from your usual seat.

## Limits and preserved behaviour
Playback resolution, codec capabilities, stream authentication, single-stream handling and recording-conflict logic were not changed. No recording was created or deleted for testing. No quick guide over playback, programme search, channel reordering or scheduled-recording badges were added in this build. The supplied logo is not converted into platform app-icon artwork.

## Working project
/Users/markrogers/Documents/Codex/2026-09-13/i-ve/work/PigTV-Apple/PigTV.xcodeproj

Open this existing project to build for your device. The archive contains source and assets, not a signed distributable. No Git publication was performed.


# PigTV guide adjustments — 15 September 2026

## Included in this build
- Wider channel column: 340 points on large screens (previously 250); 150 on narrow screens.
- Smaller guide-only typography: 24-point TV programme/channel/filter text, 20-point secondary text and 34-point heading. Other sections keep their existing type sizes.
- Programme description and Options moved between category strip and guide.
- Every category included in one horizontally scrolling row, preserving server order. All and Favourites lead the strip. Search has a dedicated header button.
- Guide now uses the same native backdrop as Recordings and Settings; the custom purple guide background is removed.
- Each row contains the full loaded day in a native horizontal scroll view, with ninety minutes visible. Moving into later programme buttons can scroll beyond the original block. The active row synchronizes the time header and other rows; channel names remain fixed. Earlier/Later and Jump to remain available.
- Half-hour labels stay aligned to the timeline during scrolling. Long programme titles remain positioned in the visible part of their box.
- Right-edge collision fix: programme boxes entering from the right stay blank until their trailing edge is visible. A programme longer than the viewport may show text once its start is at or before the left edge. Explicit clipping prevents painting beyond the table boundary. Buttons remain focusable, with their accessible titles intact.
- Error state no longer also claims there are no matching channels.

## Validation
Both final Xcode simulator builds (tvOS and iOS) succeeded. 81 synthetic contract checks passed, including five-hour scroll synchronization, clamping and five right-edge title visibility cases.

The final programme-cell and remote interaction checks remain unverified: Device Hub UI control timed out, and the latest simulator screenshot showed server request timeouts. The header, all-category strip, description placement and native background were visible. Do not interpret the unit checks as an end-to-end remote test. The earlier screenshot in outputs is from the previous build, not this adjustment.

## Quick check
1. Move right across several programme boundaries; confirm the axis and all rows move together.
2. Find a programme starting close to the right edge. Its box should be blank until scrolling reveals its end. Confirm neighbouring text stays within its cell.
3. Move along the category strip to categories previously hidden under More.
4. Check long channel names, programme description placement and readability from your seat.
5. Return from playback and details; confirm position. Check all three section backgrounds.

Playback/media handling is unchanged. The supplied logo remains included. The archive contains the existing Xcode project and source, not a signed device distribution.

Working project: /Users/markrogers/Documents/Codex/2026-09-13/i-ve/work/PigTV-Apple/PigTV.xcodeproj

## Token question
For these concrete changes, direct project editing is likely more economical overall because an image mockup would add a step before implementation. This is a workflow estimate, not a measured token comparison. OpenAI documents separate image-token usage for image generation: https://developers.openai.com/api/docs/models/gpt-image-1.5


## Stability and guide rebuild — 16 September 2026 (Claude, Cowork)

Starting point: the previous agent's `work/stability.py` had been applied to this
working copy at 09:29 on 15 Sept but never compiled or run. This pass reviewed
that patch, kept the useful parts (off-main JSON decoding, artwork redirect
handling, EPG icon index, local category filtering) and rebuilt the guide grid.

### Root-cause analysis of the reported problems
- **Simulator SpringBoard crashes.** Every guide row was a horizontal
  `ScrollView` containing the full loaded day (24 h ÷ 90 min ≈ 16 screen widths
  of `Color` + ~50 focusable buttons + context menus per row), all rows kept in
  sync by writing `viewport` from `onScrollGeometryChange` and calling
  `scrollTo` on every other row. That produces enormous compositing layers and a
  feedback loop between rows; both are classic render-server killers. The grid
  now draws only programmes that overlap the visible two-hour window, so a row is
  never wider than its frame and there is no cross-row scroll synchronisation.
- **"EPG only loads what is visible".** Data was in fact requested for 24 h, but
  the "right-edge collision fix" deliberately left every programme box blank
  until its trailing edge scrolled fully into view, so most of the grid to the
  right looked empty. That blanking is removed: titles are always drawn, and a
  programme that starts before the left edge keeps its title at the left edge.
- **Missing channel images.** `library/guide` rows only carry the playlist
  `logo`. The web guide falls back to the EPG channel `icon`; the client now does
  the same via `/api/sources` + `/api/proxy/epg/{id}` (index by EPG id, then by
  normalised name, e.g. "Sky News HD" ⇢ "sky news"). A server-side fallback is
  still recommended — see "Server requests" below.

### Changes (files: GuideView, DVRModels, BrowseModel, ChannelArtwork, LibraryView, FavouritesView, ContractChecks)
- Two-hour viewport, four half-hour columns, current-time line, viewport
  snapped to half hours. `Earlier`/`Later` move 30 minutes; `Now` and `Jump to…`
  unchanged. On iPad/iPhone a horizontal swipe over the grid moves one hour.
- Remote navigation (tvOS): left/right move between programmes of the focused
  channel; when the next programme is off screen the viewport advances by
  whole columns so its start lands in the last column, moving left puts the
  earlier programme in the first column. Up/down keep the same time anchor.
  Up from the top row hands focus to the selected filter chip so the header
  controls remain reachable.
- Data: a 24-hour window starting two hours before the viewport is loaded in
  50-channel pages; after the first page the remainder keeps loading in the
  background (the "N of M channels" indicator next to Options). Filters,
  favourites and search then work entirely locally, and moving through the day
  never waits on the network. A reload happens only when the viewport leaves
  the loaded day.
- Filtered rows are cached in view state instead of being recomputed in `body`
  on every focus change/clock tick.
- Logo decoding (`CGImageSource` thumbnail) moved off the main thread; decoded
  thumbnails are cached so recycled lazy rows do not decode again.
- Category filtering compares the guide row's `category` against both the
  category ID and its name, source-qualified.
- Contract checks updated: two-hour window, visible-programme selection, reveal
  logic, reload boundaries, category matching and EPG icon matching (the old
  90-minute scroll-offset checks were removed with the code they covered).

### Not verified in this pass
This session had no Xcode access (the connected shell is a Linux VM and
computer use was off), so the files were syntax-checked only. **Build in Xcode
before testing** — see the steps below. If the build fails, paste the first
error into the chat; the likely spots are `#if os(iOS)` in the modifier chain
of `GuideView` and strict-concurrency warnings around `ChannelArtwork`.

### Build and test
1. Open `/Users/markrogers/Documents/Codex/2026-09-13/i-ve/work/PigTV-Apple/PigTV.xcodeproj`.
2. Product ▸ Clean Build Folder, then build the PigTV scheme for the Apple TV
   simulator and once for an iPad simulator.
3. Optional: `sh Tools/test-contracts.sh` from the project folder runs the
   synthetic contract checks (no server needed).
4. On the Apple TV simulator: open TV Guide, wait for "N of M channels" to
   disappear, then hold right on the remote across at least six programmes.
   The axis should advance in 30-minute steps and every box should have a
   title. Press up from the top row: focus should land on the selected filter
   chip. Move down through channels: the selected time should stay put.
5. Check logos: count rows with the grey TV placeholder before and after the
   index loads (a few seconds after launch). Any that remain blank have no
   playlist logo and no EPG icon matching by ID or name — tell me the channel
   names and I will look at the matching.
6. Watch memory in Xcode's Debug navigator while scrolling the guide; it should
   stay flat after the background load finishes.

### Server requests (optional, would remove the client-side EPG download)
1. `GET /api/library/guide` and `/api/library/channels`: when a channel has no
   `tvg-logo`, populate `logo` from the matched EPG channel's `icon` (same
   matching the web guide uses: tvg-id, then name). Also include `tvgId` on each
   row so the client can match by ID without a name heuristic.
2. Confirm the `category` value returned on guide rows: the client accepts
   either the category ID or its display name.

### Compact channel column — 16 September 2026 (follow-up)
Modelled on the iPad guide screenshot Mark supplied: the channel column is now a
logo tile (176 pt on TV/iPad, 96 pt on iPhone) with no channel name beside it.
The channel name appears as a small caption on the top line of the first
visible programme cell, next to the start time; when a channel has no artwork
the name is drawn inside the tile instead. Programme cells are rounded cards
with a 4 pt gap, start time on the first line and title below.

### Round two after Mark's simulator test — 16 September 2026
- **Double jump fixed.** `onMoveCommand` and the native focus engine were both
  moving the selection. The handler now acts only when the next programme is
  not drawn (shifts the viewport and focuses the revealed box); otherwise the
  focus engine does the work. Up/down are entirely native again, with the
  time-anchor re-targeting kept in `onChange(of: focus)`.
- **Left bound at the live programme.** Finished programmes are drawn dimmed
  and disabled, so neither the remote nor my handler can land on them.
  Earlier/Later still let you browse the past deliberately.
- **Logos.** No container any more; the logo fills the tile (176 pt on TV and
  iPad). Each decoded logo is analysed (mean luminance of opaque pixels,
  share of transparent pixels). A plain white backing appears behind a dark
  transparent mark in dark mode and a plain black one behind a light mark in
  light mode; everything else sits directly on the row. Channel name stays a
  small caption on the first cell, or inside the tile when no artwork exists.
- **AVAudioSession warnings.** Category/activation and deactivation moved off
  the main thread into detached tasks in `PlaybackModel`.
- **iPhone.** One-hour viewport (two columns), 84 pt tile, category menu
  instead of the chip strip, and tapping a tile opens the channel's programme
  list. Swipe left/right moves half a viewport.
- **Channel programme list** (`ChannelScheduleView`): every programme on a
  channel from now on, with Watch live at the top; selecting one opens the
  existing programme sheet for recording. On TV/iPad it is reached from
  Options ("All programmes on …") or a long press on the tile; on iPhone from
  a tap on the tile.
- **Category strip** is clipped to the guide's width with a 36 pt fade at
  each edge.
- **Light appearance**: the selected filter chip inverts primary/background
  instead of assuming white-on-dark; cells, tiles and backings already derive
  from `Color.primary` and the colour scheme. Switch Settings ▸ Appearance ▸
  Light and report anything that still looks wrong.

## Five-phase build — 16 September 2026 (Claude, Cowork)

### Phase 1 — player surface (tvOS + iOS)
- `PlayerHost` keeps the full-screen player presented while the channel
  changes underneath it; `AppModel.switchPlayback(to:)` releases the previous
  provider stream first (the new `PlaybackModel.prerequisite`) then resolves.
- tvOS: swipe down for two panels — **Info** (now/next with progress and
  description) and **Channels** (the guide's row order at the time playback
  started; select to switch). The transport bar has a **Channel** menu with
  Next/Previous channel and "Back to <last channel>".
- iOS: top overlay with close, channel name, previous/next and a Channels
  sheet.
- `AVPlayerItem.externalMetadata` carries channel/programme title, so the
  system player UI and Now Playing show them.

### Phase 3 — guide polish
- Red record dot on programme cells with an active schedule (matched by
  channel name + programme start); red dot on the tile while a channel is
  recording. Schedules load with the guide and refresh every 15 minutes.
- Search sheet now has a **Programmes** section: title search across every
  loaded channel, upcoming only, selecting a hit opens the programme sheet.
- The viewport is remembered between launches (`pigtv.guide.viewport`) when
  it is still in the future-ish range; last channel was already remembered.

### Phase 4 — resilience
- A complete guide load is written to `Caches/pigtv-guide.json`; on launch
  the cached day is shown immediately (if <12 h old and still covering the
  next 4 h) while a fresh load replaces it in place — `loadGuide(reset:
  keepVisible:)` keeps the old rows until the first new page arrives.
- `refreshGuideIfStale()` re-centres and reloads the day every 15 minutes
  when it is more than 4 hours old.
- `UnreachableView`: when a saved sign-in exists but the server cannot be
  reached (URLError), a dedicated screen explains (asleep / wrong network /
  Tailscale) and retries every 20 s, with "Use a different server".

### Phase 2 — recording playback (client side; server work needed)
- `RecordingPlayerScreen` / `RecordingPlayerModel`: native player with resume
  (position saved every 5 s in UserDefaults), commercial-break detection
  from `/recordings/{id}/markers`, a **Skip break** contextual action on
  tvOS (iOS: overlay button) and an **Auto-skip breaks** toggle in the
  transport menu. "Play recording" appears in recording details for
  completed recordings.
- **Server contract required:** `GET /api/recordings/{id}/playback` →
  `{ "url": "/api/recordings/{id}/hls/index.m3u8", "container": "hls",
  "durationSec": 3600 }`. The URL must be under `/api/recordings/` and accept
  the bearer token as `?token=` like the live endpoints (the client appends
  it). HLS (fMP4 or TS segments, H.264/HEVC + AAC/AC-3) is preferred; a
  progressive MP4 with `Accept-Ranges` also works for seeking. Until the
  endpoint exists the client receives 404 and shows "not available on this
  server yet".

### Phase 5 — branding
- iOS `AppIcon` (light / dark / tinted 1024²) and a tvOS
  `App Icon & Top Shelf Image.brandassets` (layered icon: dark back, soft
  pink disc, pig front; top shelf 1920×720 and wide 2320×720) generated from
  `PigLogo.png`; `ASSETCATALOG_COMPILER_APPICON_NAME[sdk=appletv*]` now
  points at it. Replace the PNGs if you want a hand-drawn version — the
  catalog structure is what matters.
- Now Playing is populated by AVPlayerViewController from the item metadata
  above; nothing else needed.

### Build status
tvOS (Apple TV 4K simulator) built and launched after Phase 1. Phases 2–5
were built together at the end of the session — see the chat for the result
and any follow-ups.

### Follow-up after device testing — 16 September 2026 (evening)
- Logos: mixed marks (dark badge + white lettering, e.g. Fox League "502 HD")
  were losing one half on a black or white backing. Analysis now records the
  share of light and dark opaque pixels; when both exceed 12 % the tile gets a
  neutral mid-grey backing, otherwise the single-tone rule applies as before.
- Player (tvOS): the swipe-down panel is now "Now & Next" (AVKit adds its own
  "Info" tab from the item metadata, which is why two appeared) and shows the
  current programme with description plus the next three. A "Go to live"
  contextual action appears when playback is more than 20 s behind the live
  edge after a pause or rewind. Note: the tvOS simulator's on-screen remote
  cannot focus the info-panel tabs reliably; test on the physical Apple TV.
- iPhone: icon-only header controls (Earlier/Later/Search/Jump) in one row,
  the description block hidden, "Now" icon-only and the category menu on one
  line, so nothing wraps.
- Both destinations built clean (Apple TV 4K and iPhone 18 Pro simulators).
- Server: full review published to the PigTV project as
  `claude/server-review-2026-09-16.md` (P0: HLS segment retention filling
  docker.img, EPG batch loss, unauthenticated state-changing routes).
  Verified the recording playback contract the server now exposes matches the
  client (`/playback` bearer → `media.mp4?token=` with byte ranges).
