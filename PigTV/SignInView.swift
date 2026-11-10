import SwiftUI

// Sign in (D-44 batch 6, R5-SignIn-*): first the server, then two big tiles: Pair with browser (recommended) and
// Username and password. Pairing shows its code; the password tile opens the two fields.

/// Where Sign in is (pure, `SignInStepTests`).
nonisolated enum SignInStep: Equatable, Sendable {
    /// Step 1: the server's address.
    case server
    /// Step 2: how to sign in (the two tiles).
    case method
    /// Step 2, Username and password chosen.
    case password

    /// Sign in opens on the tiles when an address is known, unless the viewer asked for a different server.
    static func opening(server: String, askServer: Bool) -> SignInStep {
        askServer || server.trimmingCharacters(in: .whitespaces).isEmpty ? .server : .method
    }

    /// "pigtv.local:3000" from the saved address (scheme and trailing slash left out).
    static func shortAddress(_ server: String) -> String {
        var text = server.trimmingCharacters(in: .whitespaces)
        for scheme in ["http://", "https://"] where text.lowercased().hasPrefix(scheme) { text.removeFirst(scheme.count) }
        while text.hasSuffix("/") { text.removeLast() }
        return text
    }
}

struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @State private var step: SignInStep?
    #if os(tvOS)
    @FocusState private var focus: SignInFocus?
    private enum SignInFocus: Hashable { case address, pair, password, username }
    #endif

    private var current: SignInStep { step ?? SignInStep.opening(server: model.serverText, askServer: model.signInAtServer) }

    var body: some View {
        ZStack {
            PigPageBackground()
            ScrollView {
                VStack(spacing: SignInMetrics.spacing) {
                    brand
                    if let pairing = model.pairing {
                        serverChip
                        pairingCard(pairing)
                    } else {
                        switch current {
                        case .server: serverStep
                        case .method: serverChip; methodStep
                        case .password: serverChip; passwordStep
                        }
                    }
                }
                .padding(.horizontal, SignInMetrics.sidePadding).padding(.vertical, SignInMetrics.topPadding)
                .frame(maxWidth: SignInMetrics.width)
                .frame(maxWidth: .infinity)
            }
        }
        #if os(tvOS)
        .buttonStyle(PigSecondaryButtonStyle())
        #endif
    }

    private func go(_ next: SignInStep) {
        withAnimation(.easeOut(duration: 0.15)) { step = next }
        #if os(tvOS)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            focus = next == .server ? .address : next == .password ? .username : .pair
        }
        #endif
    }

    /// The kit's stacked lockup, with a static halo behind the pig only, and the welcome line.
    private var brand: some View {
        VStack(spacing: SignInMetrics.brandSpacing) {
            PigLockup(kind: .stacked, pigInkWidth: SignInMetrics.pigInk, trimmedToInk: true)
                .padding(DetailMetrics.heroPadding)
                .background { PigIdentityBackdrop() }
                .padding(-DetailMetrics.heroPadding)
            Text(SignInMetrics.welcome).font(SignInType.welcome).multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.bottom, PigSpacing.s)
    }

    // MARK: Step 1

    private var serverStep: some View {
        VStack(alignment: .leading, spacing: SignInMetrics.cardSpacing) {
            StepHeading(number: 1, title: "Server", active: true)
            TextField("http://pigtv.local:3000", text: $model.serverText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .pigField()
                .disabled(model.authBusy)
                #if os(tvOS)
                .focused($focus, equals: .address)
                #endif
                .accessibilityLabel("Server address")
                .accessibilityIdentifier("signin.address")
                .onSubmit(continueToMethod)
            Text("The server address only, with its port if needed. HTTP is fine on your home network.")
                .font(SignInType.hint).foregroundStyle(Color.pigSecondary)
            HStack(spacing: PigSpacing.m) {
                Button("Continue", systemImage: "arrow.right", action: continueToMethod)
                    .pigPrimaryButton()
                    .disabled(model.authBusy || model.serverText.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("signin.continue")
                if model.authBusy { ProgressView("Checking…") }
            }
            StepHeading(number: 2, title: "How to sign in", active: false).padding(.top, PigSpacing.s)
        }
        .padding(SignInMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: PigRadius.hero, style: .continuous))
    }

    private func continueToMethod() {
        Task { if await model.checkServer() { go(.method) } }
    }

    /// Step 1 once done: the server (a check when this session reached it), with Change.
    private var serverChip: some View {
        HStack(spacing: PigSpacing.m) {
            if model.checkedServer == model.serverText {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.pigSuccess)
                    .font(SignInType.chipIcon).accessibilityLabel("Reached")
            } else {
                StepNumber(number: 1, active: false)
            }
            VStack(alignment: .leading, spacing: PigSpacing.xxs) {
                Text("SERVER").font(SignInType.eyebrow).tracking(1).foregroundStyle(Color.pigSecondary)
                Text(SignInStep.shortAddress(model.serverText)).font(SignInType.chipValue).fontDesign(.monospaced).lineLimit(1)
            }
            Spacer(minLength: 12)
            Button("Change") {
                model.cancelPairing()
                go(.server)
            }
            .disabled(model.authBusy && model.pairing == nil)
            .accessibilityLabel("Change server")
            .accessibilityIdentifier("signin.server.change")
        }
        .padding(SignInMetrics.chipPadding)
        .background(Color.pigAccent.opacity(0.14), in: RoundedRectangle(cornerRadius: PigRadius.card, style: .continuous))
        .overlay(alignment: .leading) {
            Capsule().fill(Color.pigAccent).frame(width: 4, height: 28).padding(.leading, PigSpacing.xs).accessibilityHidden(true)
        }
        #if os(tvOS)
        .focusSection()
        #endif
    }

    // MARK: Step 2

    private var methodStep: some View {
        VStack(alignment: .leading, spacing: SignInMetrics.cardSpacing) {
            StepHeading(number: 2, title: "How to sign in", active: true)
            let tiles = Group {
                Button { model.startPairing() } label: {
                    SignInTile(systemImage: "qrcode", title: "Pair with browser", detail: SignInMetrics.pairDetail,
                               recommended: true)
                }
                .buttonStyle(SignInTileStyle(primary: true))
                #if os(tvOS)
                .focused($focus, equals: .pair)
                #endif
                .disabled(model.authBusy || model.serverText.isEmpty)
                .accessibilityIdentifier("signin.pair")
                Button { go(.password) } label: {
                    SignInTile(systemImage: "person.crop.circle", title: "Username and password",
                               detail: SignInMetrics.passwordDetail, recommended: false)
                }
                .buttonStyle(SignInTileStyle(primary: false))
                #if os(tvOS)
                .focused($focus, equals: .password)
                #endif
                .disabled(model.authBusy)
                .accessibilityIdentifier("signin.password")
            }
            if SignInMetrics.stacksTiles {
                VStack(spacing: SignInMetrics.tileSpacing) { tiles }
            } else {
                HStack(alignment: .top, spacing: SignInMetrics.tileSpacing) { tiles }
                    #if os(tvOS)
                    .focusSection()
                    #endif
            }
            if model.canRestore {
                Button("Retry saved sign-in", systemImage: "arrow.clockwise") { Task { await model.restore() } }
                    .disabled(model.authBusy)
            }
            if model.authBusy { ProgressView("Connecting…") }
        }
        #if os(tvOS)
        .defaultFocus($focus, .pair)
        #endif
    }

    private var passwordStep: some View {
        VStack(alignment: .leading, spacing: SignInMetrics.cardSpacing) {
            StepHeading(number: 2, title: "Username and password", active: true)
            TextField("Username", text: $model.username)
                .autocorrectionDisabled().textInputAutocapitalization(.never).disabled(model.authBusy)
                .textContentType(.username)
                .pigField()
                #if os(tvOS)
                .focused($focus, equals: .username)
                #endif
                .accessibilityIdentifier("signin.username")
            SecureField("Password", text: $model.password).disabled(model.authBusy)
                .textContentType(.password)
                .pigField()
                .accessibilityIdentifier("signin.passwordField")
            HStack(spacing: PigSpacing.m) {
                Button("Sign in", systemImage: "person.crop.circle") { Task { await model.login() } }
                    .pigPrimaryButton()
                    .disabled(model.authBusy || model.serverText.isEmpty || model.username.isEmpty || model.password.isEmpty)
                    .accessibilityIdentifier("signin.submit")
                Button("Back", systemImage: "chevron.left") { go(.method) }
                    .disabled(model.authBusy)
                    .accessibilityIdentifier("signin.back")
                if model.authBusy { ProgressView("Connecting…") }
            }
            #if os(tvOS)
            .focusSection()
            #endif
        }
        .padding(SignInMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: PigRadius.hero, style: .continuous))
        #if os(tvOS)
        .onExitCommand { go(.method) }
        #endif
    }

    private func pairingCard(_ pairing: PairStart) -> some View {
        VStack(alignment: .leading, spacing: SignInMetrics.cardSpacing) {
            StepHeading(number: 2, title: "Pair with your browser", active: true)
            Text(pairing.code).font(SignInType.code).fontDesign(.monospaced).tracking(8)
                .accessibilityLabel("Pairing code \(pairing.code.map(String.init).joined(separator: " "))")
            Text("Open PigTV in your browser, sign in, then approve this code in Settings → Devices.")
                .font(SignInType.body)
            Text("Expires \(pairing.expiry, style: .time)").font(SignInType.hint).foregroundStyle(Color.pigSecondary)
            ProgressView("Waiting for approval…")
            Button("Cancel pairing", systemImage: "xmark") { model.cancelPairing() }
                .accessibilityIdentifier("signin.cancelPairing")
        }
        .padding(SignInMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.pigRaised, in: RoundedRectangle(cornerRadius: PigRadius.hero, style: .continuous))
    }
}

/// "1 Server": the step's number in a disc, then its name.
private struct StepHeading: View {
    let number: Int
    let title: String
    let active: Bool
    var body: some View {
        HStack(spacing: PigSpacing.s) {
            StepNumber(number: number, active: active)
            Text(title).font(SignInType.step).foregroundStyle(active ? Color.pigText : Color.pigSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(title)")
        .accessibilityAddTraits(.isHeader)
    }
}

private struct StepNumber: View {
    let number: Int
    let active: Bool
    var body: some View {
        Text("\(number)").font(SignInType.stepNumber).monospacedDigit().fontDesign(.rounded)
            .foregroundStyle(active ? Color.pigOnAccent : Color.pigText)
            .frame(width: SignInMetrics.disc, height: SignInMetrics.disc)
            .background(active ? Color.pigAccent : Color.pigSurface, in: Circle())
            .accessibilityHidden(true)
    }
}

private struct SignInTile: View {
    let systemImage: String
    let title: String
    let detail: String
    let recommended: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: SignInMetrics.tileInner) {
            if recommended {
                Text("RECOMMENDED").font(SignInType.badge).tracking(1)
                    .padding(.horizontal, PigSpacing.s).padding(.vertical, PigSpacing.xs)
                    .background(Color.pigCanvas.opacity(0.85), in: Capsule())
                    .foregroundStyle(Color.pigAccentText)
            }
            Image(systemName: systemImage).font(SignInType.tileIcon).accessibilityHidden(true)
            Text(title).font(SignInType.tileTitle)
            Text(detail).font(SignInType.body).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                .opacity(0.85)
        }
        .frame(maxWidth: .infinity, minHeight: SignInMetrics.tileHeight, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

/// A sign-in tile: the recommended one is the screen's one rose primary. Focused (tvOS), the shared focus treatment
/// (PigFocus.swift; the primary keeps its rose fill); pressed (touch), the pink fill and a small press.
private struct SignInTileStyle: ButtonStyle {
    let primary: Bool
    @Environment(\.isFocused) private var focused
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: SignInMetrics.tileRadius, style: .continuous)
        let lit = focused || configuration.isPressed
        configuration.label
            .padding(SignInMetrics.tilePadding)
            .foregroundStyle(primary ? Color.pigOnAccent : Color.pigText)
            .background(primary ? Color.pigAccent : lit ? PigFocus.fill : Color.pigRaised, in: shape)
            #if os(tvOS)
            .pigFocus(focused, in: shape, lift: .card)
            .opacity(enabled ? 1 : 0.5)
            #else
            .overlay { shape.strokeBorder(focused ? Color.pigAccent : .clear, lineWidth: 3).padding(-PigFocus.clearance).allowsHitTesting(false) }
            .scaleEffect(focused ? 1.03 : configuration.isPressed ? 0.98 : 1)
            .opacity(enabled ? 1 : 0.5)
            .animation(.easeOut(duration: 0.12), value: focused)
            #endif
    }
}

nonisolated enum SignInMetrics {
    #if os(tvOS)
    static let width: CGFloat = 1480
    static let sidePadding: CGFloat = 40
    static let topPadding: CGFloat = 30
    static let spacing: CGFloat = PigSpacing.xl
    static let brandSpacing: CGFloat = 14
    static let pigInk: CGFloat = 130
    static let cardSpacing: CGFloat = 20
    static let cardPadding = EdgeInsets(top: 34, leading: 40, bottom: 34, trailing: 40)
    static let chipPadding = EdgeInsets(top: 12, leading: 24, bottom: 12, trailing: 16)
    static let disc: CGFloat = 34
    static let tileSpacing: CGFloat = 28
    static let tileInner: CGFloat = 14
    static let tilePadding = EdgeInsets(top: 36, leading: 40, bottom: 36, trailing: 40)
    static let tileHeight: CGFloat = 230
    static let tileRadius = PigRadius.hero
    static let stacksTiles = false
    static let welcome = "Your channels. Your server."
    static let pairDetail = "The TV shows a code; approve it in PigTV on your phone or computer. No typing with the remote."
    static let passwordDetail = "Type your PigTV account with the on-screen keyboard."
    #else
    static let width: CGFloat = 760
    static let sidePadding: CGFloat = 20
    static let topPadding: CGFloat = 40
    static let spacing: CGFloat = PigSpacing.xl
    static let brandSpacing: CGFloat = 10
    static let pigInk: CGFloat = 96
    static let cardSpacing: CGFloat = 14
    static let cardPadding = EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)
    static let chipPadding = EdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 12)
    static let disc: CGFloat = 30
    static let tileSpacing: CGFloat = 16
    static let tileInner: CGFloat = 8
    static let tilePadding = EdgeInsets(top: 20, leading: 20, bottom: 20, trailing: 20)
    static let tileHeight: CGFloat = 0
    static let tileRadius = PigRadius.hero
    static var stacksTiles: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    static let welcome = "Your channels. Your server." // #243: one tagline on every platform
    static var pairDetail: String {
        "The \(UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone") shows a code; approve it in PigTV on your phone or computer."
    }
    static let passwordDetail = "Type your PigTV account."
    #endif
}

nonisolated enum SignInType {
    #if os(tvOS)
    static let welcome: Font = .system(size: PigType.display, weight: .bold)
    static let step: Font = .system(size: PigType.cardTitle, weight: .bold)
    static let stepNumber: Font = .system(size: PigType.caption, weight: .heavy)
    static let eyebrow: Font = .system(size: PigType.caption, weight: .bold)
    static let chipValue: Font = .system(size: PigType.secondary, weight: .semibold)
    static let chipIcon: Font = .system(size: PigType.sectionTitle)
    static let hint: Font = .system(size: PigType.secondary)
    static let body: Font = .system(size: PigType.body)
    static let badge: Font = .system(size: PigType.caption, weight: .heavy)
    static let tileIcon: Font = .system(size: PigType.pageTitle, weight: .regular)
    static let tileTitle: Font = .system(size: PigType.sectionTitle, weight: .bold)
    static let code: Font = .system(size: PigType.jumbo, weight: .bold)
    #else
    static let welcome: Font = .title.bold()
    static let step: Font = .title3.bold()
    static let stepNumber: Font = .subheadline.weight(.heavy)
    static let eyebrow: Font = .caption.weight(.bold)
    static let chipValue: Font = .headline
    static let chipIcon: Font = .title2
    static let hint: Font = .footnote
    static let body: Font = .subheadline
    static let badge: Font = .caption2.weight(.heavy)
    static let tileIcon: Font = .title
    static let tileTitle: Font = .title3.bold()
    static let code: Font = .system(size: PigType.jumbo, weight: .bold)
    #endif
}
