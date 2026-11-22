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

    private var queued = 0
    /// #232 (Codex high): moves with every snapshot save, in call order (on the main actor, before the save leaves it).
    private var saveRevision = 0

    var current: Int { lock.withLock { generation } }

    /// How many file changes are on the queue or have run (tests: counted once queued).
    var queuedCount: Int { lock.withLock { queued } }

    /// Tests only: awaited by `run` before it queues its work, so a test can choose an order the
    /// detached callers allow (a scheduling barrier). Nil in the app.
    nonisolated(unsafe) static var beforeQueueing: (@Sendable (String) async -> Void)?

    /// #232: the revision of a save being started now; every later save (Hide scores' scrub too) supersedes it.
    func newSave() -> Int { lock.withLock { saveRevision += 1; return saveRevision } }

    /// #232: no save was started after the one with `revision`. Checked on the file queue right before writing, so a save
    /// whose detached task queued late never overwrites a newer one (a scored snapshot after Hide scores' scrub).
    func isNewestSave(_ revision: Int) -> Bool { lock.withLock { saveRevision == revision } }

    /// The session's files are no longer its to write. Returns the new generation.
    @discardableResult
    func retire() -> Int { lock.withLock { generation += 1; return generation } }

    /// A2-R (build 52): queues `work` now, before this returns, so anything the caller (or the next
    /// session) publishes afterwards runs after it. For the sign-out clear: the next session shares
    /// the generation the clear leaves, so only this order - never a generation check - keeps a
    /// clear from removing what that session has published.
    func queueNow(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
        lock.withLock { queued += 1 }
    }

    /// Runs `work` in order with every other Top Shelf file change - only while `generation` is
    /// still current (nil: always). Nil when it was dropped.
    func run<T: Sendable>(ifCurrent generation: Int?, label: String = "", _ work: @escaping @Sendable () -> T) async -> T? {
        if let gate = Self.beforeQueueing { await gate(label) }
        return await withCheckedContinuation { continuation in
            queue.async {
                if let generation, generation != self.current { continuation.resume(returning: nil); return }
                continuation.resume(returning: work())
            }
            lock.withLock { queued += 1 }
        }
    }

    /// Every file change queued so far has run (tests).
    func idle() async { _ = await run(ifCurrent: nil) { true } }
}

/// #232 (D-66): the live games the Top Shelf carousel shows, from the Sport front page's answer. Pure (`TopShelfGamesTests`).
/// The games are the player's live games list (`PlayerGames.list`): under way or on air before play on a channel that airs
/// them now, followed teams' games first, then the other live games of the leagues the household follows (the answer
/// holds only those), each group in the answer's order; at most `TopShelfSnapshot.gameLimit`. Scores follow D-66: written
/// only when the household shows them (`hidden`: the account's Hide scores as the sport pages hold it, unknown counting
/// as hidden; the answer's own switch also hides), with the scores feed, and when nobody is recording the game.
nonisolated enum TopShelfGames {
    /// The games for an answer received at `answeredAt`; nil when there is none, it is too old to show
    /// (`TopShelfSnapshot.gamesMaxAge`) or no game is live.
    static func games(_ front: SportFront?, answeredAt: Date?, hidden: Bool, labels: [String: String] = [:], now: Date,
                      calendar: Calendar = .current) -> [TopShelfSnapshot.Game]? {
        guard let front, let answeredAt, now.timeIntervalSince(answeredAt) < TopShelfSnapshot.gamesMaxAge else { return nil }
        let rows = PlayerGames.list(front, hidden: hidden, labels: labels, calendar: calendar, now: now)
            .prefix(TopShelfSnapshot.gameLimit)
        return rows.isEmpty ? nil : rows.map { Self.game($0) }
    }

    static func game(_ row: PlayerGame) -> TopShelfSnapshot.Game {
        // PlayerGames already withholds a score that is hidden, recorded or not fresh; a game with only one side's score
        // shows none.
        let scores = row.sides.flatMap { sides -> [String]? in
            let values = sides.compactMap(\.score)
            return values.count == 2 && sides.count == 2 ? values : nil
        }
        let best = row.game.channels.first
        return TopShelfSnapshot.Game(
            id: row.id, title: row.title, league: row.league, clock: row.clock,
            sides: row.sides?.map { TopShelfSnapshot.Game.Side(name: $0.name, code: $0.code, logo: $0.logo) },
            scores: row.recording ? nil : scores, recording: row.recording,
            channel: best.map { TopShelfSnapshot.Game.Channel(sourceId: $0.sourceId, id: $0.rawID, name: $0.name, number: $0.number) })
    }
}

extension BrowseModel {
    /// The channels (favourites first, else the lineup's first rows) and, while any is live, the live games (#232).
    func topShelfSnapshot(now: Date = Date()) -> TopShelfSnapshot? {
        guard var snapshot = topShelfChannels(now: now) else { return nil }
        if let games = topShelfGames(now: now) {
            snapshot.games = games
            snapshot.gamesAt = sportFront.updatedAt
        }
        return snapshot
    }

    /// #232: the live games from the Sport front page's latest answer, scores as the household's Hide scores allows now.
    func topShelfGames(now: Date = Date()) -> [TopShelfSnapshot.Game]? {
        let front = sportFront
        let hidden = SportSpoilers.hidden(preference: f1Page.hidesSpoilers, answer: front.front?.spoilerFree, page: false)
        return TopShelfGames.games(front.front, answeredAt: front.updatedAt, hidden: hidden,
                                   labels: front.labels, now: now)
    }

    private func topShelfChannels(now: Date) -> TopShelfSnapshot? {
        // Review of 383-385 (medium): the small first page (6 hours of 50 channels, BrowseModel.guideIsPreview) is never
        // exported: with it on screen the snapshot is built as with no guide at all.
        let rows = guideIsPreview ? [] : guide
        if !favourites.isEmpty {
            let entries = favourites.prefix(TopShelfSnapshot.limit).map { favourite -> TopShelfSnapshot.Entry in
                if !guideIsPreview, let row = guideChannel(id: favourite.id) { return topShelfEntry(row, now: now) }
                // Guide not loaded (or the channel is outside it): the
                // favourites list's own now/next.
                let slots = [favourite.now, favourite.next].compactMap { $0 }
                    .filter { $0.endTime > $0.startTime }
                    .map { TopShelfSnapshot.Slot(title: $0.title, start: $0.start, end: $0.end) }
                return TopShelfSnapshot.Entry(id: favourite.rawID, sourceId: favourite.sourceId, name: favourite.name,
                                              number: favourite.number,
                                              logo: absoluteLogo(logo(for: favourite)), programmes: slots)
            }
            return TopShelfSnapshot(kind: "favourites", channels: Array(entries), savedAt: now)
        }
        guard !rows.isEmpty else { return nil }
        let entries = rows.prefix(TopShelfSnapshot.limit).map { topShelfEntry($0, now: now) }
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

    /// #313 item 1: the export, finished only once its snapshot is written (or there was nothing to write). The
    /// background export waits on this while it holds a background task, so the app is not suspended halfway.
    func exportTopShelfUntilWritten() async {
        exportTopShelf()
        #if os(tvOS)
        await TopShelfCardExport.finish()
        #endif
    }

    /// Saves the snapshot when its content changed, and tells the Top Shelf.
    /// Build 32, tvOS: first renders its card images (TopShelfCards.swift),
    /// so the saved snapshot points at them.
    func exportTopShelf() {
        // The Top Shelf exists only on tvOS and only its extension reads the snapshot:
        // elsewhere this does nothing, so the guide scan below never runs.
        #if os(tvOS)
        guard publishesTopShelf else { return } // #362: an offline fixture's line-up is never published
        guard let snapshot = topShelfSnapshot() else {
            TopShelfLog.logger.notice("export: nothing to save yet (no favourites or guide rows)")
            return
        }
        // A2: under this session's generation; after sign-out it publishes nothing.
        guard topShelfGeneration == TopShelfPublication.shared.current else { return }
        TopShelfCardExport.schedule(snapshot, logoSources: topShelfLogoSources(for: snapshot),
                                    loader: { [weak self] logo in await self?.topShelfLogoImage(logo) }, generation: topShelfGeneration)
        #endif
    }
}

enum TopShelfExport {
    @MainActor static var lastWritten: TopShelfSnapshot?

    /// Writes `snapshot` unless it is unchanged, then (build 32) deletes card
    /// images it no longer points at, and tells the Top Shelf.
    /// A2: only for the session `generation`, checked again on the file queue right before writing.
    /// #313: returns the write (nil when there is nothing to write), so a card run can finish only once it is on disk.
    @discardableResult
    @MainActor static func save(_ snapshot: TopShelfSnapshot, pruneCardsIn cards: URL? = nil, generation: Int,
                                container: URL? = TopShelfSnapshot.containerURL) -> Task<Void, Never>? {
        guard generation == TopShelfPublication.shared.current else { return nil }
        guard !snapshot.sameContent(as: lastWritten) else { return nil }
        lastWritten = snapshot
        // #232 (Codex high): taken now, in call order; the detached task may queue its write after a later save's.
        let revision = TopShelfPublication.shared.newSave()
        return Task.detached(priority: .utility) {
            let written = await TopShelfPublication.shared.run(ifCurrent: generation, label: "save") { () -> Bool? in
                // A newer save (or Hide scores' scrub) was started after this one: it, not this, is what goes on disk.
                guard TopShelfPublication.shared.isNewestSave(revision) else { return nil }
                guard snapshot.write(container: container) else { return false }
                if let cards {
                    // #232: and the live games' cards.
                    let keep = Set(snapshot.channels.flatMap { $0.cards ?? [] }.map(\.file) + (snapshot.games ?? []).compactMap(\.image))
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

    /// #232 (D-66, the #192 stale-choice risk): Hide scores was switched on (or the choice became unknown). The saved
    /// Top Shelf loses its scores at once, before any new export: a card run in progress (which may carry scores) is
    /// cancelled, and the last snapshot written (else the one on disk) is written again without them. Nothing happens
    /// when it has none.
    @discardableResult
    @MainActor static func hideScores(generation: Int, container: URL? = TopShelfSnapshot.containerURL) -> Task<Void, Never>? {
        guard generation == TopShelfPublication.shared.current else { return nil }
        TopShelfCardExport.cancel()
        guard let saved = lastWritten ?? TopShelfSnapshot.read(container: container),
              saved.games?.contains(where: { $0.scores != nil }) == true else { return nil }
        return save(saved.withoutScores, generation: generation, container: container)
    }

    /// Signing out removes the snapshot (no channels on the Top Shelf). A2: the session's generation is retired first and its
    /// card render cancelled, so nothing it still has in flight is written after this. A2-R: the
    /// removal is queued before this returns, so the next session's first export (and the
    /// `lastWritten` it sets) always comes after it and is never removed by it.
    @MainActor static func clear(container: URL? = AppGroupStorage.containerURL) {
        TopShelfPublication.shared.retire()
        TopShelfCardExport.cancel()
        lastWritten = nil
        TopShelfPublication.shared.queueNow {
            if let url = TopShelfSnapshot.fileURL(in: container) { try? FileManager.default.removeItem(at: url) }
            // Build 32: and the card images.
            TopShelfCards.removeAll(in: container)
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
