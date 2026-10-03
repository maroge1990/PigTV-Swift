import Foundation

// C-K (server flag `providerReminders`): licence reminders. Pure text and the
// once-a-day rule live here (unit-tested, no UI); ProviderReminderModel drives
// the fetch and the banner.

nonisolated enum ProviderReminderText {
    /// "Tue 30 Mar" in the given time zone.
    static func day(_ date: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: date)
    }

    /// "Trex expires Tue 30 Mar. Renew it with the provider; PigTV picks up
    /// the new date by itself." Several providers are listed in one sentence; one past
    /// its expiry reads "expired on …".
    static func message(for reminders: [ProviderReminder], now: Date = Date(),
                        timeZone: TimeZone = .current, locale: Locale = .current) -> String? {
        guard !reminders.isEmpty else { return nil }
        let clauses = reminders.sorted { $0.expiresAt < $1.expiresAt }.map { reminder -> String in
            let date = day(reminder.expiry, timeZone: timeZone, locale: locale)
            return reminder.expiry <= now ? "\(reminder.name) expired on \(date)" : "\(reminder.name) expires \(date)"
        }
        let list: String
        if clauses.count == 1 { list = clauses[0] }
        else { list = clauses.dropLast().joined(separator: ", ") + " and " + clauses[clauses.count - 1] }
        return "\(list). Renew \(reminders.count == 1 ? "it" : "them") with the provider; PigTV picks up the new date by itself."
    }
}

/// At most one popup per local day on this device.
nonisolated struct ProviderReminderSchedule {
    static let key = "pigtv.providerReminderDay"
    let defaults: UserDefaults

    static func dayStamp(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func shownToday(now: Date, timeZone: TimeZone = .current) -> Bool {
        defaults.string(forKey: Self.key) == Self.dayStamp(now, timeZone: timeZone)
    }

    func markShown(now: Date, timeZone: TimeZone = .current) {
        defaults.set(Self.dayStamp(now, timeZone: timeZone), forKey: Self.key)
    }
}
