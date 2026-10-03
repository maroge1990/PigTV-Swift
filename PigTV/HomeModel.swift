import Foundation
import Combine

/// Everything Home draws, rebuilt when its inputs change and every minute
/// rather than on each render (the guide has ~18 000 channels).
struct HomeContent: Equatable {
    var hero: HomeChannel?
    var recent: [HomeChannel] = []
    var favouritesOnNow: [HomeChannel] = []
    var startingSoon: [HomeSoonItem] = []
    /// C-I: live sport events, then those starting within the hour.
    var sport: [SportEvent] = []
    var recordings: [Recording] = []
    /// Recording id → its channel's logo (found by channel name in the guide).
    var recordingLogos: [Int: String] = [:]

    var isEmpty: Bool { hasNoHistory && sport.isEmpty }
    /// First run: nothing watched, no favourites, no recordings yet.
    var hasNoHistory: Bool {
        hero == nil && recent.isEmpty && favouritesOnNow.isEmpty && startingSoon.isEmpty && recordings.isEmpty
    }
}

/// Home's content, built from the stores Home draws from and published only
/// when the result differs (audit R05). The view observes this, not the
/// guide, recordings and library stores, so a guide page or a recordings
/// refresh that changes nothing Home shows re-renders nothing. The content
/// is kept while Home is hidden: coming back to a tab with unchanged inputs
/// shows it at once with no rebuild, and nothing is rebuilt while hidden.
@MainActor
final class HomeModel: ObservableObject {
    @Published private(set) var content = HomeContent()
    /// The guide is loading and nothing is shown yet (the "Loading your
    /// channels…" line, and no welcome until it is known there is no history).
    @Published private(set) var guideLoading = false
    /// This device's last played channel (AppModel's; the view passes it in).
    var lastWatched: LastWatched? {
        didSet { if lastWatched != oldValue { invalidate(after: .zero) } }
    }
    /// How many times the content was recomputed (tests, profiling).
    private(set) var rebuilds = 0

    /// Content older than this is rebuilt when Home reappears: its "on now"
    /// rows and countdowns are time-dependent.
    static let maxAge: TimeInterval = 60

    private unowned let browse: BrowseModel
    private let delay: Duration
    private var visible = false
    private var dirty = true
    private var builtAt: Date?
    private var pending: Task<Void, Never>?
    private var subscriptions: [AnyCancellable] = []

    /// `guideDelay`: guide pages arrive in bursts; rebuild at most a few
    /// times a second.
    init(browse: BrowseModel, guideDelay: Duration = .milliseconds(400)) {
        self.browse = browse
        delay = guideDelay
        // The stores publish before they store, so each sink takes the
        // emitted value and only marks the content stale; the rebuild runs
        // after the change has landed.
        subscriptions = [
            browse.guideStore.$guide.map(\.count).removeDuplicates().dropFirst()
                .sink { [weak self] _ in self?.invalidate(after: guideDelay) },
            Publishers.CombineLatest(browse.guideStore.$guideBusy, browse.guideStore.$guide.map(\.isEmpty))
                .map { $0 && $1 }.removeDuplicates()
                .sink { [weak self] loading in self?.guideLoading = loading },
            // Whole-value equality, not id lists: a recording's status or
            // `native_status` changing (same id) must rebuild Home, while an
            // unrelated publish that leaves these arrays equal does not.
            browse.library.$favourites.removeDuplicates().dropFirst()
                .sink { [weak self] _ in self?.invalidate(after: .zero) },
            browse.library.$recent.removeDuplicates().dropFirst()
                .sink { [weak self] _ in self?.invalidate(after: .zero) },
            browse.recordingStore.$recordings.removeDuplicates().dropFirst()
                .sink { [weak self] _ in self?.invalidate(after: .zero) },
            // C-I: the sport events (refreshed every minute while Home shows).
            browse.sport.$events.removeDuplicates().dropFirst()
                .sink { [weak self] _ in self?.invalidate(after: guideDelay) }
        ]
    }

    /// Home came on screen. Fresh content stays as it is; stale or changed
    /// content is rebuilt.
    func activate(lastWatched: LastWatched?) {
        visible = true
        self.lastWatched = lastWatched
        refreshIfNeeded()
    }

    /// Home went away: nothing is rebuilt until it is back.
    func deactivate() {
        visible = false
        pending?.cancel()
        pending = nil
    }

    /// Rebuilds only when an input changed or the content is a minute old.
    func refreshIfNeeded(now: Date = Date()) {
        guard dirty || builtAt.map({ now.timeIntervalSince($0) >= Self.maxAge }) ?? true else { return }
        rebuild(now: now)
    }

    /// The minute's tick: the time-dependent rows are recomputed whether or
    /// not an input changed; nothing is published when they come out equal.
    func rebuild(now: Date = Date()) {
        let sp = PigTVSignpost.begin("HomeRebuild"); defer { PigTVSignpost.end("HomeRebuild", sp) }
        pending?.cancel()
        pending = nil
        dirty = false
        builtAt = now
        rebuilds += 1
        let next = build(now: now)
        if next != content { content = next }
    }

    private func invalidate(after wait: Duration) {
        dirty = true
        guard visible else { return }
        // A sooner request replaces a pending later one; a later one joins it.
        if pending != nil, wait != .zero { return }
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            if wait != .zero { try? await Task.sleep(for: wait) } else { await Task.yield() }
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.refreshIfNeeded()
        }
    }

    private func build(now: Date) -> HomeContent {
        let model = browse
        let recent = model.recent.map(model.homeChannel)
        let hero = HomeRows.continueWatching(last: lastWatched, recent: recent) { last in
            model.guideRow(id: last.id, identityKey: last.identityKey).map(model.homeChannel)
        }
        let favourites = model.favourites.map(model.homeChannel)
        var next = HomeContent()
        next.hero = hero
        next.recent = HomeRows.recentlyWatched(recent, excluding: hero)
        next.favouritesOnNow = HomeRows.onNow(favourites, now: now)
        next.startingSoon = HomeRows.startingSoon(favourites, now: now)
        if model.sportEnabled {
            next.sport = SportRows.nowAndNext(SportRows.buckets(model.sport.events, now: now))
        }
        next.recordings = HomeRows.recordings(model.recordings)
        // One pass over the guide for the recordings' channel logos.
        let names = Set(next.recordings.compactMap(\.channel_name))
        if !names.isEmpty {
            var logos: [String: String] = [:]
            for row in model.guide where names.contains(row.name) && logos[row.name] == nil {
                if let logo = model.logo(for: row) { logos[row.name] = logo }
                if logos.count == names.count { break }
            }
            for recording in next.recordings {
                if let name = recording.channel_name, let logo = logos[name] { next.recordingLogos[recording.id] = logo }
            }
        }
        return next
    }
}
