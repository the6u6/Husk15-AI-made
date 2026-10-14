// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

// MARK: - the top of every page

/// An item's page opens on its artwork: the icon over a blurred, darkened copy of itself, the name, a line under it, and
/// the one thing to do -- Play, Open, Start -- as a big button.
private struct PageHero<Action: View>: View {
    let item: LibraryItem
    let subtitle: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                ItemBackdrop(item: item, fallback: Color(.tertiarySystemFill))
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                HStack(alignment: .bottom, spacing: 14) {
                    ItemIcon(item: item, size: 84)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title)
                            .font(.system(.title2, design: .rounded).weight(.heavy))
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(2)
                    }
                    .foregroundColor(.white)
                    Spacer(minLength: 0)
                }
                .padding(16)
            }
            .frame(height: 210)
            action
                .padding(14)
        }
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// The page's main button.
private struct BigButton: View {
    let title: String
    let systemImage: String
    var prominent = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.system(.headline, design: .rounded))
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .foregroundColor(prominent ? Color.white : Color.accentColor)
                .huskBackground(prominent ? Color.accentColor : Color.accentColor.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(CardButtonStyle())
    }
}

/// A hero that sits in a List as its first row, edge to edge within the list's margins.
private extension View {
    func heroRow() -> some View {
        listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
    }
}

private func fileBytes(_ paths: [String]) -> String {
    let total = paths.reduce(Int64(0)) { sum, p in
        sum + (((try? FileManager.default.attributesOfItem(atPath: p)[.size]) as? NSNumber)?.int64Value ?? 0)
    }
    return ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
}

@MainActor private func turnOnJIT() {
    let jit = JITCoordinator.shared
    if HuskBuiltInJIT.isAvailable { jit.method = .builtIn }
    jit.enable()
}

// MARK: - a game

/// A translation-layer game: Play, its settings, what it is, and removing it.
struct GamePage: View {
    let app: TLApp
    @ObservedObject private var showcase = ShowcaseStore.shared

    @ObservedObject private var store = TranslationLayerStore.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @Environment(\.presentationMode) private var huskPM
    @State private var playing = false
    @State private var backupFile: URL?
    @State private var savesBusy = false
    @State private var savesMessage: String?
    /// Which dialog is showing. One `.alert` per view on iOS 13/14 -- see
    /// huskOneAlert -- and these three used to be three separate modifiers,
    /// of which only the last could ever be presented. "Close Husk to Play"
    /// was one of the two that silently did nothing.
    @State private var dialog: Dialog? = nil
    private enum Dialog { case quit, remove, restore(URL) }
    // The compatibility report is a sheet rather than an alert, so it is not in
    // the enum: sheets do not share the one-per-view limit that makes the three
    // alerts above collapse into one.
    @State private var reporting: CompatSubject?

    private var runs: Bool { app.report?.canRun == true }

    private var compatSubject: CompatSubject? {
        app.packageName.map { CompatSubject(package: $0, name: app.label, isGame: LibraryItem.game(app).isGame, iconPath: app.iconPath) }
    }

    /// Another game already loaded in this run of Husk: engines cannot be unloaded, so this one cannot start until Husk is
    /// closed and opened again.
    private var blockedBy: String? {
        guard let loaded = husk_native_loaded_apk().map({ String(cString: $0) }), let apk = app.apks.first, loaded != apk
        else { return nil }
        return store.apps.first { $0.apks.first == loaded }?.label ?? "Another game"
    }

    private var preflight: AppDiagnosis? { AppDiagnosis.preflight(app) }

    private var subtitle: String {
        if let used = LibraryItem.game(app).usedText { return used }
        return runs ? "Ready to play" : "May not run on this iPhone"
    }

    // The three footer sentences are built here rather than inline in the
    // Section's footer. The type checker cannot fold
    //   Text("a " + "b " + "\(x)" + " c")
    // inside an if/else-if chain inside a ViewBuilder in reasonable time, and
    // gives up with "the compiler is unable to type-check this expression in
    // reasonable time". Handing it a finished String is trivial for it.
    private var geodeFooter: String {
        "This is Geode's Android launcher. On Husk, Geode runs inside Geometry Dash instead: "
        + "turn it on here (or in Geometry Dash's settings, under Mods), then start Geometry Dash "
        + "and use Geode's button on its main menu to get mods. This APK supplies a library Geode "
        + "needs, so keep it."
    }

    private func loadedFooter(_ other: String) -> String {
        "\(other) is still loaded, and a game cannot be unloaded once it has started. "
        + "Close Husk with the button above, then open it again to play \(app.label)."
    }

    private var noCodeFooter: String {
        "This APK has no 64-bit code Husk can run, so it will probably not start."
    }

    // The Saves section's footer, for the same reason as the three above. Its
    // chain also interpolates `app.label` twice, which is enough on its own to
    // push the type checker over its budget.
    private var savesFooter: String {
        if let savesMessage { return savesMessage }
        if loadedNow {
            return "\(app.label) has been started in this run of Husk. "
            + "Close Husk and open it again to restore saves."
        }
        return "A backup is a .zip of everything \(app.label) has saved in Husk, "
        + "to keep in Files or move to another device."
    }

    var body: some View {
        List {
            Section {
                PageHero(item: .game(app), subtitle: subtitle) { primary }
            } footer: {
                if isGeodeLauncher {
                    Text(geodeFooter)
                } else if let other = blockedBy {
                    Text(loadedFooter(other))
                } else if !runs {
                    Text(noCodeFooter)
                }
            }
            .heroRow()

            // what the files say before it starts: a damaged APK, the wrong CPU, a missing piece, protection that refuses Husk
            if let d = preflight {
                Section {
                    AppDiagnosisCard(diagnosis: d)
                        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                }
            }
            // why it stopped last time, until it plays again
            if let d = GameStatusStore.shared.diagnosis(app.id), d != preflight {
                Section(header: Text("Last Run")) {
                    AppDiagnosisCard(diagnosis: d, showsEvidence: true)
                        .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                }
            }

            if let compatSubject, !isGeodeLauncher {
                CompatibilitySection(subject: compatSubject, reporting: $reporting)
            }

            if !ShowcaseStore.shared.pictures(for: app.packageName).isEmpty {
                Section(header: Text("Screenshots")) {
                    ShowcaseGallery(package: app.packageName)
                        .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                }
            }

            Section {
                NavigationLink(destination: libraryDestination(LibraryRoute.gameSettings(app.id))) {
                    Label("Game Settings", systemImage: "slider.horizontal.3")
                }
                NavigationLink(destination: libraryDestination(LibraryRoute.gameReport(app.id))) {
                    Label("Technical Details", systemImage: "cpu")
                }
            }

            if !isGeodeLauncher {
                Section {
                    Button { backUp() } label: { Label("Back Up Saves", systemImage: "square.and.arrow.up") }
                        .disabled(savesBusy || !SaveBackup.hasData(app))
                    Button { pickRestore() } label: { Label("Restore Saves", systemImage: "clock.arrow.circlepath") }
                        .disabled(savesBusy || loadedNow)
                } header: {
                    Text("Saves")
                } footer: {
                    Text(savesFooter)
                }
            }

            Section(header: Text("About")) {
                HuskLabeledContent("Runs With", value: app.report?.runnerName ?? "Unknown")
                if let st = GameStatusStore.shared.status(app.id) {
                    HuskLabeledContent("Last Result") {
                        Label(st.result.label, systemImage: st.result.symbol).foregroundColor(st.result.color)
                    }
                }
                HuskLabeledContent("Last Played", value: app.lastPlayed.map { huskFormatDateTime($0) } ?? "Never")
                HuskLabeledContent("Size", value: fileBytes(app.apks))
            }

            Section {
Button(action: { dialog = .remove }) {
                    Label("Remove Game", systemImage: "trash")
                }
                    .foregroundColor(Color.red)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(app.label)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $playing, onDismiss: askHowItRan) { TLAttemptView(app: app) }
        .sheet(item: $reporting) { CompatReportSheet(subject: $0) }
        .sheet(item: Binding(get: { backupFile.map(IdentifiedURL.init) }, set: { backupFile = $0?.url })) { f in
            ShareSheet(items: [f.url])
        }
        .huskOneAlert(isPresented: Binding(get: { dialog != nil },
                                          set: { if !$0 { dialog = nil } })) {
            switch dialog {
            case .quit:
                return Alert(
                    title: Text("Close Husk?"),
                    message: Text("\(blockedBy ?? "The other game") is still loaded and only one "
                                  + "game can run per session. Husk closes; open it again and "
                                  + "\(app.label) starts by itself."),
                    dismissButton: .default(Text("Close Husk")) {
                        // The game that is loaded is closed with Husk, which is
                        // the normal way out for it, not a crash; and this one
                        // starts by itself when Husk is opened again.
                        Router.shared.switchTo(app.id)
                        CrashReport.gameEnded()
                        HuskLog.flushNow()
                        exit(0)
                    })
            case .remove:
                return Alert(
                    title: Text("Remove \(app.label)?"),
                    message: Text("The game and everything it saved here are deleted from Husk."),
                    dismissButton: .destructive(Text("Remove")) {
                        huskPM.wrappedValue.dismiss()
                        store.remove(app)
                    })
            case .restore(let url):
                return Alert(
                    title: Text("Replace \(app.label)'s saves?"),
                    message: Text("What \(app.label) has saved now is replaced by the backup. "
                                  + "Back up first if you want to keep it."),
                    dismissButton: .destructive(Text("Replace")) { restore(url) })
            case .none:
                // Unreachable: the modifier only presents when `dialog` is set.
                // Exists because the compiler cannot know that, and a blank
                // alert beats a crash if it ever were.
                return Alert(title: Text(""), dismissButton: .cancel(Text("")))
            }
        }
        .id(jit.attachGeneration)
        .onAppear {
            // Kept until JIT is on: this page is rebuilt when it attaches (.id above), and plays then.
            guard Router.shared.autoPlay == app.id, Launcher.jitOn, blockedBy == nil else { return }
            Router.shared.autoPlay = nil
            play()
        }
    }

    /// Play: with Geode on, whatever it is missing (a newer release, its resources) is fetched first.
    private func play() {
        guard TLAppSettings.load(app.id).geode, case .ready = GeodeSupport.shared.current(app) else {
            if TLAppSettings.load(app.id).geode {
                Task { await GeodeSupport.shared.prepare(app); start() }
            } else {
                start()
            }
            return
        }
        start()
    }

    /// After a session that got going: how did it run? Once per game per build, and only when it played (a crash has its own sheet).
    private func askHowItRan() {
        guard var subject = compatSubject, CompatibilityStore.shared.shouldAsk(subject.package),
              GameStatusStore.shared.status(app.id)?.result == .plays else { return }
        subject.afterPlaying = true
        Task { try? await Task.sleep(nanoseconds: 500_000_000); reporting = subject }
    }

    /// Full screen, or in a window over Husk when Multitasking says so for this app.
    private func start() {
        if app.report?.runsOnNativeRuntime == true || app.report?.webKind != nil, AppWindows.opensInWindow(app) {
            AppWindows.shared.open(app)
        } else {
            AppWindows.shared.close(app)
            playing = true
        }
    }

    /// This game's engine is loaded in this run of Husk, so its files may be open: no restoring under it.
    private var loadedNow: Bool {
        guard let loaded = husk_native_loaded_apk().map({ String(cString: $0) }) else { return false }
        return loaded == app.apks.first
    }

    private func backUp() {
        savesBusy = true; savesMessage = nil
        let app = self.app
        Task.detached {
            let result = Result { try SaveBackup.export(app) }
            await MainActor.run {
                savesBusy = false
                switch result {
                case .success(let url): backupFile = url
                case .failure(let e): savesMessage = e.localizedDescription
                }
            }
        }
    }

    private func pickRestore() {
        HuskFilePicker.present(types: [.zip], multiple: false) { urls in
            if let url = urls.first { dialog = .restore(url) }
        } onFail: { savesMessage = $0 }
    }

    private func restore(_ url: URL) {
        savesBusy = true; savesMessage = nil
        let app = self.app
        Task.detached {
            let result = Result { try SaveBackup.restore(app, from: url) }
            await MainActor.run {
                savesBusy = false
                switch result {
                case .success(let n): savesMessage = "Restored \(n) file\(n == 1 ? "" : "s") from \(url.lastPathComponent)."
                case .failure(let e): savesMessage = e.localizedDescription
                }
            }
        }
    }

    /// Geode's Android launcher, added as if it were a game: it is a whole Android app, which Husk does not run. On Husk Geode
    /// is turned on from Geometry Dash's own settings, and this APK only lends it a library.
    private var isGeodeLauncher: Bool { app.packageName == GeodeSupport.launcherPackage }
    private var geometryDash: TLApp? { store.apps.first { $0.packageName == GeodeSupport.gamePackage } }

    @ViewBuilder
    private var primary: some View {
        if isGeodeLauncher {
            if let gd = geometryDash {
                BigButton(title: TLAppSettings.load(gd.id).geode ? "Geode Is On for Geometry Dash" : "Turn On Geode for Geometry Dash",
                          systemImage: "puzzlepiece.extension.fill", prominent: !TLAppSettings.load(gd.id).geode) {
                    var s = TLAppSettings.load(gd.id)
                    s.geode = true
                    s.save(gd.id)
                    Task { await GeodeSupport.shared.prepare(gd) }
                }
            } else {
                BigButton(title: "Add Geometry Dash First", systemImage: "plus", prominent: false) { }.disabled(true)
            }
        } else if blockedBy != nil {
            BigButton(title: "Close Husk to Play", systemImage: "xmark.circle", prominent: false) { dialog = .quit }
        } else if !Launcher.jitOn {
            if jit.busy {
                HStack(spacing: 10) { ProgressView(); Text(jit.status ?? "Turning on JIT…").foregroundColor(.secondary) }
                    .frame(maxWidth: .infinity).frame(height: 50)
            } else {
                BigButton(title: "Turn On JIT to Play", systemImage: "bolt.fill", action: turnOnJIT)
            }
        } else {
            BigButton(title: runs ? "Play" : "Try to Run", systemImage: "play.fill", prominent: runs) { play() }
        }
    }
}

// MARK: - a PS4 game

/// A PS4 game from Documents/PS4 Games: Play, and what it is. Run by the PS4 layer (libhuskps4.dylib) on Husk's JIT.
struct PS4GamePage: View {
    let game: PS4Game
    @ObservedObject private var jit = JITCoordinator.shared
    @State private var playing = false
    @State private var confirmQuit = false

    private var item: LibraryItem { .ps4(game) }

    /// Another game already loaded in this run of Husk (an Android game's engine, or another PS4 game).
    private var blockedBy: String? {
        if Router.shared.androidStarted { return "Android" }   // QEMU holds the JIT region the PS4 layer needs
        guard let loaded = husk_native_loaded_apk().map({ String(cString: $0) }), loaded != game.libraryID else { return nil }
        if loaded.hasPrefix("ps4:") { return PS4Store.shared.game(String(loaded.dropFirst(4)))?.title ?? "Another game" }
        return TranslationLayerStore.shared.apps.first { $0.apks.first == loaded }?.label ?? "Another game"
    }

    private var subtitle: String {
        if let used = item.usedText { return used }
        return "PlayStation 4" + (game.version.map { " · v\($0)" } ?? "")
    }

    var body: some View {
        List {
            PageHero(item: item, subtitle: subtitle) { primary }
                .heroRow()
            if !PS4Store.available {
                Section {
                    Text(PS4Store.moduleURL == nil
                         ? "This build of Husk does not include the PS4 layer."
                         : "PS4 games need iOS 17.4 or later.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("About") {
                LabeledContent("Runs With", value: "Husk's PS4 layer")
                LabeledContent("Title ID", value: game.titleID)
                if let v = game.version { LabeledContent("Version", value: v) }
                LabeledContent("Last Played", value: game.lastPlayed.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Never")
                LabeledContent("Folder", value: "PS4 Games/" + game.folder.lastPathComponent)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(game.title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $playing) { PS4PlayView(game: game) }
        .confirmationDialog("Close Husk?", isPresented: $confirmQuit, titleVisibility: .visible) {
            Button("Close Husk") {
                Router.shared.switchTo(game.libraryID)
                CrashReport.gameEnded()
                HuskLog.flushNow()
                exit(0)
            }
        } message: {
            Text("\(blockedBy ?? "The other game") is still loaded and only one game can run per session. Husk closes; open it again and \(game.title) starts by itself.")
        }
        .id(jit.attachGeneration)
        .onAppear {
            guard Router.shared.autoPlay == game.libraryID, Launcher.jitOn, blockedBy == nil, PS4Store.available else { return }
            Router.shared.autoPlay = nil
            playing = true
        }
    }

    @ViewBuilder
    private var primary: some View {
        if !PS4Store.available {
            BigButton(title: "Can't Play Here", systemImage: "xmark.octagon", prominent: false) { }.disabled(true)
        } else if blockedBy != nil {
            BigButton(title: "Close Husk to Play", systemImage: "xmark.circle", prominent: false) { confirmQuit = true }
        } else if !Launcher.jitOn {
            if jit.busy {
                HStack(spacing: 10) { ProgressView(); Text(jit.status ?? "Turning on JIT…").foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity).frame(height: 50)
            } else {
                BigButton(title: "Turn On JIT to Play", systemImage: "bolt.fill", action: turnOnJIT)
            }
        } else {
            BigButton(title: "Play", systemImage: "play.fill") { playing = true }
        }
    }
}

// MARK: - an app inside Android

struct IdentifiedURL: Identifiable {
    let url: URL
    var id: String { url.path }
}
