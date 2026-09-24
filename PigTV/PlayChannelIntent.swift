import Foundation
import AppIntents
import Combine
import os

// A4.5: Siri / Shortcuts "Play channel". The channel parameter is an
// AppEntity whose query searches a small channel directory the app keeps in
// the App Group container (every guide channel's id, name and number; the
// Top Shelf snapshot as a fallback). `perform` opens the app and hands the
// channel to the same path as a pigtv://play deep link (AppModel.open).

// MARK: Channel directory

nonisolated struct ChannelDirectory: Codable, Equatable, Sendable {
    static let fileName = "channel-directory.json"

    nonisolated struct Entry: Codable, Equatable, Hashable, Sendable {
        var id: String
        var sourceId: Int
        var name: String
        var number: Int?
        var key: String { "\(sourceId):\(id)" }
        var title: String { number.map { "\($0) \(name)" } ?? name }
    }

    var channels: [Entry]

    /// `<App Group>/Library/Caches/channel-directory.json` (build 29: the
    /// container's root is not writable on tvOS; see `AppGroupStorage`).
    static func fileURL(in container: URL?) -> URL? { AppGroupStorage.fileURL(fileName, in: container) }

    static var fileURL: URL? { fileURL(in: AppGroupStorage.containerURL) }

    static func read(container: URL? = AppGroupStorage.containerURL) -> ChannelDirectory? {
        guard let url = fileURL(in: container), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ChannelDirectory.self, from: data)
    }

    @discardableResult
    func write(container: URL? = AppGroupStorage.containerURL) -> Bool {
        guard let url = Self.fileURL(in: container) else {
            TopShelfLog.logger.error("directory: no App Group container for \(AppGroupStorage.appGroup, privacy: .public)")
            return false
        }
        do {
            try AppGroupStorage.createDirectory(for: url)
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
            return true
        } catch {
            TopShelfLog.logger.error("directory: write failed at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    /// Channels matching what was said or typed, best first: a number
    /// ("503", "channel 503") matches that number exactly; otherwise names
    /// that equal, then start with, then contain the text (case and
    /// accents ignored), then names containing every word. Each channel once.
    static func match(_ text: String, in entries: [Entry], limit: Int = 20) -> [Entry] {
        var query = normalise(text)
        for prefix in ["channel ", "number "] where query.hasPrefix(prefix) {
            query = String(query.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        guard !query.isEmpty else { return [] }
        if let number = Int(query) {
            return Array(entries.filter { $0.number == number }.prefix(limit))
        }
        let words = query.split(separator: " ").map(String.init)
        var ranked: [(rank: Int, index: Int, entry: Entry)] = []
        for (index, entry) in entries.enumerated() {
            let name = normalise(entry.name)
            let rank: Int
            if name == query { rank = 0 }
            else if name.hasPrefix(query) { rank = 1 }
            else if name.contains(query) { rank = 2 }
            else if words.count > 1, words.allSatisfy({ name.contains($0) }) { rank = 3 }
            else { continue }
            ranked.append((rank, index, entry))
        }
        var seen = Set<String>()
        return Array(ranked.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .map(\.entry).filter { seen.insert($0.key).inserted }.prefix(limit))
    }

    static func normalise(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }
}

extension BrowseModel {
    /// Saves every guide channel's id, name and number for the Siri query
    /// (once the whole guide has loaded; unchanged lists are not rewritten).
    func exportChannelDirectory() {
        let entries = guide.map {
            ChannelDirectory.Entry(id: $0.rawID, sourceId: $0.sourceId, name: $0.name, number: number(for: $0))
        }
        guard !entries.isEmpty, entries != PlayLinkInbox.lastDirectory else { return }
        PlayLinkInbox.lastDirectory = entries
        Task.detached(priority: .utility) {
            ChannelDirectory(channels: entries).write()
            PigTVShortcuts.updateAppShortcutParameters()
        }
    }
}

// MARK: Hand-off to the app

/// Play requests from the intent, consumed by ContentView (which passes
/// them to AppModel.open like a deep link). Latest wins; kept until
/// consumed, so a request made while the app is still launching survives.
@MainActor
final class PlayLinkInbox: ObservableObject {
    static let shared = PlayLinkInbox()
    @Published private(set) var pending: URL?
    static var lastDirectory: [ChannelDirectory.Entry]?

    func submit(_ url: URL) { pending = url }

    func take() -> URL? {
        defer { pending = nil }
        return pending
    }
}

// MARK: Entity and query

// Swift 6: App Intents reads entities, queries and shortcuts from its own
// queues, so these types are nonisolated (not the app's default main actor);
// only perform() runs on the main actor.
nonisolated struct ChannelEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Channel"
    static let defaultQuery = ChannelQuery()

    /// "sourceId:id", the app's channel identity.
    let id: String
    let sourceId: Int
    let rawID: String
    let name: String
    let number: Int?

    init(_ entry: ChannelDirectory.Entry) {
        id = entry.key; sourceId = entry.sourceId; rawID = entry.id; name = entry.name; number = entry.number
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(number.map { "\($0) " } ?? "")\(name)")
    }

    var playURL: URL { PigTVLink.playURL(sourceId: sourceId, id: rawID, name: name, number: number) }
}

nonisolated struct ChannelQuery: EntityStringQuery {
    /// The directory, else the Top Shelf snapshot's channels.
    private static func entries() -> [ChannelDirectory.Entry] {
        if let directory = ChannelDirectory.read(), !directory.channels.isEmpty { return directory.channels }
        return (TopShelfSnapshot.read()?.channels ?? []).map {
            ChannelDirectory.Entry(id: $0.id, sourceId: $0.sourceId, name: $0.name, number: $0.number)
        }
    }

    func entities(for identifiers: [ChannelEntity.ID]) async throws -> [ChannelEntity] {
        let wanted = Set(identifiers)
        return Self.entries().filter { wanted.contains($0.key) }.map(ChannelEntity.init)
    }

    func entities(matching string: String) async throws -> [ChannelEntity] {
        ChannelDirectory.match(string, in: Self.entries()).map(ChannelEntity.init)
    }

    /// Favourites (or the first channels), as on the Top Shelf.
    func suggestedEntities() async throws -> [ChannelEntity] {
        let shelf = (TopShelfSnapshot.read()?.channels ?? []).map {
            ChannelDirectory.Entry(id: $0.id, sourceId: $0.sourceId, name: $0.name, number: $0.number)
        }
        return (shelf.isEmpty ? Array(Self.entries().prefix(TopShelfSnapshot.limit)) : shelf).map(ChannelEntity.init)
    }
}

// MARK: Intent and shortcut

// The intent keeps the default isolation (its @Parameter storage cannot be
// nonisolated); its static metadata is nonisolated, perform() hops to main.
struct PlayChannelIntent: AppIntent {
    nonisolated static let title: LocalizedStringResource = "Play channel"
    nonisolated static let description = IntentDescription("Opens PigTV and plays a live channel.")
    nonisolated static let openAppWhenRun = true

    @Parameter(title: "Channel")
    var channel: ChannelEntity

    nonisolated static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$channel)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        PlayLinkInbox.shared.submit(channel.playURL)
        return .result()
    }
}

nonisolated struct PigTVShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayChannelIntent(),
                    phrases: ["Play \(\.$channel) on \(.applicationName)"],
                    shortTitle: "Play channel",
                    systemImageName: "play.tv")
    }
}
