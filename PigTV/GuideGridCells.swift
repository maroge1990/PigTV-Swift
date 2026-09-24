#if os(tvOS)
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
    var clock: Date
}

struct GuideGridProgrammeView: View {
    let info: GuideGridProgrammeInfo
    let focused: Bool
    /// Clipped under the channel column, and how far the title slides.
    let clip: GuideGridMath.ClipAppearance
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let clippedLeading = clip.clipped
        let shape = UnevenRoundedRectangle(topLeadingRadius: clippedLeading ? 0 : 10,
                                           bottomLeadingRadius: clippedLeading ? 0 : 10,
                                           bottomTrailingRadius: 10, topTrailingRadius: 10)
        let finished = info.programme.map { $0.end <= info.clock } ?? false
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
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(focused ? Color.pigAccent.opacity(0.22) : Color.guideCell(scheme), in: shape)
            .overlay { shape.stroke(focused ? Color.pigAccent : .clear, lineWidth: 3) }
            .clipShape(Rectangle())
            .opacity(finished ? 0.4 : 1)
    }

    @ViewBuilder private var content: some View {
        if let programme = info.programme {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if let caption = info.caption { Text(caption).lineLimit(1).layoutPriority(1) }
                    Text(programme.start, style: .time)
                    if info.scheduled {
                        Image(systemName: "record.circle.fill").foregroundStyle(Color.red)
                    }
                }
                .font(GuideTypography.small).foregroundStyle(.secondary).lineLimit(1)
                Text(programme.title).font(GuideTypography.body).lineLimit(info.caption == nil ? 2 : 1)
                    .foregroundStyle(.primary)
                if programme.isLive(at: info.clock) {
                    ProgressView(value: min(1, max(0, info.clock.timeIntervalSince(programme.start)
                                                  / programme.end.timeIntervalSince(programme.start))))
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
/// unreliable-channel dots and the pink focus outline.
struct GuideGridTileView: View {
    let channel: GuideChannel
    let logo: String?
    let client: APIClient?
    let flaky: Bool
    let recording: Bool
    let focused: Bool

    var body: some View {
        ChannelTile(name: channel.name, logo: logo, client: client)
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 4) {
                    if flaky { Circle().fill(Color.orange).frame(width: 12, height: 12) }
                    if recording { Circle().fill(Color.red).frame(width: 12, height: 12) }
                }
                .padding(6)
            }
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(focused ? Color.pigAccent : .clear, lineWidth: 3) }
    }
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

    override func updateConfiguration(using state: UICellConfigurationState) {
        guard let info else { contentConfiguration = nil; return }
        contentConfiguration = UIHostingConfiguration {
            GuideGridProgrammeView(info: info, focused: state.isFocused, clip: clip)
        }
        .margins(.all, 0)
        accessibilityLabel = info.programme.map { "\(info.channelName), \($0.title)" }
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
    }
    var info: Info? {
        didSet { if info != oldValue { setNeedsUpdateConfiguration() } }
    }
    var channel: GuideChannel?
    var client: APIClient?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundConfiguration = .clear()
        isAccessibilityElement = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateConfiguration(using state: UICellConfigurationState) {
        guard let info, let channel else { contentConfiguration = nil; return }
        let client = client
        contentConfiguration = UIHostingConfiguration {
            GuideGridTileView(channel: channel, logo: info.logo, client: client,
                              flaky: info.flaky, recording: info.recording, focused: state.isFocused)
        }
        .margins(.all, 0)
        accessibilityLabel = info.number.map { "\($0) \(channel.name)" } ?? channel.name
        accessibilityValue = [info.flaky ? "Unreliable channel" : nil, info.recording ? "Recording now" : nil]
            .compactMap { $0 }.joined(separator: ", ")
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

    /// Rebuilds the labels for a loaded day (origin or width changed).
    func configure(origin: Date, duration: TimeInterval, metrics: GuideGridMetrics) {
        labels.forEach { $0.removeFromSuperview() }
        labels = GuideGridMath.headerMarks(origin: origin, duration: duration).map { mark in
            let label = UILabel()
            label.font = UIFont.monospacedDigitSystemFont(ofSize: 20, weight: .regular)
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
#endif
