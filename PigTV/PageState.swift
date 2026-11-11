import Foundation

// Brand 1.8 §14 (maroge1990/PigTV#280, the owner's picks of 11 Nov 2026: L1, E1, R1): every page has four designed
// states. A page model says which one it is in (`PageState`); the page draws it with the shared parts in
// PageStateViews.swift (`PigLoadingPage` and its placeholder layouts, `PigEmptyState`, `PigErrorState`,
// `PigStaleNotice`). The words are fixed sentences (`PageWords`), never an error's own text, a status code or a
// system description. Pure, so the page models' states are tested without a view (`PageStateTests`).

/// What a page shows.
nonisolated enum PageState: Equatable, Sendable {
    /// The first answer has not come: the page's shape, pulsing (L1).
    case loading
    /// The answer, current.
    case content
    /// The answer is on screen but the last refresh failed: it stays, with the slim notice (`since`: when what is shown
    /// was received, nil when not known).
    case stale(since: Date?)
    /// The answer has nothing to show (E1).
    case empty
    /// Nothing to show and no answer to show it from (R1).
    case failed(PageFailure)

    /// The page draws its content (current or stale).
    var showsContent: Bool {
        switch self {
        case .content, .stale: true
        default: false
        }
    }

    /// A first answer that failed: what is not shown and why; with content on screen the notice says it instead.
    var failure: PageFailure? {
        if case .failed(let failure) = self { return failure }
        return nil
    }

    /// The state of a page that loads one answer: `hasAnswer` says whether one is held (an empty one included), `failed`
    /// whether the last attempt failed. A failure with an answer held keeps it (stale); with none, the page failed.
    static func of(loaded: Bool, hasAnswer: Bool, isEmpty: Bool, failed: Bool, stale: Bool, since: Date?,
                   failure: PageFailure) -> PageState {
        guard hasAnswer else { return loaded || failed ? .failed(failure) : .loading }
        if isEmpty { return .empty }
        return stale ? .stale(since: since) : .content
    }
}

/// #280 (one retry clock): when a page model asks the server next, as its own polling schedules it. A failed page's
/// error view counts down to this (its "Try again" asks now) instead of running a timer of its own, so a page asks no
/// more often failed than healthy.
nonisolated struct RefreshSchedule: Equatable, Sendable {
    /// The next request.
    let at: Date
    /// The wait before it, in seconds (the model's healthy interval).
    let interval: TimeInterval

    init(after interval: Duration, from now: Date = Date()) {
        let seconds = Double(interval.components.seconds) + Double(interval.components.attoseconds) / 1e18
        self.interval = seconds
        self.at = now.addingTimeInterval(seconds)
    }

    /// Whole seconds until the next request.
    func remaining(now: Date) -> Int { max(0, Int(at.timeIntervalSince(now).rounded(.up))) }
    /// How much of the ring is drawn: 1 just after a request, 0 when the next is due.
    func fraction(now: Date) -> Double {
        guard interval > 0 else { return 0 }
        return min(1, max(0, at.timeIntervalSince(now) / interval))
    }
}

/// Why a page has nothing to show, in plain words: what happened, what still works. The action is always "Try again".
nonisolated struct PageFailure: Equatable, Sendable {
    enum Reason: Equatable, Sendable {
        /// The server did not answer, or answered with an error.
        case couldNotLoad
        /// The server answered `available: false` (C-P, C-Q, C-S, C-T, C-V): it has nothing yet from the sports feed, or
        /// cannot reach it and kept nothing. An honest state, not an error; a later request has it.
        case notAvailable
    }

    let reason: Reason
    let title: String
    /// What happened.
    let message: String
    /// What still works.
    let stillWorks: String
}

/// The words of the page states (#280): sentence case, no exclamation marks, no codes. One name per thing: the retry
/// action is "Try again" everywhere.
nonisolated enum PageWords {
    static let tryAgain = "Try again"
    static let tryingAgain = "Trying again…"
    static let loading = "Loading"
    /// A change to the sport preferences the server refused or did not get.
    static let notSaved = "Your change wasn’t saved. Try again."

    /// R1's slim notice over content whose refresh failed.
    static func stale(since: Date?) -> String {
        guard let since else { return "Couldn’t update. Showing what you had before." }
        return "Couldn’t update. Showing what you had at \(since.formatted(date: .omitted, time: .shortened))."
    }

    // MARK: Sport

    static let sportStillWorks = "The TV Guide and your recordings still work."
    static let leagueStillWorks = "Your other sports, the TV Guide and your recordings still work."

    /// The Sport front page and the sport pages (they share one answer).
    static let sportFailed = PageFailure(reason: .couldNotLoad, title: "Sport didn’t load",
                                         message: "PigTV couldn’t get today’s games from your server.",
                                         stillWorks: sportStillWorks)

    /// A league's own page (`label`: "Formula 1", "Premier League") that did not load.
    static func leagueFailed(_ label: String) -> PageFailure {
        PageFailure(reason: .couldNotLoad, title: "\(label) didn’t load",
                    message: "PigTV couldn’t get \(label) from your server.", stillWorks: leagueStillWorks)
    }

    /// A league's own page whose server answered `available: false`.
    static func leagueNotAvailable(_ label: String) -> PageFailure {
        PageFailure(reason: .notAvailable, title: "\(label) isn’t available right now",
                    message: "Your server hasn’t had \(label) from the sports feed yet, or can’t reach it at the moment.",
                    stillWorks: leagueStillWorks)
    }

    /// The front page with nothing followed. With per-account follows (C-U) the button opens Settings › Sport; an older
    /// server keeps its follows in the web app, so the page says where and has no button.
    static let followTitle = "Follow a sport to start"
    static let followAction = "Choose your sport"
    static func followText(settings: Bool) -> String {
        settings ? "Choose the sports, leagues and teams you follow. Their games show here, on every device."
            : SportFrontText.followHelp(settings: false)
    }

    /// A league's empty page: the one thing the app can open from it.
    static let openGuide = "Open the TV Guide"

    /// A sport, or one of its leagues, with no games in the answer.
    static let nothingSoonTitle = "Nothing in the next three days"
    static func nothingSoonText(_ name: String) -> String { "\(name) has no games in the next three days." }

    /// A fixture league with no rounds.
    static func noRoundsTitle(_ label: String) -> String { "No \(label) games listed" }
    static func noRoundsText(_ label: String) -> String { "The sports feed has no rounds for \(label) at the moment." }
    /// An events league with nothing this week.
    static func emptyWeekTitle(_ label: String) -> String { "Nothing in \(label) this week" }
    static let emptyWeekText = "Its next events show here once the sports feed lists them."
    /// Formula 1 with no weekend.
    static let noRaceTitle = "No race scheduled"
    static let noRaceText = "The next race weekend shows here once the sports feed lists it."
    /// Cricket with no match.
    static let noCricketTitle = "No cricket today or tomorrow"
    static let noCricketText = "Matches show here once the sports feed lists them."
}
