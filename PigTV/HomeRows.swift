import Foundation

// Home screen (build 28): the data behind each row, as pure functions so the
// choices (what "continue watching" is, what counts as starting soon, which
// channels are sport, the order of recordings) are unit-tested
// (`HomeRowsTests`). HomeView only draws what these return.

/// One channel as Home draws it: identity, what it shows, and its programmes
/// (the guide's day when loaded, else the server's now/next).
nonisolated struct HomeChannel: Identifiable, Equatable, Sendable {
    let sourceId: Int
    let rawID: String
    let name: String
    var number: Int? = nil
    var logo: String? = nil
    var category: String? = nil
    var stableId: String? = nil
    var programmes: [GuideProgramme] = []

    var id: String { "\(sourceId):\(rawID)" }
    var identityKey: String { stableId.map { "\(sourceId):s:\($0)" } ?? id }

    func current(at now: Date) -> GuideProgramme? { GuideNavigation.programme(in: programmes, at: now) }
    func onNow(at now: Date) -> OnNowRow { OnNowRow.make(programmes: programmes, now: now) }
}

/// The last channel played on this device, kept across launches
/// (UserDefaults `pigtv.home.lastChannel`), for the "Continue watching" hero.
nonisolated struct LastWatched: Codable, Equatable, Sendable {
    let sourceId: Int
    let rawID: String
    let name: String
    var number: Int? = nil
    var logo: String? = nil
    var category: String? = nil
    var stableId: String? = nil
    var watchedAt: Date = Date()

    var id: String { "\(sourceId):\(rawID)" }
    var identityKey: String { stableId.map { "\(sourceId):s:\($0)" } ?? id }

    /// The channel from its own fields alone (no programmes).
    var channel: HomeChannel {
        HomeChannel(sourceId: sourceId, rawID: rawID, name: name, number: number, logo: logo,
                    category: category, stableId: stableId)
    }

    static let key = "pigtv.home.lastChannel"

    static func load(from defaults: UserDefaults = .standard) -> LastWatched? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(LastWatched.self, from: data)
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    static func clear(from defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}

/// A programme about to start on a favourite channel.
nonisolated struct HomeSoonItem: Identifiable, Equatable, Sendable {
    let channel: HomeChannel
    let programme: GuideProgramme
    var id: String { "\(channel.id)|\(Int64(programme.startTime))" }
}

nonisolated enum HomeRows {
    /// "Starting soon" looks this far ahead.
    static let startingSoonWindow: TimeInterval = 3600
    static let rowLimit = 20

    /// The hero's channel: this device's last played channel (resolved
    /// against the guide by `lookup`, else from its remembered fields), or,
    /// with no local memory, the server's most recent watch.
    static func continueWatching(last: LastWatched?, recent: [HomeChannel],
                                 lookup: (LastWatched) -> HomeChannel?) -> HomeChannel? {
        if let last { return lookup(last) ?? last.channel }
        return recent.first
    }

    /// Recently watched, without the hero's channel and without duplicates
    /// (a cross-listed channel counts once).
    static func recentlyWatched(_ recent: [HomeChannel], excluding hero: HomeChannel?) -> [HomeChannel] {
        var seen = Set<String>()
        if let hero { seen.insert(hero.identityKey) }
        return Array(recent.filter { seen.insert($0.identityKey).inserted }.prefix(rowLimit))
    }

    /// Channels with a programme on now, in their given order, once each.
    static func onNow(_ channels: [HomeChannel], now: Date) -> [HomeChannel] {
        var seen = Set<String>()
        return Array(channels.filter { $0.current(at: now) != nil && seen.insert($0.identityKey).inserted }.prefix(rowLimit))
    }

    /// The next programme on each favourite that starts after `now` and
    /// within `window`, soonest first (ties keep the favourites' order).
    static func startingSoon(_ favourites: [HomeChannel], now: Date,
                             window: TimeInterval = startingSoonWindow) -> [HomeSoonItem] {
        var seen = Set<String>()
        let limit = now.addingTimeInterval(window)
        let items = favourites.enumerated().compactMap { index, channel -> (Int, HomeSoonItem)? in
            guard seen.insert(channel.identityKey).inserted,
                  let next = channel.programmes
                    .filter({ $0.end > $0.start && $0.start > now && $0.start <= limit })
                    .min(by: { $0.start < $1.start }) else { return nil }
            return (index, HomeSoonItem(channel: channel, programme: next))
        }
        return Array(items.sorted { ($0.1.programme.start, $0.0) < ($1.1.programme.start, $1.0) }.map(\.1).prefix(rowLimit))
    }

    /// "in 12 min" (rounded up, so a programme 30 s away reads "in 1 min").
    static func countdown(to start: Date, now: Date) -> String {
        let seconds = start.timeIntervalSince(now)
        guard seconds > 0 else { return "starting now" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "in \(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "in \(hours) h" : "in \(hours) h \(rest) min"
    }

    /// C-H: channels in categories marked sport with something on now, live
    /// events first (then guide order). Empty without the server flag or
    /// when no category is marked.
    static func sportOnNow(_ channels: [HomeChannel], categories: [Category], enabled: Bool,
                           now: Date, limit: Int = rowLimit) -> [HomeChannel] {
        let sport = categories.filter(\.sport)
        guard enabled, !sport.isEmpty else { return [] }
        // A guide row's category is the category id or its name (as stored).
        let keys = Set(sport.flatMap { ["\($0.sourceId)|\($0.rawID)", "\($0.sourceId)|\($0.name)"] })
        var seen = Set<String>()
        let matches = channels.enumerated().compactMap { index, channel -> (Int, Bool, HomeChannel)? in
            guard let category = channel.category, keys.contains("\(channel.sourceId)|\(category)"),
                  let current = channel.current(at: now), seen.insert(channel.identityKey).inserted else { return nil }
            return (index, isLiveEvent(current), channel)
        }
        return Array(matches.sorted { lhs, rhs in
            lhs.1 != rhs.1 ? lhs.1 : lhs.0 < rhs.0
        }.map(\.2).prefix(limit))
    }

    /// A live event, as EPGs mark it: the word "live" in the title
    /// ("LIVE: …", "… Live", "(Live)"), not "Lively" or "Liverpool".
    static func isLiveEvent(_ programme: GuideProgramme) -> Bool {
        programme.title.range(of: #"(?i)(^|[^a-z])live($|[^a-z])"#, options: .regularExpression) != nil
    }

    /// Recordings for Home: in progress first (newest first), then the
    /// newest completed ones. Scheduled, failed and other states are left to
    /// the Recordings tab.
    static func recordings(_ recordings: [Recording], limit: Int = 12) -> [Recording] {
        let newest: (Recording, Recording) -> Bool = { ($0.started_at ?? 0, $0.id) > ($1.started_at ?? 0, $1.id) }
        let recording = recordings.filter { $0.status == "recording" }.sorted(by: newest)
        let completed = recordings.filter { $0.status == "completed" }.sorted(by: newest)
        return Array((recording + completed).prefix(limit))
    }

    /// 0…1 of a recording already watched (the player's resume point), or
    /// nil when nothing useful is remembered.
    static func resumeFraction(position: Double, duration: Double?) -> Double? {
        guard let duration, duration > 0, position > 10, position < duration - 30 else { return nil }
        return min(1, position / duration)
    }
}
