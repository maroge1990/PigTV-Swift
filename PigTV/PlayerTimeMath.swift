import Foundation

// The pure time sums behind the players' programme timeline and their "behind live"
// readout. (Start over and the dated timeshift window went with the server's tuner
// model in build 39.)
nonisolated enum PlayerTimeMath {
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
