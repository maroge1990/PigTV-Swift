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

/// A1 (build 47): this device's saved recording positions (`RecordingProgress.swift`) are private
/// per server and account too: recording ids are per server, so a key without both let one login's
/// position resume another's recording with the same id.
nonisolated extension Recording {
    /// This device's saved-position key for recording `id` on `address` as `accountID`;
    /// nil without a known account (then nothing local is read or saved).
    static func localResumeKey(_ id: Int, address: ServerAddress, accountID: Int?) -> String? {
        guard let accountID else { return nil }
        let scope = SHA256.hash(data: Data("resume|\(address.url.absoluteString)|\(accountID)".utf8))
            .prefix(8).map { String(format: "%02x", $0) }.joined()
        return "pigtv.resume.\(scope).\(id)"
    }

    /// A1: delete the unscoped `pigtv.resume.<id>` keys of builds before 47. Returns how many went.
    @discardableResult
    static func retireLegacyResumeKeys(in defaults: UserDefaults = .standard) -> Int {
        let legacy = defaults.dictionaryRepresentation().keys.filter { key in
            guard key.hasPrefix("pigtv.resume.") else { return false }
            let rest = key.dropFirst("pigtv.resume.".count)
            return !rest.isEmpty && rest.allSatisfy(\.isNumber)
        }
        legacy.forEach(defaults.removeObject(forKey:))
        return legacy.count
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

/// A5 (build 48): the artwork folder's size, counted as files are written, so the cap holds while
/// the app runs and not only at launch. A5-R (build 53): every change to the folder - a write, a
/// replacement, a removal by a prune - runs alone (`change`) and is counted with what it actually
/// did, so the count is the folder's size, not an estimate: a prune between a replacement's size
/// read and its write can no longer leave bytes uncounted. One prune at a time; the folder is
/// listed once per prune, never once per image.
nonisolated final class ArtworkBudget: @unchecked Sendable {
    private let lock = NSLock()        // the state below
    private let files = NSLock()       // A5-R: one change to the folder at a time
    private var bytes: Int?            // nil until the first prune has counted the folder
    private var pruning = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var prunes = 0        // tests: how many times the folder was listed

    /// Tests only: called when a change has to wait for another one to finish (a scheduling
    /// barrier a test can observe). Nil in the app.
    nonisolated(unsafe) static var waitingForFiles: (@Sendable () -> Void)?

    private func owningFiles<T>(_ body: () -> T) -> T {
        if !files.try() {
            Self.waitingForFiles?()
            files.lock()
        }
        defer { files.unlock() }
        return body()
    }

    /// Runs `body` - one change to the folder - alone, and counts the bytes it reports (negative:
    /// removed) together with it.
    func change<T>(_ body: () -> (T, Int)) -> T {
        owningFiles {
            let (result, delta) = body()
            lock.withLock { bytes = bytes.map { $0 + delta } }
            return result
        }
    }

    /// The folder's size as `total` lists it, with no change running meanwhile.
    func recount(_ total: () -> Int) {
        owningFiles {
            let counted = total()
            lock.withLock { bytes = counted }
        }
    }

    /// True when the caller should start a prune now (over the cap, or never counted) and none runs.
    func claimPrune(limit: Int) -> Bool {
        lock.withLock {
            guard !pruning, bytes.map({ $0 > limit }) ?? true else { return false }
            pruning = true
            return true
        }
    }

    /// Claims a prune (launch). False when one is already running.
    func begin() -> Bool {
        lock.withLock {
            guard !pruning else { return false }
            pruning = true
            return true
        }
    }

    /// A prune ended; true when it should run again (still over the cap after it removed something:
    /// what was written meanwhile).
    func finished(limit: Int, removedAny: Bool) -> Bool {
        let (again, resume) = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
            prunes += 1
            if removedAny, (bytes ?? 0) > limit { return (true, []) }
            pruning = false
            defer { waiters = [] }
            return (false, waiters)
        }
        resume.forEach { $0.resume() }
        return again
    }

    var counted: Int? { lock.withLock { bytes } }

    /// Tests: no prune is running.
    func idle() async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock { () -> Bool in
                if pruning { waiters.append(continuation); return false }
                return true
            }
            if now { continuation.resume() }
        }
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
    /// A5: the folder's running size and its one prune at a time.
    let budget = ArtworkBudget()
    var limit = ArtworkDiskStore.maxBytes

    init(directory: URL, limit: Int = ArtworkDiskStore.maxBytes) {
        self.directory = directory
        self.limit = limit
    }

    /// The app's store. Created on first use (sign-in/restore, i.e. launch),
    /// which also prunes it in the background and removes the pre-R14 folder.
    static let shared: ArtworkDiskStore = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
        let store = ArtworkDiskStore(directory: base.appendingPathComponent("PigTVArtwork-v2", isDirectory: true))
        Task.detached(priority: .background) {
            try? FileManager.default.removeItem(at: base.appendingPathComponent("PigTVArtwork", isDirectory: true))
            if store.budget.begin() { store.pruneLoop() }
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

    /// Tests only: called by a write between reading the old file's size and replacing it. Nil in the app.
    nonisolated(unsafe) static var beforeReplacing: (@Sendable (String) -> Void)?

    private static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
    }

    func write(_ data: Data, key: String) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(forKey: key)
        // A5-R: the size read, the replacement and its count are one change: no prune or other
        // writer of the same file runs in between.
        let written = budget.change { () -> (Bool, Int) in
            let previous = Self.size(url)
            Self.beforeReplacing?(key)
            guard (try? data.write(to: url, options: .atomic)) != nil else { return (false, 0) }
            return (true, data.count - previous)
        }
        // A5: crossing the cap starts one pruning pass in the background.
        if written, budget.claimPrune(limit: limit) {
            let store = self
            Task.detached(priority: .background) { store.pruneLoop() }
        }
    }

    /// A5: prune, and again while what was written meanwhile keeps it over the cap.
    func pruneLoop() {
        repeat {} while budget.finished(limit: limit, removedAny: pruneOnce(maxBytes: limit).removed > 0)
    }

    /// A5-R: removes `url`, counting the size it has as it goes (a write may have replaced it since it was listed).
    private func remove(_ url: URL) -> Bool {
        budget.change { () -> (Bool, Int) in
            let size = Self.size(url)
            guard (try? FileManager.default.removeItem(at: url)) != nil else { return (false, 0) }
            return (true, -size)
        }
    }

    /// Removes expired files, then the least recently used until under `maxBytes`. Returns the bytes left.
    @discardableResult
    func prune(maxBytes: Int = ArtworkDiskStore.maxBytes, maxAge: TimeInterval = ArtworkDiskStore.maxAge, now: Date = Date()) -> Int {
        pruneOnce(maxBytes: maxBytes, maxAge: maxAge, now: now).left
    }

    private func pruneOnce(maxBytes: Int, maxAge: TimeInterval = ArtworkDiskStore.maxAge, now: Date = Date()) -> (left: Int, removed: Int) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let list = { try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) }
        if budget.counted == nil {
            budget.recount { (list() ?? []).reduce(0) { $0 + Self.size($1) } }
        }
        guard let urls = list() else { return (budget.counted ?? 0, 0) }
        var removed = 0
        var entries: [(url: URL, date: Date, size: Int)] = []
        for url in urls {
            let values = try? url.resourceValues(forKeys: Set(keys))
            let date = values?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(date) > maxAge {
                if remove(url) { removed += 1 }
                continue
            }
            entries.append((url, date, values?.fileSize ?? 0))
        }
        // What to remove is decided from this listing (its dates are its recency); what is counted is
        // what each removal really removed. Writes since the listing are a later pass's (pruneLoop).
        var listed = entries.reduce(0) { $0 + $1.size }
        for entry in entries.sorted(by: { $0.date < $1.date }) where listed > maxBytes {
            if remove(entry.url) { removed += 1 }
            listed -= entry.size
        }
        return (budget.counted ?? 0, removed)
    }
}
