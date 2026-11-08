import XCTest
@testable import PigTV

/// #257 (Mark, 8 Nov): a live event carried by several channels offers "Watch on… (N channels)" in the long-press menu,
/// so the channel is chosen before the player opens. Before, only Record on let you choose another channel.
final class WatchOnTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_157_200) // 8 Nov 2026 17:00 UTC
    private var ms: Double { now.timeIntervalSince1970 * 1000 }

    private func channel(_ id: String, _ name: String, stable: String? = nil, quality: SportQuality? = .hd) -> SportEventChannel {
        var c = SportEventChannel(sourceId: 1, rawID: id, stableId: stable, name: name)
        c.quality = quality
        return c
    }
    private func race(channels: [SportEventChannel], replay: Bool = false) -> SportEvent {
        var e = SportEvent(id: "f1-race", title: "Sao Paulo Grand Prix", league: "F1", startTime: ms - 600_000,
                           endTime: ms + 7_200_000, channels: channels)
        if replay { e.kind = .replay }
        return e
    }
    private var programme: GuideProgramme {
        GuideProgramme(title: "Live Sao Paulo F1 Grand Prix", description: nil, startTime: ms - 300_000, endTime: ms + 7_000_000)
    }

    func testALiveEventOnSeveralChannelsIsFoundFromAnyOfThem() {
        let event = race(channels: [channel("pos_1", "Sky Sports F1", quality: .uhd), channel("pos_2", "Fox Sports 506"),
                                    channel("pos_3", "Kayo 1", stable: "kayo1")])
        XCTAssertEqual(WatchOn.event(in: [event], sourceId: 1, rawID: "pos_2", stableId: nil, programme: programme, now: now)?.id, "f1-race")
        XCTAssertEqual(WatchOn.event(in: [event], sourceId: 1, rawID: "renumbered", stableId: "kayo1", programme: programme, now: now)?.id,
                       "f1-race", "by stable id when the position moved")
        XCTAssertNil(WatchOn.event(in: [event], sourceId: 1, rawID: "pos_9", stableId: nil, programme: programme, now: now), "another channel")
        XCTAssertNil(WatchOn.event(in: [event], sourceId: 1, rawID: "pos_2", stableId: nil, programme: programme,
                                   now: now.addingTimeInterval(-3600)), "not on yet")
        XCTAssertNil(WatchOn.event(in: [race(channels: [channel("pos_2", "Fox Sports 506")])], sourceId: 1, rawID: "pos_2",
                                   stableId: nil, programme: programme, now: now), "one channel: nothing to choose")
        XCTAssertNil(WatchOn.event(in: [race(channels: [channel("pos_1", "A"), channel("pos_2", "B")], replay: true)], sourceId: 1,
                                   rawID: "pos_2", stableId: nil, programme: programme, now: now), "never a replay")
        XCTAssertEqual(WatchOn.label(channel("pos_1", "Sky Sports F1", quality: .uhd)), "Sky Sports F1 · UHD")
    }

    func testTheMenuOffersWatchOnOnlyWithAChoice() {
        var subject = ProgrammeMenuSubject(channelName: "Fox Sports 506", programme: programme)
        XCTAssertFalse(ProgrammeMenu.items(subject, now: now).contains { $0.id == "watchOn" })
        subject.watchOnChannels = 3
        let items = ProgrammeMenu.items(subject, now: now)
        let watch = items.first { $0.id == "watchOn" }
        XCTAssertEqual(watch?.title, "Watch on… (3 channels)")
        XCTAssertEqual(watch?.isRecordSection, false)
        XCTAssertLessThan(items.firstIndex { $0.id == "watchOn" }!, items.firstIndex { $0.id == "details" }!, "first after RECORD")
    }

    /// 185 Codex round 1 (high): a channel whose airing has ended, or not begun, is never offered or played.
    func testOnlyChannelsAiringItNowAreOfferedAndPlayed() {
        var ended = channel("pos_2", "Fox Sports 506"); ended.startTime = ms - 7_200_000; ended.endTime = ms - 60_000
        var later = channel("pos_3", "Kayo 1"); later.startTime = ms + 3_600_000; later.endTime = ms + 9_000_000
        let event = race(channels: [channel("pos_1", "Sky Sports F1"), ended, later, channel("pos_4", "Viaplay")])
        XCTAssertEqual(WatchOn.onAir(event, now: now).channels.map(\.rawID), ["pos_1", "pos_4"])
        XCTAssertNil(WatchOn.play(event, on: ended, now: now), "ended meanwhile: nothing plays")
        XCTAssertEqual(WatchOn.play(event, on: event.channels[3], now: now)?.channels.map(\.rawID), ["pos_1", "pos_4"], "the zap list too")
        let two = race(channels: [channel("pos_1", "Sky Sports F1"), ended])
        XCTAssertNil(WatchOn.event(in: [two], sourceId: 1, rawID: "pos_1", stableId: nil, programme: programme, now: now),
                     "only one channel on air: nothing to choose")
    }

    /// 185 Codex round 1 (medium): after a renumbering, a cached event's position can be another channel's.
    func testAReusedPositionWithAnotherStableIdIsNotTheEvent() {
        let event = race(channels: [channel("pos_1", "Sky Sports F1", stable: "skyf1"), channel("pos_2", "Fox Sports 506", stable: "fox506")])
        XCTAssertNil(WatchOn.event(in: [event], sourceId: 1, rawID: "pos_2", stableId: "hbo", programme: programme, now: now))
        XCTAssertNotNil(WatchOn.event(in: [event], sourceId: 1, rawID: "pos_9", stableId: "fox506", programme: programme, now: now))
    }
}
