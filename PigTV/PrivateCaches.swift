import Foundation
import CryptoKit

/// Who a private cache belongs to: the server (normalised base URL, so a
/// second server never reads the first one's data), the account on it, and a
/// schema version (bumping it orphans every older file instead of decoding it
/// with the wrong shape). Artwork is not private and is keyed by URL instead.
nonisolated struct CacheScope: Equatable, Sendable {
    /// Bump when a private cache's on-disk format changes.
    static let schemaVersion = 2

    let server: String
    let account: String

    init(address: ServerAddress, accountID: Int?) {
        // `ServerAddress` already lower-cases the host and drops default ports.
        server = address.url.absoluteString
        account = accountID.map(String.init) ?? "none"
    }

    /// A short stable digest: the file name never contains the server text.
    var digest: String {
        let hash = SHA256.hash(data: Data("v\(Self.schemaVersion)|\(server)|\(account)".utf8))
        return hash.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

/// One account's guide cache file. Sign-out (or switching server/account)
/// retires the store: the file is deleted and any save still in flight from
/// the old session is dropped, so a late callback cannot recreate the file
/// or write into the next session's cache.
nonisolated final class GuideCacheStore: @unchecked Sendable {
    static let defaultDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PigTVGuide", isDirectory: true)
    }()

    let fileURL: URL
    private let lock = NSLock()
    private var retired = false

    init(scope: CacheScope, directory: URL = GuideCacheStore.defaultDirectory) {
        fileURL = directory.appendingPathComponent("guide-v\(CacheScope.schemaVersion)-\(scope.digest).json")
        Self.removeLegacyFileOnce()
    }

    func load() -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !retired else { return nil }
        return try? Data(contentsOf: fileURL)
    }

    /// Returns false when the store was retired and the write was dropped.
    @discardableResult
    func save(_ data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !retired else { return false }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (try? data.write(to: fileURL, options: .atomic)) != nil
    }

    func retire() {
        lock.lock(); defer { lock.unlock() }
        retired = true
        try? FileManager.default.removeItem(at: fileURL)
    }

    var isRetired: Bool { lock.lock(); defer { lock.unlock() }; return retired }

    /// The old single `pigtv-guide.json` (one file for every server and
    /// account) is deleted once, the first time any store is created.
    private static let legacyRemoval: Void = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        try? FileManager.default.removeItem(at: base.appendingPathComponent("pigtv-guide.json"))
    }()
    private static func removeLegacyFileOnce() { _ = legacyRemoval }
}

/// Artwork cache keys. The canonical key is the absolute URL the logo
/// resolves to on its server, minus anything that identifies the session
/// (`token`, fragment): two servers' `/api/logo/1` are different keys, and a
/// rotated token does not orphan the cache.
nonisolated enum ArtworkKey {
    static func canonical(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url.absoluteString }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = parts.host?.lowercased()
        if let port = parts.port, port == (parts.scheme == "https" ? 443 : 80) { parts.port = nil }
        parts.fragment = nil
        let kept = (parts.queryItems ?? []).filter { $0.name.lowercased() != "token" }
        parts.queryItems = kept.isEmpty ? nil : kept
        return parts.string ?? url.absoluteString
    }

    static func key(logo: String, address: ServerAddress) -> String? {
        guard !logo.isEmpty, let url = URL(string: logo, relativeTo: address.url)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return canonical(url)
    }
}

/// Artwork on disk, bounded: least recently used files go first once the
/// folder is over its size cap, and anything untouched for the age cap goes
/// regardless. Reads refresh the file's date, so it is a real LRU. Everything
/// here does file I/O: call it off the main actor.
nonisolated struct ArtworkDiskStore: Sendable {
    static let maxBytes = 50 * 1024 * 1024
    static let maxAge: TimeInterval = 30 * 24 * 3600

    let directory: URL

    /// The app's store. Created on first use (sign-in/restore, i.e. launch),
    /// which also prunes it in the background and removes the pre-R14 folder.
    static let shared: ArtworkDiskStore = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let store = ArtworkDiskStore(directory: base.appendingPathComponent("PigTVArtwork-v2", isDirectory: true))
        Task.detached(priority: .background) {
            try? FileManager.default.removeItem(at: base.appendingPathComponent("PigTVArtwork", isDirectory: true))
            store.prune()
        }
        return store
    }()

    func fileURL(forKey key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        return directory.appendingPathComponent(digest.map { String(format: "%02x", $0) }.joined())
    }

    func read(key: String, now: Date = Date()) -> Data? {
        let url = fileURL(forKey: key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: url.path)
        return data
    }

    func write(_ data: Data, key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(forKey: key), options: .atomic)
    }

    func prune(maxBytes: Int = ArtworkDiskStore.maxBytes, maxAge: TimeInterval = ArtworkDiskStore.maxAge, now: Date = Date()) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return }
        var entries: [(url: URL, date: Date, size: Int)] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let date = values?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(date) > maxAge { try? FileManager.default.removeItem(at: url); continue }
            entries.append((url, date, values?.fileSize ?? 0))
        }
        var total = entries.reduce(0) { $0 + $1.size }
        for entry in entries.sorted(by: { $0.date < $1.date }) where total > maxBytes {
            try? FileManager.default.removeItem(at: entry.url)
            total -= entry.size
        }
    }
}
