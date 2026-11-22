import Foundation
import Observation

// Audit R05: BrowseModel used to be one ObservableObject with ~25 @Published
// properties, so any publish (a guide page arriving, a busy flag flipping)
// re-evaluated every screen that held it. These are the seams it is split
// along; BrowseModel owns one of each and forwards its old properties to them.
// #51: the stores are @Observable, so a view is re-evaluated only by the
// properties its body reads (through BrowseModel's forwarding too); nothing
// has to be spelled out. A property marked @ObservationIgnored is one no
// change of which redraws anything (it was never published).

/// A store whose changes can be suppressed when equal.
@MainActor
protocol ChangeSuppressing: AnyObject {}

@MainActor
extension ChangeSuppressing {
    /// Assigns only when the value differs, so a repeated flag or an equal
    /// refresh publishes nothing.
    func change<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<Self, Value>, to value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}

/// The guide: its channels and programmes, the window it covers and the
/// paging state. Changes a lot while a load pages in.
@MainActor @Observable
final class GuideStore: ChangeSuppressing {
    var guide: [GuideChannel] = [] { didSet { guideIndex = nil } }
    // Channel id → position in `guide`, built lazily after each change. The
    // full guide is ~18 000 channels, so per-render `first(where:)` scans in
    // the guide header and player channel list were measurable work.
    @ObservationIgnored private var guideIndex: [String: Int]?
    var guideBusy = false
    var guideError: String?
    var guideHasMore = false
    /// Later pages are being fetched now (the first page's load, or the paging after it). `guideHasMore` is only the
    /// cursor a retry resumes from: it stays when paging stopped on a failure (#342, Codex sign-off of 325).
    var guidePaging = false
    var window = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 1800) * 1800)
    var guideTotal = 0
    var guideLoadedAt: Date?
    var fromCache = false
    // Build 33: how far ahead programme data actually reaches (initially
    // `window + GuideNavigation.loadedDuration`, then pushed forward as
    // `extendGuideForward()` merges in more slices). GuideGridLayout draws
    // content this wide; GuideView compares the viewport against it instead
    // of always assuming exactly one day is loaded.
    var guideLoadedUntil = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 1800) * 1800)
        .addingTimeInterval(GuideNavigation.loadedDuration)
    // True once a forward slice came back with no programmes at all (the
    // provider's guide has ended): stops further extension attempts.
    var guideEnded = false
    // Bumped whenever programmes are merged into (or trimmed from) existing
    // rows in place: `guide.count`/first/last id do not change, so this is
    // what tells GuideView's row-filter memoisation to recompute.
    var guideProgrammesVersion = 0
    /// #280 (one retry clock): the app's next freshness pass (AppFreshness), which is what retries a guide that failed;
    /// published only while it has failed, for the error's countdown.
    var schedule: RefreshSchedule?

    func channel(id: String) -> GuideChannel? {
        if guideIndex == nil {
            guideIndex = Dictionary(guide.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        return guideIndex?[id].map { guide[$0] }
    }
}

/// Recordings and schedules, with the load's busy and error state.
@MainActor @Observable
final class RecordingsStore: ChangeSuppressing {
    var recordings: [Recording] = []
    var schedules: [ScheduledRecording] = [] { didSet { marks?.follow(schedules, hiding: pendingRemovals) } }
    /// #51: the marks derived from `schedules` and `pendingRemovals`, told of every change to either (`ScheduleMarks`).
    @ObservationIgnored weak var marks: ScheduleMarks?
    var recordingsBusy = false
    var recordingsError: String?
    /// #280: an answer has come since sign-in (until then the page is loading, never "No recordings yet").
    var loaded = false
    /// When the list shown was received (the stale notice's time). Not published: it changes with every quiet refresh.
    @ObservationIgnored var updatedAt: Date?
    /// When the scheduled list on show was asked for (Codex review of #347: a card's `recordingCancelling` older than it
    /// is reconciled against it).
    @ObservationIgnored var schedulesAskedAt: Date?
    /// Codex sign-off of #347: open record pages whose card lists cancellations (they wait for a newer read). While any
    /// waits, every accepted read is published (`readsSeen`), even one with the same rows; otherwise a quiet refresh
    /// that finds nothing new still publishes nothing (ObservationTests).
    @ObservationIgnored var readWaiters = 0
    var readsSeen = 0
    /// #280 (one retry clock): the next request the polling makes (AppFreshness, or the Recordings page's own loop);
    /// published only while the list has failed.
    var schedule: RefreshSchedule?
    /// #280: the rules have answered once (Scheduled shows their shape until then, not "No rules yet").
    var rulesLoaded = false
    /// C-M (Apple 120): the recording rules Scheduled lists, and why they could not be loaded.
    var rules: [RecordingRule] = []
    var rulesError: String?
    /// Apple 122 (D-44 point 9): what a destructive action hid at once while its Undo runs (`RecordingsHome.key`).
    var pendingRemovals: Set<String> = [] { didSet { marks?.follow(schedules, hiding: pendingRemovals) } }
    /// Apple 125 (Codex 5b round 1, medium): removals the server confirmed, by key, with when. Each stays hidden (and is
    /// filtered out of any list fetched before it) until a refresh that began after it has loaded. #51: observed (a view
    /// reading it, `cancellingHere`, is told when it changes; it used to be redrawn by the store's next publish).
    var tombstones: [String: Date] = [:]
    /// Removals whose answer never came (a transport error or a timeout), by key, with when: the server may or may not
    /// have done them, so they stay in progress until a scheduled-list refresh that began after then has answered
    /// (Mark, 19 Nov 2026: nothing races a cancellation in progress).
    var uncertainRemovals: [String: Date] = [:]
    /// #357 (Codex review of 359-360): Records the server refused 409 "cancelling", by the cancellation key of the
    /// schedule it named, with the airing tried: that airing waits (Cancelling…) until an accepted scheduled-list read
    /// asked for after the refusal lists the schedule not "cancelling", or not at all, whether or not the list on show
    /// has its row. Every distinct airing refused for a schedule is kept, each settled by a read asked for after its own
    /// refusal (Codex sign-off of 359-364: a second refusal replaced the first's airing). Never an empty list.
    var refusedAirings: [String: [RefusedAiring]] = [:]
}

/// A Record refused 409 "cancelling" (#357): the schedule the server named, the airing tried (its game, channel identity
/// and guide bounds) and when.
nonisolated struct RefusedAiring: Equatable, Sendable {
    let scheduleId: Int
    let gameId: String?
    let sourceId: Int
    let rawID: String
    let stableId: String?
    let channelName: String
    let start: Double
    let end: Double
    let since: Date

    /// The same airing tried (whenever it was refused).
    func sameAiring(_ other: RefusedAiring) -> Bool {
        scheduleId == other.scheduleId && gameId == other.gameId && sourceId == other.sourceId && rawID == other.rawID
            && stableId == other.stableId && channelName == other.channelName && start == other.start && end == other.end
    }

    /// An airing that overlaps this one and is the same game or on the same channel (by identity, as
    /// `BrowseModel.sameChannel`) waits with it.
    func covers(gameId: String?, channel: GuideChannel, start: Double, end: Double) -> Bool {
        guard start < self.end, self.start < end else { return false }
        if let gameId, gameId == self.gameId { return true }
        guard channel.sourceId == sourceId else { return false }
        if let stable = stableId, !stable.isEmpty, let mine = channel.stableId, !mine.isEmpty { return stable == mine }
        return channel.rawID == rawID
    }
}

/// Favourites. Nothing draws the load's busy state, so it is a plain property: a load that finds nothing new publishes
/// nothing. The error is published: the Guide's Favourites chip shows it (#355).
@MainActor @Observable
final class LibraryStore: ChangeSuppressing {
    var favourites: [Channel] = []
    /// The favourites' first answer (or failure) has come (#342: the Guide's Favourites chip waits for it).
    var favouritesAnswered = false
    @ObservationIgnored var favouritesBusy = false
    var favouritesError: String?
}

/// Which programmes are scheduled and which channels are recording now,
/// derived from the schedules and republished only when those sets change
/// (the Guide marks cells with them; it does not care that a recordings
/// refresh happened).
@MainActor @Observable
final class ScheduleMarks: ChangeSuppressing {
    private(set) var scheduledKeys: Set<String> = []
    private(set) var recordingChannels: Set<String> = []

    private(set) var recordingChannelKeys: Set<String> = []
    func isRecording(_ channel: SportEventChannel) -> Bool {
        recordingChannelKeys.contains(channel.identityKey)
    }

    /// #51: the recordings store calls `follow` on every change of its schedules or the removals it hides (it used to be a
    /// Combine subscription to their publishers), and once now.
    init(following store: RecordingsStore) {
        store.marks = self
        follow(store.schedules, hiding: store.pendingRemovals)
    }

    /// Apple 122: a schedule cancelled with Undo leaves the guide's marks at once.
    func follow(_ all: [ScheduledRecording], hiding hidden: Set<String>) {
        let schedules = all.filter { !hidden.contains(RecordingsHome.key($0)) }
        change(\.scheduledKeys, to: Set(schedules.filter(\.isActive).map(\.guideKey)))
        change(\.recordingChannels, to: Set(schedules.filter { $0.status == "recording" }.compactMap(\.channel_name)))
        change(\.recordingChannelKeys, to: Set(schedules.filter { $0.status == "recording" }.compactMap(\.channelIdentityKey)))
    }
}

/// The transient result of a schedule, cancel or delete.
@MainActor @Observable
final class ActionState: ChangeSuppressing {
    var mutationBusy = false
    var actionMessage: String?
    var actionError: String?
}
