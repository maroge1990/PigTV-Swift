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
    /// Build 32, tvOS: first renders its card images (TopShelfCards.swift),
    /// so the saved snapshot points at them.
    func exportTopShelf() {
        guard let snapshot = topShelfSnapshot() else {
            TopShelfLog.logger.notice("export: nothing to save yet (no favourites or guide rows)")
            return
        }
        #if os(tvOS)
        TopShelfCardExport.schedule(snapshot, logoSources: topShelfLogoSources(for: snapshot),
                                    loader: { [weak self] logo in await self?.topShelfLogoImage(logo) })
        #else
        TopShelfExport.save(snapshot)
        #endif
    }
}

enum TopShelfExport {
    @MainActor static var lastWritten: TopShelfSnapshot?

    /// Writes `snapshot` unless it is unchanged, then (build 32) deletes card
    /// images it no longer points at, and tells the Top Shelf.
    @MainActor static func save(_ snapshot: TopShelfSnapshot, pruneCardsIn cards: URL? = nil) {
        guard !snapshot.sameContent(as: lastWritten) else { return }
        lastWritten = snapshot
        Task.detached(priority: .utility) {
            guard snapshot.write() else {
                // Try again on the next export rather than treating it as saved.
                await MainActor.run {
                    if TopShelfExport.lastWritten == snapshot { TopShelfExport.lastWritten = nil }
                }
                return
            }
            if let cards {
                let keep = Set(snapshot.channels.flatMap { $0.cards ?? [] }.map(\.file))
                let removed = TopShelfCards.prune(keeping: keep, in: cards)
                TopShelfLog.logger.notice("export: \(keep.count) cards in use, \(removed) stale removed")
            }
            contentChanged()
        }
    }

    /// The Siri channel directory older builds wrote (Siri was removed in
    /// build 37). Deleted at launch and on sign-out so it does not linger.
    nonisolated static let legacyChannelDirectoryName = "channel-directory.json"

    nonisolated static func removeLegacyChannelDirectory() {
        Task.detached(priority: .utility) {
            guard let container = AppGroupStorage.containerURL else { return }
            for url in [AppGroupStorage.fileURL(legacyChannelDirectoryName, in: container),
                        container.appendingPathComponent(legacyChannelDirectoryName)] {
                if let url { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    /// Signing out removes the snapshot (no channels on the Top Shelf) and
    /// any leftover Siri channel directory.
    @MainActor static func clear() {
        lastWritten = nil
        Task.detached(priority: .utility) {
            if let url = TopShelfSnapshot.fileURL { try? FileManager.default.removeItem(at: url) }
            // Build 32: and the card images.
            TopShelfCards.removeAll(in: AppGroupStorage.containerURL)
            // And the Siri channel directory older builds wrote.
            if let url = AppGroupStorage.fileURL(legacyChannelDirectoryName, in: AppGroupStorage.containerURL) { try? FileManager.default.removeItem(at: url) }
            // Build 29: files an earlier build left in the container's root
            // (possible on iOS only; tvOS never allowed writing there).
            if let root = AppGroupStorage.containerURL {
                for name in [TopShelfSnapshot.fileName, legacyChannelDirectoryName] {
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
