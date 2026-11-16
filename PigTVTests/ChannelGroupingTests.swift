import XCTest
@testable import PigTV

// D-65 (#266): an F1 race listed Sky Sports F1 about a dozen times. The pickers (the Sport event page's channel list,
// the long-press channel picker, the record page's Record on) now show one row per channel name with a chip per measured
// quality and frame rate, best first; copies with the same name, quality and frame rate fold into one chip that acts on
// the first of them in the server's order; a name in one quality offers no choice. Display only.
final class ChannelGroupingTests: XCTestCase {
    private func copy(_ id: String, _ name: String, _ label: MeasuredQuality.Label? = nil, fps: Int? = nil,
                      quality: SportQuality? = nil) -> SportEventChannel {
        SportEventChannel(sourceId: 1, rawID: id, name: name, quality: quality,
                          measured: label.map { MeasuredQuality(label: $0, fps: fps) })
    }

    /// The server's best-first list: an F1 race with Sky Sports F1 in five copies and a simulcast on another channel.
    private var race: [SportEventChannel] {
        [copy("a", "Sky Sports F1", .fhd, fps: 50),
         copy("b", "Sky Sports F1", .uhd, fps: 50),
         copy("c", "Sky Sports Main Event", .fhd, fps: 50),
         copy("d", "sky sports  F1 ", .fhd, fps: 50),
         copy("e", "Sky Sports F1", .fhd, fps: 25),
         copy("f", "Sky Sports F1", .sd, fps: 25)]
    }

    func testOneRowPerNameInTheServersOrder() {
        let groups = ChannelGrouping.group(race)
        XCTAssertEqual(groups.map(\.name), ["Sky Sports F1", "Sky Sports Main Event"], "a simulcast keeps its own row")
        XCTAssertEqual(groups[0].indices, [0, 1, 3, 4, 5], "the name matches whatever its case and spacing")
    }

    func testChipsAreBestFirstThenHigherFrameRate() {
        let chips = ChannelGrouping.group(race)[0].choices.map { $0.chip?.text }
        XCTAssertEqual(chips, ["4K · 50", "1080 · 50", "1080 · 25", "SD · 25"])
    }

    func testSameNameQualityAndFrameRateFoldIntoOneChipActingOnTheFirstCopy() {
        let fold = ChannelGrouping.group(race)[0].choices[1]
        XCTAssertEqual(fold.indices, [0, 3])
        XCTAssertEqual(fold.copy.rawID, "a", "the first of the folded copies in the server's order")
    }

    func testAChipActsOnItsOwnCopy() {
        let choices = ChannelGrouping.group(race)[0].choices
        XCTAssertEqual(choices.map(\.copy.rawID), ["b", "a", "e", "f"])
        XCTAssertEqual(ChannelGrouping.group(race)[0].best.copy.rawID, "b", "the row (iPhone tap) acts on the best chip's copy")
    }

    func testANameInOneQualityOffersNoChoice() {
        let groups = ChannelGrouping.group([copy("a", "BT Sport 1", .fhd, fps: 50), copy("b", "BT Sport 1", .fhd, fps: 50),
                                            copy("c", "Eurosport", .hd, fps: 25)])
        XCTAssertEqual(groups.map(\.choosesQuality), [false, false])
        XCTAssertEqual(groups[0].best.copy.rawID, "a")
        XCTAssertEqual(groups[0].best.indices, [0, 1])
    }

    func testUnmeasuredCopiesFallBackToTheNamesLabel() {
        let groups = ChannelGrouping.group([copy("a", "Fox Sports UHD", quality: .uhd), copy("b", "Fox Sports UHD", quality: .uhd),
                                            copy("c", "Fox Sports UHD", .fhd, fps: 50), copy("d", "Fox Sports UHD", .uhd, fps: 50)])
        let chips = groups[0].choices.map(\.chip)
        XCTAssertEqual(chips.map { $0?.text }, ["4K · 50", "4K", "1080 · 50"], "measured 4K, then the name's 4K, then 1080")
        XCTAssertEqual(chips.map { $0?.measured }, [true, false, true])
        XCTAssertEqual(groups[0].choices[1].indices, [0, 1], "unmeasured copies with the same name fold together")
    }

    func testACopyWithNoQualityAtAllComesLast() {
        let groups = ChannelGrouping.group([copy("a", "Kayo", nil), copy("b", "Kayo", .sd, fps: 25)])
        XCTAssertEqual(groups[0].choices.map { $0.chip?.text }, ["SD · 25", nil])
        XCTAssertNil(ChannelGrouping.group([copy("a", "Kayo", nil)])[0].best.chip, "no badge at all")
    }

    func testTheRecordPageGroupsItsOptionsAndAChipSelectsItsCopy() {
        let programme = GuideProgramme(title: "F1", description: nil, startTime: 1_000_000, endTime: 5_000_000)
        let airings = race.map { channel in
            RecordRequest.Airing(channel: GuideChannel(rawID: channel.rawID, sourceId: 1, name: channel.name, logo: nil,
                                                       category: nil, programmes: [programme]),
                                 programme: programme, quality: channel.quality, measured: channel.measured)
        }
        let request = RecordRequest(title: "F1", airings: airings)
        let groups = RecordPlan.channelGroups(request)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].choices.map(\.copy), [1, 0, 4, 5], "each chip selects that copy's airing")
        XCTAssertEqual(groups[1].choosesQuality, false)
        XCTAssertEqual(RecordPlan.recordOnNote(groups), "2 channels in your guide carry it")
        XCTAssertEqual(RecordPlan.recordOnNote([groups[0]]), "1 channel in your guide carries it, in 4 qualities")
    }

    func testOnIPhoneATapRecordsBeforeTheGame() {
        XCTAssertEqual(PhoneChannelTap.of(.play), .play)
        XCTAssertEqual(PhoneChannelTap.of(.wait), .record, "D-65: no choice sheet; Watch at is in touch and hold")
        XCTAssertEqual(PhoneChannelTap.of(.ended), PhoneChannelTap.none)
    }

    #if DEBUG
    @MainActor func testTheQualitiesFixtureDrawsChips() {
        let guide = (0..<6).map { GuideChannel(rawID: "g\($0)", sourceId: 1, name: "G\($0)", logo: nil, category: nil, programmes: []) }
        guard let event = GuideFixtures.qualityEvent(from: guide) else { return XCTFail("no fixture") }
        let groups = ChannelGrouping.group(event.channels)
        XCTAssertEqual(groups.map(\.name), ["Sky Sports F1", "Sky Sports Main Event"])
        XCTAssertEqual(groups[0].choices.map { $0.chip?.text }, ["4K · 50", "1080 · 50", "1080 · 25", "1080", "720 · 50", "SD · 25"])
        XCTAssertEqual(groups[0].best.indices, [0, 3, 8], "three 4K · 50 copies fold into one chip")
        XCTAssertEqual(groups[1].choices.map { $0.chip?.text }, ["4K · 50", "1080 · 50"])
        XCTAssertEqual(Set(event.channels.map(\.id)).count, event.channels.count, "every copy has its own id")
    }
    #endif
}
