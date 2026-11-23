import Foundation

/// #58, #308, #369 (option B, Mark, 23 Nov 2026): one rule for the buttons of every player (live TV, a recording still
/// being made, a finished recording) on every device. Buttons that move you in time sit on the progress bar: Start over at
/// its start, Skip break and Go to live at its end. Everything else sits in one row in a fixed order, a button that does
/// not apply left out and the rest closing up. Pure (tests `PlayerButtonsTests`).
nonisolated enum PlayerButton: String, Equatable, Hashable, Sendable {
    // On the bar.
    case startOver, skipBreak, goLive
    // In the row, in this order.
    case playPause, autoSkip, tracks, favourite, record, lastChannel, syncMarker

    /// The row's order (the bar's is Start over, then Skip break, then Go to live).
    static let rowOrder: [PlayerButton] = [.playPause, .autoSkip, .tracks, .favourite, .record, .lastChannel, .syncMarker]
    static let barOrder: [PlayerButton] = [.startOver, .skipBreak, .goLive]

    var onBar: Bool { Self.barOrder.contains(self) }
}

/// The buttons one player shows now: the row and the bar, each left to right.
nonisolated struct PlayerButtons: Equatable, Sendable {
    let row: [PlayerButton]
    let bar: [PlayerButton]

    init(_ shown: Set<PlayerButton>) {
        row = PlayerButton.rowOrder.filter(shown.contains)
        bar = PlayerButton.barOrder.filter(shown.contains)
    }

    /// Live TV. `startOver`: a recording of the programme now on the channel can be watched from its start (#308);
    /// `goLive`: behind the live point or paused; `tracks`: more than one sound track or any subtitles (Apple TV only);
    /// `lastChannel`: a remembered channel other than this one; `syncMarker`: Labs › Sync marker (Apple TV: last in the row).
    /// `pause`: Pause is a row button (the Apple TV); on iPad and iPhone it is the big centre button instead.
    static func live(startOver: Bool, goLive: Bool, tracks: Bool, lastChannel: Bool, syncMarker: Bool,
                     pause: Bool = true) -> PlayerButtons {
        var shown: Set<PlayerButton> = [.favourite, .record]
        if pause { shown.insert(.playPause) }
        if startOver { shown.insert(.startOver) }
        if goLive { shown.insert(.goLive) }
        if tracks { shown.insert(.tracks) }
        if lastChannel { shown.insert(.lastChannel) }
        if syncMarker { shown.insert(.syncMarker) }
        return PlayerButtons(shown)
    }

    /// A recording (still being made, or finished). `inBreak`: the playhead is in a break found in it; `hasBreaks`: any
    /// were found (Auto-skip breaks, no dead control otherwise); `canGoLive`: still being made and well short of its live
    /// point (#335, `RecordingGoLive`). `pause` as for `live`.
    static func recording(inBreak: Bool, hasBreaks: Bool, canGoLive: Bool, pause: Bool = true) -> PlayerButtons {
        var shown: Set<PlayerButton> = []
        if pause { shown.insert(.playPause) }
        if hasBreaks { shown.insert(.autoSkip) }
        if inBreak { shown.insert(.skipBreak) }
        if canGoLive { shown.insert(.goLive) }
        return PlayerButtons(shown)
    }

    func buttons(in line: PlayerCursor.Line) -> [PlayerButton] { line == .row ? row : bar }
}

/// The Apple TV remote's place in the player's two lines of buttons (the players are one full-screen Button that reads
/// every press itself, not SwiftUI focus). It names the button it is on, so a button appearing or going elsewhere in the
/// line never moves it; when its own button goes it moves to the nearest one left in that line, or back to the row when
/// the bar has none. Pure (tests `PlayerCursorTests`).
nonisolated struct PlayerCursor: Equatable, Sendable {
    enum Line: String, Equatable, Sendable { case row, bar }
    enum Move: Equatable, Sendable { case left, right, up, down }

    private(set) var line: Line = .row
    /// The position in the line (kept in range by `settle`).
    private(set) var index = 0
    /// The button it is on, when it is on one.
    private(set) var button: PlayerButton?
    /// The row position it left for the bar, to return to.
    private var rowIndex = 0
    private var rowButton: PlayerButton?

    init() {}

    /// The chrome opens: on the row, its first button (#335: never Go to live).
    mutating func open(in buttons: PlayerButtons) {
        line = .row
        index = 0
        button = buttons.row.first
        rowIndex = 0
        rowButton = nil
    }

    /// A press of the remote's arrows while the chrome shows. False: the chrome hides (Up from the row; Down from the bar,
    /// or from the row when the bar has nothing).
    mutating func move(_ move: Move, in buttons: PlayerButtons) -> Bool {
        settle(in: buttons)
        let items = buttons.buttons(in: line)
        switch (move, line) {
        case (.left, _):
            guard !items.isEmpty else { return true }
            index = max(0, index - 1)
            button = items[index]
        case (.right, _):
            guard !items.isEmpty else { return true }
            index = min(items.count - 1, index + 1)
            button = items[index]
        case (.up, .row), (.down, .bar):
            return false
        case (.down, .row):
            guard let target = Self.landing(buttons.bar) else { return false }
            rowIndex = index
            rowButton = button
            line = .bar
            index = target
            button = buttons.bar[target]
        case (.up, .bar):
            backToRow(buttons)
        }
        return true
    }

    /// Puts it on `target` (a break starting while the chrome shows: Skip break), when that is shown.
    mutating func select(_ target: PlayerButton, in buttons: PlayerButtons) {
        let targetLine: Line = target.onBar ? .bar : .row
        guard let at = buttons.buttons(in: targetLine).firstIndex(of: target) else { return }
        if targetLine == .bar, line == .row { rowIndex = index; rowButton = button }
        line = targetLine
        index = at
        button = target
    }

    /// The buttons changed: stay on the same button wherever it now is; if it has gone, the nearest one left in the line;
    /// if the bar has none left, back to the row where it was.
    mutating func settle(in buttons: PlayerButtons) {
        let items = buttons.buttons(in: line)
        if line == .bar, items.isEmpty { backToRow(buttons); return }
        if let button, let at = items.firstIndex(of: button) { index = at; return }
        guard !items.isEmpty else { index = 0; button = nil; return }
        index = min(max(0, index), items.count - 1)
        button = items[index]
    }

    /// Where it is on these buttons, without moving it (what the screen draws between presses).
    func settled(in buttons: PlayerButtons) -> PlayerCursor {
        var copy = self
        copy.settle(in: buttons)
        return copy
    }

    /// The button Select runs, if any.
    func current(in buttons: PlayerButtons) -> PlayerButton? {
        let at = settled(in: buttons)
        let items = buttons.buttons(in: at.line)
        return items.indices.contains(at.index) ? items[at.index] : nil
    }

    /// Down from the row lands on the bar's right end (Skip break before Go to live), else Start over.
    static func landing(_ bar: [PlayerButton]) -> Int? {
        if let skip = bar.firstIndex(of: .skipBreak) { return skip }
        if let live = bar.firstIndex(of: .goLive) { return live }
        return bar.isEmpty ? nil : 0
    }

    private mutating func backToRow(_ buttons: PlayerButtons) {
        line = .row
        let items = buttons.row
        if let rowButton, let at = items.firstIndex(of: rowButton) { index = at }
        else { index = items.isEmpty ? 0 : min(rowIndex, items.count - 1) }
        button = items.indices.contains(index) ? items[index] : nil
    }
}

extension PlayerCursor {
    /// The players' DEBUG accessibility value: "action=<position in the line>; line=row|bar; button=<name>".
    static func describe(_ cursor: PlayerCursor, _ buttons: PlayerButtons) -> String {
        let at = cursor.settled(in: buttons)
        return "action=\(at.index); line=\(at.line.rawValue); button=\(at.current(in: buttons)?.rawValue ?? "none")"
    }
}

/// The words and symbols the players give their buttons (one place for the Apple TV and the touch players).
nonisolated enum PlayerButtonText {
    static let startOver = "Start over"
    static let skipBreak = "Skip break"

    /// "Auto-skip breaks: Off"; `short` (iPhone): "Auto-skip: Off".
    static func autoSkip(on: Bool, short: Bool = false) -> String {
        "\(short ? "Auto-skip" : "Auto-skip breaks"): \(on ? "On" : "Off")"
    }

    static func autoSkipIcon(on: Bool) -> String { on ? "circle.inset.filled" : "circle" }

    static func icon(_ button: PlayerButton) -> String {
        switch button {
        case .startOver: return "backward.end.fill"
        case .skipBreak: return "forward.end.fill"
        case .goLive: return "dot.radiowaves.left.and.right"
        case .playPause: return "pause.fill"
        case .autoSkip: return autoSkipIcon(on: false)
        case .tracks: return "captions.bubble"
        case .favourite: return "heart"
        case .record: return "record.circle"
        case .lastChannel: return "arrow.uturn.backward"
        case .syncMarker: return "waveform.badge.exclamationmark"
        }
    }

    static func label(_ button: PlayerButton) -> String {
        switch button {
        case .startOver: return startOver
        case .skipBreak: return skipBreak
        case .goLive: return "Go to live"
        case .playPause: return "Pause"
        case .autoSkip: return autoSkip(on: false)
        case .tracks: return "Audio & subtitles"
        case .favourite: return "Favourite"
        case .record: return "Record"
        case .lastChannel: return "Last channel"
        case .syncMarker: return SyncMarker.label
        }
    }
}

extension BrowseModel {
    /// #308: Start over on live TV: the recording being made of the programme on this channel at `now`, when it can be
    /// watched from its start (the Guide's Watch from start, `recordingInProgress`); nil otherwise.
    func startOverRecording(channel: Channel, at now: Date) -> Recording? {
        guard let row = guideRow(id: channel.id, identityKey: channel.identityKey),
              let programme = GuideNavigation.programme(in: row.programmes, at: now) else { return nil }
        return recordingInProgress(channel: row, programme: programme)
    }
}

/// #308 fixture (PIGTV_UI_TEST_START_OVER, `PlayerButtonsTests`): the programme on `channel` at `now` is being recorded
/// and can be watched from its start: its schedule (status "recording", naming the channel by its item) and the recording.
@MainActor enum PlayerButtonsFixture {
    @discardableResult
    static func recordNow(_ channel: Channel, in browse: BrowseModel, at now: Date = Date(), watchLive: Bool = true) -> Recording? {
        guard let row = browse.guideRow(id: channel.id, identityKey: channel.identityKey),
              let programme = GuideNavigation.programme(in: row.programmes, at: now) else { return nil }
        let id = 731
        let title = programme.title.replacingOccurrences(of: "\"", with: "'")
        let schedule = #"{"id":\#(id + 1),"title":"\#(title)","channel_name":"\#(row.name)","program_start":\#(Int64(programme.startTime)),"program_end":\#(Int64(programme.endTime)),"status":"recording","recording_id":\#(id),"source_id":\#(row.sourceId),"channel_item_id":"\#(row.rawID)"}"#
        let recording = #"{"id":\#(id),"title":"\#(title)","channel_name":"\#(row.name)","started_at":\#(programme.startTime),"status":"recording","watch_live":\#(watchLive)}"#
        guard let scheduled = try? JSONDecoder().decode(ScheduledRecording.self, from: Data(schedule.utf8)),
              let made = try? JSONDecoder().decode(Recording.self, from: Data(recording.utf8)) else { return nil }
        browse.schedules += [scheduled]
        browse.recordings += [made]
        return made
    }
}
