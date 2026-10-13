// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit

/// The tab UI: library, store, downloads, help, settings, with the snow over it.
struct ContentView: View {
    @ObservedObject private var router = Router.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @State private var showOnboarding = Onboarding.needed
    @Environment(\.huskScenePhase) private var scenePhase
    @huskAppStorage(Theme.Appearance.key) private var appearance = Theme.Appearance.system
    @ObservedObject private var theme = AppTheme.shared
    @ObservedObject private var incoming = IncomingFiles.shared
    @ObservedObject private var showcase = ShowcaseStore.shared
    @ObservedObject private var tlStore = TranslationLayerStore.shared
    @ObservedObject private var crash = CrashReport.shared
    @ObservedObject private var massTest = MassTest.shared
    @ObservedObject private var updates = AppUpdates.shared
    @State private var showWhatsNew = false
    @huskAppStorage(Holiday.key) private var holiday = true

    /// Which of the two dialogs this view can show, if any.
    ///
    /// iOS 13/14 presents only the LAST `.alert(isPresented:)` chained on a
    /// view and drops the rest with no diagnostic -- see huskOneAlert. These
    /// three used to be three separate modifiers, so "Husk is available" and
    /// "Metadata Updated" were never reachable and only the guest update
    /// appeared. The third, the guest update, went with the VM; the other two
    /// keep the consolidation, because splitting them apart again is the bug.
    ///
    /// They are derived from outside state rather than set by a button, so this
    /// stays computed rather than becoming a stored enum.
    private var activeDialog: ContentDialog? {
        if updates.available != nil && !showOnboarding && !showWhatsNew && crash.pending == nil {
            return .huskUpdate
        }
        if showcase.shouldAsk && !showOnboarding { return .metadata }
        return nil
    }

    private enum ContentDialog { case huskUpdate, metadata }

    /// The alert's own dismiss path: SwiftUI writes false through `isPresented`
    /// for every way out of an Alert, including the buttons, so each case has to
    /// put the underlying state back the way it was.
    private func dismissActiveDialog() {
        switch activeDialog {
        case .huskUpdate: updates.dismiss()
        case .metadata: showcase.asked()
        case .none: break
        }
    }

    var body: some View {
        ZStack {
            TabView(selection: $router.tab) {
                HomeView()
                    .tabItem { huskLabel("Home", systemImage: "house.fill") }
                    .tag(HuskTab.home)

                LibraryScreen()
                    .tabItem { huskLabel("Library", systemImage: "square.grid.2x2.fill") }
                    .tag(HuskTab.library)

                StoreView()
                    .tabItem { huskLabel("Store", systemImage: "cart.fill") }
                    .tag(HuskTab.store)

                FAQTab()
                    .tabItem { huskLabel("FAQ", systemImage: "questionmark.circle.fill") }
                    .tag(HuskTab.help)

                SettingsTab()
                    .tabItem { huskLabel("Settings", systemImage: "gearshape.fill") }
                    .tag(HuskTab.settings)
            }

            // Christmas: snow over the tabs. Never over an app's window, which
            // comes after it.
            if holiday {
                Snowfall()
                    .huskIgnoresSafeArea()
                    // Belt and braces with the isUserInteractionEnabled = false in
                    // SnowView.makeUIView. Upstream relied on Canvas being inert,
                    // which was a property of that primitive; the UIView this became
                    // has to earn it. Nothing in the snow takes touches by design --
                    // Appearance turns the whole thing off.
                    .allowsHitTesting(false)
            }

            // Multitasking: an app in a window over everything else in Husk (AppWindows.swift).
            //
            // No .allowsHitTesting here any more, and that is deliberate: upstream
            // had `.allowsHitTesting(showGuestScreen)` on this layer, because a
            // full-screen layer that draws nothing still absorbs every touch under
            // it, and with QEMU gone so was `showGuestScreen` and the guard that
            // named it. The whole tab UI went inert -- drawn, and dead to the touch.
            //
            // The guard now lives inside AppWindowLayer, on its GeometryReader,
            // where `windows.app != nil` is the honest condition and where it
            // cannot be lost again by editing this file. See AppWindows.swift.
            AppWindowLayer()
                // `.ignoresSafeArea(.keyboard)` is iOS 14 -- `Edge.Set.keyboard`
                // alongside it is too -- and this is what it meant: ignore the
                // keyboard edge and nothing else.
                //
                // `huskIgnoresSafeArea()` with no argument ignores `.all`, and
                // `.all` includes `.container`. The GeometryReader in
                // AppWindowLayer measures the screen it is given and AppWindow
                // computes its frame from that, so ignoring the container there
                // changes the size it is handed and everything positioned inside
                // it. `edgesIgnoringSafeArea(_:)` is the iOS 11 spelling and takes
                // an Edge.Set, so the original instruction is expressible here.
                .edgesIgnoringSafeArea(.keyboard)

        }
        .accentColor(theme.accentColor)
        // The user's appearance: the system's, unless they pinned one. Set on the
        // window rather than with .preferredColorScheme — see Theme.apply.
        .onAppear { Theme.apply(appearance) }
        .huskOnChange(of: appearance) { Theme.apply($0) }
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingView {
                showOnboarding = false
            }
        }
        // A game that ended Husk last time: say so, with its report.
        .sheet(item: Binding(get: { showOnboarding ? nil : crash.pending }, set: { crash.pending = $0 }),
               onDismiss: { if WhatsNew.due { showWhatsNew = true } }) { r in
            CrashReportSheet(report: r)
        }
        // After an update: what it brought, once.
        .fullScreenCover(isPresented: $showWhatsNew) {
            WhatsNewSheet { WhatsNew.markSeen(); showWhatsNew = false }
        }
        // The alerts are further down the chain: one per view on iOS 13/14, and
        // this view has three. See huskOneAlert.
        //
        // Upstream adds a fourth here -- the "Husk X Is Available" prompt, which
        // is the same dialog the .huskUpdate case of activeDialog already
        // renders with the same title, message and buttons. It is written as a
        // plain second .alert because several can be chained from iOS 15; on
        // this floor only the last one is ever presented, so adding it would put
        // "Husk is available" and "Metadata Updated" back out of reach.
        //
        // .task is iOS 15. onAppear + Task is the same thing with the
        // cancellation thrown away; there is nothing to cancel here.
        .onAppear {
            Task { await updates.check() }
            Task { await CompatibilityStore.shared.refresh() }
        }
        .sheet(isPresented: $router.showDownloads) { DownloadsTab() }
        // Pictures for the apps here: read the index on launch and whenever the
        // set of apps changes. .task(id:) is iOS 15, so the two halves are
        // spelled out.
        .onAppear { showcase.refresh(for: showcasePackages) }
        .huskOnChange(of: showcasePackages) { _ in showcase.refresh(for: showcasePackages) }
        // An APK shared to Husk: where does it go?
        .sheet(isPresented: Binding(get: { !incoming.waiting.isEmpty },
                                    set: { if !$0 { incoming.discard() } })) {
            IncomingChooser()
                .huskDetent(.medium)
                .huskDragIndicator()
        }
        .sheet(isPresented: $jit.showSetup) { JITSetupFlow() }
        // The built-in helper attaches while Husk stays in the foreground, so
        // there is no relaunch to trigger the region claim below; this is it.
        .huskOnChange(of: jit.attachGeneration) { _ in evaluate() }
        // Asking rather than downloading. Two gigabytes over someone's cellular
        // connection is not a decision to make on their behalf.
        //
        // All three of this view's dialogs are here, in one modifier, because
        // iOS 13/14 presents only the last .alert(isPresented:) on a view. Only
        // this one -- the last of the three -- could appear before; "Husk is
        // available" and "Metadata Updated" have never been reachable.
        .huskOneAlert(isPresented: Binding(get: { activeDialog != nil },
                                          set: { if !$0 { dismissActiveDialog() } })) {
            switch activeDialog {
            case .huskUpdate:
                return Alert(
                    title: Text("Husk \(updates.available?.version ?? "") Is Available"),
                    message: Text("You have \(AppUpdates.current). The new version's IPA is "
                                  + "on its release page."),
                    primaryButton: .default(Text("View Release")) {
                        if let page = updates.available?.page { UIApplication.shared.open(page) }
                        updates.dismiss()
                    },
                    secondaryButton: .cancel(Text("Not Now")))
            case .metadata:
                return Alert(
                    title: Text("Metadata Updated"),
                    message: Text("Metadata for \(showcase.updates.count) of your app"
                                  + "\(showcase.updates.count == 1 ? "" : "s") has been "
                                  + "updated. Would you like to download the updates?"),
                    primaryButton: .default(Text("Download")) { showcase.downloadUpdates() },
                    secondaryButton: .cancel(Text("Not Now")) { showcase.asked() })
            case .none:
                return Alert(title: Text(""), dismissButton: .cancel(Text("")))
            }
        }
        .sheet(isPresented: $massTest.shareResults) { ShareSheet(items: [MassTest.resultsURL]) }
        .onAppear {
            crash.checkPreviousRun()
            // the developer mass test: the last app's fate, then the next app (it clears a crash report it has written down)
            massTest.resume(crash: crash)
            if crash.pending == nil, !massTest.active { router.resumeSwitch() }
            if crash.pending == nil, WhatsNew.due { showWhatsNew = true }
            evaluate()
        }
        // The two-parameter onChange is iOS 17; this single-parameter form is
        // deprecated there but still works, and is the only one that compiles
        // against the 16.0 deployment target.
        .huskOnChange(of: scenePhase) { phase in
            // StikDebug relaunches Husk after attaching, so returning to the
            // foreground is the moment worth re-checking, not first launch.
            if phase == .active { evaluate() }
        }
        // scenePhase is iOS 14 and is a property of a scene; on 13 the app has
        // one window and no scene, so this bridges the four UIApplication
        // notifications into the environment value the reader above expects.
        .huskScenePhaseTracking()
    }

    /// Every package Husk holds: what the picture index is read for. It was the
    /// union of what the guest had and what the translation layer has, because
    /// the index covers both; there is one list now.
    private var showcasePackages: Set<String> {
        Set(tlStore.apps.compactMap(\.packageName))
    }

    private func evaluate() {
        // Before anything else wants JIT: the setting that turns it on as Husk opens.
        jit.enableAtLaunchIfAsked()

        if !JITBootstrap.ready {
            HuskLog.log("ui", "no JIT yet; waiting for a debugger")
            return
        }

        // Claim the JIT region now, on the first foreground pass after the debugger
        // attaches, while it is still running. Waiting for the Start button means
        // iOS has often suspended the debugger, causing unserviced brk freezes.
        // After the first call this is a no-op, and on success it also detaches the debugger.
        JITBootstrap.prewarm()
    }
}

/// Live log tail with a share button. The share sheet is the practical way to get
/// husk.log off the device. Reached from Settings, behind the gear.
struct LogView: View {
    var isSheet = true
    @Environment(\.presentationMode) private var huskPM
    @State private var lines: [String] = []
    @State private var showShare = false
    private let tick = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            ScrollView {
                huskLazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        Text(line)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(color(for: line))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                    }
                }
                .padding(.horizontal, 8)
            }
            // ScrollViewReader is iOS 14. What it was asked for here is one
            // thing -- keep the log at the last line -- and huskScrollToBottom
            // does that by moving the enclosing scroll view's offset. The token
            // is the last line's index, which is what scrollTo(last) used.
            .huskScrollToBottom(lines.count)
            .onReceive(tick) { _ in
                lines = HuskLog.recentLines(800)
            }
            .navigationTitle("Logs")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: AnyView(
                    Group {
                        if isSheet {
                            Button("Done") { huskPM.wrappedValue.dismiss() }
                        }
                    }
                ),
                trailing: AnyView(
                    Button { showShare = true } label: { Image(systemName: "square.and.arrow.up") }
                )
            )
            .sheet(isPresented: $showShare) {
                // The guest's serial console used to be here too. It is the
                // native log below that matters now, and that is what made this
                // sheet worth having: without it a crash could not be diagnosed
                // from a shared log.
                ShareSheet(items: [
                    HuskLog.logFileURL,
                    HuskLog.nativeLogURL,
                    HuskLog.previousNativeLogURL,
                ])
            }
        }
    }

    /// Colour by source so the JIT path stands out from QEMU's own chatter.
    private func color(for line: String) -> Color {
        if line.contains("FAIL") || line.contains("FATAL") || line.contains("error") {
            return .red
        }
        if line.contains("[husk-jit]") { return .green }
        if line.contains("[husk-dpy]") { return Color(.cyan) }
        if line.contains("[guest]")    { return .yellow }
        return .primary
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
