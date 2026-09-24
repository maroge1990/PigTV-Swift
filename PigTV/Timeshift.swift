import Foundation

// C-E (server flag `timeshift`): the live window may be hours long and
// segments carry EXT-X-PROGRAM-DATE-TIME, so AVPlayerItem.currentDate() is
// meaningful. These are the pure date sums behind Start over and the info
// overlay's programme timeline; PlaybackModel feeds them from AVPlayerItem.
enum TimeshiftMath {
    /// Wall-clock dates at the ends of the seekable range, from the item's
    /// current date and its media times (seconds):
    /// start = currentDate − (currentTime − rangeStart),
    /// end = currentDate + (rangeEnd − currentTime).
    static func rangeDates(currentDate: Date, currentTime: Double, rangeStart: Double,
                           rangeEnd: Double) -> ClosedRange<Date>? {
        guard currentTime.isFinite, rangeStart.isFinite, rangeEnd.isFinite, rangeEnd >= rangeStart else { return nil }
        let start = currentDate.addingTimeInterval(-(currentTime - rangeStart))
        let end = currentDate.addingTimeInterval(rangeEnd - currentTime)
        return start...end
    }

    /// Start over is offered when the programme began inside the window
    /// (and before its live edge).
    static func canStartOver(programmeStart: Date, window: ClosedRange<Date>) -> Bool {
        programmeStart >= window.lowerBound && programmeStart < window.upperBound
    }

    /// Fraction of `programme` elapsed at `date`, clamped to 0…1.
    static func fraction(of date: Date, from start: Date, to end: Date) -> Double {
        let length = end.timeIntervalSince(start)
        guard length > 0 else { return 0 }
        return min(1, max(0, date.timeIntervalSince(start) / length))
    }

    /// "4:05" under an hour, "1 h 05 min" from an hour (a 3 h window made
    /// minutes:seconds unreadable: "134:10").
    static func behindText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.isFinite ? seconds.rounded() : 0))
        if total >= 3600 {
            return String(format: "%d h %02d min", total / 3600, (total / 60) % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
