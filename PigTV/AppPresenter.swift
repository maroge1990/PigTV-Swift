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
    case recordingPlayer(Recording)

    var id: String {
        switch self {
        case .recording(let recording): "recording:\(recording.id)"
        case .channelSchedule(let channel): "schedule:\(channel.id)"
        case .record(let request): "record:\(request.id)"
        case .recordingPlayer(let recording): "player:\(recording.id)"
        }
    }

    /// Shown full screen on every platform (a player), not as a page.
    var isPlayer: Bool { if case .recordingPlayer = self { true } else { false } }
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

    func present(_ item: AppPresentation) {
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

    // MARK: Undo toast

    struct PendingUndo: Identifiable {
        let id = UUID()
        let message: String
        /// The toast's second line (D-44 R5-Undo: "Undo for 10 seconds" when nil).
        var detail: String? = nil
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
    func offerUndo(_ message: String, detail: String? = nil, undone: (() -> Void)? = nil, commit: @escaping () -> Void) {
        commitPendingUndo()
        let pending = PendingUndo(message: message, detail: detail, commit: commit, undone: undone)
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
        detailCover(item: Binding(get: { presenter.presented.flatMap { $0.isPlayer ? nil : $0 } }, set: { presenter.hostSet($0) }),
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
                case .recordingPlayer:
                    EmptyView()
                }
            }
        }
        // The player's own layer: full screen on iOS too (a page is a sheet there). Hosted on a background so it never
        // shares a view with the page cover.
        .background {
            Color.clear.fullScreenCover(item: Binding(get: { presenter.presented.flatMap { $0.isPlayer ? $0 : nil } },
                                                      set: { presenter.hostSet($0) }),
                                        onDismiss: { presenter.didDismiss() }) { item in
                if let browse, case .recordingPlayer(let recording) = item {
                    RecordingPlayerScreen(recording: recording, client: browse.client, fromStart: true) {
                        Task { await browse.loadRecordings() }
                    }
                }
            }
        }
    }
}

/// The Undo toast (D-44 R5-Undo): what was done, "Undo for 10 seconds", and the Undo button, gone after 10 s
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
    private static let title: Font = .system(size: 23, weight: .bold)
    private static let detail: Font = .system(size: 17)
    private static let bottom: CGFloat = 64
    #else
    private static let title: Font = .subheadline.weight(.bold)
    private static let detail: Font = .caption
    private static let bottom: CGFloat = 24
    #endif

    var body: some View {
        if let pending = presenter.pendingUndo {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pending.message).font(Self.title).foregroundStyle(Color("PigText")).lineLimit(2)
                    Text(pending.detail ?? "Undo for 10 seconds").font(Self.detail).foregroundStyle(Color.pigSecondary)
                }
                .accessibilityElement(children: .combine)
                Button("Undo") { presenter.undoPending() }
                    .pigPrimaryButton()
                    .focused($focused)
                    .accessibilityLabel("Undo: \(pending.message)")
                    .accessibilityIdentifier("undo.toast.undo")
            }
            .padding(.leading, 26).padding(.trailing, 14).padding(.vertical, 14)
            .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
            .shadow(color: Color.pigShadow.opacity(0.5), radius: 30, y: 14)
            .padding(.horizontal, 12)
            .padding(.bottom, bottom)
            .transition(.move(edge: .bottom).combined(with: .opacity))
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
