import SwiftUI

// #280 (L1): the loading layouts of the TV Guide, Search, Recordings, Scheduled and Settings › Sport, drawn from the shared
// placeholder parts (PageStateViews.swift) at the sizes of what they stand for (the grid's channel tiles and programme
// cells, the On now rows, the featured recording and its cards, the Coming up strip and card, the scheduled rows, the
// settings rows), so nothing jumps when the content arrives. Neutral shapes only: no words, times or names. Each page's
// real header and controls stay drawn around them.

/// The TV Guide's grid on Apple TV and iPad (`GuideGridView`): the time header, then rows of a channel tile and programme
/// cells of the grid's own pitch.
struct GuideGridPlaceholder: View {
    private let metrics = GuideGridMetrics()
    /// Half-hour columns per cell, a row at a time (they repeat).
    private static let rows: [[CGFloat]] = [[1, 1, 1, 1, 1], [2, 1, 2], [1, 2, 1, 1], [3, 2], [1, 1, 2, 1], [2, 2, 1]]

    var body: some View {
        PigLoadingPage(identifier: "guide.loading") {
            GeometryReader { geometry in
                let timeline = max(0, geometry.size.width - metrics.channelWidth)
                let column = timeline * CGFloat(GuideNavigation.step) / CGFloat(GuideNavigation.visibleDuration)
                let count = max(1, Int(((geometry.size.height - metrics.headerHeight) / metrics.rowHeight).rounded(.up)))
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(0..<4, id: \.self) { _ in
                            PigPlaceholderBar(width: min(110, column * 0.5)).frame(width: column, alignment: .leading)
                        }
                    }
                    .padding(.leading, metrics.channelWidth + metrics.inset)
                    .frame(height: metrics.headerHeight)
                    ForEach(0..<count, id: \.self) { row in
                        HStack(spacing: metrics.gap) {
                            PigPlaceholderBlock(width: metrics.channelWidth - metrics.gap, height: metrics.rowHeight - metrics.gap,
                                                radius: PigRadius.compact)
                            ForEach(Array(Self.rows[row % Self.rows.count].enumerated()), id: \.offset) { _, span in
                                PigPlaceholderBlock(width: max(0, span * column - metrics.gap), height: metrics.rowHeight - metrics.gap,
                                                    radius: PigRadius.compact)
                            }
                        }
                        .frame(height: metrics.rowHeight, alignment: .leading)
                        .frame(width: geometry.size.width, alignment: .leading)
                        .clipped()
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                .clipped()
            }
        }
    }
}

#if os(iOS)
/// The iPhone's On now list (`OnNowList`): rows of a logo tile, the channel's line, the title and the progress bar.
struct OnNowPlaceholder: View {
    /// The list's row insets (OnNowList: 6 above and below each row, 16 leading, 12 trailing).
    private static let rowGap: CGFloat = 12
    private static let leading: CGFloat = 16
    private static let trailing: CGFloat = 12
    private static let top: CGFloat = 6

    var body: some View {
        PigLoadingPage(identifier: "guide.loading") {
            VStack(alignment: .leading, spacing: Self.rowGap) {
                ForEach(0..<9, id: \.self) { row in
                    HStack(spacing: PigSpacing.m) {
                        PigPlaceholderBlock(width: 76, height: 48, radius: PigRadius.compact)
                        VStack(alignment: .leading, spacing: PigSpacing.xs) {
                            PigPlaceholderBar(width: 90)
                            PigPlaceholderBar(width: row % 2 == 0 ? 200 : 160, height: 14)
                            PigPlaceholderBar(width: 220, height: 4)
                        }
                        Spacer(minLength: 0)
                        PigPlaceholderDisc(size: 22)
                    }
                }
            }
            .padding(.leading, Self.leading).padding(.trailing, Self.trailing).padding(.top, Self.top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
#endif

/// Search's results (`GuideSearchPage`): the section's line, then result rows (a logo tile, the title and its line).
struct SearchResultsPlaceholder: View {
    #if os(tvOS)
    private let logo = CGSize(width: 136, height: 76)
    #else
    private let logo = CGSize(width: 72, height: 40)
    #endif

    var body: some View {
        PigLoadingPage(identifier: "search.loading") {
            VStack(alignment: .leading, spacing: PigSpacing.s) {
                PigPlaceholderBar(width: 260).padding(.top, PigSpacing.xs)
                ForEach(0..<5, id: \.self) { row in
                    PigPlaceholderBlock(inset: PigSpacing.s) {
                        HStack(spacing: PigSpacing.l) {
                            RoundedRectangle(cornerRadius: PigRadius.compact, style: .continuous).fill(Color.pigBorder)
                                .frame(width: logo.width, height: logo.height)
                            VStack(alignment: .leading, spacing: PigSpacing.xs) {
                                PigPlaceholderBar(width: row % 2 == 0 ? 360 : 280, height: PigPlaceholderMetrics.title)
                                PigPlaceholderBar(width: 300)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// Recordings on Apple TV and iPad: the featured recording (its art, the kicker, title, line and three buttons), then
/// "Ready to watch" and its cards.
struct RecordingsPlaceholder: View {
    /// Play or Resume, Details and Delete, at their sizes (they fit beside the art on the narrowest iPad).
    #if os(tvOS)
    private static let chips: [CGFloat] = [200, 150, 150]
    #else
    private static let chips: [CGFloat] = [110, 86, 86]
    #endif

    var body: some View {
        PigLoadingPage(identifier: "recordings.loading") {
            VStack(alignment: .leading, spacing: RecordingsMetrics.gap) {
                HStack(alignment: .center, spacing: RecordingsMetrics.gap * 1.6) {
                    PigPlaceholderBlock(width: RecordingsMetrics.featuredArtWidth, height: RecordingsMetrics.featuredArtHeight,
                                        radius: PigRadius.hero)
                    VStack(alignment: .leading, spacing: PigSpacing.s) {
                        PigPlaceholderBar(width: 260)
                        PigPlaceholderBar(width: 520, height: PigPlaceholderMetrics.title * 1.8)
                        PigPlaceholderBar(width: 300)
                        HStack(spacing: PigSpacing.m) {
                            PigPlaceholderChip(width: Self.chips[0])
                            PigPlaceholderChip(width: Self.chips[1])
                            PigPlaceholderChip(width: Self.chips[2])
                        }
                        .padding(.top, PigSpacing.m)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: PigSpacing.s) {
                    PigPlaceholderTitle(width: 220)
                    // In a fixed scroll view, as the real row is: the cards past the edge are cut off, never widening the page.
                    ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: RecordingsMetrics.spacing) {
                        ForEach(0..<6, id: \.self) { _ in
                            PigPlaceholderBlock(width: RecordingsMetrics.cardWidth, inset: PigSpacing.s) {
                                VStack(alignment: .leading, spacing: PigSpacing.s) {
                                    PigPlaceholderBlock(height: (RecordingsMetrics.cardWidth - 2 * PigSpacing.s) / RecordingsMetrics.artRatio,
                                                        radius: PigRadius.compact)
                                    PigPlaceholderBar(width: 220)
                                    PigPlaceholderBar(width: 140)
                                }
                            }
                        }
                    }
                    .padding(.vertical, PigSpacing.s).padding(.horizontal, PigSpacing.xs)
                    }
                    .scrollDisabled(true)
                    .scrollIndicators(.hidden)
                }
            }
        }
    }
}

/// The Coming up strip (Apple TV, iPad) and card (iPhone) while the schedules load: a surface of their size, no
/// "Nothing scheduled" before the answer.
struct ComingUpPlaceholder: View {
    var card = false
    var body: some View {
        PigLoadingPage(identifier: "recordings.comingUp.loading") {
            PigPlaceholderBlock(height: card ? RecordingsMetrics.comingUpCardHeight : RecordingsMetrics.comingUpStripHeight,
                                radius: card ? PigRadius.hero : PigRadius.card) {
                HStack(spacing: PigSpacing.m) {
                    PigPlaceholderBar(width: card ? 140 : 120)
                    if !card {
                        PigPlaceholderBar(width: 260)
                        PigPlaceholderBar(width: 260)
                    }
                }
            }
        }
    }
}

#if os(iOS)
/// The iPhone's recording card (`RecordingStackCard`): the art, the kicker and title, Play and More.
struct RecordingsPhonePlaceholder: View {
    var body: some View {
        PigLoadingPage(identifier: "recordings.loading") {
            VStack(alignment: .leading, spacing: 0) {
                PigPlaceholderBlock(height: RecordingsMetrics.phoneCardHeight * 0.58, radius: 0)
                VStack(alignment: .leading, spacing: PigSpacing.m) {
                    PigPlaceholderBar(width: 140)
                    PigPlaceholderBar(width: 220, height: PigPlaceholderMetrics.title)
                    HStack(spacing: PigSpacing.m) {
                        Capsule().fill(Color.pigBorder).frame(height: 50)
                        PigPlaceholderDisc(size: 50)
                    }
                    .padding(.top, PigSpacing.s)
                }
                .padding(PigSpacing.l)
                Spacer(minLength: 0)
            }
            .frame(height: RecordingsMetrics.phoneCardHeight)
            .background(Color.pigSurface)
            .clipShape(RoundedRectangle(cornerRadius: PigRadius.hero, style: .continuous))
        }
    }
}
#endif

/// Scheduled's Coming up (and the rules column): rows of the day and time, the title and its line, and the row's button.
struct ScheduledRowsPlaceholder: View {
    var rows = 4
    var compact = false
    #if os(tvOS)
    private let height: CGFloat = 96
    #else
    private let height: CGFloat = 66
    #endif

    var body: some View {
        PigLoadingPage(identifier: "scheduled.loading") {
            VStack(alignment: .leading, spacing: PigSpacing.s) {
                ForEach(0..<rows, id: \.self) { row in
                    PigPlaceholderBlock(height: height, inset: PigSpacing.m) {
                        HStack(spacing: PigSpacing.m) {
                            if !compact {
                                VStack(alignment: .leading, spacing: PigSpacing.xs) {
                                    PigPlaceholderBar(width: 90)
                                    PigPlaceholderBar(width: 60)
                                }
                                .frame(width: compact ? 0 : 120, alignment: .leading)
                            }
                            VStack(alignment: .leading, spacing: PigSpacing.xs) {
                                PigPlaceholderBar(width: row % 2 == 0 ? 300 : 240, height: PigPlaceholderMetrics.title * 0.8)
                                PigPlaceholderBar(width: 200)
                            }
                            Spacer(minLength: 0)
                            PigPlaceholderChip(width: compact ? PigPlaceholderMetrics.chip : 120)
                        }
                    }
                }
            }
        }
    }
}

/// Settings › Sport: Hide scores, the "Your sport" heading, then the sports' rows (#280: Score delay is one level down).
struct SettingsSportPlaceholder: View {
    var body: some View {
        PigLoadingPage(identifier: "settings.sport.loading") {
            VStack(alignment: .leading, spacing: PigSpacing.s) {
                #if os(tvOS)
                PigPlaceholderBlock(height: SettingsSportMetrics.tileHeight)
                PigPlaceholderBar(width: 420, height: PigPlaceholderMetrics.title).padding(.vertical, PigSpacing.xs)
                #endif
                ForEach(0..<3, id: \.self) { _ in
                    PigPlaceholderBlock(height: SettingsSportMetrics.rowHeight, inset: PigSpacing.s) {
                        HStack(spacing: PigSpacing.m) {
                            PigPlaceholderBar(width: 180)
                            Spacer(minLength: 0)
                            PigPlaceholderDisc(size: SettingsSportMetrics.badge)
                            PigPlaceholderBar(width: 120)
                        }
                        .frame(maxHeight: .infinity)
                    }
                }
            }
        }
    }
}
