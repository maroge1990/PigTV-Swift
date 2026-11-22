import Combine
import Foundation
import Observation
@testable import PigTV

/// maroge1990/PigTV#51: what re-evaluates a view's body, for either kind of model. A view holding an `ObservableObject`
/// (`@ObservedObject`, `@StateObject`) is re-evaluated whenever that object publishes, whatever changed; a view reading
/// an `@Observable` model is re-evaluated only when a property its body read changes. So this counts both: each
/// `objectWillChange` of `objects` that are ObservableObjects, and each change to an observed property `reads` reads
/// (`withObservationTracking`, registered again at once after each change, so every change counts, as each publish does).
/// `reads` stands for the view's body: it reads exactly what the view draws.
@MainActor
final class Invalidations {
    private(set) var count = 0
    private var publishers: [AnyCancellable] = []
    private let reads: @MainActor () -> Void
    private var stopped = false
    /// Run on the main queue just after each counted property change has been made (it is counted as it is about to be).
    var afterEachChange: (@MainActor () -> Void)?

    init(observing objects: [AnyObject] = [], reads: @escaping @MainActor () -> Void) {
        self.reads = reads
        for object in objects {
            if let published = object as? any ObservableObject {
                publishers.append(Self.sink(published) { [weak self] in self?.count += 1 })
            }
        }
        track()
    }

    /// Stops counting (the counter may be kept for its total).
    func stop() {
        stopped = true
        publishers.removeAll()
    }

    private static func sink<Object: ObservableObject>(_ object: Object, _ seen: @escaping @MainActor () -> Void) -> AnyCancellable {
        object.objectWillChange.sink { _ in MainActor.assumeIsolated { seen() } }
    }

    private func track() {
        guard !stopped else { return }
        withObservationTracking { reads() } onChange: { [weak self] in
            // Called as the property is about to change, on the actor that changes it (the models are main-actor).
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                self.count += 1
                self.track()
                if let after = self.afterEachChange { DispatchQueue.main.async { after() } }
            }
        }
    }
}

@MainActor
extension Invalidations {
    /// Invalidations seen while `event` runs (and 50 ms after it, for anything it set off).
    static func during(observing objects: [AnyObject] = [], reads: @escaping @MainActor () -> Void,
                       _ event: () async -> Void) async -> Int {
        let counter = Invalidations(observing: objects, reads: reads)
        await event()
        try? await Task.sleep(for: .milliseconds(50))
        counter.stop()
        return counter.count
    }
}

/// Everything a view could draw from each store: a view reading all of a store is re-evaluated by any change to it, which
/// is what observing an ObservableObject store meant (#51 keeps those guarantees while views come to read less).
@MainActor
extension GuideStore {
    func readEverything() {
        _ = (guide, guideBusy, guideError, guideHasMore, guidePaging, window, guideTotal, guideLoadedAt, fromCache)
        _ = (guideLoadedUntil, guideEnded, guideProgrammesVersion, schedule)
    }
}

@MainActor
extension RecordingsStore {
    func readEverything() {
        _ = (recordings, schedules, recordingsBusy, recordingsError, loaded, readsSeen, schedule, rulesLoaded, rules)
        _ = (rulesError, pendingRemovals, uncertainRemovals, refusedAirings)
    }
}

@MainActor
extension LibraryStore {
    func readEverything() { _ = (favourites, favouritesAnswered, favouritesError) }
}

@MainActor
extension ScheduleMarks {
    func readEverything() { _ = (scheduledKeys, recordingChannels, recordingChannelKeys) }
}

@MainActor
extension ActionState {
    func readEverything() { _ = (mutationBusy, actionMessage, actionError) }
}
