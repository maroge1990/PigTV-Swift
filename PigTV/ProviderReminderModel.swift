import Foundation
import Combine

/// C-K: fetches `GET providers/reminders` on launch and on returning to the
/// foreground and offers a short, non-blocking banner (ContentView overlay,
/// never a cover, never focusable on tvOS). Shown at most once per local day
/// on this device, never during playback, gone after 15 s or on its button.
@MainActor
final class ProviderReminderModel: ObservableObject {
    @Published private(set) var message: String?

    private let defaults: UserDefaults
    private let clock: () -> Date
    private let timeZone: TimeZone
    private let autoDismiss: Duration
    private var dismissTask: Task<Void, Never>?
    private var checking = false

    init(defaults: UserDefaults = .standard, clock: @escaping () -> Date = Date.init,
         timeZone: TimeZone = .current, autoDismiss: Duration = .seconds(15)) {
        self.defaults = defaults
        self.clock = clock
        self.timeZone = timeZone
        self.autoDismiss = autoDismiss
    }

    /// Call on launch/sign-in, on foreground and when playback ends. Does
    /// nothing without the flag, while playing, while a banner is up, or after
    /// today's popup; a failed request is silent.
    func check(client: APIClient?, playing: () -> Bool) async {
        guard let client, client.info?.features.providerReminders == true,
              !playing(), message == nil, !checking else { return }
        let schedule = ProviderReminderSchedule(defaults: defaults)
        guard !schedule.shownToday(now: clock(), timeZone: timeZone) else { return }
        checking = true
        defer { checking = false }
        guard let data = try? await client.response("providers/reminders", timeout: 10).data,
              let items = try? ProviderReminder.list(from: data), !items.isEmpty else { return }
        // Playback may have started, or a banner appeared, while waiting.
        guard !playing(), message == nil, !schedule.shownToday(now: clock(), timeZone: timeZone) else { return }
        guard let text = ProviderReminderText.message(for: items, now: clock(), timeZone: timeZone) else { return }
        schedule.markShown(now: clock(), timeZone: timeZone)
        message = text
        dismissTask?.cancel()
        dismissTask = Task { [weak self, autoDismiss] in
            try? await Task.sleep(for: autoDismiss)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// Hides the banner (the button, the 15 s timer, or playback starting).
    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        message = nil
    }
}
