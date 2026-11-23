import SwiftUI
import UIKit

// A2.1: cells of the UIKit guide grid. UIKit owns position and focus; the
// visuals are SwiftUI (UIHostingConfiguration) and reproduce GuideView's
// `cellVisual` and `ChannelTile`.

/// What a programme cell draws. `programme == nil` is the "no programme
/// information" placeholder.
struct GuideGridProgrammeInfo: Equatable {
    var channelName: String
    var programme: GuideProgramme?
    /// Channel name on the now-playing cell when the tile shows a logo.
    var caption: String?
    var scheduled: Bool
    /// maroge1990/PigTV#360 (G5): what the time changes in the drawing, not the time itself (a new clock in every cell's
    /// info rebuilt every visible cell at each 30 s tick). Finished: dimmed.
    var finished: Bool
    /// On air: the progress bar's fill (0...1, to the thousandth); nil otherwise.
    var progress: Double?

    /// The on-air programme's progress at `now`, rounded to the thousandth (a step of 30 s for any programme up to 8 h).
    static func progress(of programme: GuideProgramme, at now: Date) -> Double? {
        guard programme.isLive(at: now) else { return nil }
        let length = programme.end.timeIntervalSince(programme.start)
        guard length > 0 else { return 0 }
        return (min(1, max(0, now.timeIntervalSince(programme.start) / length)) * 1000).rounded() / 1000
    }
}

struct GuideGridProgrammeView: View {
    let info: GuideGridProgrammeInfo
    let focused: Bool
    /// Clipped under the channel column, and how far the title slides.
    let clip: GuideGridMath.ClipAppearance
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let clippedLeading = clip.clipped
        let shape = UnevenRoundedRectangle(topLeadingRadius: clippedLeading ? 0 : PigRadius.compact,
                                           bottomLeadingRadius: clippedLeading ? 0 : PigRadius.compact,
                                           bottomTrailingRadius: PigRadius.compact, topTrailingRadius: PigRadius.compact)
        let finished = info.finished
        // Keep the title on screen while a long programme is clipped on the
        // left, until the visible part gets narrower than the text needs;
        // then it slides under the channel column like the cell does
        // (GuideView's `hiddenLeading`).
        let shift = clip.titleShift
        return content
            // A clipped cell narrower than the title lays out as if it were
            // 160 pt wide and lets the rest slide under the column.
            .frame(width: shift < 0 ? 136 : nil, alignment: .leading)
            .offset(x: shift)
            .padding(.horizontal, PigSpacing.s)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(focused ? PigFocus.fill : Color.guideCell(scheme), in: shape)
            #if os(tvOS)
            .clipShape(Rectangle())
            .opacity(finished ? 0.4 : 1)
            // Brand 1.8: the shared focus treatment, outside the cell's clip (the cell stops clipping while focused, and
            // the ring sits in the 8 pt gap to its neighbours).
            .pigFocusWhenFocused(focused, in: shape, lift: .cell)
            #else
            .overlay { shape.stroke(focused ? Color.pigAccent : .clear, lineWidth: 3) }
            .clipShape(Rectangle())
            .opacity(finished ? 0.4 : 1)
            #endif
    }

    @ViewBuilder private var content: some View {
        if let programme = info.programme {
            VStack(alignment: .leading, spacing: GuideGridMetrics.cellLineSpacing) {
                HStack(spacing: PigSpacing.s) {
                    if let caption = info.caption { Text(caption).lineLimit(1).layoutPriority(1) }
                    Text(programme.start, style: .time)
                    if info.scheduled {
                        Image(systemName: "record.circle.fill").foregroundStyle(Color.pigDanger)
                    }
                    // #56: LIVE / NEW and the episode, after the time (the title keeps its lines).
                    let tags = ProgrammeTags(programme)
                    ForEach(tags.badges, id: \.self) { ProgrammeTagBadge(badge: $0) }
                    if let episode = tags.episodeLine(title: programme.title) {
                        Text(episode).lineLimit(1).truncationMode(.tail)
                    }
                }
                .font(GuideTypography.small).foregroundStyle(.secondary).lineLimit(1)
                Text(programme.title).font(GuideTypography.body).lineLimit(GuideGridMetrics.titleLines(caption: info.caption != nil))
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                if let progress = info.progress {
                    ProgressView(value: progress)
                        .tint(.pigAccent).scaleEffect(x: 1, y: 0.4).frame(height: 4)
                        .accessibilityHidden(true)
                }
            }
        } else {
            Text("No programme information — watch live")
                .font(GuideTypography.body).foregroundStyle(.primary).lineLimit(1)
                .fixedSize()
        }
    }
}

/// The pinned channel tile: GuideView's ChannelTile with the recording and
/// unreliable-channel dots and the shared focus treatment (tvOS).
struct GuideGridTileView: View {
    let channel: GuideChannel
    let logo: String?
    let client: APIClient?
    let flaky: Bool
    let recording: Bool
    let focused: Bool
    /// #265: UHD or SD only (`BrowseModel.guideQuality`).
    var quality: SportQuality? = nil

    var body: some View {
        ChannelTile(name: channel.name, logo: logo, client: client, focused: focused)
            .overlay(alignment: .bottomTrailing) {
                if let quality { GuideQualityBadge(quality: quality).padding(PigSpacing.xs) }
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: PigSpacing.xs) {
                    if flaky { GuideStatusMarkView(mark: .unreliable) }
                    if recording { GuideStatusMarkView(mark: .recording) }
                }
                .padding(PigSpacing.xs)
            }
            #if os(tvOS)
            .pigFocusWhenFocused(focused, in: RoundedRectangle(cornerRadius: PigRadius.compact), lift: .cell)
            #else
            .overlay { RoundedRectangle(cornerRadius: PigRadius.compact).stroke(focused ? Color.pigAccent : .clear, lineWidth: 3) }
            #endif
    }
}

/// Brand 1.8 §4 and §14 (#280): status is a word or a symbol as well as a colour. A channel's marks in the guide differ in
/// shape (a warning triangle, a record symbol), not only in colour, and each carries its words for VoiceOver. Before
/// Apple 206 the grid drew two 12 pt dots told apart by colour alone.
nonisolated enum GuideStatusMark: CaseIterable, Sendable {
    case unreliable, recording

    var symbol: String {
        switch self {
        case .unreliable: "exclamationmark.triangle.fill"
        case .recording: "record.circle.fill"
        }
    }

    var words: String {
        switch self {
        case .unreliable: "Unreliable channel"
        case .recording: "Recording now"
        }
    }
}

struct GuideStatusMarkView: View {
    let mark: GuideStatusMark
    /// The mark's side: the dots' 12 pt footprint and a little more, so the shape reads (the grid keeps its density).
    var side: CGFloat = GuideStatusMarkMetrics.side

    var body: some View {
        Image(systemName: mark.symbol).resizable().scaledToFit()
            .frame(width: side, height: side)
            .foregroundStyle(mark == .unreliable ? Color.pigWarning : Color.pigDanger)
            .accessibilityLabel(mark.words)
    }
}

nonisolated enum GuideStatusMarkMetrics {
    #if os(tvOS)
    static let side: CGFloat = 20
    #else
    static let side: CGFloat = 14
    #endif
}

final class GuideGridProgrammeCell: UICollectionViewCell {
    static let reuseID = "guide.programme"
    var info: GuideGridProgrammeInfo? {
        didSet { if info != oldValue { setNeedsUpdateConfiguration() } }
    }
    private var clip = GuideGridMath.ClipAppearance()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        isAccessibilityElement = true
        // A title sliding under the channel column must not draw over it.
        clipsToBounds = true
        contentView.clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func apply(_ layoutAttributes: UICollectionViewLayoutAttributes) {
        super.apply(layoutAttributes)
        // Only the cells at the channel column see their clip change while
        // the grid slides, and only a change in what they draw (clipped or
        // not, the title's shift) rebuilds the SwiftUI content.
        let next = GuideGridMath.clipAppearance(leadingClip: (layoutAttributes as? GuideGridAttributes)?.leadingClip ?? 0,
                                                visibleWidth: layoutAttributes.frame.width)
        if next != clip {
            clip = next
            setNeedsUpdateConfiguration()
        }
    }

    // #360 (E1): the grid's layout fixes every frame (GuideGridLayout ignores preferred sizes), but UIKit asked each cell
    // coming on screen for its size: a SwiftUI size-to-fit of its content, text included (4.3 ms per press up or down,
    // 8.4 per press right, on the MacBook simulator), thrown away. The layout's own attributes are the answer.
    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        layoutAttributes
    }

    #if DEBUG
    /// Tests: content sized to fit (UIKit's self-sizing of a cell), counted.
    override func systemLayoutSizeFitting(_ targetSize: CGSize, withHorizontalFittingPriority horizontal: UILayoutPriority,
                                          verticalFittingPriority vertical: UILayoutPriority) -> CGSize {
        GuidePerf.cellSizingsForTesting += 1
        return super.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: horizontal, verticalFittingPriority: vertical)
    }
    #endif

    override func updateConfiguration(using state: UICellConfigurationState) {
        guard let info else { contentConfiguration = nil; return }
        let measured = GuidePerf.cellBegan(); defer { GuidePerf.cellEnded(measured) } // #362
        #if os(tvOS)
        // Brand 1.8: only the focused cell stops clipping, so its ring (outside the cell) shows; its content still clips
        // itself (GuideGridProgrammeView's clipShape), so a title sliding under the channel column never draws over it.
        clipsToBounds = !state.isFocused
        contentView.clipsToBounds = !state.isFocused
        #endif
        contentConfiguration = UIHostingConfiguration {
            // Touch (iPad): the pressed cell takes the focus look.
            GuideGridProgrammeView(info: info, focused: state.isFocused || state.isHighlighted, clip: clip)
        }
        .margins(.all, 0)
        accessibilityLabel = info.programme.map { programme in
            ["\(info.channelName), \(programme.title)", ProgrammeTags(programme).spoken(title: programme.title)]
                .compactMap { $0 }.joined(separator: ", ")
        }
            ?? "No programme information — watch live"
    }
}

final class GuideGridTileCell: UICollectionViewCell {
    static let reuseID = "guide.tile"
    struct Info: Equatable {
        var channelID: String
        var number: String?
        var logo: String?
        var flaky: Bool
        var recording: Bool
        var quality: SportQuality? = nil
    }
    var info: Info? {
        didSet { if info != oldValue { setNeedsUpdateConfiguration() } }
    }
    var channel: GuideChannel?
    var client: APIClient?
    /// #360 (G4): whether the tile is on screen (the grid's willDisplay / didEndDisplaying). Its logo loads only while it
    /// is: a tile that leaves before its logo arrives cancels the fetch (ChannelArtwork reads this from the environment).
    let artworkLifetime = ArtworkLifetime()

    func setDisplayed(_ displayed: Bool) {
        if artworkLifetime.isDisplayed != displayed { artworkLifetime.isDisplayed = displayed }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // #360 (E1): as the programme cell: the layout's frame, never a SwiftUI size-to-fit.
    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        layoutAttributes
    }

    #if DEBUG
    override func systemLayoutSizeFitting(_ targetSize: CGSize, withHorizontalFittingPriority horizontal: UILayoutPriority,
                                          verticalFittingPriority vertical: UILayoutPriority) -> CGSize {
        GuidePerf.cellSizingsForTesting += 1
        return super.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: horizontal, verticalFittingPriority: vertical)
    }
    #endif

    override func updateConfiguration(using state: UICellConfigurationState) {
        guard let info, let channel else { contentConfiguration = nil; return }
        let measured = GuidePerf.cellBegan(); defer { GuidePerf.cellEnded(measured) } // #362
        let client = client, lifetime = artworkLifetime
        contentConfiguration = UIHostingConfiguration {
            GuideGridTileView(channel: channel, logo: info.logo, client: client,
                              flaky: info.flaky, recording: info.recording, focused: state.isFocused || state.isHighlighted,
                              quality: info.quality)
                .environment(lifetime)
        }
        .margins(.all, 0)
        accessibilityLabel = info.number.map { "\($0) \(channel.name)" } ?? channel.name
        accessibilityValue = [info.quality?.spoken, info.flaky ? GuideStatusMark.unreliable.words : nil,
                              info.recording ? GuideStatusMark.recording.words : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }
}

/// #372 (Mark's option A): a divider channel as a slim section heading across the grid: its label in the detail pages'
/// eyebrow (small uppercase letters in the accent text colour) at the channel column's left edge, then a hairline in the
/// border colour to the right edge. No tile, no programmes; it never takes focus.
struct GuideGridHeadingView: View {
    let label: String

    var body: some View {
        HStack(spacing: PigSpacing.s) {
            Eyebrow(text: label).lineLimit(1).truncationMode(.tail)
            Rectangle().fill(Color.pigBorder).frame(height: GuideGridMetrics.headingRule)
                .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
    }
}

final class GuideGridHeadingCell: UICollectionViewCell {
    static let reuseID = "guide.heading"
    var label: String? {
        didSet { if label != oldValue { setNeedsUpdateConfiguration() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        isAccessibilityElement = true
        accessibilityTraits = .header
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFocused: Bool { false }

    // As the other cells: the layout's frame, never a SwiftUI size-to-fit.
    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        layoutAttributes
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        guard let label else { contentConfiguration = nil; return }
        contentConfiguration = UIHostingConfiguration { GuideGridHeadingView(label: label) }.margins(.all, 0)
        accessibilityLabel = label
    }
}

/// The time header above the grid: half-hour labels on a strip that
/// follows the grid's horizontal offset. It is clipped at the timeline's
/// left edge, so labels slide under the channel column like the cells.
/// Plain UIKit: it moves on every scroll frame.
final class GuideGridTimeHeader: UIView {
    private let strip = UIView()
    private var labels: [UILabel] = []
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        addSubview(strip)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// The system font's rounded design with monospaced digits (a figure, never running text).
    private static func roundedMonospacedDigits(ofSize size: CGFloat) -> UIFont {
        let base = UIFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        guard let rounded = base.fontDescriptor.withDesign(.rounded) else { return base }
        // Keep the monospaced-digit feature explicitly: a new design can start from a fresh descriptor.
        let digits = rounded.addingAttributes([.featureSettings: [[
            UIFontDescriptor.FeatureKey.type: kNumberSpacingType,
            UIFontDescriptor.FeatureKey.selector: kMonospacedNumbersSelector,
        ]]])
        return UIFont(descriptor: digits, size: size)
    }

    /// Rebuilds the labels for a loaded day (origin or width changed).
    func configure(origin: Date, duration: TimeInterval, metrics: GuideGridMetrics) {
        labels.forEach { $0.removeFromSuperview() }
        labels = GuideGridMath.headerMarks(origin: origin, duration: duration).map { mark in
            let label = UILabel()
            #if os(tvOS)
            label.font = Self.roundedMonospacedDigits(ofSize: PigType.secondary)
            #else
            label.font = Self.roundedMonospacedDigits(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize)
            #endif
            label.textColor = .secondaryLabel
            label.text = Self.formatter.string(from: mark)
            label.sizeToFit()
            // Position at offset 0; the strip carries the scroll offset.
            label.frame.origin = CGPoint(x: GuideGridMath.headerLabelX(mark: mark, origin: origin, offsetX: 0, metrics: metrics),
                                         y: (metrics.headerHeight - label.frame.height) / 2)
            strip.addSubview(label)
            return label
        }
    }

    /// Follows the grid's contentOffset.x.
    func follow(offsetX: CGFloat) {
        strip.frame = CGRect(x: -offsetX, y: 0, width: 1, height: bounds.height)
    }
}

/// #265: the guide's quality badge, smaller than a picker's: UHD in pink, SD faint and outlined.
struct GuideQualityBadge: View {
    let quality: SportQuality
    var body: some View {
        Text(quality.rawValue)
            #if os(tvOS)
            .font(.system(size: PigType.caption, weight: .bold)).monospaced()
            #else
            .font(.caption2.weight(.bold)).monospaced()
            #endif
            .padding(.horizontal, PigSpacing.xs).padding(.vertical, PigSpacing.xxs)
            .foregroundStyle(quality == .uhd ? Color.pigOnAccent : Color.secondary)
            .background(quality == .uhd ? Color.pigAccent : Color.clear, in: Capsule())
            .overlay { Capsule().strokeBorder(quality == .uhd ? Color.clear : Color.secondary.opacity(0.5), lineWidth: 1) }
            .opacity(quality == .sd ? 0.8 : 1)
            .accessibilityHidden(true)
            .accessibilityIdentifier("guide.quality.\(quality.rawValue)")
    }
}
