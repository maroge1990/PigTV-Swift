import Foundation
import TVServices

// A4.1: PigTV's Top Shelf. Reads the snapshot the app keeps in the App Group
// container (Shared/TopShelfSnapshot.swift); no networking here. Logos load
// from their absolute URLs (the server's /api/logo route is unauthenticated).
// Sectioned items have a title but no subtitle, so the programme on now
// follows the channel in the title: "503 · Fox Footy — AFL Live".
final class ContentProvider: TVTopShelfContentProvider {
    override func loadTopShelfContent() async -> (any TVTopShelfContent)? {
        guard let snapshot = TopShelfSnapshot.read(), !snapshot.channels.isEmpty else { return nil }
        let now = Date()
        let items = snapshot.channels.prefix(TopShelfSnapshot.limit).map { entry -> TVTopShelfSectionedItem in
            let item = TVTopShelfSectionedItem(identifier: entry.playURL.absoluteString)
            if let programme = entry.programme(at: now) {
                item.title = "\(entry.title) — \(programme.title)"
            } else {
                item.title = entry.title
            }
            item.imageShape = .hdtv
            if let logo = entry.logo { item.setImageURL(logo, for: [.screenScale1x, .screenScale2x]) }
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
