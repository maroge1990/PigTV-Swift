# PigTV Apple client

Native SwiftUI and AVKit client for Apple TV, iPad and iPhone.

Start with [blueprint.md](blueprint.md): current implementation, planned work, decisions, verification evidence and developer transition instructions. [TESTING.md](TESTING.md) contains the regression checklist. Previous handovers are frozen in [docs/archive](docs/archive).

## Open and run

Open `PigTV.xcodeproj` from this repository and select the shared **PigTV** scheme. Choose an Apple TV destination for tvOS or an iPad/iPhone destination for iOS. The project currently targets iOS/tvOS 26.5; physical devices require the configured development signing. Final minimum OS support is not yet decided.

Use this Git checkout; the old OneDrive/Codex working-copy locations in archived notes are obsolete. Obtain Mark's approval before internet access, server integration testing, commits to main or publication.

## Current functionality

- TV Guide, Recordings and Settings navigation; category/favourites filters, programme search and cached guide data.
- Native live playback, channel switching, now/next metadata, Go to live and recording-conflict prompts.
- Recording scheduling/management, native recording playback, resume and commercial-break controls.
- Channel artwork, pig branding and System/Light/Dark appearance.

Implementation does not imply device verification. The blueprint distinguishes completed source work from outstanding tests and tracks integration with server changes through build 0086.

## Connect to a server

After server testing is approved, enter the server origin, such as `http://192.168.1.20:3000`, without a path, query or embedded credentials. Use password login or **Pair with browser** and approve the code in the server web app's Settings → Devices. Credentials are stored in Keychain for the selected origin.

The server must advertise API version 1, library and playbackResolve support. Stream preparation remains on the server; the client requests segmented delivery and uses AVPlayer. Build **1.0 (2)** adds viewer takeover confirmation, one automatic live recovery attempt, cancellable recording-preparation polling, server logo fallback, waiting explanations, auth rate-limit handling and optional diagnostics. Returning from the background still shows the guide.

## Local validation

```sh
sh Tools/test-contracts.sh
```

Runs synthetic model/API checks using the local Xcode Swift toolchain; no server or provider is contacted. On 21 September 2026 all **123** checks passed. Full simulator builds and all 11 XCTest tests also passed on tvOS 26.5 and iPadOS 26.5. Physical playback and remote interaction still need testing; see the blueprint and testing checklist.
