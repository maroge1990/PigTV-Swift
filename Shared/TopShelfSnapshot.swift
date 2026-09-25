import Foundation
import os

// A4.1: shared by the app and its extensions (the Top Shelf; Siri reads it
// too). The app writes a small snapshot of up to 12 channels into the App
// Group container whenever the guide or favourites load; extensions only
// read it and never touch the network. Nothing secret goes in: channel
// identity, name, number, an absolute logo URL (served unauthenticated by
// the server's /api/logo route, or the provider's own URL) and now/next
// titles and times.

nonisolated struct TopShelfSnapshot: Codable, Equatable, Sendable {
    static let appGroup = AppGroupStorage.appGroup
    static let fileName = "topshelf-snapshot.json"
    static let limit = 12

    /// "favourites" or "channels" (the first rows of the lineup).
    var kind: String
    var channels: [Entry]
    var savedAt: Date

    nonisolated struct Entry: Codable, Equatable, Sendable {
        var id: String
        var sourceId: Int
        var name: String
        var number: Int?
        var logo: URL?
        /// Now, then next (either may be missing).
        var programmes: [Slot]
        /// Build 32 (tvOS): card images the app rendered for this channel,
        /// in the App Group's `Library/Caches/topshelf/`. Absent in older
        /// snapshots and when rendering failed (the logo URL is used then).
        var cards: [Card]? = nil

        /// The item's title: the channel name. Build 29 dropped the "503 · "
        /// prefix (Mark: channel numbers are not important to him); the number
        /// is still saved for the play link.
        var title: String { name }

        /// What is on at `date` among the saved slots.
        func programme(at date: Date) -> Slot? {
            programmes.first { $0.start <= date && date < $0.end }
        }

        var playURL: URL { PigTVLink.playURL(sourceId: sourceId, id: id, name: name, number: number) }

        /// The card for `date`: the one drawn for the programme on then, or
        /// the channel's own card (no programme) when there is one.
        func card(at date: Date) -> Card? {
            cards?.first { card in
                guard let start = card.start, let end = card.end else { return false }
                return start <= date && date < end
            } ?? cards?.first { $0.start == nil }
        }

        /// What the Top Shelf item shows: the rendered card's file URL when
        /// one applies and exists, else the logo's URL (the pre-build-32
        /// behaviour).
        func imageURL(at date: Date, container: URL? = AppGroupStorage.containerURL) -> URL? {
            if let card = card(at: date), let url = TopShelfCards.fileURL(card.file, in: container),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            return logo
        }
    }

    /// A rendered card (build 32): its file name in the cards directory and
    /// the programme it shows (both nil for a channel-only card).
    nonisolated struct Card: Codable, Equatable, Sendable {
        var file: String
        var start: Date?
        var end: Date?
    }

    nonisolated struct Slot: Codable, Equatable, Sendable {
        var title: String
        var start: Date
        var end: Date
    }

    var sectionTitle: String { kind == "favourites" ? "Favourites" : "Channels" }

    /// Equal apart from when it was saved (so an unchanged list is not rewritten).
    func sameContent(as other: TopShelfSnapshot?) -> Bool {
        guard let other else { return false }
        return kind == other.kind && channels == other.channels
    }

    // MARK: Storage

    /// The App Group container, or nil when this process is not entitled to
    /// it (a device build whose provisioning lacks the group).
    static var containerURL: URL? { AppGroupStorage.containerURL }

    /// The snapshot's path inside a container directory (the App Group's by
    /// default; tests pass a temporary one): `<container>/Library/Caches/`.
    static func fileURL(in container: URL?) -> URL? {
        AppGroupStorage.fileURL(fileName, in: container)
    }

    static var fileURL: URL? { fileURL(in: containerURL) }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) -> TopShelfSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do { return try decoder.decode(TopShelfSnapshot.self, from: data) }
        catch {
            TopShelfLog.logger.error("snapshot: decode failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Reads the snapshot, logging each step (Console: subsystem
    /// au.markrogers.PigTV.TopShelf) so a device shows why nothing appears.
    static func read(container: URL? = containerURL) -> TopShelfSnapshot? {
        guard let url = fileURL(in: container) else {
            TopShelfLog.logger.error("read: no App Group container for \(appGroup, privacy: .public) (entitlement or provisioning missing)")
            return nil
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            TopShelfLog.logger.notice("read: no snapshot at \(url.path, privacy: .public) (the app has not written one)")
            return nil
        }
        do {
            let data = try Data(contentsOf: url)
            let snapshot = decode(data)
            TopShelfLog.logger.notice("read: \(data.count) bytes, \(snapshot?.channels.count ?? -1) channels")
            return snapshot
        } catch {
            TopShelfLog.logger.error("read: \(url.path, privacy: .public) unreadable: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Writes atomically; false when the App Group container is unavailable
    /// (for example before the group is registered for a device build).
    @discardableResult
    func write(container: URL? = TopShelfSnapshot.containerURL) -> Bool {
        guard let url = Self.fileURL(in: container) else {
            TopShelfLog.logger.error("write: no App Group container for \(Self.appGroup, privacy: .public) (entitlement or provisioning missing)")
            return false
        }
        do {
            try AppGroupStorage.createDirectory(for: url)
            try encoded().write(to: url, options: .atomic)
            TopShelfLog.logger.notice("write: \(channels.count) \(kind, privacy: .public) channels to \(url.path, privacy: .public)")
            return true
        } catch {
            TopShelfLog.logger.error("write: failed at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }
}

/// Where the app and its extensions keep shared files. Build 29: on tvOS
/// the root of an App Group container is not writable (the device refused
/// the snapshot with NSCocoaErrorDomain 513 / POSIX 1 "Operation not
/// permitted"); an app may only write under `Library/Caches` inside it (tvOS
/// has no persistent Documents). Caches can be purged by the system, which
/// is fine: the snapshot and the channel directory are rewritten whenever
/// the guide or favourites load. iOS uses the same place so both platforms
/// share one path.
nonisolated enum AppGroupStorage {
    static let appGroup = "group.au.markrogers.PigTV"

    /// The App Group container, or nil when this process is not entitled to it.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    /// `<container>/Library/Caches`, the writable directory inside a container.
    static func directory(in container: URL?) -> URL? {
        container?.appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
    }

    /// A shared file's path: `<container>/Library/Caches/<name>`.
    static func fileURL(_ name: String, in container: URL?) -> URL? {
        directory(in: container)?.appendingPathComponent(name, isDirectory: false)
    }

    /// Creates the file's directory if needed (writers call this; a reader
    /// only looks, so a missing directory reads as "nothing written").
    static func createDirectory(for file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    }
}

/// Build 32: the Top Shelf card images, `<container>/Library/Caches/topshelf/`.
/// The app renders and writes them (TopShelfCards.swift); the extension
/// only hands their file URLs to tvOS.
nonisolated enum TopShelfCards {
    static let directoryName = "topshelf"

    static func directory(in container: URL?) -> URL? {
        AppGroupStorage.directory(in: container)?.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func fileURL(_ name: String, in container: URL?) -> URL? {
        // Only plain file names (the app makes them); never a path.
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return nil }
        return directory(in: container)?.appendingPathComponent(name, isDirectory: false)
    }

    /// Writes one card atomically, creating the directory.
    @discardableResult
    static func write(_ data: Data, named name: String, in container: URL?) -> Bool {
        guard let url = fileURL(name, in: container) else { return false }
        do {
            try AppGroupStorage.createDirectory(for: url)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            TopShelfLog.logger.error("cards: write failed at \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }

    static func exists(_ name: String, in container: URL?) -> Bool {
        fileURL(name, in: container).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// Deletes every card not in `keeping`; returns how many were removed.
    @discardableResult
    static func prune(keeping: Set<String>, in container: URL?) -> Int {
        guard let directory = directory(in: container),
              let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var removed = 0
        for name in names where !keeping.contains(name) {
            if (try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }

    /// Sign-out: every card goes.
    static func removeAll(in container: URL?) {
        guard let directory = directory(in: container) else { return }
        try? FileManager.default.removeItem(at: directory)
    }

    /// Cards the snapshot refers to that exist on disk.
    static func renderedCount(for snapshot: TopShelfSnapshot?, in container: URL?) -> Int {
        (snapshot?.channels ?? []).flatMap { $0.cards ?? [] }.filter { exists($0.file, in: container) }.count
    }
}

/// Top Shelf diagnostics, in both the app and the extension. On a device:
/// Console.app → the Apple TV → filter "subsystem:au.markrogers.PigTV.TopShelf"
/// (the category is the process's bundle identifier).
nonisolated enum TopShelfLog {
    static let subsystem = "au.markrogers.PigTV.TopShelf"
    static let logger = Logger(subsystem: subsystem, category: Bundle.main.bundleIdentifier ?? "unknown")
}

/// `pigtv://play?sourceId=…&id=…[&name=…&number=…]`: from Top Shelf items
/// and the Siri intent. Name and number let the app build a channel when
/// the guide has not loaded yet.
nonisolated enum PigTVLink {
    static let scheme = "pigtv"

    struct Play: Equatable, Sendable {
        var sourceId: Int
        var id: String
        var name: String?
        var number: Int?
        /// The app's channel identity ("sourceId:id").
        var channelKey: String { "\(sourceId):\(id)" }
    }

    static func playURL(sourceId: Int, id: String, name: String? = nil, number: Int? = nil) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "play"
        var items = [URLQueryItem(name: "sourceId", value: String(sourceId)), URLQueryItem(name: "id", value: id)]
        if let name { items.append(URLQueryItem(name: "name", value: name)) }
        if let number { items.append(URLQueryItem(name: "number", value: String(number))) }
        parts.queryItems = items
        // `+` is legal in a query but read as a space by some parsers; encode it.
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return parts.url!
    }

    /// `pigtv://home`: open the app on Home (Siri's "Open PigTV", build 31).
    static let homeURL = URL(string: "\(scheme)://home")!

    static func isHome(_ url: URL) -> Bool {
        url.scheme?.lowercased() == scheme && url.host?.lowercased() == "home"
    }

    static func parse(_ url: URL) -> Play? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "play",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let sourceText = value("sourceId"), let sourceId = Int(sourceText), let id = value("id") else { return nil }
        let number = value("number").flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
        let name = value("name").map { String($0.prefix(200)) }
        return Play(sourceId: sourceId, id: id, name: name, number: number)
    }
}

// MARK: Diagnostics (build 31)

/// What the Top Shelf extension did the last time tvOS asked it for
/// content, written by the extension next to the snapshot so the app's
/// Settings can show whether tvOS is asking at all (build 31: tvOS never
/// could: the extension exited as soon as it launched; see ContentProvider).
nonisolated struct TopShelfExtensionStatus: Codable, Equatable, Sendable {
    static let fileName = "topshelf-extension-status.json"
    var askedAt: Date
    /// Items returned (0 with no snapshot: the static image is shown).
    var items: Int
    /// "returned 12 items", "no snapshot", "no App Group container"…
    var note: String

    static func read(container: URL? = AppGroupStorage.containerURL) -> TopShelfExtensionStatus? {
        guard let url = AppGroupStorage.fileURL(fileName, in: container), let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(TopShelfExtensionStatus.self, from: data)
    }

    @discardableResult
    func write(container: URL? = AppGroupStorage.containerURL) -> Bool {
        guard let url = AppGroupStorage.fileURL(Self.fileName, in: container) else { return false }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        do {
            try AppGroupStorage.createDirectory(for: url)
            try encoder.encode(self).write(to: url, options: .atomic)
            return true
        } catch {
            TopShelfLog.logger.error("status: write failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}

/// Settings → Diagnostics (tvOS): one line about the app's snapshot and one
/// about the extension, read from the App Group (pure apart from the reads;
/// tests pass a temporary container).
nonisolated enum TopShelfDiagnostics {
    struct Lines: Equatable, Sendable {
        var snapshot: String
        var extensionStatus: String
    }

    static func lines(container: URL? = AppGroupStorage.containerURL,
                      format: (Date) -> String = { $0.formatted(date: .abbreviated, time: .shortened) }) -> Lines {
        guard let container, let url = TopShelfSnapshot.fileURL(in: container) else {
            return Lines(snapshot: "Not written: no App Group (entitlement or provisioning missing)",
                         extensionStatus: "Unknown: no App Group")
        }
        let snapshot: String
        if let data = try? Data(contentsOf: url) {
            let written = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
            let decoded = TopShelfSnapshot.decode(data)
            let count = decoded?.channels.count
            let when = (decoded?.savedAt ?? written).map(format) ?? "at an unknown time"
            // Build 32: and how many card images it points at exist.
            let cards = TopShelfCards.renderedCount(for: decoded, in: container)
            let items = count.map { "\($0) \($0 == 1 ? "item" : "items"), \(cards) \(cards == 1 ? "card" : "cards") rendered" }
            snapshot = "Written \(when), \(items ?? "unreadable") · App Group OK"
        } else {
            snapshot = "Not written yet · App Group OK"
        }
        let status = TopShelfExtensionStatus.read(container: container)
            .map { "Last asked \(format($0.askedAt)): \($0.note)" }
            ?? "Not asked yet: move to PigTV in the top row"
        return Lines(snapshot: snapshot, extensionStatus: status)
    }
}
