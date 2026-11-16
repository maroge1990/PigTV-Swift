#if os(iOS)
import XCTest
@testable import PigTV

/// #336: the iPhone crashed (_dispatch_assert_queue_fail) when UIKit called `requestGeometryUpdate`'s error handler on a
/// background queue: the handler was a closure written inside `OrientationLock`, main-actor isolated under the target's
/// default isolation, so the runtime's isolation check trapped. The handler is now a nonisolated function.
final class OrientationLockTests: XCTestCase {
    /// Called the way UIKit calls it: off the main thread. Main-actor isolated, this would not compile here (a synchronous
    /// call from a nonisolated context); as a closure it would trap at run time.
    func testTheGeometryErrorHandlerRunsOffTheMainThread() {
        let done = expectation(description: "handler returned")
        DispatchQueue.global(qos: .userInitiated).async {
            XCTAssertFalse(Thread.isMainThread)
            OrientationLock.geometryUpdateFailed(NSError(domain: "UISceneErrorDomain", code: 101))
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }

    /// The function is what is handed to UIKit: it must be usable as a Sendable error handler.
    func testTheHandlerIsASendableErrorHandler() {
        let handler: @Sendable (any Error) -> Void = OrientationLock.geometryUpdateFailed
        let done = expectation(description: "detached call returned")
        Task.detached {
            handler(CocoaError(.featureUnsupported))
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }
}
#endif
