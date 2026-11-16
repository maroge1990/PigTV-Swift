import Foundation

// D-65 / D-67 (#265, #266): a channel's measured quality and the badge every channel list and player shows.
// The server adds `measured: {label: "4K"|"1080"|"720"|"SD", fps: Int}` to a channel it has measured (C-I event
// channels, C-O/C-R card channels, guide rows, the record page's options); without it the name-derived `quality`
// (UHD/FHD/HD/SD) is the fallback, drawn dashed. Pure; tested in `MeasuredQualityTests`.

/// What the server measured a channel's stream to be. Decoding never fails: an unreadable value has no `label`
/// (and counts as unmeasured), so a malformed `measured` never drops the channel that carries it.
nonisolated struct MeasuredQuality: Codable, Hashable, Sendable {
    nonisolated enum Label: String, Codable, Hashable, Sendable, CaseIterable {
        case uhd = "4K", fhd = "1080", hd = "720", sd = "SD"

        /// Best first: 4K, 1080, 720, SD.
        var rank: Int {
            switch self {
            case .uhd: 0
            case .fhd: 1
            case .hd: 2
            case .sd: 3
            }
        }

        /// The server's label, any case; anything else is none.
        init?(server: String) {
            let text = server.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            guard let value = Label.allCases.first(where: { $0.rawValue == text }) else { return nil }
            self = value
        }
    }

    var label: Label?
    /// Frames per second, rounded; nil when absent or not positive.
    var fps: Int?

    init(label: Label?, fps: Int? = nil) {
        self.label = label
        self.fps = fps.flatMap { $0 > 0 ? $0 : nil }
    }

    enum CodingKeys: String, CodingKey { case label, fps }

    init(from decoder: Decoder) {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { label = nil; fps = nil; return }
        label = ((try? c.decodeIfPresent(String.self, forKey: .label)) ?? nil).flatMap(Label.init(server:))
        let whole = (try? c.decodeIfPresent(Int.self, forKey: .fps)) ?? nil
        let fraction = ((try? c.decodeIfPresent(Double.self, forKey: .fps)) ?? nil).flatMap { $0.isFinite ? Int($0.rounded()) : nil }
        fps = (whole ?? fraction).flatMap { $0 > 0 ? $0 : nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(label?.rawValue, forKey: .label)
        try c.encodeIfPresent(fps, forKey: .fps)
    }

    /// Itself when it has a label; nil otherwise.
    var known: MeasuredQuality? { label == nil ? nil : self }
}

/// One quality badge (or picker chip): the measured label and frame rate ("4K · 50"), or, unmeasured, the label taken
/// from the channel's name ("4K", "1080", "HD", "SD"), drawn dashed.
nonisolated struct QualityChip: Hashable, Sendable {
    /// 0 = 4K … 3 = SD (the name's UHD/FHD/HD/SD map onto the same tiers).
    let tier: Int
    let measured: Bool
    let fps: Int?
    let text: String
    let spoken: String

    /// 4K that was measured: the accent fill.
    var accent: Bool { measured && tier == 0 }

    /// The badge for a channel: measured when known, else from the name; nil when neither exists.
    static func make(measured: MeasuredQuality?, quality: SportQuality?) -> QualityChip? {
        if let measured, let label = measured.label {
            let text = measured.fps.map { "\(label.rawValue) · \($0)" } ?? label.rawValue
            let words: String
            switch label {
            case .uhd: words = "4K"
            case .fhd: words = "1080p"
            case .hd: words = "720p"
            case .sd: words = "Standard definition"
            }
            return QualityChip(tier: label.rank, measured: true, fps: measured.fps, text: text,
                               spoken: measured.fps.map { "\(words), \($0) frames per second" } ?? words)
        }
        guard let quality else { return nil }
        switch quality {
        case .uhd: return QualityChip(tier: 0, measured: false, fps: nil, text: "4K", spoken: quality.spoken)
        case .fhd: return QualityChip(tier: 1, measured: false, fps: nil, text: "1080", spoken: quality.spoken)
        case .hd: return QualityChip(tier: 2, measured: false, fps: nil, text: "HD", spoken: quality.spoken)
        case .sd: return QualityChip(tier: 3, measured: false, fps: nil, text: "SD", spoken: quality.spoken)
        }
    }

    /// Best first: the tier (4K > 1080 > 720 > SD), then measured before name-only, then the higher frame rate.
    static func isBetter(_ a: QualityChip?, than b: QualityChip?) -> Bool {
        guard let a else { return false }
        guard let b else { return true }
        if a.tier != b.tier { return a.tier < b.tier }
        if a.measured != b.measured { return a.measured }
        return (a.fps ?? 0) > (b.fps ?? 0)
    }
}

/// One chip of a channel row: the copies (same name, same chip) folded into it, in the server's order.
nonisolated struct ChannelChoice<Copy>: Identifiable {
    let chip: QualityChip?
    /// Every folded copy's index in the server's (best-first) list, ascending.
    let indices: [Int]
    /// The copy a choice acts on: the first in the server's order.
    let copy: Copy
    /// The copy's airing (ms), when the caller gave one: copies fold only when it is the same.
    var start: Double? = nil
    var end: Double? = nil
    var id: String {
        (chip.map { "\($0.measured ? "m" : "n")|\($0.text)" } ?? "none") + "|\(start.map { String(Int64($0)) } ?? "")|\(end.map { String(Int64($0)) } ?? "")"
    }
}

/// One row of a channel picker: every copy of one channel name, its chips best first.
nonisolated struct ChannelNameGroup<Copy>: Identifiable {
    let name: String
    let key: String
    /// Never empty; best first.
    let choices: [ChannelChoice<Copy>]
    var id: String { key }
    var best: ChannelChoice<Copy> { choices[0] }
    /// More than one chip: the row offers a choice; otherwise the row itself acts.
    var choosesQuality: Bool { choices.count > 1 }
    /// Every copy's index in the server's list.
    var indices: [Int] { choices.flatMap(\.indices).sorted() }
    /// A chip whose copy starts at another time than the row's (its best copy's): it shows its start.
    func startsDifferently(_ choice: ChannelChoice<Copy>) -> Bool {
        choice.start != nil && choice.start != best.start
    }
}

extension ChannelChoice: Equatable where Copy: Equatable {}
extension ChannelChoice: Sendable where Copy: Sendable {}
extension ChannelNameGroup: Equatable where Copy: Equatable {}
extension ChannelNameGroup: Sendable where Copy: Sendable {}

nonisolated enum ChannelGrouping {
    /// The name with its quality words removed (UHD, FHD, HD, SD, HDR, 4K, 1080p50, 720p, 50fps, superscript ᵁᴴᴰ …),
    /// spaces collapsed, case and region prefix kept: "Sky Sports F1 UHD" → "Sky Sports F1". The server's
    /// `channelMeasurements.nameKey` rule (and the web's SportView.baseName), before lower-casing; a name that is only
    /// quality words stays as it was.
    static func baseName(_ name: String) -> String {
        let range = { (text: String) in NSRange(text.startIndex..., in: text) }
        var text = superscriptTags.stringByReplacingMatches(in: name, range: range(name), withTemplate: " ")
        text = qualityWords.stringByReplacingMatches(in: text, range: range(text), withTemplate: " ")
        let folded = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return folded.isEmpty ? name.trimmingCharacters(in: .whitespacesAndNewlines) : folded
    }

    /// The key copies share a row by: the server's `nameKey` when it sent one, else the same rule here (`baseName`,
    /// lower case), so "Sky Sports F1 UHD" and "Sky Sports F1 HD" share a row.
    static func key(_ name: String, serverKey: String? = nil) -> String {
        if let serverKey = serverKey?.trimmingCharacters(in: .whitespacesAndNewlines), !serverKey.isEmpty { return serverKey }
        return baseName(name).lowercased()
    }

    // ICU patterns of the server's QUALITY_WORDS and SUPERSCRIPT_TAGS (`[([]` is written `[(\[]`: ICU nests sets).
    nonisolated(unsafe) private static let qualityWords = try! NSRegularExpression(
        pattern: #"[\s\-_|]*[(\[]?\b(?:u?hd|fhd|sd|hdr(?:10)?|[48]k|\d{3,4}[pi](?:\s?\d{2})?|\d{2}\s?fps)\b[)\]]?"#,
        options: [.caseInsensitive])
    nonisolated(unsafe) private static let superscriptTags = try! NSRegularExpression(pattern: "ᵁᴴᴰ|ᶠᴴᴰ|ᴴᴰ|ˢᴰ")

    /// D-65: one row per channel name (in the order the server lists the names, best first); within it one chip per
    /// quality and frame rate, best first; copies with the same name and chip fold into one chip, which acts on the
    /// first of them in the server's order. Display only: what a copy does is unchanged.
    /// `serverKey`: the copy's `nameKey` from the server, when it sent one. A row's name is its first (best) copy's name
    /// without the quality words.
    /// `airing`: the copy's start and end (ms); copies with the same name and chip fold only when it is the same too, so
    /// a later airing of the channel stays its own chip (it can be watched or recorded on its own times).
    static func group<Copy>(_ copies: [Copy], name: (Copy) -> String, serverKey: (Copy) -> String? = { _ in nil },
                            airing: (Copy) -> (start: Double, end: Double)? = { _ in nil },
                            chip: (Copy) -> QualityChip?) -> [ChannelNameGroup<Copy>] {
        var order: [String] = []
        var names: [String: String] = [:]
        var folds: [String: [(chip: QualityChip?, indices: [Int], copy: Copy, start: Double?, end: Double?)]] = [:]
        for (index, copy) in copies.enumerated() {
            let display = name(copy)
            let key = key(display, serverKey: serverKey(copy))
            if names[key] == nil { order.append(key); names[key] = baseName(display) }
            let badge = chip(copy)
            let times = airing(copy)
            if let at = folds[key, default: []].firstIndex(where: {
                $0.chip == badge && $0.start == times?.start && $0.end == times?.end
            }) {
                folds[key]![at].indices.append(index)
            } else {
                folds[key, default: []].append((badge, [index], copy, times?.start, times?.end))
            }
        }
        return order.map { key in
            // A stable sort: equal chips with different airings keep the server's order.
            let sorted = folds[key, default: []].enumerated().sorted { a, b in
                if QualityChip.isBetter(a.element.chip, than: b.element.chip) { return true }
                if QualityChip.isBetter(b.element.chip, than: a.element.chip) { return false }
                return a.offset < b.offset
            }.map(\.element)
            return ChannelNameGroup(name: names[key] ?? key, key: key,
                                    choices: sorted.map { ChannelChoice(chip: $0.chip, indices: $0.indices, copy: $0.copy,
                                                                                start: $0.start, end: $0.end) })
        }
    }

    /// Channels grouped on their own airing times (`startTime`/`endTime`, nil when absent).
    static func group(_ channels: [SportEventChannel]) -> [ChannelNameGroup<SportEventChannel>] {
        group(channels, name: \.name, serverKey: \.nameKey,
              airing: { channel in channel.startTime.flatMap { start in channel.endTime.map { (start: start, end: $0) } } }, chip: \.chip)
    }

    /// An event's channels, grouped: each copy on its own airing of the event (#20, `SportEvent.airing(on:)`).
    static func group(_ event: SportEvent) -> [ChannelNameGroup<SportEventChannel>] {
        group(event.channels, name: \.name, serverKey: \.nameKey, airing: { event.airing(on: $0) }, chip: \.chip)
    }
}

extension SportEventChannel {
    /// D-65: this channel's badge (measured, else from the name).
    nonisolated var chip: QualityChip? { QualityChip.make(measured: measured, quality: quality) }
}

/// D-65, iPhone: what a tap on a channel row (or one of its chips) does: play a copy that is on or about to start,
/// record on it before the game (no choice sheet: Watch at <time> is in the row's touch and hold), nothing once it ended.
nonisolated enum PhoneChannelTap: Equatable, Sendable {
    case play, record, none

    static func of(_ action: SportRows.ChannelAction) -> PhoneChannelTap {
        switch action {
        case .play: .play
        case .wait: .record
        case .ended: .none
        }
    }
}

/// D-67: the players' quality tag: the playing channel's measured badge when known, else the decoded picture height.
nonisolated enum PlayerQualityTag {
    static func chip(measured: MeasuredQuality?) -> QualityChip? {
        measured?.known.flatMap { QualityChip.make(measured: $0, quality: nil) }
    }

    /// The decoded height's tag ("1080p"), or nil before the first frame is sized.
    static func decoded(height: CGFloat) -> String? {
        let height = max(height, 0)
        if height >= 2000 { return "4K" }
        if height >= 1400 { return "1440p" }
        if height >= 1030 { return "1080p" }
        if height >= 700 { return "720p" }
        if height >= 560 { return "576p" }
        if height > 0 { return "SD" }
        return nil
    }
}
