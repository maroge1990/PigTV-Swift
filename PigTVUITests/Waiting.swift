import Foundation

/// Polls `condition` until it holds or `timeout` passes; true when it held. For UI tests
/// that would otherwise sleep a fixed time and then assert: instant when the app is quick,
/// patient when the simulator is loaded (a fixed sleep fails then, and wastes time when not).
func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return condition()
}
