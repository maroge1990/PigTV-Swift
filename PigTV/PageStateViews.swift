import SwiftUI

// Brand 1.8 §14 (maroge1990/PigTV#280, the owner's picks of 11 Nov 2026): the shared parts that draw a page's states
// (`PageState`). One API each:
// - Loading (L1): `PigLoadingPage(identifier:) { … }` around a page's placeholder layout, built from `PigPlaceholderBar`,
//   `PigPlaceholderDisc` and `PigPlaceholderBlock`: neutral shapes where the content will sit, no words, pulsing gently
//   (still under Reduce Motion); VoiceOver hears one "Loading" for the page. The header, tabs and title stay real.
// - Empty (E1): `PigEmptyState(title:text:action:)`: the small pig mark, a title, one sentence and the page's one action,
//   centred; on Apple TV the action takes focus when the state appears.
// - Error (R1): `PigErrorState(failure:retry:)`: the Offline screen's pig in its retry ring (`RetryRing`), what happened,
//   what still works, the countdown to the automatic retry and "Try again" (focused on Apple TV).
// - Stale (R1, content on screen): `PigStaleNotice(since:retry:)`: a slim notice above the content, "Try again" beside it.
// A page fills its scroll area with a whole-page state with `pigStateFillsPage()`.

/// Sizes of the state parts.
nonisolated enum PigStateMetrics {
    #if os(tvOS)
    static let emptyMark: CGFloat = 110
    static let ring: CGFloat = 200
    static let ringWidth: CGFloat = 8
    static let ringMark: CGFloat = 104
    static let textWidth: CGFloat = 1000
    static let title: Font = .system(size: PigType.pageTitle, weight: .heavy)
    static let text: Font = .system(size: PigType.body)
    static let countdown: Font = .system(size: PigType.body, weight: .medium)
    static let notice: Font = .system(size: PigType.body, weight: .medium)
    static let noticeIcon: Font = .system(size: PigType.cardTitle, weight: .semibold)
    #else
    static var emptyMark: CGFloat { phone ? 64 : 72 }
    static var ring: CGFloat { phone ? 130 : 140 }
    static let ringWidth: CGFloat = 6
    static var ringMark: CGFloat { phone ? 66 : 70 }
    static let textWidth: CGFloat = 520
    static let title: Font = .title2.bold()
    static let text: Font = .body
    static let countdown: Font = .subheadline
    static let notice: Font = .footnote.weight(.medium)
    static let noticeIcon: Font = .subheadline.weight(.semibold)
    private static var phone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    #endif
    /// The stale notice's outline.
    static let noticeBorder: CGFloat = 2
}

/// #280 (one rule on every page, Apple TV): a state's button takes focus when it appears only if focus is inside the page
/// (or nowhere, so it would be lost); never off the tab bar, where the viewer may be moving from tab to tab. Down from the
/// tab bar reaches it (it is the page's default focus).
enum PigStateFocus {
    @MainActor static func mayTake() -> Bool {
        #if os(tvOS)
        // The scene's focus system (UIScreen.focusedItem asserts in a scene-based app).
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first { $0.isKeyWindow }
        var view = window.flatMap { UIFocusSystem.focusSystem(for: $0)?.focusedItem } as? UIView
        guard view != nil else { return true }
        while let current = view {
            if current is UITabBar || String(describing: type(of: current)).contains("TabBar") { return false }
            view = current.superview
        }
        return true
        #else
        return false
        #endif
    }
}

/// The page's one action in an empty state.
struct PigStateAction {
    let label: String
    var systemImage: String? = nil
    /// The rose primary; false where the screen already has one (one rose per screen): the secondary style.
    var prominent = true
    let run: () -> Void
}

private extension View {
    @ViewBuilder func pigStateButton(prominent: Bool) -> some View {
        if prominent { pigPrimaryButton() } else { pigSecondaryButton() }
    }
}

extension View {
    /// A whole-page state (loading, empty, failed) fills its scroll view's height, centred.
    func pigStateFillsPage() -> some View {
        containerRelativeFrame(.vertical, alignment: .center)
    }
}

// MARK: Empty (E1)

struct PigEmptyState: View {
    let title: String
    let text: String
    var action: PigStateAction? = nil
    var identifier: String = "page.empty"
    #if os(tvOS)
    @FocusState private var focused: Bool
    #endif

    var body: some View {
        VStack(spacing: PigSpacing.m) {
            PigBrandMark(width: PigStateMetrics.emptyMark, height: PigStateMetrics.emptyMark * 797 / 1000)
            Text(title).font(PigStateMetrics.title).multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            Text(text).font(PigStateMetrics.text).foregroundStyle(Color.pigSecondary).multilineTextAlignment(.center)
                .frame(maxWidth: PigStateMetrics.textWidth)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action: action.run) {
                    if let image = action.systemImage { Label(action.label, systemImage: image) } else { Text(action.label) }
                }
                .pigStateButton(prominent: action.prominent)
                #if os(iOS)
                .controlSize(.large)
                #elseif os(tvOS)
                .focused($focused)
                .onAppear { if PigStateFocus.mayTake() { focused = true } }
                #endif
                .padding(.top, PigSpacing.s)
                .accessibilityIdentifier("\(identifier).action")
            }
        }
        .padding(.vertical, PigSpacing.empty).padding(.horizontal, PigSpacing.l)
        .frame(maxWidth: .infinity)
        #if os(tvOS)
        .defaultFocus($focused, true)
        .focusSection()
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: Error (R1)

struct PigErrorState: View {
    let failure: PageFailure
    /// Loads the page again; the countdown starts over when it returns.
    let retry: () async -> Void
    var identifier: String = "page.error"
    /// The model's own next request (its polling): the ring and countdown follow it and the view keeps no timer of its
    /// own. Without one (a model that does not poll) the view retries every 20 s itself.
    var schedule: RefreshSchedule? = nil
    /// When the countdown to the next automatic attempt began (the last attempt, or the state appearing).
    @State private var started = Date()
    @State private var trying = false
    #if os(tvOS)
    @FocusState private var focused: Bool
    #endif

    var body: some View {
        VStack(spacing: PigSpacing.l) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: PigSpacing.l) {
                    RetryRing(fraction: trying ? 1 : fraction(now: context.date),
                              ring: PigStateMetrics.ring, ringWidth: PigStateMetrics.ringWidth, mark: PigStateMetrics.ringMark)
                    VStack(spacing: PigSpacing.s) {
                        Text(failure.title).font(PigStateMetrics.title).multilineTextAlignment(.center)
                            .accessibilityAddTraits(.isHeader)
                        Text("\(failure.message) \(failure.stillWorks)").font(PigStateMetrics.text)
                            .foregroundStyle(Color.pigSecondary).multilineTextAlignment(.center)
                            .frame(maxWidth: PigStateMetrics.textWidth)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("\(identifier).message")
                    }
                    Text(countdown(now: context.date))
                        .font(PigStateMetrics.countdown).monospacedDigit().fontDesign(.rounded)
                        .foregroundStyle(Color.pigSecondary)
                        .accessibilityIdentifier("\(identifier).countdown")
                }
            }
            Button { Task { await attempt() } } label: { Label(PageWords.tryAgain, systemImage: "arrow.clockwise") }
                .pigPrimaryButton()
                #if os(iOS)
                .controlSize(.large)
                #elseif os(tvOS)
                .focused($focused)
                .onAppear { if PigStateFocus.mayTake() { focused = true } }
                #endif
                .accessibilityIdentifier("\(identifier).retry")
        }
        .padding(.vertical, PigSpacing.empty).padding(.horizontal, PigSpacing.l)
        .frame(maxWidth: .infinity)
        #if os(tvOS)
        .defaultFocus($focused, true)
        .focusSection()
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
        .task(id: started) {
            // One retry clock (#280): only a page whose model does not poll retries from here, 20 s after the last attempt
            // (as the Offline screen); otherwise the model's next scheduled request is the retry.
            guard Self.ownsRetryClock(schedule: schedule) else { return }
            do { try await Task.sleep(for: .seconds(RetryCountdown.period)) } catch { return }
            await attempt()
        }
    }

    /// Whether the view runs the automatic retry itself (pure, PageStateTests).
    nonisolated static func ownsRetryClock(schedule: RefreshSchedule?) -> Bool { schedule == nil }

    private func fraction(now: Date) -> Double {
        schedule?.fraction(now: now) ?? RetryCountdown.fraction(from: started, now: now)
    }

    private func countdown(now: Date) -> String {
        let seconds = schedule?.remaining(now: now) ?? RetryCountdown.remaining(from: started, now: now)
        return trying || seconds == 0 ? PageWords.tryingAgain : RetryCountdown.text(seconds)
    }

    private func attempt() async {
        guard !trying else { return }
        trying = true
        await retry()
        trying = false
        started = Date()
    }
}

// MARK: Stale (R1, content on screen)

struct PigStaleNotice: View {
    /// When what is shown was received.
    let since: Date?
    let retry: () async -> Void
    var identifier: String = "page.stale"
    @State private var trying = false

    var body: some View {
        HStack(spacing: PigSpacing.m) {
            Image(systemName: "exclamationmark.triangle").font(PigStateMetrics.noticeIcon).foregroundStyle(Color.pigWarning)
                .accessibilityHidden(true)
            Text(PageWords.stale(since: since)).font(PigStateMetrics.notice).fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("\(identifier).text")
            Spacer(minLength: PigSpacing.s)
            Button {
                guard !trying else { return }
                Task {
                    trying = true
                    await retry()
                    trying = false
                }
            } label: { Label(trying ? PageWords.tryingAgain : PageWords.tryAgain, systemImage: "arrow.clockwise") }
                .pigSecondaryButton()
                .accessibilityIdentifier("\(identifier).retry")
        }
        .padding(.leading, PigSpacing.l).padding(.trailing, PigSpacing.s).padding(.vertical, PigSpacing.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous)
                .strokeBorder(Color.pigWarning, lineWidth: PigStateMetrics.noticeBorder)
                .allowsHitTesting(false)
        }
        #if os(tvOS)
        .focusSection()
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: Loading (L1)

/// The placeholder shapes' sizes: a line of text, a title line, a chip or button, a badge.
nonisolated enum PigPlaceholderMetrics {
    #if os(tvOS)
    static let line: CGFloat = 22
    static let title: CGFloat = 32
    static let chip: CGFloat = 56
    static let disc: CGFloat = 32
    static let rowHeight: CGFloat = 44
    #else
    static let line: CGFloat = 12
    static let title: CGFloat = 20
    static let chip: CGFloat = 34
    static let disc: CGFloat = 24
    static let rowHeight: CGFloat = 30
    #endif
    /// How dim a placeholder gets at the bottom of its pulse, and half the pulse's period.
    static let pulseLow: Double = 0.45
    static let pulseHalf: Double = 0.8
}

/// A line of text that has not come yet.
struct PigPlaceholderBar: View {
    var width: CGFloat? = nil
    var height: CGFloat = PigPlaceholderMetrics.line
    var body: some View {
        // At most `width` (all of it when nil), narrower when the space is: a bar never pushes its card wider.
        Capsule().fill(Color.pigBorder).frame(maxWidth: width ?? .infinity).frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A button or chip that has not come yet: exactly `width` wide, side by side with others.
struct PigPlaceholderChip: View {
    var width: CGFloat
    var body: some View {
        Capsule().fill(Color.pigBorder).frame(width: width, height: PigPlaceholderMetrics.chip)
    }
}

/// A badge, logo or avatar that has not come yet.
struct PigPlaceholderDisc: View {
    var size: CGFloat = PigPlaceholderMetrics.disc
    var body: some View { Circle().fill(Color.pigBorder).frame(width: size, height: size) }
}

/// A card, banner or list surface, with the shapes of what it will hold.
struct PigPlaceholderBlock<Content: View>: View {
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    var radius: CGFloat = PigRadius.card
    var inset: CGFloat = PigSpacing.l
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(inset)
            .frame(width: width, height: height, alignment: .topLeading)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension PigPlaceholderBlock where Content == Color {
    /// A plain surface. (#280: its content is a clear colour, not EmptyView, which drops every modifier, so the surface
    /// was never drawn.)
    init(width: CGFloat? = nil, height: CGFloat? = nil, radius: CGFloat = PigRadius.card) {
        self.init(width: width, height: height, radius: radius) { Color.clear }
    }
}

/// A page's placeholder layout: pulsing gently (still under Reduce Motion), not focusable or pressable, one "Loading"
/// for VoiceOver.
struct PigLoadingPage<Content: View>: View {
    var identifier: String = "page.loading"
    @ViewBuilder var content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dim = false

    var body: some View {
        content
            .opacity(dim && !reduceMotion ? PigPlaceholderMetrics.pulseLow : 1)
            .allowsHitTesting(false)
            #if os(tvOS)
            .focusable(false)
            #endif
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(PageWords.loading)
            .accessibilityIdentifier(identifier)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: PigPlaceholderMetrics.pulseHalf).repeatForever(autoreverses: true)) { dim = true }
            }
    }
}

// MARK: Placeholder parts shared by the page layouts

/// A card in a rail: a kicker, a title and a line.
struct PigPlaceholderCard: View {
    var width: CGFloat? = nil
    var height: CGFloat
    var body: some View {
        PigPlaceholderBlock(width: width, height: height, inset: PigSpacing.m) {
            VStack(alignment: .leading, spacing: PigSpacing.xs) {
                PigPlaceholderBar(width: 110)
                PigPlaceholderBar(width: 240, height: PigPlaceholderMetrics.title)
                PigPlaceholderBar(width: 190)
            }
        }
    }
}

/// A section's title line.
struct PigPlaceholderTitle: View {
    var width: CGFloat = 300
    var body: some View { PigPlaceholderBar(width: width, height: PigPlaceholderMetrics.title) }
}

/// A list of rows: a badge, a name and a value each.
struct PigPlaceholderRows: View {
    var count: Int
    var badge = true
    var body: some View {
        VStack(alignment: .leading, spacing: PigSpacing.s) {
            ForEach(0..<count, id: \.self) { _ in
                HStack(spacing: PigSpacing.m) {
                    if badge { PigPlaceholderDisc() }
                    PigPlaceholderBar(width: 200)
                    Spacer(minLength: 0)
                    PigPlaceholderBar(width: 80)
                }
                .frame(height: PigPlaceholderMetrics.rowHeight)
            }
        }
    }
}

/// A grid of game cards, `columns` across (or as many as fit).
struct PigPlaceholderGrid: View {
    var count: Int
    var cardWidth: CGFloat?
    var cardHeight: CGFloat
    var columns: Int? = nil
    var gap: CGFloat

    var body: some View {
        let items: [GridItem] = columns.map { Array(repeating: GridItem(.flexible(), spacing: gap, alignment: .top), count: $0) }
            ?? [GridItem(.adaptive(minimum: cardWidth ?? 260, maximum: cardWidth ?? .infinity), spacing: gap, alignment: .topLeading)]
        LazyVGrid(columns: items, alignment: .leading, spacing: gap) {
            ForEach(0..<count, id: \.self) { _ in PigPlaceholderCard(width: columns == nil ? cardWidth : nil, height: cardHeight) }
        }
    }
}
