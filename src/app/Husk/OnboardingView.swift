// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// What Husk asks on a first install, and remembers.
///
/// Deliberately versioned rather than a plain "seen it" flag: a later build that
/// adds a question needs to be able to ask it, and existing installs must not be
/// dragged back through the whole flow for one new answer. Bumping
/// `Onboarding.version` is what re-opens it.
enum Onboarding {
    /// Raise this when a question is added that existing installs must answer.
    static let version = 1

    private static let key = "husk.onboardingVersion"

    static var needed: Bool {
        UserDefaults.standard.integer(forKey: key) < version
    }

    static func complete() {
        UserDefaults.standard.set(version, forKey: key)
    }

    /// Start the guest as soon as the app opens, when JIT is available.
    }

struct OnboardingView: View {
    let onDone: () -> Void

    @State private var page = 0
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var jit = JITCoordinator.shared
    @State private var settingUpJIT = false

    private let pages = 3

    var body: some View {
        ZStack {
            Theme.backdrop

            VStack(spacing: 0) {
                TabView(selection: $page) {
                    welcome.tag(0)
                    jitPage.tag(1)
                    ready.tag(2)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .sheet(isPresented: $settingUpJIT) { JITSetupFlow() }

                // One control, always in the same place. A flow that moves its
                // own button around is harder to get through than one that does
                // not, and this is the first thing anyone sees.
                VStack(spacing: 12) {
                    HStack(spacing: 6) {
                        ForEach(0..<pages, id: \.self) { i in
                            Capsule()
                                .fill(i == page ? Theme.accent : Color.secondary.opacity(0.3))
                                .frame(width: i == page ? 18 : 6, height: 6)
                                .huskAnimation(.huskSnappy, value: page)
                        }
                    }
                    Button {
                        if page < pages - 1 {
                            withAnimation(.huskSnappy) { page += 1 }
                        } else {
                            save()
                            onDone()
                        }
                    } label: {
                        Text(page < pages - 1 ? "Continue" : "Start using Husk")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.horizontal, 28)
                }
                .padding(.bottom, 28)
            }
        }
    }

    private func save() {
        let d = UserDefaults.standard
        Onboarding.complete()
        HuskLog.log("ui", "setup complete")
    }

    // MARK: pages

    private var welcome: some View {
        VStack(spacing: 20) {
            Spacer()
            if let art = HuskAppIcon.current.preview(dark: scheme == .dark) {
                Image(uiImage: art)
                    .resizable().scaledToFit()
                    .frame(width: 112, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 25, style: .continuous))
                    .shadow(color: Theme.accent.opacity(0.35), radius: 22, y: 10)
            }
            Text("Husk").font(.system(size: 40, weight: .semibold, design: .rounded))
            Text("Android apps, on your iPhone.")
                .font(.title3).foregroundColor(.secondary)
            // This said "runs a real Android system and opens APKs inside it",
            // which is exactly what the VM removal makes false -- and it was the
            // first thing a new user read.
            Text("Husk runs the game on the iPhone itself, translating what it needs "
               + "from Android. One question first, and it changes what runs.")
                .font(.callout).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34).padding(.top, 4)
            Spacer()
        }
    }
    private var jitState: String? {
        if JITBootstrap.ready { return "JIT is on." }
        if jit.method == .stikDebug { return "Husk will use StikDebug." }
        if jit.method == .trollStore { return "Husk will use TrollStore." }
        switch jit.pairingSource {
        case .onDevice: return "Paired on this device."
        case .imported: return "Pairing file imported."
        case nil: return nil
        }
    }

    private var jitPage: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "bolt.fill")
                .font(.system(size: 54))
                .foregroundColor(Theme.accent)
            Text("Turn on JIT").font(.largeTitle.weight(.semibold))
            Text("Android and Translation Layer games need JIT, which on iOS only an attached debugger can grant. "
               + "StikJIT is built into Husk and is the recommended way: it turns JIT on from inside the app, "
               + "with no computer and no other app. StikDebug and TrollStore work too.")
                .font(.callout).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
            if let state = jitState {
                huskLabel(state, systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.medium)).foregroundColor(.green)
            }
            Button(jitState == nil ? "Set Up StikJIT Now" : "Change JIT Setup") { settingUpJIT = true }
                .font(.body.weight(.semibold))
                .foregroundColor(Theme.accent)
                .padding(.top, 4)
            Spacer()
        }
    }

    private var ready: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 62))
                .foregroundColor(Theme.accent)
            Text("Ready").font(.largeTitle.weight(.semibold))
            Text("If JIT is not on when Android starts, Husk turns it on with the "
               + "method you chose, or walks you through setting one up. You can "
               + "change it any time in Settings › JIT & sideload.")
                .font(.callout).foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 34)
            Spacer()
        }
    }
}
