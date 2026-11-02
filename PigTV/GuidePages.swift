import SwiftUI

// D-44 (#49, Apple 108–110): the TV Guide's pages are pushed on its NavigationStack (Back pops, and the grid keeps its
// focus underneath): programme details, the channel page and Search with Jump to. Routes carry stable ids (the channel's
// id and the programme's start), never offsets, and are resolved against the loaded guide when drawn.

enum GuideRoute: Hashable {
    case programme(channel: String, start: Double)
    case channel(String)
    /// Search and Jump to (one page); `jump`: opened from Jump to…, so focus starts on the day.
    case search(jump: Bool)
}

/// "Also on ABC TV tonight" on a programme's page: the programmes after it on its channel that evening. Pure; tested.
nonisolated enum AlsoOn {
    /// "Also on ABC TV tonight" (today from 5 pm), "today", "tomorrow", else "on Saturday 27 September".
    static func heading(channel: String, programme: GuideProgramme, now: Date, calendar: Calendar = .current) -> String {
        let day = DetailText.day(programme.start, now: now, calendar: calendar)
        let when: String
        switch day {
        case "Today": when = calendar.component(.hour, from: programme.start) >= 17 ? "tonight" : "today"
        case "Tomorrow": when = "tomorrow"
        case "Yesterday": when = "yesterday"
        default: when = "on \(day)"
        }
        return "Also on \(channel) \(when)"
    }

    /// Up to `limit` programmes starting after it ends, until 6 am after its day.
    static func programmes(after programme: GuideProgramme, in list: [GuideProgramme], limit: Int = 4,
                           calendar: Calendar = .current) -> [GuideProgramme] {
        let day = calendar.startOfDay(for: programme.start)
        let until = calendar.date(byAdding: .hour, value: 30, to: day) ?? programme.end.addingTimeInterval(12 * 3600)
        return Array(GuideNavigation.ordered(list)
            .filter { $0.startTime >= programme.endTime - 1000 && $0.start < until && $0.startTime != programme.startTime }
            .prefix(limit))
    }
}
