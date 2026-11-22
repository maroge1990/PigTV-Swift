import XCTest
@testable import PigTV

/// #360 (G4, build 379): SharedFetches' interleavings, forced rather than timed (CacheTests' shared-logo test failed once
/// on the iPhone with its fetch held open). Each scheduling point is a gate the test opens: a caller that joined and is
/// cancelled before it waits, a non-cancelling caller joining before or after the last cancelling one leaves, and the
/// logo test's own case (a non-cancelling caller cancelled before it starts).
final class SharedFetchesTests: XCTestCase {
    /// Suspends until opened (not cancellable: a task waiting here stays until `open`).
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if isOpen { lock.unlock(); continuation.resume() } else { waiters.append(continuation); lock.unlock() }
            }
        }
        var isOpenNow: Bool { lock.lock(); defer { lock.unlock() }; return isOpen }
        func open() {
            lock.lock(); isOpen = true; let all = waiters; waiters = []; lock.unlock()
            all.forEach { $0.resume() }
        }
    }

    private let fetches = SharedFetches<Int>()
    private let starts = Locked(0)
    private let finish = Gate()

    /// The fetch: counted, finished when the test opens `finish`, then 7; cancelled at once when cancelled (its sleep).
    private func start() -> Task<Int, any Error> {
        starts.value += 1
        let finish = finish
        return Task {
            while !finish.isOpenNow { try await Task.sleep(for: .milliseconds(5)) }
            try Task.checkCancellation()
            return 7
        }
    }

    /// A caller: joins, waits at `beforeWait` (if any), then waits for the fetch.
    private func caller(cancellable: Bool, beforeWait: Gate? = nil, joined: Gate? = nil) -> Task<Int, any Error> {
        Task {
            let (entry, _) = fetches.join("logo", cancellable: cancellable) { start() }
            joined?.open()
            await beforeWait?.wait()
            return try await fetches.wait(for: entry, key: "logo", cancellable: cancellable)
        }
    }

    /// The logo test's case: two non-cancelling callers, the first cancelled before it even starts.
    func testANonCancellingCallerCancelledBeforeItStartsLeavesTheSharedFetchToTheOther() async throws {
        let joinedA = Gate(), joinedB = Gate()
        let a = caller(cancellable: false, joined: joinedA)
        a.cancel()
        await joinedA.wait()
        let b = caller(cancellable: false, joined: joinedB)
        await joinedB.wait()
        finish.open()
        let fromB = try await b.value
        XCTAssertEqual(fromB, 7)
        XCTAssertEqual(starts.value, 1, "one fetch for both")
        let fromA = try? await a.value
        XCTAssertEqual(fromA, 7, "a non-cancelling caller is answered even when its own task was cancelled")
    }

    /// The last cancelling caller leaves after a non-cancelling one joined: the fetch is kept.
    func testTheLastCancellingCallerLeavingKeepsAFetchANonCancellingCallerJoined() async throws {
        let joinedA = Gate(), joinedB = Gate(), proceedA = Gate()
        let a = caller(cancellable: true, beforeWait: proceedA, joined: joinedA)
        await joinedA.wait()
        let b = caller(cancellable: false, joined: joinedB)
        await joinedB.wait()
        a.cancel()
        proceedA.open() // A registers already cancelled: it leaves at once
        finish.open()
        let fromB = try await b.value
        XCTAssertEqual(fromB, 7)
        XCTAssertEqual(starts.value, 1)
        _ = try? await a.value
    }

    /// A cancelling caller cancelled between its join and its wait leaves (the fetch is cancelled, nobody else waits);
    /// a non-cancelling caller joining after that starts a new fetch and is answered.
    func testACallerCancelledBetweenJoinAndWaitLeavesAndALaterCallerGetsItsOwnFetch() async throws {
        let joinedA = Gate(), joinedB = Gate(), proceedA = Gate()
        let a = caller(cancellable: true, beforeWait: proceedA, joined: joinedA)
        await joinedA.wait()
        a.cancel()
        proceedA.open()
        do { _ = try await a.value; XCTFail("the cancelled caller's fetch was not cancelled") } catch {}
        let b = caller(cancellable: false, joined: joinedB)
        await joinedB.wait()
        finish.open()
        let fromB = try await b.value
        XCTAssertEqual(fromB, 7, "a caller after the cancelled fetch is answered by a new one")
        XCTAssertEqual(starts.value, 2)
    }

    /// Two cancelling callers: the first leaving keeps the fetch for the second.
    func testOneOfTwoCancellingCallersLeavingKeepsTheFetch() async throws {
        let joinedA = Gate(), joinedB = Gate(), proceedA = Gate()
        let a = caller(cancellable: true, beforeWait: proceedA, joined: joinedA)
        await joinedA.wait()
        let b = caller(cancellable: true, joined: joinedB)
        await joinedB.wait()
        a.cancel()
        proceedA.open()
        finish.open()
        let fromB = try await b.value
        XCTAssertEqual(fromB, 7)
        XCTAssertEqual(starts.value, 1)
        _ = try? await a.value
    }
}
