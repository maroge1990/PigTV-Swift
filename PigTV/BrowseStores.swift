import Foundation
import Combine

// Audit R05: BrowseModel used to be one ObservableObject with ~25 @Published
// properties, so any publish (a guide page arriving, a busy flag flipping)
// re-evaluated every screen that held it. These are the seams it is split
// along; BrowseModel owns one of each and forwards its old properties to them,
// so only views changed. A screen observes exactly the stores it reads, and
// BrowseModel itself publishes nothing (a view that reads `model.guide`
// without observing `model.guideStore` would never update, so a view's
// stores are always spelled out in its initialiser).

@MainActor
extension ObservableObject {
    /// Assigns only when the value differs, so a repeated flag or an equal
    /// refresh publishes nothing.
    func change<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<Self, Value>, to value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}

/// The guide: its channels and programmes, the window it covers and the
/// paging state. Changes a lot while a load pages in.
@MainActor
final class GuideStore: ObservableObject {
    @Published var guide: [GuideChannel] = [] { didSet { guideIndex = nil } }
    // Channel id → position in `guide`, built lazily after each change. The
    // full guide is ~18 000 channels, so per-render `first(where:)` scans in
    // the guide header and player channel list were measurable work.
    private var guideIndex: [String: Int]?
    @Published var guideBusy = false
    @Published var guideError: String?
    @Published var guideHasMore = false
    @Published var window = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 1800) * 1800)
    @Published var guideTotal = 0
    @Published var guideLoadedAt: Date?
    @Published var fromCache = false
    // Build 33: how far ahead programme data actually reaches (initially
    // `window + GuideNavigation.loadedDuration`, then pushed forward as
    // `extendGuideForward()` merges in more slices). GuideGridLayout draws
    // content this wide; GuideView compares the viewport against it instead
    // of always assuming exactly one day is loaded.
    @Published var guideLoadedUntil = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970 / 1800) * 1800)
        .addingTimeInterval(GuideNavigation.loadedDuration)
    // True once a forward slice came back with no programmes at all (the
    // provider's guide has ended): stops further extension attempts.
    @Published var guideEnded = false
    // Bumped whenever programmes are merged into (or trimmed from) existing
    // rows in place: `guide.count`/first/last id do not change, so this is
    // what tells GuideView's row-filter memoisation to recompute.
    @Published var guideProgrammesVersion = 0
    /// #280 (one retry clock): the app's next freshness pass (AppFreshness), which is what retries a guide that failed;
    /// published only while it has failed, for the error's countdown.
    @Published var schedule: RefreshSchedule?

    func channel(id: String) -> GuideChannel? {
        if guideIndex == nil {
            guideIndex = Dictionary(guide.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        return guideIndex?[id].map { guide[$0] }
    }
}

/// Recordings and schedules, with the load's busy and error state.
@MainActor
final class RecordingsStore: ObservableObject {
    @Published var recordings: [Recording] = []
    @Published var schedules: [ScheduledRecording] = []
    @Published var recordingsBusy = false
    @Published var recordingsError: String?
    /// #280: an answer has come since sign-in (until then the page is loading, never "No recordings yet").
    @Published var loaded = false
    /// When the list shown was received (the stale notice's time). Not published: it changes with every quiet refresh.
    var updatedAt: Date?
    /// #280 (one retry clock): the next request the polling makes (AppFreshness, or the Recordings page's own loop);
    /// published only while the list has failed.
    @Published var schedule: RefreshSchedule?
    /// #280: the rules have answered once (Scheduled shows their shape until then, not "No rules yet").
    @Published var rulesLoaded = false
    /// C-M (Apple 120): the recording rules Scheduled lists, and why they could not be loaded.
    @Published var rules: [RecordingRule] = []
    @Published var rulesError: String?
    /// Apple 122 (D-44 point 9): what a destructive action hid at once while its Undo runs (`RecordingsHome.key`).
    @Published var pendingRemovals: Set<String> = []
    /// Apple 125 (Codex 5b round 1, medium): removals the server confirmed, by key, with when. Each stays hidden (and is
    /// filtered out of any list fetched before it) until a refresh that began after it has loaded.
    var tombstones: [String: Date] = [:]
}

/// Favourites. Nothing draws the load's busy or error
/// state, so those are plain properties: a load that finds nothing new
/// publishes nothing.
@MainActor
final class LibraryStore: ObservableObject {
    @Published var favourites: [Channel] = []
    var favouritesBusy = false
    var favouritesError: String?
}

/// Which programmes are scheduled and which channels are recording now,
/// derived from the schedules and republished only when those sets change
/// (the Guide marks cells with them; it does not care that a recordings
/// refresh happened).
@MainActor
final class ScheduleMarks: ObservableObject {
    @Published private(set) var scheduledKeys: Set<String> = []
    @Published private(set) var recordingChannels: Set<String> = []
    private var cancellable: AnyCancellable?

    @Published private(set) var recordingChannelKeys: Set<String> = []
    func isRecording(_ channel: SportEventChannel) -> Bool {
        recordingChannelKeys.contains(channel.identityKey)
    }

    init(following store: RecordingsStore) {
        // `$schedules` hands over the new value before it is stored.
        // Apple 122: a schedule cancelled with Undo leaves the guide's marks at once.
        cancellable = store.$schedules.combineLatest(store.$pendingRemovals).sink { [weak self] all, hidden in
            let schedules = all.filter { !hidden.contains(RecordingsHome.key($0)) }
            self?.change(\.scheduledKeys, to: Set(schedules.filter(\.isActive).map(\.guideKey)))
            self?.change(\.recordingChannels, to: Set(schedules.filter { $0.status == "recording" }.compactMap(\.channel_name)))
            self?.change(\.recordingChannelKeys, to: Set(schedules.filter { $0.status == "recording" }.compactMap(\.channelIdentityKey)))
        }
    }
}

/// The transient result of a schedule, cancel or delete.
@MainActor
final class ActionState: ObservableObject {
    @Published var mutationBusy = false
    @Published var actionMessage: String?
    @Published var actionError: String?
}
