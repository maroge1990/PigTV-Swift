# PigTV Apple client — first milestone

Native SwiftUI and AVKit client for tvOS, iPad and iPhone. The shared PigTV scheme supports iOS and tvOS 26.5, matching the supplied starter project's OS generation. Final minimum OS/device support is still to be agreed. The existing development team and bundle identifier are preserved.

## Open and run

Open `PigTV.xcodeproj`, select the **PigTV** scheme and an **Apple TV** simulator destination, then choose Product → Run. Use an iPad/iPhone destination for touch layouts. Xcode may need to finish installing or starting a simulator. Physical devices need your development signing configuration.

This is a working copy prepared under the Codex workspace. The original OneDrive project has not been edited because this running task still cannot write there, even after the user changed access settings. To use these files in the original project, first review and copy the contents while preserving its `.git` and `xcuserdata`; do not replace the entire original folder. No native app changes have been published to GitHub.

Enter the PigTV server **origin**, e.g. `http://192.168.1.20:3000` or its HTTPS hostname. Paths such as `/pigtv`, URL credentials and query strings are explicitly rejected. The URL is editable; no real server or credentials are embedded. `GET /api/info` must advertise API version 1 with library and playbackResolve support.

Choose **Pair with browser**, then approve the displayed code in your existing PigTV web Settings → Devices, or use the username/password form. Pairing tokens are collected once, then `/api/auth/me` supplies the user identity. Pairing supports expiry and cancellation. Tokens are saved in Keychain scoped to the normalized server origin; only the server address is stored in preferences. Passwords are cleared after successful authentication and are not persisted. A failed Keychain write is reported.

## Included behavior

- Real channel names, now/next EPG and programme progress. Missing EPG is shown explicitly. No invented content, recommendation feed, artwork or extra provider metadata requests.
- Category buttons, submitted search, manual refresh and pagination. Composite source/channel identities prevent duplicate UI identifiers. Search uses structured query encoding; stale responses cannot append into a newer search.
- Native AVPlayerViewController controls, remote-selectable channel buttons and native adaptive navigation. System light/dark surfaces with provisional pink accents. Logo and store-ready icons remain pending.
- Server decides playback using `POST /api/playback/resolve`. The app accepts only same-origin media endpoints, adds the token without duplicating it, and never constructs a provider stream URL. API redirects are refused to keep account credentials on the chosen server.
- Stopping/dismissing/backgrounding pauses and clears the native player, then releases any returned server session. A pending resolve is allowed to finish so its returned session can also be released. Further selections are held until cleanup finishes. A failure to confirm release is reported.
- Native AVFoundation checks report HEVC (both common profiles) and AC-3/E-AC-3 support. HLS/fMP4 remain supported; AV1/FLAC stay conservative. No client transcoding library or server playback change is introduced.

## Validation

`sh Tools/test-contracts.sh` runs 40 synthetic model/API checks directly on the Mac without a simulator or server. It compiles a temporary test executable using Xcode's Swift toolchain. These checks passed. The same checks are included in the Xcode unit-test target; the starter UI-test targets are retained but not part of the shared scheme's test action.

All Swift app sources passed type-checking against both installed iOS and tvOS 26.5 SDKs with the project's MainActor default isolation. Full command-line builds were blocked at asset compilation by inaccessible CoreSimulator services in the task sandbox. Xcode GUI build status is recorded in `HANDOVER.md`; do not equate type-checking or contract tests with verified playback or device behavior.

## Integration limits to test next

The user confirmed pairing and supplied the server address. Read-only inspection reports server 3.5.0. The user encountered a playback startup timeout; successful real playback and cleanup remain unverified. Only one provider stream is allowed: stop web playback and ensure no recording is active before testing the native app.

- **Authenticated HLS:** current server code does not add tokens to nested segments/keys/playlists, for both transcode and proxied HLS. Adding a token to the initial playlist alone does not fix `requireStreamAuth=true`. Implement server-side media authorization in a separate reviewed change. This app does not disable that setting or use undocumented AVPlayer header options.
- **Stream formats:** direct, progressive fMP4 remux and HLS decisions all need native-device testing. Codec capability claims are deliberately conservative. The server remains responsible for compatibility, and the app's build does not prove every output works with AVPlayer.
- **Lease/cleanup:** the deployed server has a recording/viewer coordinator, but direct proxy streams are not included in its inspected viewer registry. Closing direct/remux playback relies on connection teardown because no session ID is returned. Abrupt termination, timeout before resolve returns, or a network loss can prevent explicit server cleanup. Confirm idle cleanup on the server before relying on immediate channel switching.
- **Categories:** the current backend filters a category ID across sources. The app additionally filters matching source IDs after receiving each page, so some source-specific pages can be empty while Load more remains available. A sourceId API filter is a later backend improvement.
- **Guide freshness:** refresh requests update programme titles. The progress bar updates locally every 30 seconds. Automatic now/next refresh is future work.
- **Transport:** `AppConfiguration.plist` permits arbitrary HTTP loads because the user selects a home server with an unknown IP/hostname. The API still limits authenticated requests to that selected origin and validates TLS normally for HTTPS. Prefer HTTPS for remote use; review ATS configuration before public distribution. Do not add certificate-trust bypasses.
- **Conflict prompts:** the app polls every five seconds while playing, posts a decline when the viewer keeps watching, releases playback if they agree, and requires explicit confirmation before force=true on a recording-in-progress 409. These are foreground prompts, not push notifications.
- **Scope:** recording scheduling, full guide grid, favourites, artwork, background audio, AirPlay, PiP and store submission are not included. External playback and PiP are disabled until session lifecycle supports them properly. The existing Windows web app and backend remain unchanged.


Latest build: Live TV, Guide, Favourites and Recordings management; native segmentedDelivery enabled. See TESTING.md and the latest section of HANDOVER.md. Recorded-media playback remains pending its server contract.
