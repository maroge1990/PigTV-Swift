import XCTest
@testable import PigTV

/// A clock the test moves by hand: `sleep` suspends until `advance` reaches
/// its deadline, and throws when the task is cancelled (as Task.sleep does).
nonisolated final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var now = Duration.zero
    private var waiters: [UUID: (deadline: Duration, continuation: CheckedContinuation<Void, any Error>)] = [:]

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[id] = (now + duration, continuation)
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let waiter = waiters.removeValue(forKey: id)
            lock.unlock()
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }

    /// Moves time on and resumes every sleeper whose deadline has passed.
    func advance(_ duration: Duration) {
        lock.lock()
        now += duration
        let due = waiters.filter { $0.value.deadline <= now }
        for id in due.keys { waiters[id] = nil }
        lock.unlock()
        for waiter in due.values { waiter.continuation.resume() }
    }

    var sleepers: Int { lock.withLock { waiters.count } }
}

@MainActor
final class ChannelWarmerTests: XCTestCase {
    private let clock = ManualClock()
    private var sent: [WarmTarget] = []
    private var cancelled: [WarmTarget] = []
    /// When true a send stays in flight until it is cancelled.
    private var hold = false
    private var answer = true

    private let a = WarmTarget(sourceId: 1, channelId: "a", identityKey: "1:a")
    private let b = WarmTarget(sourceId: 1, channelId: "b", identityKey: "1:b")

    private func makeWarmer(enabled: Bool = true) -> ChannelWarmer {
        let clock = clock
        let warmer = ChannelWarmer(dwell: .milliseconds(1500), refresh: .seconds(60),
                                   sleep: { try await clock.sleep($0) }) { [unowned self] target in
            sent.append(target)
            if hold {
                do { try await Task.sleep(for: .seconds(60)) } catch { cancelled.append(target); return false }
            }
            return answer
        }
        warmer.setEnabled(enabled)
        return warmer
    }

    /// Lets main-actor tasks run: continuations resume, sends begin and end.
    private func settle() async { for _ in 0..<30 { await Task.yield() } }

    private func advance(_ seconds: Double) async {
        clock.advance(.milliseconds(Int(seconds * 1000)))
        await settle()
    }

    private func browse(_ warmer: ChannelWarmer, _ target: WarmTarget?, owner: String = "shelf") async {
        warmer.setBrowseTarget(target, owner: owner)
        await settle()
    }

    // MARK: Gates

    func testNothingIsSentWhileTheFeatureOrSettingIsOff() async {
        let warmer = makeWarmer(enabled: false)
        await browse(warmer, a)
        await advance(10)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(clock.sleepers, 0, "not even a dwell is started")
    }

    func testServerInfoDecidesWhetherWarmingIsOn() throws {
        XCTAssertTrue(try FakePigTVServer.info(warmingEnabled: true).warmingActive)
        XCTAssertFalse(try FakePigTVServer.info(warmingEnabled: false).warmingActive)
        XCTAssertFalse(try FakePigTVServer.info().warmingActive, "an older server has neither field")
    }

    // MARK: Dwell

    func testDwellIsRespectedAndFocusChurnSendsNothing() async {
        let warmer = makeWarmer()
        await browse(warmer, a)
        await advance(1.0)
        await browse(warmer, b)
        await advance(1.0)
        XCTAssertTrue(sent.isEmpty, "a moved before its dwell ended; b has only had 1 s")
        await browse(warmer, a)
        await advance(1.0)
        await browse(warmer, nil)
        await advance(5)
        XCTAssertTrue(sent.isEmpty, "focus left before anything settled")
        await browse(warmer, b)
        await advance(1.4)
        XCTAssertTrue(sent.isEmpty)
        await advance(0.2)
        XCTAssertEqual(sent, [b])
    }

    func testTheSameTargetReportedAgainDoesNotRestartTheDwell() async {
        let warmer = makeWarmer()
        await browse(warmer, a)
        await advance(1.0)
        await browse(warmer, a)
        await advance(0.6)
        XCTAssertEqual(sent, [a])
    }

    func testBrowsingWarmsOnceAndNeverRefreshes() async {
        let warmer = makeWarmer()
        await browse(warmer, a)
        await advance(1.6)
        await advance(300)
        XCTAssertEqual(sent, [a])
    }

    func testAShelfCannotClearAnotherShelfsTarget() async {
        let warmer = makeWarmer()
        await browse(warmer, a, owner: "first")
        await browse(warmer, b, owner: "second")
        await browse(warmer, nil, owner: "first") // arrives after the second shelf took focus
        await advance(1.6)
        XCTAssertEqual(sent, [b])
    }

    // MARK: One at a time, cancellation

    func testANewTargetCancelsTheRequestInFlight() async {
        hold = true
        let warmer = makeWarmer()
        await browse(warmer, a)
        await advance(1.6)
        XCTAssertEqual(sent, [a])
        XCTAssertTrue(cancelled.isEmpty)
        await browse(warmer, b)
        XCTAssertEqual(cancelled, [a], "the old request is cancelled, not left running")
        await advance(1.6)
        XCTAssertEqual(sent, [a, b])
        XCTAssertEqual(warmer.scheduled, b)
    }

    func testFocusMovingOffCancelsTheRequestInFlight() async {
        hold = true
        let warmer = makeWarmer()
        await browse(warmer, a)
        await advance(1.6)
        await browse(warmer, nil)
        XCTAssertEqual(cancelled, [a])
        XCTAssertNil(warmer.scheduled)
    }

    func testBackgroundingCancelsAndForgetsTheTarget() async {
        hold = true
        let warmer = makeWarmer()
        await browse(warmer, a)
        await advance(1.6)
        warmer.setActive(false)
        await settle()
        XCTAssertEqual(cancelled, [a])
        warmer.setActive(true)
        await advance(10)
        XCTAssertEqual(sent, [a], "coming back does not warm what was focused before")
    }

    func testBackgroundingDuringTheDwellSendsNothing() async {
        let warmer = makeWarmer()
        await browse(warmer, a)
        await advance(1.0)
        warmer.setActive(false)
        await advance(5)
        XCTAssertTrue(sent.isEmpty)
    }

    func testAFailedWarmIsNotRetried() async {
        answer = false
        let warmer = makeWarmer()
        warmer.setPlayerTarget(a)
        await settle()
        await advance(1.6)
        await advance(600)
        XCTAssertEqual(sent, [a], "a 204 or an error ends the series quietly")
    }

    // MARK: A real play

    func testNoWarmWhileARealPlayStartsAndItCancelsOneInFlight() async {
        hold = true
        let warmer = makeWarmer()
        await browse(warmer, a)
        await advance(1.6)
        let play = UUID()
        warmer.beginStart(play)
        await settle()
        XCTAssertEqual(cancelled, [a], "a warm never gets in a real play's way")
        warmer.setPlayerTarget(b)
        await advance(10)
        XCTAssertEqual(sent, [a], "nothing during the start")
        warmer.endStart(play)
        await settle()
        await advance(1.6)
        XCTAssertEqual(sent, [a, b], "after the resolve answers, the dwell starts afresh")
    }

    func testClosingThePlayerLiftsAStartThatNeverFinished() async {
        let warmer = makeWarmer()
        warmer.beginStart(UUID())
        warmer.setPlayerTarget(a)
        await advance(5)
        XCTAssertTrue(sent.isEmpty)
        warmer.playerClosed()
        await browse(warmer, b)
        await advance(1.6)
        XCTAssertEqual(sent, [b])
    }

    // MARK: While watching

    func testThePlayerRefreshesEverySixtySecondsAndStopsWhenItCloses() async {
        let warmer = makeWarmer()
        warmer.setPlayerTarget(a)
        await settle()
        await advance(1.6)
        XCTAssertEqual(sent, [a])
        await advance(59)
        XCTAssertEqual(sent.count, 1)
        await advance(1.5)
        XCTAssertEqual(sent, [a, a], "keeps the 90 s lifetime alive")
        await advance(60)
        XCTAssertEqual(sent.count, 3)
        warmer.playerClosed()
        await settle()
        await advance(300)
        XCTAssertEqual(sent.count, 3)
    }

    func testAChangeOfLikelyChannelReplacesTheOldAndRestartsTheDwell() async {
        let warmer = makeWarmer()
        warmer.setPlayerTarget(a)
        await settle()
        await advance(1.6)
        warmer.setPlayerTarget(b)
        await settle()
        await advance(1.0)
        XCTAssertEqual(sent, [a])
        await advance(0.6)
        XCTAssertEqual(sent, [a, b])
    }

    func testThePlayersTargetWinsOverWhatWasFocused() async {
        let warmer = makeWarmer()
        await browse(warmer, a)
        warmer.setPlayerTarget(b)
        await settle()
        await advance(1.6)
        XCTAssertEqual(sent, [b])
    }

    // MARK: The player's choice

    private func channel(_ id: String) -> Channel {
        Channel(rawID: id, sourceId: 1, name: id, logo: nil, category: nil, now: nil, next: nil)
    }

    func testPreviousChannelAfterASwitchElseTheNextUp() {
        let list = ["1", "2", "3", "4"].map(channel)
        // Just switched 2 -> 3: they often flip back.
        XCTAssertEqual(ChannelWarmer.likelyNext(current: list[2], previous: list[1], justSwitched: true, list: list)?.id, "1:2")
        // Opened the player on 3 (a remembered previous from long ago is not a switch): next up.
        XCTAssertEqual(ChannelWarmer.likelyNext(current: list[2], previous: list[0], justSwitched: false, list: list)?.id, "1:4")
        // Wraps like zap(1).
        XCTAssertEqual(ChannelWarmer.likelyNext(current: list[3], previous: nil, justSwitched: false, list: list)?.id, "1:1")
        // A switch with no usable previous falls back to next up.
        XCTAssertEqual(ChannelWarmer.likelyNext(current: list[0], previous: nil, justSwitched: true, list: list)?.id, "1:2")
        XCTAssertEqual(ChannelWarmer.likelyNext(current: list[0], previous: list[0], justSwitched: true, list: list)?.id, "1:2")
    }

    func testNoChoiceWhenThereIsNowhereToGo() {
        let only = [channel("1")]
        XCTAssertNil(ChannelWarmer.likelyNext(current: only[0], previous: nil, justSwitched: false, list: only))
        XCTAssertNil(ChannelWarmer.likelyNext(current: only[0], previous: nil, justSwitched: false, list: []))
        // A current channel outside the list steps to the list's first, as zap does.
        XCTAssertEqual(ChannelWarmer.likelyNext(current: channel("9"), previous: nil, justSwitched: false, list: only)?.id, "1:1")
    }

    // MARK: Sport focus

    func testOnlyAFocusedLiveEventWarmsItsBestChannel() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func event(_ id: String, start: Double, end: Double, kind: SportEventKind = .event, channels: Bool = true) -> SportEvent {
            SportEvent(id: id, title: id, league: "NFL", startTime: (now.timeIntervalSince1970 + start) * 1000,
                       endTime: (now.timeIntervalSince1970 + end) * 1000,
                       channels: channels ? [SportEventChannel(sourceId: 1, rawID: "701", name: "ESPN"),
                                             SportEventChannel(sourceId: 2, rawID: "88", name: "NFL")] : [], kind: kind)
        }
        let events = [event("live", start: -600, end: 600), event("soon", start: 600, end: 1200),
                      event("replay", start: -600, end: 600, kind: .replay), event("bare", start: -600, end: 600, channels: false)]
        XCTAssertEqual(SportWarming.target(eventID: "live", in: events, now: now),
                       WarmTarget(sourceId: 1, channelId: "701", identityKey: "1:701"))
        XCTAssertNil(SportWarming.target(eventID: "soon", in: events, now: now))
        XCTAssertNil(SportWarming.target(eventID: "replay", in: events, now: now))
        XCTAssertNil(SportWarming.target(eventID: "bare", in: events, now: now))
        XCTAssertNil(SportWarming.target(eventID: "missing", in: events, now: now))
        XCTAssertNil(SportWarming.target(eventID: nil, in: events, now: now))
    }
}
