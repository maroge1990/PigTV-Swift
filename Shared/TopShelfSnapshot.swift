import Foundation

// A4.1: shared by the app and its extensions (the Top Shelf; Siri reads it
// too). The app writes a small snapshot of up to 12 channels into the App
// Group container whenever the guide or favourites load; extensions only
// read it and never touch the network. Nothing secret goes in: channel
// identity, name, number, an absolute logo URL (served unauthenticated by
// the server's /api/logo route, or the provider's own URL) and now/next
// titles and times.

nonisolated struct TopShelfSnapshot: Codable, Equatable, Sendable {
    static let appGroup = "group.au.markrogers.PigTV"
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

        /// "503 · Fox Footy", or the name alone without a number.
        var title: String { number.map { "\($0) · \(name)" } ?? name }

        /// What is on at `date` among the saved slots.
        func programme(at date: Date) -> Slot? {
            programmes.first { $0.start <= date && date < $0.end }
        }

        var playURL: URL { PigTVLink.playURL(sourceId: sourceId, id: id, name: name, number: number) }
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

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(fileName)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) -> TopShelfSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try? decoder.decode(TopShelfSnapshot.self, from: data)
    }

    static func read() -> TopShelfSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    /// Writes atomically; false when the App Group container is unavailable
    /// (for example before the group is registered for a device build).
    @discardableResult
    func write() -> Bool {
        guard let url = Self.fileURL, let data = try? encoded() else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }
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
