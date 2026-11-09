import Foundation

// D-43 (1 Nov): the banner's pure parts (the list's window, the full-width rule, what a row and the hero say, the
// backdrop), Foundation only so the contract checks compile them with the C-R models. The view is SportBanner.swift.

/// The list's window: which four items show, and what the "N more" line says. Pure (tests `SportBannerTests`).
nonisolated struct SportBannerWindow: Equatable, Sendable {
    static let visible = 4

    let count: Int
    let start: Int

    init(count: Int, start: Int = 0) {
        self.count = max(0, count)
        self.start = min(max(0, start), max(0, self.count - Self.visible))
    }

    /// The items on show.
    var range: Range<Int> { start..<min(count, start + Self.visible) }
    /// How many are below the window.
    var below: Int { max(0, count - start - Self.visible) }

    /// Focus moved to item `index`: the window moves the least that shows it (down one row at a time, up likewise).
    func focusing(_ index: Int) -> SportBannerWindow {
        guard count > 0 else { return self }
        let index = min(max(0, index), count - 1)
        if index < start { return SportBannerWindow(count: count, start: index) }
        if index >= start + Self.visible { return SportBannerWindow(count: count, start: index - Self.visible + 1) }
        return self
    }

    /// "5 more · de Minaur, Min Woo Lee, Arsenal …": the items below the window, the first three named; nil with none.
    func moreLine(names: [String]) -> String? {
        guard below > 0 else { return nil }
        let rest = Array(names.dropFirst(start + Self.visible))
        let named = rest.prefix(3).joined(separator: ", ")
        return "\(below) more" + (named.isEmpty ? "" : " · \(named)") + (rest.count > 3 ? " …" : "")
    }
}

/// D-43 point 4: one item (a sport with one league, or only one picked; a front page with one follow) or none runs the
/// banner full width, with no list and no line.
nonisolated enum SportBannerLayout {
    static func fullWidth(itemCount: Int) -> Bool { itemCount <= 1 }
}

/// One row of the banner's list.
nonisolated struct SportBannerItem: Identifiable, Equatable, Sendable {
    struct Badge: Equatable, Sendable {
        let name: String
        let logo: String?
        let league: String
    }

    let id: String
    let title: String
    /// "LIVE · v Man City", "Mon 5:00 am", "2 live".
    let trailing: String
    let live: Bool
    var badge: Badge? = nil
}

/// The hero's words, spoiler-free already applied.
nonisolated struct SportBannerHero: Equatable, Sendable {
    /// "LIVE · FOOTBALL · PREMIER LEAGUE".
    let kicker: String
    /// The kicker's dot and colour: something is on now.
    let live: Bool
    let title: String
    /// "1–1 · 2nd half 67' · Optus Sport 1 HD".
    let line: String
}

/// What fades behind the hero: the hero team's badge, or a race's circuit map (C-P `info.map`; `mapDark` in dark mode).
nonisolated enum SportBannerBackdrop: Equatable, Sendable {
    case badge(String)
    case map(light: String, dark: String?)

    func path(dark: Bool) -> String {
        switch self {
        case .badge(let path): return path
        case .map(let light, let dark2): return dark ? (dark2 ?? light) : light
        }
    }
}

/// D-43 (1 Nov): what a banner row and a kicker call a league and a followed name. Pure (tests `SportLabelsTests`).
nonisolated enum SportLabels {
    /// The catalogue's labels by canonical league (C-U `GET sports/catalog`: "EPL" → "Premier League", "Cricket" →
    /// "International (men)").
    static func labels(_ catalog: SportCatalog) -> [String: String] {
        var out: [String: String] = [:]
        for league in catalog.sports.flatMap(\.leagues) where !league.label.isEmpty { out[league.league] = league.label }
        return out
    }

    /// A league's label, else its canonical code (no catalogue yet, an older server, or a league it does not list).
    static func label(_ league: String, in labels: [String: String]) -> String {
        labels[league].flatMap { $0.isEmpty ? nil : $0 } ?? league
    }

    /// The hero kicker's word for a followed name in the sport: a driver, a player, a fighter, else a team.
    static func yours(sport: String) -> String {
        switch sport {
        case "Motorsport": return "YOUR DRIVER"
        case "Tennis", "Golf": return "YOUR PLAYER"
        case "Combat": return "YOUR FIGHTER"
        default: return "YOUR TEAM"
        }
    }
}

/// #264 (Mark, 9 Nov 2026, option B): the slim strip the front page's banner becomes once the page scrolls past it,
/// pinned under the header while the rails scroll beneath: the hero's game (its kicker's live dot, title and line,
/// spoiler-free already applied) and the other follows' next games. Pure (tests `SportHeroStripTests`).
nonisolated struct SportHeroStrip: Equatable, Sendable {
    static let othersShown = 3

    let live: Bool
    let title: String
    let line: String
    /// "Oscar Piastri Race · Sat 2:27 pm  ·  Arsenal Sat 11:30 pm": up to three other follows; nil with none.
    let others: String?

    init(hero: SportBannerHero, items: [SportBannerItem], selected: Int?) {
        live = hero.live
        title = hero.title
        line = hero.line
        let rest = items.indices.filter { $0 != selected }.prefix(Self.othersShown).map { "\(items[$0].title) \(items[$0].trailing)" }
        others = rest.isEmpty ? nil : rest.joined(separator: "  ·  ")
    }

    /// The strip shows once the banner has scrolled under it: `scrolled` past the banner's height less the strip's.
    static func shows(scrolled: CGFloat, bannerHeight: CGFloat, stripHeight: CGFloat) -> Bool {
        bannerHeight > 0 && scrolled > bannerHeight - stripHeight
    }
}
