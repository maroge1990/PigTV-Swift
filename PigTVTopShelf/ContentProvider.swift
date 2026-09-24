import Foundation
import TVServices
import os

// A4.1: PigTV's Top Shelf. Reads the snapshot the app keeps in the App Group
// container (Shared/TopShelfSnapshot.swift); no networking here. Logos load
// from their absolute URLs (the server's /api/logo route is unauthenticated).
// The server is plain http on the LAN, so this extension's Info.plist needs
// its own App Transport Security exception (build 27): the app's does not
// cover it, and without it every logo was refused.
// Sectioned items have a title but no subtitle, so the programme on now
// follows the channel in the title: "Fox Footy — AFL Live" (no channel number since build 29).
// Each step is logged under subsystem au.markrogers.PigTV.TopShelf.
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        let log = TopShelfLog.logger
        log.notice("extension: loadTopShelfContent called")
        guard let snapshot = TopShelfSnapshot.read() else {
            log.notice("extension: no snapshot; the static Top Shelf image is shown")
            return nil
        }
        guard !snapshot.channels.isEmpty else {
            log.notice("extension: snapshot has no channels; the static Top Shelf image is shown")
            return nil
        }
        let content = Self.content(for: snapshot, now: Date())
        log.notice("extension: returning \(snapshot.channels.prefix(TopShelfSnapshot.limit).count) \(snapshot.kind, privacy: .public) items saved \(snapshot.savedAt, privacy: .public)")
        return content
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
            if let logo = entry.logo {
                item.setImageURL(logo, for: [.screenScale1x, .screenScale2x])
                log.debug("extension: \(entry.title, privacy: .public) logo \(logo.absoluteString, privacy: .public)")
            } else {
                log.notice("extension: \(entry.title, privacy: .public) has no logo URL")
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
