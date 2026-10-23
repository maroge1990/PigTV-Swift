import Foundation
import os
#if os(tvOS)
import TVServices
#endif

// A4.1: builds and saves the App Group snapshot the Top Shelf extension
// (and the Siri intent's channel query) reads. Favourites first; without
// any, the first channels of the lineup.

/// A2 (build 48): one owner for every Top Shelf file change - the snapshot, its card images and
/// the sign-out clear. Each session publishes under a generation; sign-out (or a server/account
/// switch) retires it, and the files are only touched on one serial queue, where a write checks
/// its generation immediately before it runs. A render, save or late guide/favourite export from
/// the old session can therefore never recreate what the clear removed: a write queued before the
/// clear finishes before it (and is then removed); one queued after it is dropped.
nonisolated final class TopShelfPublication: @unchecked Sendable {
    static let shared = TopShelfPublication()
    private let lock = NSLock()
    private var generation = 0
    private let queue = DispatchQueue(label: "au.markrogers.PigTV.topshelf-files")

    var current: Int { lock.withLock { generation } }

    /// The session's files are no longer its to write. Returns the new generation.
    @discardableResult
    func retire() -> Int { lock.withLock { generation += 1; return generation } }

    /// Runs `work` in order with every other Top Shelf file change - only while `generation` is
    /// still current (nil: always, for the clear). Nil when it was dropped.
    func run<T: Sendable>(ifCurrent generation: Int?, _ work: @escaping @Sendable () -> T) async -> T? {
        await withCheckedContinuation { continuation in
            queue.async {
                if let generation, generation != self.current { continuation.resume(returning: nil); return }
                continuation.resume(returning: work())
            }
        }
    }

    /// Every file change queued so far has run (tests).
    func idle() async { _ = await run(ifCurrent: nil) { true } }
}

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
        // A2: under this session's generation; after sign-out it publishes nothing.
        guard topShelfGeneration == TopShelfPublication.shared.current else { return }
        #if os(tvOS)
        TopShelfCardExport.schedule(snapshot, logoSources: topShelfLogoSources(for: snapshot),
                                    loader: { [weak self] logo in await self?.topShelfLogoImage(logo) }, generation: topShelfGeneration)
        #else
        TopShelfExport.save(snapshot, generation: topShelfGeneration)
        #endif
    }
}

enum TopShelfExport {
    @MainActor static var lastWritten: TopShelfSnapshot?

    /// Writes `snapshot` unless it is unchanged, then (build 32) deletes card
    /// images it no longer points at, and tells the Top Shelf.
    /// A2: only for the session `generation`, checked again on the file queue right before writing.
    @MainActor static func save(_ snapshot: TopShelfSnapshot, pruneCardsIn cards: URL? = nil, generation: Int,
                                container: URL? = TopShelfSnapshot.containerURL) {
        guard generation == TopShelfPublication.shared.current else { return }
        guard !snapshot.sameContent(as: lastWritten) else { return }
        lastWritten = snapshot
        Task.detached(priority: .utility) {
            let written = await TopShelfPublication.shared.run(ifCurrent: generation) { () -> Bool in
                guard snapshot.write(container: container) else { return false }
                if let cards {
                    let keep = Set(snapshot.channels.flatMap { $0.cards ?? [] }.map(\.file))
                    let removed = TopShelfCards.prune(keeping: keep, in: cards)
                    TopShelfLog.logger.notice("export: \(keep.count) cards in use, \(removed) stale removed")
                }
                contentChanged()
                return true
            }
            if written == false {
                // Try again on the next export rather than treating it as saved.
                await MainActor.run {
                    if TopShelfExport.lastWritten == snapshot { TopShelfExport.lastWritten = nil }
                }
            }
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
    /// any leftover Siri channel directory. A2: the session's generation is retired first and its
    /// card render cancelled, so nothing it still has in flight is written after this.
    @MainActor static func clear(container: URL? = AppGroupStorage.containerURL) {
        TopShelfPublication.shared.retire()
        TopShelfCardExport.cancel()
        lastWritten = nil
        Task.detached(priority: .utility) {
            _ = await TopShelfPublication.shared.run(ifCurrent: nil) { () -> Bool in
                if let url = TopShelfSnapshot.fileURL(in: container) { try? FileManager.default.removeItem(at: url) }
                // Build 32: and the card images.
                TopShelfCards.removeAll(in: container)
                // And the Siri channel directory older builds wrote.
                if let url = AppGroupStorage.fileURL(legacyChannelDirectoryName, in: container) { try? FileManager.default.removeItem(at: url) }
                // Build 29: files an earlier build left in the container's root
                // (possible on iOS only; tvOS never allowed writing there).
                if let root = container {
                    for name in [TopShelfSnapshot.fileName, legacyChannelDirectoryName] {
                        try? FileManager.default.removeItem(at: root.appendingPathComponent(name))
                    }
                }
                contentChanged()
                return true
            }
        }
    }

    nonisolated static func contentChanged() {
        #if os(tvOS)
        TVTopShelfContentProvider.topShelfContentDidChange()
        TopShelfLog.logger.notice("export: topShelfContentDidChange posted")
        #endif
    }
}
