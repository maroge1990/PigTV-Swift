import Foundation
import Combine

/// C-I: the next 72 hours of sport events (`GET sports/events?hours=72`;
/// an older server clamps it silently). The Guide's "Watch on…" reads them.
/// One per signed-in session, owned by BrowseModel.
@MainActor
final class SportModel: ObservableObject {
    static let hours = 72

    @Published private(set) var events: [SportEvent] = []
    /// True once one load has finished.
    @Published private(set) var loaded = false
    @Published private(set) var error: String?
    /// Set by the offline fixtures: no requests.
    var isFixture = false
    let client: APIClient
    private var inFlight: Task<Void, Never>?

    init(client: APIClient) { self.client = client }

    /// On now (start ≤ now < end), replays left out, by start time.
    var live: [SportEvent] { upcoming { $0.start <= $1 } }
    /// Starting within the next hour, replays left out, by start time.
    var soon: [SportEvent] {
        upcoming { $0.start > $1 && $0.start <= $1.addingTimeInterval(SportRows.soonWindow) }
    }

    private func upcoming(_ include: (SportEvent, Date) -> Bool) -> [SportEvent] {
        let now = Date()
        return events.enumerated()
            .filter { !$0.element.isReplay && $0.element.end > now && include($0.element, now) }
            .sorted { ($0.element.startTime, $0.offset) < ($1.element.startTime, $1.offset) }
            .map(\.element)
    }

    /// Fetches the events. Concurrent callers share one request; an older
    /// server without the route (404) simply has none.
    func load() async {
        let sp = PigTVSignpost.begin("SportLoad"); defer { PigTVSignpost.end("SportLoad", sp) }
        if let inFlight { await inFlight.value; return }
        guard !isFixture else { loaded = true; return }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let response: SportEventsResponse = try await self.client.decodedOffMain("sports/events",
                    query: [URLQueryItem(name: "hours", value: String(Self.hours))])
                if response.events != self.events { self.events = response.events }
                self.error = nil
            } catch is CancellationError {
            } catch {
                if error as? PigTVError == .http(404) {
                    if !self.events.isEmpty { self.events = [] }
                } else { self.error = UserMessage.text(for: error) }
            }
            self.loaded = true
        }
        inFlight = task
        await task.value
        inFlight = nil
    }

    #if DEBUG
    func setFixture(_ events: [SportEvent]) {
        isFixture = true
        self.events = events
        loaded = true
    }
    #endif
}
