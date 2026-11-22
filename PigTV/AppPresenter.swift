import SwiftUI
import Observation

/// #49 groundwork (Apple 105): what the app-level presentation layer can show. Each page is drawn by the root host
/// (`appPresentations`), above every tab, so a page never sits under another page's cover.
enum AppPresentation: Identifiable {
    case recording(Recording)
    case channelSchedule(GuideChannel)
    /// D-44 (Apple 114): the record page (More options…, every Record button, Change recording), the Guide's and Sport's.
    case record(RecordRequest)
    /// D-44 (Apple 107): Watch from start: the recording being made, from its beginning (C-L), full screen.
    /// `noLive` (#345): opened from a finished game's Sport card: no Go to live (its live edge is the coverage after
    /// the game, a spoiler), as the web's `noLive`.
    case recordingPlayer(Recording, noLive: Bool = false)
    /// #57: Play on a Search result: the recording player, from where this device left off (as Recordings' Play).
    /// `fromBeginning` (#345): from a finished game's Sport card: from the start, no Resume question.
    case playRecording(Recording, fromBeginning: Bool = false)
    /// D-66 (#57): Search and Jump to, from a page header's magnifier on any tab (`from`: that tab's name).
    case search(from: String)

    var id: String {
        switch self {
        case .recording(let recording): "recording:\(recording.id)"
        case .channelSchedule(let channel): "schedule:\(channel.id)"
        case .record(let request): "record:\(request.id)"
        case .recordingPlayer(let recording, _): "player:\(recording.id)"
        case .playRecording(let recording, _): "play:\(recording.id)"
        case .search: "search"
        }
    }

    /// Shown full screen on every platform (a player), not as a page.
    var isPlayer: Bool {
        switch self {
        case .recordingPlayer, .playRecording: true
        default: false
        }
    }

    /// Covers the whole screen on touch rather than being a page sheet: a player, and Search (D-66: the same side-by-side
    /// page with Jump to as the Guide's, which a narrow iPad sheet cannot hold). On the TV every page covers the screen.
    var coversScreen: Bool {
        if isPlayer { return true }
        #if os(iOS)
        if case .search = self { return true }
        #endif
        return false
    }
}

/// #49 groundwork (Apple 105): one app-level presentation layer, owned by the session root (`AppModel.presenter`).
/// One thing at a time: presenting while something is open closes it first and presents the new one once the old one
/// has gone (the host's `onDismiss`, `didDismiss`); `dismiss(then:)` runs an action once nothing is open (a play after a
/// page closes: the player cannot present over a cover). It also holds the Undo toast: an action offered with
/// `offerUndo` commits when its 10 s run out or when the app goes to the background (`commitPendingUndo`), unless Undo
/// (`undoPending`) cancels it. No screen uses it yet; the existing covers move to it with #49.
@Observable @MainActor
final class AppPresenter {
    /// On screen now.
    private(set) var presented: AppPresentation?
    /// Waiting for the open one to finish closing (the latest request wins).
    private(set) var queued: AppPresentation?
    /// The open one was asked to close and its dismissal has not finished.
    private(set) var closing = false
    @ObservationIgnored private var afterClose: [() -> Void] = []
    /// D-66: Jump to's Show guide on the app-level Search page: the time the TV Guide shows when it next appears (it
    /// takes it then, and clears it).
    var guideJump: Date?

    /// #54 (Codex review of 394): the session is ending: nothing new is presented until `endSession` has run.
    @ObservationIgnored var refusing = false

    func present(_ item: AppPresentation) {
        guard !refusing else { return }
        if presented == nil && !closing { presented = item; return }
        queued = item
        close()
    }

    /// Closes what is open; `action` runs once it has gone (at once when nothing is open).
    func dismiss(then action: (() -> Void)? = nil) {
        queued = nil
        if let action { afterClose.append(action) }
        if presented == nil && !closing { finish(); return }
        close()
    }

    /// The host's binding: a nil write is the viewer closing the page (Menu, a swipe).
    func hostSet(_ item: AppPresentation?) {
        if item == nil { close() } else if let item { present(item) }
    }

    /// The host's onDismiss: the page has gone.
    func didDismiss() {
        closing = false
        finish()
    }

    private func close() {
        guard presented != nil else { return }
        presented = nil
        closing = true
    }

    private func finish() {
        let actions = afterClose
        afterClose = []
        for action in actions { action() }
        if let next = queued, presented == nil, !closing {
            queued = nil
            presented = next
        }
    }

    /// #54 (Codex review of 394): the session that owned what is open has ended (Sign out, or a confirmed refusal). Its
    /// page, the one queued after it and Search's guide jump are dropped, and so are the actions waiting for the page to
    /// close (`dismiss(then:)`: a Watch from a channel's page or Search, a game from Search: plays on the ended session),
    /// never run. The host resolves a page against whatever session exists when it draws, so one left here would reopen
    /// in the next session (another server or account). The host's late onDismiss for the page that was open then finds
    /// nothing to run.
    func endSession() {
        presented = nil
        queued = nil
        closing = false
        afterClose = []
        guideJump = nil
    }

    // MARK: Undo toast

    struct PendingUndo: Identifiable {
        let id = UUID()
        let message: String
        /// The toast's second line (D-44 R5-Undo; #341: none by default).
        var detail: String? = nil
        /// #313 item 3: what the action removes (`PendingRemoval.key`, "rule:7"), so a caller can settle this one only.
        var key: String? = nil
        fileprivate let commit: () -> Void
        /// Apple 122: puts back what the action hid at once (Undo).
        fileprivate var undone: (() -> Void)? = nil
    }

    static let undoWindow: Duration = .seconds(10)
    /// The toast on screen, if any.
    private(set) var pendingUndo: PendingUndo?
    @ObservationIgnored private var undoTimer: Task<Void, Never>?
    /// The clock (tests inject one).
    @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    /// Shows the toast; `commit` runs when the 10 s end or the app goes to the background, never after Undo. A new
    /// offer commits the one before it first.
    /// `undone` runs on Undo instead (Apple 122: it shows again what the action hid at once).
    /// `key` names what it removes (`commitPendingUndo(key:)`).
    func offerUndo(_ message: String, detail: String? = nil, key: String? = nil, undone: (() -> Void)? = nil,
                   commit: @escaping () -> Void) {
        commitPendingUndo()
        let pending = PendingUndo(message: message, detail: detail, key: key, commit: commit, undone: undone)
        pendingUndo = pending
        let sleep = self.sleep
        undoTimer = Task { [weak self] in
            do { try await sleep(Self.undoWindow) } catch { return }
            guard let self, self.pendingUndo?.id == pending.id else { return }
            self.commitPendingUndo()
        }
    }

    /// Undo: the pending action never runs.
    func undoPending() {
        undoTimer?.cancel()
        undoTimer = nil
        let undone = pendingUndo?.undone
        pendingUndo = nil
        undone?()
    }

    /// #313 item 3: runs the pending action now only when it removes `key` (another action's Undo stays open).
    func commitPendingUndo(key: String) {
        guard pendingUndo?.key == key else { return }
        commitPendingUndo()
    }

    /// Runs the pending action now (its time is up, or the app is going to the background).
    func commitPendingUndo() {
        guard let pending = pendingUndo else { return }
        undoTimer?.cancel()
        undoTimer = nil
        pendingUndo = nil
        pending.commit()
    }
}

extension View {
    /// The presentation layer's host, at the tab container (LibraryView): the presenter's page as a detail cover.
    func appPresentations(_ presenter: AppPresenter, app: AppModel, browse: BrowseModel?) -> some View {
        detailCover(item: Binding(get: { presenter.presented.flatMap { $0.coversScreen ? nil : $0 } }, set: { presenter.hostSet($0) }),
                    onDismiss: { presenter.didDismiss() }) { item in
            if let browse {
                switch item {
                case .recording(let recording):
                    RecordingView(model: browse, presenter: presenter, original: recording)
                case .channelSchedule(let channel):
                    ChannelPageView(model: browse, presenter: presenter, channel: channel) {
                        presenter.dismiss { app.beginPlayback(browse.asChannel(channel)) }
                    }
                case .record(let request):
                    RecordPage(model: browse, presenter: presenter, request: request) { presenter.dismiss() }
                case .search(let from):
                    AppSearchHost(app: app, browse: browse, from: from)
                case .recordingPlayer, .playRecording:
                    EmptyView()
                }
            }
        }
        // The player's own layer: full screen on iOS too (a page is a sheet there). Hosted on a background so it never
        // shares a view with the page cover.
        .background {
            Color.clear.fullScreenCover(item: Binding(get: { presenter.presented.flatMap { $0.coversScreen ? $0 : nil } },
                                                      set: { presenter.hostSet($0) }),
                                        onDismiss: { presenter.didDismiss() }) { item in
                if let browse, case .search(let from) = item {
                    // iOS only (`coversScreen`): Search as a full page, as the Guide's.
                    AppSearchHost(app: app, browse: browse, from: from)
                } else if let browse, case .recordingPlayer(let recording, let noLive) = item {
                    RecordingPlayerScreen(recording: recording, client: browse.client, fromStart: true, noLive: noLive) {
                        Task { await browse.loadRecordings() }
                    }
                } else if let browse, case .playRecording(let recording, let fromBeginning) = item {
                    RecordingPlayerScreen(recording: recording, client: browse.client, fromBeginning: fromBeginning) {
                        Task { await browse.loadRecordings() }
                    }
                }
            }
        }
    }
}

/// The Undo toast (D-44 R5-Undo): what was done and the Undo button, gone after 10 s
/// (AppPresenter). An overlay, never a cover. On the TV it takes focus when it appears, so Select undoes at once.
struct UndoToast: View {
    let presenter: AppPresenter
    @FocusState private var focused: Bool
    #if os(iOS)
    /// The iPhone's tab bar is at the bottom: the toast sits above it.
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var bottom: CGFloat { sizeClass == .compact ? 96 : Self.bottom }
    #else
    private var bottom: CGFloat { Self.bottom }
    #endif

    #if os(tvOS)
    private static let title: Font = .system(size: PigType.body, weight: .bold)
    private static let detail: Font = .system(size: PigType.caption)
    private static let bottom: CGFloat = 64
    #else
    private static let title: Font = .subheadline.weight(.bold)
    private static let detail: Font = .caption
    private static let bottom: CGFloat = 24
    #endif

    var body: some View {
        if let pending = presenter.pendingUndo {
            HStack(spacing: PigSpacing.l) {
                VStack(alignment: .leading, spacing: PigSpacing.xxs) {
                    Text(pending.message).font(Self.title).foregroundStyle(Color.pigText).lineLimit(2)
                    if let detail = pending.detail {
                        Text(detail).font(Self.detail).foregroundStyle(Color.pigSecondary)
                    }
                }
                .accessibilityElement(children: .combine)
                Button("Undo") { presenter.undoPending() }
                    .pigPrimaryButton()
                    .focused($focused)
                    .accessibilityLabel("Undo: \(pending.message)")
                    .accessibilityIdentifier("undo.toast.undo")
            }
            .padding(.leading, PigSpacing.xl).padding(.trailing, PigSpacing.m).padding(.vertical, PigSpacing.m)
            .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
            .shadow(color: Color.pigShadow.opacity(0.5), radius: 30, y: 14)
            .padding(.horizontal, PigSpacing.s)
            .padding(.bottom, bottom)
            .pigSlide(from: .bottom)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("undo.toast")
            #if os(tvOS)
            .focusSection()
            // Apple 128: a claim made while the toast slides in, with the focus engine still leaving the row that
            // went, can be dropped on a slow device (CI's runner). Claim until it takes, for at most a second.
            .task(id: pending.id) {
                for _ in 0..<10 where !focused {
                    focused = true
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            #endif
        }
    }
}

/// Work that must finish once started, even if the app goes to the background meanwhile (an Undo's committed call):
/// it runs as a background task, ended when the work is done or the system's time runs out.
@MainActor
enum BackgroundWork {
    @MainActor private final class Token { var id = UIBackgroundTaskIdentifier.invalid }

    static func run(_ name: String, _ work: @escaping @MainActor () async -> Void) {
        let token = Token()
        token.id = UIApplication.shared.beginBackgroundTask(withName: name) {
            MainActor.assumeIsolated { end(token) }
        }
        Task { @MainActor in
            await work()
            end(token)
        }
    }

    private static func end(_ token: Token) {
        guard token.id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(token.id)
        token.id = .invalid
    }
}

/// #49 (maroge1990/PigTV#280): something to do once an event has happened (a page has closed, a step has appeared), in
/// place of a guessed wait for it. Pure.
nonisolated struct PendingUntil<Value: Equatable & Sendable>: Equatable, Sendable {
    private(set) var value: Value?

    /// Asks for `value` once the event comes (a newer request replaces it).
    mutating func request(_ value: Value) { self.value = value }

    /// The event came: what was asked for, once.
    mutating func take() -> Value? {
        defer { value = nil }
        return value
    }

    /// The event for `value` came (a step appeared): true, once, when that is what was asked for.
    mutating func take(when appeared: Value) -> Bool {
        guard value == appeared else { return false }
        value = nil
        return true
    }
}
