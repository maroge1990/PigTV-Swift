import Foundation
import os
#if os(tvOS)
import TVServices
#endif

// A4.1: builds and saves the App Group snapshot the Top Shelf extension
// (and the Siri intent's channel query) reads. Favourites first; without
// any, the first channels of the lineup.

extension BrowseModel {
    func topShelfSnapshot(now: Date = Date()) -> TopShelfSnapshot? {
        if !favourites.isEmpty {
            let entries = favourites.prefix(TopShelfSnapshot.limit).map { favourite -> TopShelfSnapshot.Entry in
                if let row = guideChannel(id: favourite.id) { return topShelfEntry(row, now: now) }
                // Guide not loaded (or the channel is outside it): the
                // favourites list's own now/next.
                let slots = [favourite.now, favourite.next].compactMap { $0 }
                    .filter { $0.endTime > $0.startTime }
                    .map { TopShelfSnapshot.Slot(title: $0.title, start: $0.start, end: $0.end) }
                return TopShelfSnapshot.Entry(id: favourite.rawID, sourceId: favourite.sourceId, name: favourite.name,
                                              number: showsChannelNumbers ? favourite.number : nil,
                                              logo: absoluteLogo(logo(for: favourite)), programmes: slots)
            }
            return TopShelfSnapshot(kind: "favourites", channels: Array(entries), savedAt: now)
        }
        guard !guide.isEmpty else { return nil }
        let entries = guide.prefix(TopShelfSnapshot.limit).map { topShelfEntry($0, now: now) }
        return TopShelfSnapshot(kind: "channels", channels: Array(entries), savedAt: now)
    }

    private func topShelfEntry(_ row: GuideChannel, now: Date) -> TopShelfSnapshot.Entry {
        let current = GuideNavigation.programme(in: row.programmes, at: now)
        let next = row.programmes.filter { $0.start >= (current?.end ?? now) && $0.end > $0.start }
            .min { $0.start < $1.start }
        let slots = [current, next].compactMap { $0 }
            .map { TopShelfSnapshot.Slot(title: $0.title, start: $0.start, end: $0.end) }
        return TopShelfSnapshot.Entry(id: row.rawID, sourceId: row.sourceId, name: row.name, number: number(for: row),
                                      logo: absoluteLogo(logo(for: row)), programmes: slots)
    }

    /// The logo as an absolute http(s) URL (relative server paths resolved
    /// against the server address); never carries credentials.
    private func absoluteLogo(_ logo: String?) -> URL? {
        guard let logo else { return nil }
        return client.artworkRequest(logo)?.url
    }

    /// Saves the snapshot when its content changed, and tells the Top Shelf.
    func exportTopShelf() {
        guard let snapshot = topShelfSnapshot() else {
            TopShelfLog.logger.notice("export: nothing to save yet (no favourites or guide rows)")
            return
        }
        guard !snapshot.sameContent(as: TopShelfExport.lastWritten) else { return }
        TopShelfExport.lastWritten = snapshot
        Task.detached(priority: .utility) {
            guard snapshot.write() else {
                // Try again on the next export rather than treating it as saved.
                await MainActor.run {
                    if TopShelfExport.lastWritten == snapshot { TopShelfExport.lastWritten = nil }
                }
                return
            }
            TopShelfExport.contentChanged()
            // The Siri channel suggestions are the Top Shelf's channels.
            PigTVShortcuts.refreshParameters(reason: "Top Shelf snapshot written")
        }
    }
}

enum TopShelfExport {
    @MainActor static var lastWritten: TopShelfSnapshot?

    /// Signing out removes the snapshot (no channels on the Top Shelf) and
    /// the Siri channel directory.
    @MainActor static func clear() {
        lastWritten = nil
        PlayLinkInbox.lastDirectory = nil
        Task.detached(priority: .utility) {
            if let url = TopShelfSnapshot.fileURL { try? FileManager.default.removeItem(at: url) }
            // A4.5: and the Siri channel directory.
            if let url = ChannelDirectory.fileURL { try? FileManager.default.removeItem(at: url) }
            // Build 29: files an earlier build left in the container's root
            // (possible on iOS only; tvOS never allowed writing there).
            if let root = AppGroupStorage.containerURL {
                for name in [TopShelfSnapshot.fileName, ChannelDirectory.fileName] {
                    try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
                }
            }
            contentChanged()
        }
    }

    nonisolated static func contentChanged() {
        #if os(tvOS)
        TVTopShelfContentProvider.topShelfContentDidChange()
        TopShelfLog.logger.notice("export: topShelfContentDidChange posted")
        #endif
    }
}
