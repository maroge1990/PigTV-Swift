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
        fileprivate let commit: () -> Void
    }

    static let undoWindow: Duration = .seconds(10)
    /// The toast on screen, if any.
    private(set) var pendingUndo: PendingUndo?
    @ObservationIgnored private var undoTimer: Task<Void, Never>?
    /// The clock (tests inject one).
    @ObservationIgnored var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

    /// Shows the toast; `commit` runs when the 10 s end or the app goes to the background, never after Undo. A new
    /// offer commits the one before it first.
    func offerUndo(_ message: String, commit: @escaping () -> Void) {
        commitPendingUndo()
        let pending = PendingUndo(message: message, commit: commit)
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
        pendingUndo = nil
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
                    RecordingDetails(model: browse, original: recording)
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

/// The Undo toast: the message, an Undo button, gone after 10 s (AppPresenter). An overlay, never a cover.
struct UndoToast: View {
    let presenter: AppPresenter
    var body: some View {
        if let pending = presenter.pendingUndo {
            HStack(spacing: 20) {
                Text(pending.message).foregroundStyle(Color("PigText"))
                Button("Undo") { presenter.undoPending() }
                    .accessibilityIdentifier("undo.toast.undo")
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .background(Color.pigRaised, in: Capsule())
            .shadow(color: Color.pigShadow.opacity(0.3), radius: 16, y: 8)
            .padding(.bottom, 40)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier("undo.toast")
        }
    }
}
