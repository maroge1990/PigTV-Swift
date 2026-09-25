import Foundation
import TVServices
import os

// A4.1: PigTV's Top Shelf. Reads the snapshot the app keeps in the App Group
// container (Shared/TopShelfSnapshot.swift); no networking here. Logos load
// from their absolute URLs (the server's /api/logo route is unauthenticated).
// The server is plain http on the LAN, so this extension's Info.plist needs
// its own App Transport Security exception (build 27): the app's does not
// cover it, and without it every logo was refused.
// Build 32 (Mark: the logos were "very pixelated when blown up to that
// size"): the app renders a 16:9 card per channel and programme
// (TopShelfCards.swift) into the App Group's Library/Caches/topshelf/, and
// items point at those file URLs; the logo URL is only the fallback.
// Sectioned items have a title but no subtitle, so the programme on now
// follows the channel in the title: "Fox Footy — AFL Live" (no channel number since build 29).
// Each step is logged under subsystem au.markrogers.PigTV.TopShelf, and the
// outcome is saved for Settings → Diagnostics (`TopShelfExtensionStatus`).
//
// Build 31, the real reason the Top Shelf only ever showed the pig: the
// target linked with the tv-app-extension product type's entry point
// `_TVExtensionMain`, which in the current tvOS runtime is an empty function
// (a bare `ret`). The process returned from main at once (exit status 3, no
// log line), HeadBoard logged "Connection to plugin interrupted" and fell
// back to the static image. The target now links with `-e _NSExtensionMain`
// (OTHER_LDFLAGS); `testTopShelfExtensionEntryPoint` guards it.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        let log = TopShelfLog.logger
        log.notice("extension: loadTopShelfContent called")
        guard AppGroupStorage.containerURL != nil else {
            log.error("extension: no App Group container")
            return nil
        }
        guard let snapshot = TopShelfSnapshot.read() else {
            log.notice("extension: no snapshot; the static Top Shelf image is shown")
            Self.record(items: 0, note: "no snapshot yet, showed the static image")
            return nil
        }
        guard !snapshot.channels.isEmpty else {
            log.notice("extension: snapshot has no channels; the static Top Shelf image is shown")
            Self.record(items: 0, note: "the snapshot had no channels")
            return nil
        }
        let content = Self.content(for: snapshot, now: Date())
        let count = snapshot.channels.prefix(TopShelfSnapshot.limit).count
        log.notice("extension: returning \(count) \(snapshot.kind, privacy: .public) items saved \(snapshot.savedAt, privacy: .public)")
        Self.record(items: count, note: "returned \(count) \(count == 1 ? "item" : "items")")
        return content
    }

    private static func record(items: Int, note: String) {
        TopShelfExtensionStatus(askedAt: Date(), items: items, note: note).write()
    }

    static func content(for snapshot: TopShelfSnapshot, now: Date) -> TVTopShelfSectionedContent {
        let log = TopShelfLog.logger
        let items = snapshot.channels.prefix(TopShelfSnapshot.limit).map { entry -> TVTopShelfSectionedItem in
            let item = TVTopShelfSectionedItem(identifier: entry.playURL.absoluteString)
            if let programme = entry.programme(at: now) {
                item.title = "\(entry.title) — \(programme.title)"
            } else {
                item.title = entry.title
            }
            item.imageShape = .hdtv
            // Build 32: the card the app rendered (a file URL in the App
            // Group), else the logo's URL as before.
            if let image = entry.imageURL(at: now) {
                item.setImageURL(image, for: [.screenScale1x, .screenScale2x])
                log.debug("extension: \(entry.title, privacy: .public) image \(image.absoluteString, privacy: .public)")
            } else {
                log.notice("extension: \(entry.title, privacy: .public) has no card or logo URL")
            }
            let action = TVTopShelfAction(url: entry.playURL)
            item.playAction = action
            item.displayAction = action
            return item
        }
        let section = TVTopShelfItemCollection(items: Array(items))
        section.title = snapshot.sectionTitle
        return TVTopShelfSectionedContent(sections: [section])
    }
}
