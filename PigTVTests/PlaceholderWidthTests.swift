import SwiftUI
import XCTest
@testable import PigTV

/// #280 (review of 207): a loading layout must never be wider than the width its page gives it. On an iPad in portrait the
/// Sport front's placeholder rails (four 260 pt cards side by side) and banner made the page about 1 100 pt wide, so the
/// placeholders ran off both edges and the real header above them was clipped. Each placeholder is measured as its page
/// would lay it out: in a hosting controller, proposed a width (and an unlimited height), it must choose a width no
/// greater than the one proposed (`UIHostingController.sizeThatFits(in:)`).
@MainActor
final class PlaceholderWidthTests: XCTestCase {
    private struct Case {
        let name: String
        let view: AnyView
    }

    /// The width a placeholder takes when its page proposes `width` (sport pages stack their panels below
    /// `SportColumns.narrowBelow`, as `SportsLandingView` decides from the same width on iOS).
    private func fitted(_ view: AnyView, width: CGFloat) -> CGFloat {
        #if os(iOS)
        let narrow = width < SportColumns.narrowBelow
        #else
        let narrow = false
        #endif
        let host = UIHostingController(rootView: AnyView(view.environment(\.sportNarrow, narrow)))
        return host.sizeThatFits(in: CGSize(width: width, height: 3_000)).width
    }

    /// The layouts of Apple TV, and of the iPad (and an iPhone Pro Max in landscape), which follow the Apple TV's pages.
    private var wideCases: [Case] {
        var cases = [
            Case(name: "sport front", view: AnyView(SportFrontPlaceholder())),
            Case(name: "sport page", view: AnyView(SportPagePlaceholder())),
            Case(name: "guide grid", view: AnyView(GuideGridPlaceholder())),
            Case(name: "search", view: AnyView(SearchResultsPlaceholder())),
            Case(name: "recordings", view: AnyView(RecordingsPlaceholder())),
            Case(name: "coming up strip", view: AnyView(ComingUpPlaceholder())),
            Case(name: "scheduled rows", view: AnyView(ScheduledRowsPlaceholder())),
            Case(name: "settings sport", view: AnyView(SettingsSportPlaceholder())),
        ]
        for kind in [SportLeaguePlaceholder.Kind.games, .fixture, .events, .motorsport, .cricket] {
            cases.append(Case(name: "league \(kind)", view: AnyView(SportLeaguePlaceholder(kind: kind))))
        }
        return cases
    }

    #if os(iOS)
    /// The iPhone's own layouts (and an iPad's in a narrow split view), portrait and landscape.
    private var phoneCases: [Case] {
        var cases = [
            Case(name: "phone sport front", view: AnyView(SportFrontPhonePlaceholder())),
            Case(name: "phone sport page", view: AnyView(SportPhonePagePlaceholder())),
            Case(name: "on now", view: AnyView(OnNowPlaceholder())),
            Case(name: "guide grid", view: AnyView(GuideGridPlaceholder())),
            Case(name: "search", view: AnyView(SearchResultsPlaceholder())),
            Case(name: "phone recordings", view: AnyView(RecordingsPhonePlaceholder())),
            Case(name: "coming up card", view: AnyView(ComingUpPlaceholder(card: true))),
            Case(name: "scheduled rows compact", view: AnyView(ScheduledRowsPlaceholder(compact: true))),
            Case(name: "settings sport", view: AnyView(SettingsSportPlaceholder())),
        ]
        for kind in [SportLeaguePlaceholder.Kind.games, .fixture, .events, .motorsport, .cricket] {
            cases.append(Case(name: "phone league \(kind)", view: AnyView(SportLeaguePlaceholder(kind: kind).environment(\.sportNarrow, true))))
        }
        return cases
    }
    #endif

    private func assertFits(_ cases: [Case], widths: [CGFloat], file: StaticString = #filePath, line: UInt = #line) {
        for width in widths {
            for item in cases {
                let taken = fitted(item.view, width: width)
                XCTAssertLessThanOrEqual(taken, width + 0.5, "\(item.name) at \(Int(width)) pt takes \(Int(taken.rounded())) pt",
                                         file: file, line: line)
            }
        }
    }

    func testEveryLoadingLayoutFitsTheWidthItIsGiven() {
        #if os(tvOS)
        // The full screen, and inside the 80 pt safe area on each side.
        assertFits(wideCases, widths: [1760, 1920])
        #else
        // iPads: 2/3 split view, mini and 11-inch portrait, 13-inch portrait, 11-inch and 13-inch landscape; an iPhone Pro
        // Max in landscape (regular width) as the content area inside its safe areas and margins.
        assertFits(wideCases, widths: [694, 744, 820, 834, 1024, 1194, 1366, 800])
        // iPhones in portrait (and an iPad's slide-over / half split view), then iPhones in landscape (compact width).
        assertFits(phoneCases, widths: [320, 375, 393, 430, 852])
        #endif
    }

    #if os(iOS)
    /// An iPhone on its side leaves the Recordings card about 250 pt under the page's header: the 420 pt placeholder card
    /// pushed the header off the top of the screen. It gives way, as the real card does inside its page view.
    func testTheIPhoneRecordingsCardFitsALandscapeHeight() {
        let host = UIHostingController(rootView: RecordingsPhonePlaceholder())
        for height: CGFloat in [250, 300] {
            let taken = host.sizeThatFits(in: CGSize(width: 800, height: height)).height
            XCTAssertLessThanOrEqual(taken, height + 0.5, "at \(Int(height)) pt tall it takes \(Int(taken.rounded())) pt")
        }
    }
    #endif
}
