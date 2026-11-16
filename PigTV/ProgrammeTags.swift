import SwiftUI

// #56 (Apple half): a programme's LIVE and NEW badges and its episode ("S2 E5 · The One Where…"), from the server's guide
// fields. Drawn small, in brand roles only, on the guide's cells, the programme page's hero and Search's rows; nothing is
// drawn for a programme without them (an older server).

/// What a programme carries beyond its title. Pure; tested (ProgrammeTagsTests).
nonisolated struct ProgrammeTags: Equatable, Sendable {
    var live = false
    var new = false
    var episode: String?
    var subtitle: String?

    init(live: Bool = false, new: Bool = false, episode: String? = nil, subtitle: String? = nil) {
        self.live = live
        self.new = new
        self.episode = episode
        self.subtitle = subtitle
    }

    init(_ programme: GuideProgramme) {
        self.init(live: programme.liveBroadcast == true, new: programme.isNew == true, episode: programme.episode,
                  subtitle: programme.subtitle)
    }

    /// Nothing to draw.
    var isEmpty: Bool { !live && !new && episodeLine() == nil }

    /// The badges, in order: LIVE before NEW.
    var badges: [Badge] { (live ? [Badge.live] : []) + (new ? [Badge.new] : []) }

    /// "S2 E5 · The One Where…", "S2 E5", "The One Where…", or nil. A subtitle that only repeats the title is left out.
    func episodeLine(title: String? = nil) -> String? {
        let named = self.subtitle.flatMap { text -> String? in
            guard let title else { return text }
            return text.caseInsensitiveCompare(title) == .orderedSame ? nil : text
        }
        let parts = [episode, named].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// What VoiceOver reads after the title: "live, new, S2 E5".
    func spoken(title: String? = nil) -> String? {
        let words = badges.map(\.spoken) + [episodeLine(title: title)].compactMap { $0 }
        return words.isEmpty ? nil : words.joined(separator: ", ")
    }

    nonisolated enum Badge: String, Equatable, Sendable {
        case live = "LIVE", new = "NEW"
        var spoken: String { self == .live ? "live" : "new" }
    }
}

/// One badge: LIVE on the danger fill, NEW outlined in the accent text colour. The type is the platform's caption role
/// (PigType.caption on the TV, the 23 pt floor).
struct ProgrammeTagBadge: View {
    let badge: ProgrammeTags.Badge

    var body: some View {
        Text(badge.rawValue)
            #if os(tvOS)
            .font(.system(size: PigType.caption, weight: .bold))
            #else
            .font(.caption2.weight(.bold))
            #endif
            .padding(.horizontal, PigSpacing.xs).padding(.vertical, PigSpacing.xxs)
            .foregroundStyle(badge == .live ? Color.pigOnStatus : Color.pigAccentText)
            .background(badge == .live ? Color.pigDanger : Color.clear, in: Capsule())
            .overlay { Capsule().strokeBorder(badge == .live ? Color.clear : Color.pigAccentText, lineWidth: 1) }
            .fixedSize()
            .accessibilityHidden(true)
            .accessibilityIdentifier("programme.badge.\(badge.rawValue)")
    }
}

/// The badges, then the episode line in the secondary colour; nothing when the programme has neither.
struct ProgrammeTagsRow: View {
    let tags: ProgrammeTags
    var title: String? = nil
    var font: Font = DetailType.meta

    var body: some View {
        if !tags.isEmpty {
            HStack(spacing: PigSpacing.s) {
                ForEach(tags.badges, id: \.self) { ProgrammeTagBadge(badge: $0) }
                if let line = tags.episodeLine(title: title) {
                    Text(line).font(font).foregroundStyle(Color.pigSecondary).lineLimit(1)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tags.spoken(title: title) ?? "")
        }
    }
}
