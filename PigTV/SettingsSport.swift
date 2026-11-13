import Foundation
import Combine

// Settings › Sport (D-44 batch 6, R5-SetSport-*): Score delay and the logos beside your sports. The rest of the page
// (Hide scores, your sports in order, suggestions, Add a sport) is `SportSettingsSection` over `SportFollowSettingsModel`.

/// Score delay's steps: 0–300 seconds in tens (C-O `scoreDelaySeconds`). Pure (`SettingsSportTests`).
nonisolated enum ScoreDelay {
    static let range = 0...300
    static let step = 10

    static func stepped(_ seconds: Int, by delta: Int) -> Int {
        min(range.upperBound, max(range.lowerBound, seconds + delta))
    }

    static func text(_ seconds: Int) -> String { "\(seconds) s" }
}

/// The account's score delay, read from and saved to C-O's `sports/preferences` (`{avoidSpoilers, scoreDelaySeconds,
/// revision}`; the front page applies the delay).
/// A save sends the revision it read; a refused one (409: changed on another device, or any failure) reads the value
/// again and says so.
@MainActor
final class ScoreDelaySetting: ObservableObject {
    @Published private(set) var preferences: SportsPreferences?
    @Published private(set) var saving = false
    @Published private(set) var message = ""
    /// False once the server answered 404: it keeps no score delay (its score collector is off), so there is no row.
    @Published private(set) var shown = true
    let client: APIClient
    @Published private var fixture = false

    init(client: APIClient, fixture: Bool = false) {
        self.client = client
        if fixture { useFixture() }
    }

    /// The offline fixtures: a delay of 30 s, changed locally.
    func useFixture() {
        guard !fixture else { return }
        fixture = true
        preferences = SportsPreferences(avoidSpoilers: false, scoreDelaySeconds: 30, revision: 1)
    }

    private struct Change: Encodable {
        let revision: Int
        let scoreDelaySeconds: Int
    }

    func load() async {
        guard !fixture, !saving else { return }
        // #278: the server answers this route only while its score collector or the dashboard is on; `/api/info` says which.
        // Only both flags explicitly false skip it: a server that leaves them out is asked, and its 404 decides (Codex, Apple 1).
        if let features = client.info?.features, features.sportFront == false, features.sportsDashboard == false {
            shown = false
            return
        }
        do { preferences = try await client.request("sports/preferences") }
        catch where error as? PigTVError == .http(404) { shown = false }
        catch { if !UserMessage.isCancellation(error) && preferences == nil { message = "The score delay could not be loaded." } }
    }

    /// One step of ten seconds (`delta` -10 or +10), within 0–300.
    func step(_ delta: Int) async {
        guard let current = preferences, !saving else { return }
        let next = ScoreDelay.stepped(current.scoreDelaySeconds, by: delta)
        guard next != current.scoreDelaySeconds else { return }
        message = ""
        if fixture {
            preferences?.scoreDelaySeconds = next
            return
        }
        saving = true
        defer { saving = false }
        do {
            preferences = try await client.request("sports/preferences", method: "PUT",
                                                   body: Change(revision: current.revision, scoreDelaySeconds: next))
        } catch {
            message = error as? PigTVError == .http(409)
                ? "Changed on another device: this is the delay now."
                : "Not saved: \(UserMessage.text(for: error) ?? "the change was cancelled.")"
            if let fresh: SportsPreferences = try? await client.request("sports/preferences") { preferences = fresh }
        }
    }
}

/// The logos beside a sport's followed names: the loaded Sport front page's follows carry each one's cached `/api/logo/`
/// path; `sports/names` carries none, so a name the front page has not listed draws a monogram (nil). Pure.
nonisolated enum SettingsSportLogos {
    struct Name: Equatable, Sendable {
        let name: String
        let logo: String?
    }

    static func names(_ entry: SportFollows.Entry, follows: [SportFront.Follow]) -> [Name] {
        entry.teams.map { name in
            let match = follows.first { follow in
                follow.name.caseInsensitiveCompare(name) == .orderedSame
                    && (follow.sport.map { $0 == entry.sport } ?? entry.leagues.contains(follow.league))
            }
            return Name(name: name, logo: match?.cachedLogo)
        }
    }
}
