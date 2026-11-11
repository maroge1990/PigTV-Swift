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

    /// #280: a list the app keeps current in the background (Recordings, Scheduled): `loaded` once one answer has come;
    /// `failed` while the last attempt failed. Its first answer that failed is the error; a later one keeps the list (stale).
    static func list(loaded: Bool, isEmpty: Bool, failed: Bool, since: Date?, failure: PageFailure) -> PageState {
        of(loaded: loaded, hasAnswer: loaded, isEmpty: isEmpty, failed: failed, stale: failed, since: since, failure: failure)
    }

    /// #280: the TV Guide, which pages its channels in (`channels` so far; `paging` while more are coming). Channels on
    /// screen stay when a page or a refresh fails (stale); with none, a failure is the error. It is empty only once a
    /// whole answer came with no channels; before the first answer (`loadedAt` nil) it is loading.
    static func guide(channels: Int, busy: Bool, paging: Bool, failed: Bool, loadedAt: Date?) -> PageState {
        if channels > 0 { return failed ? .stale(since: loadedAt) : .content }
        if failed { return .failed(PageWords.guideFailed) }
        if busy || paging || loadedAt == nil { return .loading }
        return .empty
    }

    /// #280: the Guide's page as drawn: the model's state (`guide`), except that channels on screen which the chosen chip
    /// filters down to none (`rowsEmpty`, once paging is done) are its empty state too.
    static func guideRows(_ guide: PageState, rowsEmpty: Bool, paging: Bool) -> PageState {
        guide.showsContent && rowsEmpty && !paging ? .empty : guide
    }

    /// #280: Search over the loaded guide. A query under two letters shows its prompt (content); while the guide has not
    /// loaded, or has failed, the page says so; until the first search has run, its shape; then the results or E1. A
    /// search waiting on its debounce keeps the last results on screen (nothing jumps while typing).
    static func search(query: String, searched: String?, found: Bool, guide: PageState) -> PageState {
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return .content }
        switch guide {
        case .loading: return .loading
        case .failed(let failure): return .failed(failure)
        default: break
        }
        guard searched != nil else { return .loading }
        return found ? .content : .empty
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

    // MARK: TV Guide and Search

    static let guideFailed = PageFailure(reason: .couldNotLoad, title: "The TV Guide didn’t load",
                                         message: "PigTV couldn’t get the programme times from your server.",
                                         stillWorks: "Sport and your recordings still work.")
    /// The guide's answer had no channels at all: nothing in the app adds one, so there is no button.
    static let noChannelsTitle = "No channels yet"
    static let noChannelsText = "Channels appear once a provider has been added in PigTV on the web."
    /// The Favourites chip with none chosen.
    static let noFavouritesTitle = "No favourites yet"
    #if os(tvOS)
    static let noFavouritesText = "Choose a channel, then Details to add it to favourites."
    #else
    static let noFavouritesText = "Open a channel’s page, then add it to favourites."
    #endif
    /// A category chip with no channels in it.
    static let noMatchingTitle = "No channels in this category"
    static let noMatchingText = "Your server lists none here today. Another category, or all channels, may have what you want."
    /// The filter empties' one action.
    static let showAllChannels = "Show all channels"

    /// Which empty the Guide shows: no channels at all, none chosen as favourites, or none in the chosen category.
    static func guideEmpty(filter: String, channels: Int) -> (title: String, text: String, showsAll: Bool) {
        if channels == 0 { return (noChannelsTitle, noChannelsText, false) }
        return filter == "favourites" ? (noFavouritesTitle, noFavouritesText, true) : (noMatchingTitle, noMatchingText, true)
    }

    static func searchNothingTitle(_ query: String) -> String { "Nothing matches “\(query)”" }
    static let searchNothingText = "No channel, and no programme in the next 24 hours, has that in its name. Check the spelling, or try another word."
    static let clearSearch = "Clear search"

    // MARK: Recordings and Scheduled

    static let recordingsStillWork = "Nothing has been deleted, and anything set to record will still record."
    static let recordingsFailed = PageFailure(reason: .couldNotLoad, title: "Your recordings didn’t load",
                                              message: "PigTV couldn’t get the list from your server.",
                                              stillWorks: recordingsStillWork)
    static let scheduledFailed = PageFailure(reason: .couldNotLoad, title: "Your scheduled recordings didn’t load",
                                             message: "PigTV couldn’t get them from your server.",
                                             stillWorks: recordingsStillWork)
    static let noRecordingsTitle = "No recordings yet"
    static let noRecordingsText = "Record a programme from the TV Guide, or a game from Sport. It shows here as soon as it starts."
    static let nothingScheduledTitle = "Nothing scheduled"
    static let nothingScheduledText = "Choose a programme in the TV Guide, or a game in Sport, and record it. It shows here until it starts."
    /// Scheduled's rules column when they did not load (the schedules themselves may have).
    static let rulesFailed = "Your recording rules didn’t load. Anything they set to record will still record."

    // MARK: Settings › Sport

    static let sportSettingsFailed = PageFailure(reason: .couldNotLoad, title: "Your sports didn’t load",
                                                 message: "PigTV couldn’t get the sports you follow from your server.",
                                                 stillWorks: "Your other settings, the TV Guide and your recordings still work.")
    static let noSportsTitle = "No sports followed yet"
    static let noSportsText = "Add a sport to fill the Sport tab with its games."
    static let addSport = "Add a sport"

    // MARK: Actions that did not work (detail pages, the record page, Scheduled, the iPhone's On now menu)

    /// What could not be done, in plain words; "Try again" where trying again can help.
    static let scheduleUnconfirmed = "The recording may not have been scheduled. Check Recordings before you try again, in case your server took it."
    static let cancelFailed = "The recording couldn’t be cancelled. Try again."
    static let changeFailed = "The recording couldn’t be changed. Try again."
    static let removeFailed = "That couldn’t be removed. Try again."
    static let chooseFailed = "That recording couldn’t be chosen. Try again."
    static let deleteFailed = "That couldn’t be deleted. Try again."
    static let ruleAddFailed = "The rule couldn’t be added. Try again."
    static let ruleChangeFailed = "The rule couldn’t be changed. Try again."
    static let ruleDeleteFailed = "The rule couldn’t be deleted. Try again."
    static let recordWhenListedFailed = "It couldn’t be set to record. Try again."
    static let followChangeFailed = "That couldn’t be changed. Try again."
    static let actionFailed = "That couldn’t be done. Try again."
    static var actionTexts: [String] {
        [scheduleUnconfirmed, cancelFailed, changeFailed, removeFailed, chooseFailed, deleteFailed, ruleAddFailed,
         ruleChangeFailed, ruleDeleteFailed, recordWhenListedFailed, followChangeFailed, actionFailed]
    }
}

/// #280: a sign-in that did not work, said on the form itself (no alert): what happened, and what to check. Never the
/// system's description of the error, a status or a code; the form keeps what was typed.
struct SignInFailure: Equatable {
    let title: String
    let check: String

    /// Where the attempt was made, which decides the wording of a sentence the app or server wrote itself.
    enum Step: Equatable, Sendable { case server, password, pairing, saved }

    /// The words for `error` (nil for a cancelled request, which is not a failure).
    static func of(_ error: Error, step: Step) -> SignInFailure? {
        if UserMessage.isCancellation(error) { return nil }
        if let url = error as? URLError {
            switch url.code {
            case .timedOut:
                return SignInFailure(title: "Your server didn’t answer in time",
                                     check: "Check that it’s switched on and awake, then try again.")
            case .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed, .serverCertificateUntrusted,
                 .serverCertificateHasBadDate, .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
                 .clientCertificateRejected, .clientCertificateRequired:
                return SignInFailure(title: "PigTV couldn’t make a safe connection to that address",
                                     check: "Check the address starts the way the PigTV web app shows it (http or https).")
            default:
                return SignInFailure(title: "PigTV couldn’t reach that address",
                                     check: "Check the address, and that this device is on the same network as your server.")
            }
        }
        guard let pig = error as? PigTVError else {
            return SignInFailure(title: "Signing in didn’t work", check: "Check the address, then try again.")
        }
        switch pig {
        case .invalidServerURL:
            return SignInFailure(title: "That isn’t an address PigTV can use",
                                 check: "Type the server’s address and its port only, as the PigTV web app shows it.")
        case .unauthorised:
            return step == .saved
                ? SignInFailure(title: "Your saved sign-in wasn’t accepted",
                                check: "Try it again, or pair or sign in again.")
                : SignInFailure(title: "That username or password wasn’t accepted",
                                check: "Check both, then sign in again.")
        case .forbidden:
            return SignInFailure(title: "This account can’t sign in here",
                                 check: "Ask whoever runs your server to check the account in the PigTV web app.")
        case .rateLimited(let seconds):
            let minutes = max(1, Int(ceil(Double(seconds) / 60)))
            return SignInFailure(title: "Too many attempts",
                                 check: "Wait \(minutes == 1 ? "a minute" : "\(minutes) minutes"), then try again.")
        case .message(let text), .serverMessage(let text, _), .viewerConflict(let text):
            let title = switch step {
            case .server: "PigTV can’t use this server"
            case .pairing: "Pairing didn’t finish"
            case .password, .saved: "Signing in didn’t work"
            }
            return SignInFailure(title: title, check: text)
        case .http, .decoding, .recordingConflict, .recordingPreparationFailed:
            return SignInFailure(title: "Your server didn’t answer as expected",
                                 check: "Check that PigTV on the server is up to date, then try again.")
        }
    }
}
