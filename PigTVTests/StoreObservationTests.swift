import XCTest
@testable import PigTV

/// maroge1990/PigTV#51: each Browse store is @Observable, so a view is re-evaluated by the properties it reads, not by
/// the rest of its store. Observing an ObservableObject store, every change to it re-evaluated every view holding it:
/// each first count below was then one or more (these tests failed on 391).
@MainActor
final class StoreObservationTests: XCTestCase {
    /// A view reading `reads` alone, while `change` changes other properties of `store`: no re-evaluation; then `told`
    /// changes what it reads: one.
    private func assertReadsOnly(_ store: AnyObject, _ reads: @escaping @MainActor () -> Void, untouchedBy change: () -> Void,
                                 toldBy told: () -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        let others = await Invalidations.during(observing: [store], reads: reads) { change() }
        XCTAssertEqual(others, 0, "a change to another property re-evaluated a view that does not read it", file: file, line: line)
        let own = await Invalidations.during(observing: [store], reads: reads) { told() }
        XCTAssertEqual(own, 1, "a change to what the view reads re-evaluates it once", file: file, line: line)
    }

    private func schedules(_ json: String) -> [ScheduledRecording] {
        try! JSONDecoder().decode([ScheduledRecording].self, from: Data(json.utf8))
    }

    func testAViewReadingTheGuideTotalIsNotReevaluatedByTheGuidesBusyAndErrorState() async {
        let store = GuideStore()
        await assertReadsOnly(store, { _ = store.guideTotal }, untouchedBy: {
            store.guideBusy = true; store.guideError = "Could not load"; store.guidePaging = true
        }, toldBy: { store.guideTotal += 1 })
    }

    func testAViewReadingTheRecordingsErrorIsNotReevaluatedByTheRules() async {
        let store = RecordingsStore()
        await assertReadsOnly(store, { _ = store.recordingsError }, untouchedBy: {
            store.rulesLoaded = true; store.rulesError = "Could not load"; store.readsSeen += 1
        }, toldBy: { store.recordingsError = "Could not load" })
    }

    func testAViewReadingTheFavouritesErrorIsNotReevaluatedByTheFirstAnswer() async {
        let store = LibraryStore()
        await assertReadsOnly(store, { _ = store.favouritesError }, untouchedBy: { store.favouritesAnswered = true },
                              toldBy: { store.favouritesError = "Could not load" })
    }

    func testAViewReadingTheScheduledMarksIsNotReevaluatedByARecordingStarting() async {
        let recordings = RecordingsStore()
        let marks = ScheduleMarks(following: recordings)
        recordings.schedules = schedules(#"[{"id":1,"title":"T","channel_name":"A","program_start":1000,"program_end":2000,"status":"scheduled"}]"#)
        XCTAssertEqual(marks.scheduledKeys, ["A|1000"])
        // Scheduled → recording: the same programme is marked; only the channels recording now change.
        await assertReadsOnly(marks, { _ = marks.scheduledKeys }, untouchedBy: {
            recordings.schedules = schedules(#"[{"id":1,"title":"T","channel_name":"A","program_start":1000,"program_end":2000,"status":"recording"}]"#)
        }, toldBy: {
            recordings.schedules = schedules(#"[{"id":1,"title":"T","channel_name":"A","program_start":3000,"program_end":4000,"status":"recording"}]"#)
        })
        XCTAssertEqual(marks.recordingChannels, ["A"])
        XCTAssertEqual(marks.scheduledKeys, ["A|3000"])
        // Undo's hiding still takes a schedule's mark away at once (Apple 122).
        recordings.pendingRemovals = [RecordingsHome.key(recordings.schedules[0])]
        XCTAssertEqual(marks.scheduledKeys, [])
        XCTAssertEqual(marks.recordingChannels, [])
    }

    func testAViewReadingTheBusyFlagIsNotReevaluatedByAnActionsMessage() async {
        let store = ActionState()
        await assertReadsOnly(store, { _ = store.mutationBusy }, untouchedBy: {
            store.actionMessage = "Scheduled"; store.actionError = "Could not schedule"
        }, toldBy: { store.mutationBusy = true })
    }
}
