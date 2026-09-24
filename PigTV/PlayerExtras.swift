#if os(iOS)
import SwiftUI

// Channel list for hopping without leaving playback (iPhone/iPad; the tvOS
// custom player has its own side list). Rows follow the order the guide was
// showing when playback started; selecting a row switches.
struct QuickGuidePanel: View {
    @ObservedObject var app: AppModel
    var browse: BrowseModel?
    var dismiss: (() -> Void)? = nil
    @FocusState private var focusedChannelID: String?

    private var channels: [Channel] {
        if !app.zapList.isEmpty { return app.zapList }
        return browse.map { model in model.guide.map(model.asChannel) } ?? []
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(channels) { channel in
                            let programmes = browse?.programmes(for: channel) ?? []
                            let now = GuideNavigation.programme(in: programmes, at: context.date)
                            Button {
                                app.switchPlayback(to: channel)
                                dismiss?()
                            } label: {
                                HStack(spacing: 16) {
                                    ChannelArtwork(logo: browse?.logo(for: channel) ?? channel.logo, client: browse?.client)
                                        .frame(width: 96, height: 54)
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                                            Text(channel.name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                                            if let number = channel.numberText {
                                                ChannelNumberText(number: number, font: .caption)
                                            }
                                        }
                                        Text(now?.title ?? "No programme information").font(.headline).lineLimit(1)
                                    }
                                    Spacer()
                                    if let now {
                                        ProgressView(value: min(1, max(0, context.date.timeIntervalSince(now.start) / now.end.timeIntervalSince(now.start))))
                                            .tint(.pigAccent).frame(width: 120)
                                    }
                                    if channel.id == app.playback?.channel.id {
                                        Image(systemName: "play.fill").foregroundStyle(Color.pigAccent)
                                    }
                                }
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .buttonStyle(QuickGuideRowStyle())
                            .focused($focusedChannelID, equals: channel.id)
                            .id(channel.id)
                        }
                    }.padding(.horizontal, 24).padding(.vertical, 12)
                }
                .task {
                    if let id = app.playback?.channel.id {
                        proxy.scrollTo(id, anchor: .center)
                        // Let the lazy row mount before assigning remote focus.
                        await Task.yield()
                        guard !Task.isCancelled else { return }
                        focusedChannelID = id
                    }
                }
            }
        }
    }
}

private struct QuickGuideRowStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused
    func makeBody(configuration: Configuration) -> some View {
        let active = focused || configuration.isPressed
        configuration.label
            .foregroundStyle(.primary)
            .background(active ? Color.pigAccent.opacity(0.25) : Color.primary.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(active ? Color.pigAccent : .clear, lineWidth: 3) }
    }
}
#endif
