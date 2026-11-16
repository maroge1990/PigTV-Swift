import Foundation
import Combine

// #57: the search answer's models are in LibrarySearchModels.swift (compiled into the contract checks too).

// MARK: Sections

/// Search's groups, in the order they are drawn (D-66): Team, Games, Programmes, Channels, Recordings.
nonisolated enum LibrarySearchSection: String, CaseIterable, Identifiable, Sendable {
    case teams, games, programmes, channels, recordings
    var id: String { rawValue }

    /// The group's heading. The guide's search (an older server) keeps its words for programmes: it looks a day ahead.
    func title(count: Int, source: LibrarySearchResults.Source = .server) -> String {
        if self == .programmes && source == .guide { return "Programmes · next 24 hours" }
        return switch self {
        case .teams: count == 1 ? "Team" : "Teams"
        case .games: count == 1 ? "Game" : "Games"
        case .programmes: count == 1 ? "Programme" : "Programmes"
        case .channels: count == 1 ? "Channel" : "Channels"
        case .recordings: count == 1 ? "Recording" : "Recordings"
        }
    }
}

/// What Search shows for one query. Pure; tested (LibrarySearchTests).
nonisolated struct LibrarySearchResults: Sendable {
    /// Where the results came from: the server's index, or the loaded guide (an older server, or the server failed).
    nonisolated enum Source: Equatable, Sendable { case server, guide }

    var query: String
    var source: Source
    var teams: [LibrarySearchTeam] = []
    var games: [SportEvent] = []
    var programmes: [GuideSearchHit] = []
    var channels: [GuideChannel] = []
    var recordings: [Recording] = []
    /// The server was asked and failed (not a 404): these are the guide's results instead.
    var serverFailed = false

    init(query: String, source: Source, teams: [LibrarySearchTeam] = [], games: [SportEvent] = [],
         programmes: [GuideSearchHit] = [], channels: [GuideChannel] = [], recordings: [Recording] = [],
         serverFailed: Bool = false) {
        self.query = query; self.source = source; self.teams = teams; self.games = games; self.programmes = programmes
        self.channels = channels; self.recordings = recordings; self.serverFailed = serverFailed
    }

    init(_ response: LibrarySearchResponse, query: String) {
        var seen = Set<String>()
        self.init(query: query, source: .server, teams: response.teams, games: response.events,
                  programmes: response.programmes,
                  // A cross-listed channel once (as the guide's search).
                  channels: response.channels.filter { seen.insert($0.identityKey).inserted },
                  recordings: response.recordings)
    }

    /// The loaded guide's search (`GuideSearch`): channels and programmes only.
    init(guide: GuideSearch.Results, query: String, serverFailed: Bool = false) {
        self.init(query: query, source: .guide, programmes: guide.programmes, channels: guide.channels,
                  serverFailed: serverFailed)
    }

    func count(_ section: LibrarySearchSection) -> Int {
        switch section {
        case .teams: teams.count
        case .games: games.count
        case .programmes: programmes.count
        case .channels: channels.count
        case .recordings: recordings.count
        }
    }

    /// The sections drawn: only those with results, in D-66's order.
    var sections: [LibrarySearchSection] { LibrarySearchSection.allCases.filter { count($0) > 0 } }
    var isEmpty: Bool { sections.isEmpty }
}

/// Four rows a section, then "Show all" in place.
nonisolated enum LibrarySearchLayout {
    static let collapsedRows = 4

    /// How many rows the section draws.
    static func visible(_ count: Int, expanded: Bool) -> Int { expanded ? count : min(count, collapsedRows) }
    /// "Show all" is offered: there are more rows than the collapsed section draws.
    static func offersShowAll(_ count: Int, expanded: Bool) -> Bool { !expanded && count > collapsedRows }
}

/// Follow on a team row: the sport whose followed leagues include the team's league. Pure; tested.
nonisolated enum LibrarySearchFollow {
    /// nil: the league is not followed (Follow is not offered: Settings › Sport adds a league first).
    static func sport(forLeague league: String, in follows: SportFollows?) -> String? {
        let wanted = league.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        return follows?.sports.first { entry in
            entry.leagues.contains { $0.caseInsensitiveCompare(wanted) == .orderedSame }
        }?.sport
    }
}

// MARK: Recent searches

/// The last eight searches on this device (not synced: D-66), newest first, each once (case aside).
@MainActor
struct RecentSearches {
    static let key = "pigtv.search.recent"
    static let limit = 8
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var all: [String] { Array((defaults.stringArray(forKey: Self.key) ?? []).prefix(Self.limit)) }

    /// Keeps a search that was run (two letters or more). -> the list now.
    @discardableResult
    func add(_ query: String) -> [String] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= LibrarySearchRunner.minimumLength else { return all }
        let list = Array(([text] + all.filter { $0.caseInsensitiveCompare(text) != .orderedSame }).prefix(Self.limit))
        defaults.set(list, forKey: Self.key)
        return list
    }

    @discardableResult
    func remove(_ query: String) -> [String] {
        let list = all.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        defaults.set(list, forKey: Self.key)
        return list
    }

    func clear() { defaults.removeObject(forKey: Self.key) }
}

// MARK: Running a search

extension APIClient {
    /// #57: `GET library/search`, decoded off the main actor. 400 for fewer than two letters; 404 on an older server.
    func librarySearch(_ query: String, limit: Int = LibrarySearchRunner.serverLimit) async throws -> LibrarySearchResponse {
        try await decodedOffMain("library/search", query: [URLQueryItem(name: "q", value: query),
                                                           URLQueryItem(name: "limit", value: String(limit))])
    }
}

/// Runs Search as the viewer types: 300 ms after the last change, one request at a time (a newer query cancels the one
/// before, and an answer for an older query is never shown). A 404 (an older server) switches to the loaded guide's
/// search for the rest of the page's life; any other failure shows the guide's results for that query, marked.
@MainActor
final class LibrarySearchRunner: ObservableObject {
    static let minimumLength = 2
    static let serverLimit = 20

    typealias Fetch = @MainActor (String) async throws -> LibrarySearchResponse
    typealias Fallback = @MainActor (String, _ serverFailed: Bool) async -> LibrarySearchResults

    /// The results shown (for `searched`); nil before the first search, and after the query is cleared.
    @Published private(set) var results: LibrarySearchResults?
    /// The query the results are for (trimmed).
    @Published private(set) var searched: String?
    /// A search is waiting or running for the current query.
    @Published private(set) var busy = false
    /// The server answered 404: it has no search endpoint, so the guide is searched instead.
    private(set) var serverMissing = false
    /// Searches go through the loaded guide (no server search, or an older server).
    var usesGuide: Bool { fetch == nil || serverMissing }

    private let fetch: Fetch?
    private let fallback: Fallback
    private let debounce: Duration
    private var task: Task<Void, Never>?
    private var generation = 0

    /// `fetch` nil: no server search at all (the offline fixtures).
    init(fetch: Fetch?, fallback: @escaping Fallback, debounce: Duration = .milliseconds(300)) {
        self.fetch = fetch
        self.fallback = fallback
        self.debounce = debounce
    }

    /// The query changed: searches it once it has stayed for the debounce, cancelling whatever was running.
    func update(_ query: String) {
        task?.cancel()
        generation += 1
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= Self.minimumLength else {
            task = nil
            busy = false
            results = nil
            searched = nil
            return
        }
        let mine = generation
        busy = true
        let debounce = self.debounce
        task = Task { [weak self] in
            do { try await Task.sleep(for: debounce) } catch { return }
            guard let self, !Task.isCancelled, self.generation == mine else { return }
            let found = await self.search(text)
            // A newer query (or a cleared one) owns the page now: this answer is dropped.
            guard let found, !Task.isCancelled, self.generation == mine else { return }
            self.results = found
            self.searched = text
            self.busy = false
        }
    }

    /// Searches again now (the guide finished loading, or a retry).
    func refresh(_ query: String) { update(query) }

    /// The results for `query` as it is on screen, or nil: an answer for an earlier query is never shown (or acted on)
    /// under a newer one; the page shows that it is searching instead.
    func results(for query: String) -> LibrarySearchResults? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let results, searched == text, text.count >= Self.minimumLength else { return nil }
        return results
    }

    /// The page is back on screen (a result's page was popped): a query whose search was interrupted (`cancel` on
    /// leaving) and has no results of its own is searched again.
    func resume(_ query: String) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= Self.minimumLength, results(for: text) == nil, !busy else { return }
        update(query)
    }

    func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        busy = false
    }

    /// nil: cancelled.
    private func search(_ text: String) async -> LibrarySearchResults? {
        guard let fetch, !serverMissing else { return await fallback(text, false) }
        do {
            let response = try await fetch(text)
            return LibrarySearchResults(response, query: text)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return nil }
            if Self.isOlderServer(error) {
                serverMissing = true
                return await fallback(text, false)
            }
            return await fallback(text, true)
        }
    }

    /// The server has no search endpoint (it is older than #57's index).
    static func isOlderServer(_ error: Error) -> Bool {
        if case PigTVError.http(404) = error { return true }
        return false
    }
}
