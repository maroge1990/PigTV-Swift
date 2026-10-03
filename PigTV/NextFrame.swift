import QuartzCore
import UIKit

/// Runs `work` after the screen has had a chance to show what was built so
/// far. A plain `DispatchQueue.main.async` is not enough: the display link
/// that paces frames is served after queued blocks, so chained blocks still
/// ran inside one long stall. Used to cut a screen's first build (the TV
/// Guide's) into pieces the viewer sees as separate frames.
@MainActor
enum NextFrame {
    /// `fallback` keeps work from waiting forever when no frames are
    /// produced (display asleep, app not on screen).
    static func run(fallback: TimeInterval = 0.25, _ work: @escaping @MainActor () -> Void) {
        let ticket = Ticket(work)
        let link = CADisplayLink(target: ticket, selector: #selector(Ticket.fire))
        ticket.link = link
        link.add(to: .main, forMode: .common)
        DispatchQueue.main.asyncAfter(deadline: .now() + fallback) { ticket.fire() }
    }

    @MainActor
    private final class Ticket: NSObject {
        var link: CADisplayLink?
        private var work: (@MainActor () -> Void)?
        init(_ work: @escaping @MainActor () -> Void) { self.work = work }
        @objc func fire() {
            link?.invalidate()
            link = nil
            guard let work else { return }
            self.work = nil
            work()
        }
    }
}
