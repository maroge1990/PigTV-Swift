import Foundation

/// maroge1990/PigTV#372: some providers put "divider" channels in their line-up (`### SPORTS ###`, programmes titled with
/// rows of arrows). The TV Guide draws such a row as a slim section heading (Mark's option A, 23 Nov 2026), which never
/// takes focus and is never played, and every channel list built from the Guide's rows leaves it out. Recognised by one
/// general rule, never one provider's text:
///
/// - the channel has programmes, and not one of their titles has a letter or a digit (only symbols, emoji, punctuation,
///   spaces); a channel with no programmes is never a heading (it keeps its "No programme information" row);
/// - its name, trimmed, begins and ends with decoration (anything but a letter, a digit or a space, e.g. `###`, `━━`,
///   `***`, `===`, `•••`) around at least one letter. The label is the name without that decoration and its spaces.
///
/// The name is checked first: almost every real channel's name begins with a letter, so the rule costs one character for
/// it and never reads its programmes.
nonisolated enum GuideHeading {
    /// The section label when `channel` is a divider, else nil.
    static func label(of channel: GuideChannel) -> String? {
        label(name: channel.name, titles: channel.programmes.lazy.map(\.title))
    }

    static func isHeading(_ channel: GuideChannel) -> Bool { label(of: channel) != nil }

    /// The rule on its own inputs: the channel's name and its programmes' titles.
    static func label<Titles: Sequence>(name: String, titles: Titles) -> String? where Titles.Element == String {
        guard let label = decoratedLabel(name) else { return nil }
        var any = false
        for title in titles {
            if hasLetterOrDigit(title) { return nil }
            any = true
        }
        return any ? label : nil
    }

    /// The name without its decoration when it is wrapped in decoration around at least one letter, else nil.
    static func decoratedLabel(_ name: String) -> String? {
        let scalars = name.unicodeScalars
        guard let firstIndex = scalars.firstIndex(where: { !isSpace($0) }),
              let lastIndex = scalars.lastIndex(where: { !isSpace($0) }),
              isDecoration(scalars[firstIndex]), isDecoration(scalars[lastIndex]) else { return nil }
        guard let from = scalars.firstIndex(where: { !isDecoration($0) && !isSpace($0) }),
              let to = scalars.lastIndex(where: { !isDecoration($0) && !isSpace($0) }) else { return nil }
        let label = String(scalars[from...to])
        return label.unicodeScalars.contains(where: { $0.properties.isAlphabetic }) ? label : nil
    }

    /// `channels` without their headings: what a channel list built from the Guide's rows offers (the player's channel
    /// up and down, its list, the warmer's guess, Go to number, Search, the Top Shelf, the iPhone's On now list).
    static func playable(_ channels: [GuideChannel]) -> [GuideChannel] {
        channels.filter { !isHeading($0) }
    }

    /// A letter (any script) or a digit (any numeral).
    static func hasLetterOrDigit(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isLetterOrDigit)
    }

    private static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool { scalar.properties.isWhitespace }

    private static func isDecoration(_ scalar: Unicode.Scalar) -> Bool { !isLetterOrDigit(scalar) && !isSpace(scalar) }
}
