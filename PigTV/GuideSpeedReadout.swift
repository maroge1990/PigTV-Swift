import SwiftUI

/// #362: Settings › About › Guide speed readout. A switch (off by default) for the Guide's speed probe, and while it is
/// on one read-only line of what the Guide's moves have been like since it was switched on or reset, with Reset. The line
/// is read when the page is shown (and after this row's own actions), never while the Guide is on screen.
struct GuideSpeedReadoutRows: View {
    @State private var on = GuidePerfProbe.isOn
    @State private var summary = ""

    var body: some View {
        Group {
            switchRow
            if on {
                SettingsRow("TV Guide", value: summary, wraps: true, lines: 4)
                    .accessibilityHint(GuidePerfProbe.readoutHint)
                    .accessibilityIdentifier("settings.guideReadout.summary")
                resetRow
            }
        }
        .onAppear(perform: read)
    }

    private func read() {
        on = GuidePerfProbe.isOn
        summary = GuidePerfProbe.shared?.readout ?? ""
    }

    private func set(_ value: Bool) {
        GuidePerfProbe.setEnabled(value)
        read()
    }

    private static let title = "Guide speed readout"
    private static let detail = "Times each move in the TV Guide, to compare with what you see. Off when not needed."

    @ViewBuilder private var switchRow: some View {
        #if os(tvOS)
        Button { set(!on) } label: {
            HStack(spacing: PigSpacing.l) {
                VStack(alignment: .leading, spacing: PigSpacing.xs) {
                    Text(Self.title)
                    Text(Self.detail).font(.system(size: PigType.secondary)).foregroundStyle(.secondary)
                }
                Spacer()
                Text(on ? "On" : "Off").foregroundStyle(.secondary)
            }
            .font(.system(size: PigType.body))
            .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(PigSurfaceButtonStyle())
        .accessibilityIdentifier("settings.guideReadout")
        .accessibilityValue(on ? "On" : "Off")
        #else
        Toggle(isOn: Binding(get: { on }, set: { set($0) })) {
            VStack(alignment: .leading, spacing: PigSpacing.xxs) {
                Text(Self.title)
                Text(Self.detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .tint(Color.pigAccent)
        .listRowBackground(Color.pigRaised)
        .accessibilityIdentifier("settings.guideReadout")
        #endif
    }

    @ViewBuilder private var resetRow: some View {
        #if os(tvOS)
        Button {
            GuidePerfProbe.shared?.reset()
            read()
        } label: {
            HStack { Text("Reset"); Spacer() }
                .font(.system(size: PigType.body))
                .padding(.horizontal, PigSpacing.l).padding(.vertical, PigSpacing.m)
                .contentShape(Rectangle())
        }
        .buttonStyle(PigSurfaceButtonStyle())
        .accessibilityIdentifier("settings.guideReadout.reset")
        #else
        Button("Reset") {
            GuidePerfProbe.shared?.reset()
            read()
        }
        .listRowBackground(Color.pigRaised)
        .accessibilityIdentifier("settings.guideReadout.reset")
        #endif
    }
}
