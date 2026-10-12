// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UniformTypeIdentifiers

/// The JIT walkthrough: pick a way in, follow its numbered steps, end with JIT on.
///
/// Three ways in. Pairing on this iPhone (iOS 27) and a pairing file made on a
/// computer both lead to Built-in StikJIT and share the last two steps,
/// LocalDevVPN and enabling. StikDebug has its own short page. Presented from
/// onboarding, Settings › JIT, and whenever Start finds JIT not set up.
struct JITSetupFlow: View {
    enum Step: Hashable { case pairOnDevice, importFile, connect, enable, stikDebug, trollStore, jailbreak }

    @ObservedObject private var jit = JITCoordinator.shared
    @ObservedObject private var pairing = OnDevicePairing.shared
    /// The step in front of `choose`, or nil for the chooser itself.
    ///
    /// This was `[Step]` bound to `NavigationView(path:)`, which is iOS 16.
    /// No step was ever popped one at a time -- Back returned to `choose` and
    /// that was the only thing on the stack below -- so a single optional is
    /// the same flow with a different shape.
    @State private var step: Step?
    @State private var importing = false
    @Environment(\.presentationMode) private var huskPM

    private var device: String { OnDevicePairing.deviceKind }

    var body: some View {
        NavigationView {
            Group {
                if let step = step { stepView(step) } else { choose }
            }
        }
        .accentColor(Theme.accent)
        // .fileImporter is iOS 14. HuskFilePicker presents the same picker from
        // the topmost view controller instead -- see HuskFilePicker.swift for why
        // that is the more reliable route -- so this is huskFilePicker with the
        // two content types as UTI strings: `.propertyList` and `.data`.
        .huskFilePicker(isPresented: $importing, types: ["com.apple.property-list", "public.data"]) { urls in
            if let url = urls.first { jit.importPairingFile(url) }
        }
        .onAppear {
            jit.refreshPairingStatus()
            pairing.reset()
            // A failed enable from the Library lands on the step that can fix it.
            if jit.error != nil, jit.hasPairing, jit.resolvedMethod == .builtIn {
                step = .enable
            }
            HuskLog.log("ui", "JIT walkthrough opened")
        }
        // Swiping the sheet away, or a copy shown from onboarding, must not
        // leave a request to show it again behind.
        .onDisappear { jit.showSetup = false }
    }

    private func close() {
        jit.showSetup = false
        huskPM.wrappedValue.dismiss()
    }

    @ViewBuilder private func stepView(_ step: Step) -> some View {
        switch step {
        case .pairOnDevice: pairOnDevice
        case .importFile: importFile
        case .connect: connect
        case .enable: enable
        case .stikDebug: stikDebug
        case .trollStore: trollStore
        case .jailbreak: jailbreak
        }
    }

    // MARK: Choose

    private var choose: some View {
        page(symbol: "bolt.fill", title: "Turn on JIT",
             subtitle: "Android needs memory it can write and then run, which on iOS only an attached "
                     + "debugger can grant. Choose how your \(device) gets one.") {
            VStack(spacing: 10) {
                let builtIn = HuskBuiltInJIT.unavailableReason
                way("Pair on this \(device)", symbol: "iphone.radiowaves.left.and.right",
                    detail: builtIn ?? (!OnDevicePairing.isSupported ? "Needs iOS 27 or later."
                        : jit.pairingSource == .onDevice ? "Paired on this \(device)."
                        : "No computer needed. Pairs from Settings in a minute."),
                    done: jit.pairingSource == .onDevice,
                    enabled: builtIn == nil && OnDevicePairing.isSupported) { step = .pairOnDevice }
                way("Use a pairing file", symbol: "doc.badge.plus",
                    detail: builtIn ?? (jit.pairingSource == .imported ? "Pairing file imported."
                        : "Import a pairing file made on a computer."),
                    done: jit.pairingSource == .imported,
                    enabled: builtIn == nil) { step = .importFile }
                way("Use StikDebug", symbol: "ant",
                    detail: JITBootstrap.isStikDebugInstalled ? "StikDebug is installed."
                        : "Enable JIT through the StikDebug app.",
                    done: jit.method == .stikDebug) { step = .stikDebug }
                way("Use TrollStore", symbol: "sparkles",
                    detail: JITBootstrap.isTrollStoreInstalled ? "TrollStore is installed."
                        : "For a Husk installed through TrollStore.",
                    done: jit.method == .trollStore) { step = .trollStore }
                way("Use a jailbreak", symbol: "lock.open",
                    detail: JITBootstrap.debuggedAtLaunch ? "JIT was already on when Husk opened."
                        : JITBootstrap.isJailbroken ? "A jailbreak was found. Turn on Allow JIT in Apps."
                        : "Dopamine can give every app JIT with one setting.",
                    done: jit.method == .jailbreak || JITBootstrap.debuggedAtLaunch) { step = .jailbreak }
            }
            if jit.hasPairing && HuskBuiltInJIT.isAvailable {
                Button { step = .connect } label: {
                    huskLabel("Continue with the current pairing", systemImage: "arrow.right")
                        .font(.system(size: 14, weight: .semibold))
                }
                .padding(.top, 4)
            }
        } actions: {
            Button("Not now") { close() }
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(Theme.textDim)
        }
    }

    private func way(_ title: String, symbol: String, detail: String, done: Bool,
                     enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Theme.accent)
                    .frame(width: 34, height: 34)
                    .huskBackground(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 16, weight: .semibold)).foregroundColor(Theme.text)
                    Text(detail).font(.system(size: 13)).foregroundColor(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: done ? "checkmark.circle.fill" : "chevron.right")
                    .font(.system(size: done ? 18 : 13, weight: .semibold))
                    .foregroundColor(done ? .green : Theme.textDim.opacity(0.7))
            }
            .padding(14)
            .contentShape(Rectangle())
            .huskCard()
        }
        .buttonStyle(CardButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    // MARK: Pair on this device

    private var pairedOnDevice: Bool {
        if case .paired = pairing.phase { return true }
        return false
    }

    private var pairOnDevice: some View {
        page(symbol: "iphone.radiowaves.left.and.right", title: "Pair on this \(device)",
             subtitle: "Husk pretends to be a computer on your Wi-Fi, and your \(device) pairs with it "
                     + "the way it would with a Mac.") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "Turn on Wi-Fi, tap **Start pairing** below and allow Local Network access.",
                      done: pairing.phase != .idle)
                point(2, "Open **Settings › Privacy & Security › Developer Mode**, scroll down and tap "
                       + "**Pair with \(OnDevicePairing.hostName)**.",
                      done: pairing.isShowingPin || pairedOnDevice)
                point(3, "Enter the code Husk shows. It also appears in a banner and a notification, "
                       + "so you don't have to switch back.",
                      done: pairedOnDevice)
                point(4, "Come back to Husk.", done: pairedOnDevice)
            }
            .padding(16).huskCard()
            pairingStatus
        } actions: {
            switch pairing.phase {
            case .idle, .failed:
                Button { pairing.start() } label: {
                    huskLabel("Start pairing", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(PrimaryButtonStyle())
            case .waiting, .pin:
Button("Cancel pairing") { pairing.cancel() }
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.textDim)
            case .paired:
                Button("Continue") { step = .connect }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    @ViewBuilder private var pairingStatus: some View {
        switch pairing.phase {
        case .idle:
            EmptyView()
        case .waiting:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    huskProgress().accentColor(Theme.accent)
                    Text("Waiting for your \(device)…").font(.system(size: 15, weight: .semibold))
                        .foregroundColor(Theme.text)
                }
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .font(.system(size: 14, weight: .semibold))
                if pairing.backgroundLimited {
                    Text("This installation can only wait about 30 seconds in the background, "
                       + "so go to Settings straight away.")
                        .font(.system(size: 13)).foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16).huskCard()
        case .pin(let pin):
            VStack(spacing: 8) {
                Text("Enter this code on your \(device)").font(.system(size: 14))
                    .foregroundColor(Theme.textDim)
                Text(pin).font(.system(size: 40, weight: .bold, design: .monospaced)).tracking(6)
                    .foregroundColor(Theme.text)
                    .accessibility(label: "Pairing code \(pin.map(String.init).joined(separator: " "))")
            }
            .frame(maxWidth: .infinity)
            .padding(18).huskCard(high: true)
        case .paired(let name):
            outcome("Paired with \(name)", ok: true)
        case .failed(let message):
            outcome(message, ok: false)
        }
    }

    // MARK: Import a pairing file

    private var importFile: some View {
        page(symbol: "doc.badge.plus", title: "Use a pairing file",
             subtitle: "A pairing file made on a computer lets Husk talk to this \(device) the same way.") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "On a computer, make this \(device)'s pairing file with the "
                       + "[StikDebug pairing-file guide](https://github.com/StikDebug/StikDebug-Guide/blob/main/pairing_file.md).",
                      done: jit.pairingSource == .imported)
                point(2, "Save it to Files, or AirDrop it to this \(device).",
                      done: jit.pairingSource == .imported)
                point(3, "Tap **Choose pairing file** and pick it.", done: jit.pairingSource == .imported)
            }
            .padding(16).huskCard()
            huskLabel("The pairing file stays in Husk's Documents folder and is only sent to Husk's own helper.",
                  systemImage: "lock.fill")
                .font(.system(size: 13)).foregroundColor(Theme.textDim)
            if let error = jit.error { outcome(error, ok: false) }
        } actions: {
            if jit.pairingSource == .imported {
                Button("Continue") { step = .connect }.buttonStyle(PrimaryButtonStyle())
                Button("Choose another file") { importing = true }
                    .font(.system(size: 15, weight: .medium))
            } else {
                Button { importing = true } label: { huskLabel("Choose pairing file", systemImage: "folder") }
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
    }

    // MARK: LocalDevVPN

    private var connect: some View {
        page(symbol: "network.badge.shield.half.filled", title: "Connect LocalDevVPN",
             subtitle: "Husk's helper reaches this \(device)'s debugging service through a local VPN. "
                     + "Nothing leaves your \(device).") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "Install [LocalDevVPN](\(LocalDevVPN.appStore.absoluteString)) from the App Store.",
                      done: LocalDevVPN.isInstalled)
                point(2, "Tap **Connect LocalDevVPN**. It switches the VPN on and comes straight back to Husk.")
                point(3, "Leave it connected whenever you turn JIT on.")
            }
            .padding(16).huskCard()
        } actions: {
            Button(LocalDevVPN.actionTitle) { LocalDevVPN.open() }
                .buttonStyle(PrimaryButtonStyle())
            Button("It's connected") { step = .enable }
                .font(.system(size: 15, weight: .medium))
        }
    }

    // MARK: Enable

    private var attached: Bool { jit.attachGeneration > 0 || JITBootstrap.debuggedFlag }

    private var enable: some View {
        page(symbol: "bolt.badge.checkmark", title: "Turn on JIT",
             subtitle: "The first check downloads and mounts Apple's Developer Disk Image, "
                     + "which can take a minute.") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "Tap **Check setup**. Husk checks LocalDevVPN and prepares the Developer Disk Image.",
                      done: jit.prepared || attached)
                point(2, "Tap **Enable JIT**. Husk's helper attaches and Android can start.", done: attached)
            }
            .padding(16).huskCard()

            if jit.busy {
                HStack(spacing: 11) {
                    huskProgress().accentColor(Theme.accent)
                    Text(jit.status ?? "Working…").font(.system(size: 14)).foregroundColor(Theme.text)
                    Spacer(minLength: 0)
                }
                .padding(16).huskCard(high: true)
            } else if attached {
                outcome("JIT is on. Android can start.", ok: true)
            } else if let error = jit.error {
                VStack(alignment: .leading, spacing: 10) {
                    outcome(error, ok: false)
                    if jit.connectionProblem == .pairing {
                        Button(OnDevicePairing.isSupported ? "Pair again" : "Import a new pairing file") {
                            step = (OnDevicePairing.isSupported ? .pairOnDevice : .importFile)
                        }
                        .font(.system(size: 14, weight: .semibold))
                    }
                    if jit.connectionProblem != nil {
                        Button(LocalDevVPN.actionTitle) { LocalDevVPN.open() }
                            .font(.system(size: 14, weight: .semibold))
                    }
                }
            } else if let status = jit.status {
                outcome(status, ok: true)
            }

            if !attached {
Button("Reset Developer Disk Image") { jit.resetDDI() }
                .foregroundColor(Color.red)
                    .font(.system(size: 13, weight: .medium))
                    .disabled(jit.busy)
                    .padding(.top, 4)
            }
        } actions: {
            if attached {
                Button("Done") { close() }.buttonStyle(PrimaryButtonStyle())
            } else if jit.prepared {
                Button { jit.enableBuiltIn() } label: { huskLabel("Enable JIT", systemImage: "bolt.fill") }
                    .buttonStyle(PrimaryButtonStyle(enabled: !jit.busy))
                    .disabled(jit.busy)
            } else {
                Button("Check setup") { jit.prepareBuiltIn() }
                    .buttonStyle(PrimaryButtonStyle(enabled: !jit.busy))
                    .disabled(jit.busy)
            }
        }
    }

    // MARK: StikDebug

    private var stikDebug: some View {
        page(symbol: "ant", title: "Use StikDebug",
             subtitle: "StikDebug is a separate app that attaches to Husk. Husk sends it the JIT script "
                     + "itself, so nothing needs configuring for Husk inside StikDebug.") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "Install [StikDebug](https://github.com/StikDebug/StikDebug/releases/latest).",
                      done: JITBootstrap.isStikDebugInstalled)
                point(2, "Import this \(device)'s pairing file into StikDebug.")
                point(3, "Install and connect [LocalDevVPN](\(LocalDevVPN.appStore.absoluteString)).")
                point(4, "Whenever Android starts, Husk opens StikDebug, which attaches and comes back.")
            }
            .padding(16).huskCard()
        } actions: {
            Button("Use StikDebug") {
                jit.method = .stikDebug
                HuskLog.log("ui", "JIT method set to StikDebug")
                close()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: TrollStore

    private var trollStore: some View {
        page(symbol: "sparkles", title: "Use TrollStore",
             subtitle: "TrollStore can enable JIT for apps it installed, with no pairing file, "
                     + "VPN or computer.") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "Install Husk.ipa through TrollStore, on an iOS version TrollStore supports. It carries the "
                       + "entitlements TrollStore keeps, so the same file works there and in a sideloader.",
                      done: JITBootstrap.isInstalledWithTrollStore)
                point(2, "In TrollStore's Settings, turn on URL Scheme. TrollStore ignores enable-jit requests without it.",
                      done: JITBootstrap.isTrollStoreInstalled)
                point(3, "Whenever Android or a game starts, Husk asks TrollStore to enable JIT. TrollStore opens Husk, "
                       + "attaches to it for a moment and lets go, which leaves it allowed to run code it wrote.")
            }
            .padding(16).huskCard()
            if !JITBootstrap.isTrollStoreInstalled {
                huskLabel("TrollStore was not found on this \(device). Husk can only use it once it is installed "
                    + "and Husk was installed through it.", systemImage: "info.circle")
                    .font(.system(size: 13)).foregroundColor(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            Button("Use TrollStore") {
                jit.method = .trollStore
                HuskLog.log("ui", "JIT method set to TrollStore")
                close()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: Jailbreak

    private var jailbreak: some View {
        page(symbol: "lock.open", title: "Use a jailbreak",
             subtitle: "On a device jailbroken with Dopamine, JIT is a setting: the jailbreak marks every app as "
                     + "debugged when it opens, and a debugged app may run code it wrote. Husk needs nothing else.") {
            VStack(alignment: .leading, spacing: 14) {
                point(1, "Open Dopamine and go to its Settings.", done: JITBootstrap.isJailbroken)
                point(2, "Turn on Allow JIT in Apps.")
                point(3, "Close Husk completely and open it again. The setting applies to apps as they start.",
                      done: JITBootstrap.debuggedAtLaunch)
            }
            .padding(16).huskCard()
            if JITBootstrap.debuggedAtLaunch {
                huskLabel("Husk was marked as debugged when it opened, so JIT is on.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13)).foregroundColor(.green)
            } else if !JITBootstrap.isJailbroken {
                huskLabel("No jailbreak was found on this \(device).", systemImage: "info.circle")
                    .font(.system(size: 13)).foregroundColor(Theme.textDim)
            }
        } actions: {
            Button("Use the jailbreak") {
                jit.method = .jailbreak
                HuskLog.log("ui", "JIT method set to jailbreak")
                close()
            }
            .buttonStyle(PrimaryButtonStyle())
        }
    }

    // MARK: Pieces

    private func page<Content: View, Actions: View>(
        symbol: String, title: String, subtitle: String,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions) -> some View {
        ZStack {
            Theme.backdrop
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: symbol)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundColor(Theme.accent)
                        .frame(width: 56, height: 56)
                        .huskBackground(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    Text(title).font(.system(size: 28, weight: .semibold)).foregroundColor(Theme.text)
                    Text(subtitle).font(.system(size: 15)).foregroundColor(Theme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    content()
                }
                // safeAreaInset is iOS 15. The action bar is overlaid at the
                // bottom edge instead, and the ScrollView carries the padding
                // safeAreaInset would have measured for it: 24pt of slack plus
                // roughly the 92pt the bar itself occupies (16 of padding plus
                // a 44pt button and 12 of spacing).
                .padding(.horizontal, 22).padding(.top, 8).padding(.bottom, 116)
            }
            VStack(spacing: 12) { actions() }
                .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 16)
                .background(Theme.backdrop)
        }
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarItems(
            leading: AnyView(
                Group {
                if step != nil {
                Button("Back") { step = nil }
                }
                }
            ),
            trailing: AnyView(
                Button("Close") { close() }
            )
        )
    }

    private func point(_ number: Int, _ text: String, done: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green.opacity(0.18) : Theme.accentSoft)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundColor(.green)
                } else {
                    Text("\(number)").font(.system(size: 13, weight: .bold)).foregroundColor(Theme.accent)
                }
            }
            .frame(width: 26, height: 26)
            Text(.init(text))
                .font(.system(size: 15))
                .foregroundColor(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func outcome(_ text: String, ok: Bool) -> some View {
        huskLabel(text, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(ok ? .green : .red)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14).huskCard()
    }
}
