// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// Settings, as the iOS Settings app lays them out: a card for the app up top, then groups of rows that each
/// push a page of their own. What belongs to the app, what belongs to the emulator, and what the thing is.
struct SettingsTab: View {
    @AppStorage(AppWindows.defaultKey) private var multitask = false
    @AppStorage(CompatibilityStore.askKey) private var askCompat = true

    var body: some View {
        NavigationView {
            List {
                Section {
                    NavigationLink { AboutSettings() } label: { appCard }
                }

                Section {
                    row(JITSettings(), "bolt.fill", .yellow, "JIT & Sideload", "StikJIT is built in — the recommended way")
                } header: {
                    Text("JIT")
                } footer: {
                    Text("Android and Translation Layer games need JIT. StikJIT, built into Husk, turns it on without a computer.")
                }

                Section(header: Text("General")) {
                    row(DiscoverView(), "sparkle.magnifyingglass",Color(.systemMintFallback), "Discover", "Find apps in F-Droid and other repositories")
                    row(AppearanceSettings(), "paintbrush.fill", .pink, "Appearance", "Light or dark, accent colour, app icon")
                }

                Section {
                    Toggle(isOn: $multitask) {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Open Apps in Windows")
                                Text("Use Husk while an app runs").font(.caption).foregroundColor(.secondary).lineLimit(1)
                            }
                        } icon: {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                // Color.gradient is iOS 16. iOS 14 has no
                                // gradient fill for a Shape, so the icon is flat
                                // purple rather than a purple gradient.
                                .fill(Color.purple)
                                .frame(width: 30, height: 30)
                                .huskOverlay {
                                    Image(systemName: "macwindow.on.rectangle")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.white)
                                }
                        }
                    }
                } header: {
                    Text("Multitasking")
                } footer: {
                    Text("Apps and games open in a window you can move, resize and minimise to a dock, like LiveContainer's multitasking. "
                       + "Each app can override this in its own settings.")
                }

                Section {
                    Toggle(isOn: $askCompat) {
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Ask How Games Ran")
                                // .foregroundStyle is iOS 15, and cannot be shimmed:
                                // ShapeStyle and HierarchicalShapeStyle are too. This
                                // is the spelling the rest of the tree uses.
                                Text("After playing, once per game per update").font(.caption).foregroundColor(.secondary).lineLimit(1)
                            }
                        } icon: {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(LinearGradient(colors: [Color.green], startPoint: .top, endPoint: .bottom))
                                .frame(width: 30, height: 30)
                                .huskOverlay {
                                    Image(systemName: "list.bullet.clipboard")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.white)
                                }
                        }
                    }
                    Link(destination: CompatibilityStore.site) {
                        Label("Compatibility List", systemImage: "safari")
                    }
                } header: {
                    Text("Compatibility")
                } footer: {
                    Text("Game pages and the Store show how each app runs for everyone, from antiweb.lol. Your reports go there "
                       + "with your device, iOS version, Husk build and JIT method.")
                }

                // .indigo is iOS 15 as a Color; Color(.systemIndigo) is the
                // equivalent, and is what this row had before.
                Section(header: Text("Emulator")) {
                    }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Settings")
        }
    }

    private var appCard: some View {
        HStack(spacing: 14) {
            HuskMark(size: 56)
            VStack(alignment: .leading, spacing: 2) {
                Text("Husk").font(.title3.weight(.semibold))
                Text("Version \(Bundle.main.version) · \(Bundle.main.commit)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func row<D: View>(_ destination: D, _ icon: String, _ tint: Color,
                              _ title: String, _ subtitle: String) -> some View {
        NavigationLink { destination } label: {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            } icon: {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    // `Color.gradient` is iOS 16; below it the fill is the flat colour.
                .fill(tint)
                    .frame(width: 30, height: 30)
                    .huskOverlay {
                        Image(systemName: icon)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.white)
                    }
            }
        }
    }
}

/// A Form, as the system draws one.
private struct HuskForm: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationBarTitleDisplayMode(.inline)
    }
}

extension View {
    func huskForm() -> some View { modifier(HuskForm()) }
}

// MARK: - Input

struct JITSettings: View {
    @ObservedObject private var jit = JITCoordinator.shared
    @AppStorage(JITCoordinator.autoEnableKey) private var autoJIT = false
    @State private var keepAttached = JITBootstrap.keepDebuggerAttached

    private var pairingLabel: String {
        switch jit.pairingSource {
        case .onDevice: return "paired on this device"
        case .imported: return "file imported"
        case nil: return "not set up"
        }
    }

    var body: some View {
        Form {
            jitCardSection
            methodSection
            jitSection
            autoJITSection
                    keepAttachedSection
            sideloadingSection
        }
        .huskForm()
        .navigationTitle("JIT & sideload")
    }

    private var jitCardSection: some View {
        Section {
            JITCard()
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    private var methodSection: some View {
        Section {
            Picker("Method", selection: $jit.method) {
                ForEach(JITMethod.allCases) { Text($0.title).tag($0) }
            }
            DetailRow(label: "StikDebug",
                      value: JITBootstrap.isStikDebugInstalled ? "installed" : "not found", mono: false)
            DetailRow(label: "TrollStore",
                      value: JITBootstrap.isTrollStoreInstalled ? "installed" : "not found", mono: false)
            DetailRow(label: "Installed with TrollStore",
                      value: JITBootstrap.isInstalledWithTrollStore ? "yes" : "no", mono: false)
            DetailRow(label: "Jailbreak",
                      value: JITBootstrap.debuggedAtLaunch ? "JIT allowed for apps"
                           : JITBootstrap.isJailbroken ? "found" : "not found", mono: false)
            DetailRow(label: "Built-in pairing", value: pairingLabel, mono: false)
            Button {
                jit.showSetup = true
            } label: {
                Label("Set up JIT", systemImage: "wand.and.stars")
            }
        } header: {
            Text("Other Ways to Turn On JIT")
        } footer: {
            Text(jit.method == .automatic
                 ? jit.automaticDescription + " Built-in StikJIT needs iOS 26, LocalDevVPN, and a "
                   + "pairing file, which Husk can make itself on iOS 27."
                 : HuskBuiltInJIT.unavailableReason ?? "Built-in StikJIT needs LocalDevVPN and a pairing "
                   + "file, which Husk can make itself on iOS 27.")
        }
    }

    private var jitSection: some View {
        Section {
            DetailRow(label: "Debugger",
                      value: JITBootstrap.isDebuggerAttached ? "attached" : "not attached",
                      mono: false)
            DetailRow(label: "Executable memory",
                      value: JITBootstrap.isLive ? "granted" : "not claimed", mono: false)
            // The two routes, named separately. Either one is enough, and
            // when someone reports "JIT does not work" these two rows are
            // the whole diagnosis.
            // A nested ternary is the other shape that blows the solver up.
            let trapServicer: String = husk_ios_jit_self_route() != nil ? "not needed"
                : JITBootstrap.prewarmed ? "answering" : "not answering"
            DetailRow(label: "Trap servicer", value: trapServicer, mono: false)
            if let route = husk_ios_jit_self_route() {
                DetailRow(label: "Made by Husk",
                          value: String(cString: route) == "MAP_JIT" ? "MAP_JIT (TrollStore entitlement)" : "plain memory (debugged or jailbroken)",
                          mono: false)
            }
            // Cached answer only: running the probe from a view body
            // could freeze the app (see JITBootstrap.mapJITWorks).
            let mapJIT: String = JITBootstrap.deviceEnforcesTXM ? "not used (TXM)"
                : JITBootstrap.mapJITResult.map { $0 ? "executes" : "refused" }
                  ?? "not tested"
            DetailRow(label: "MAP_JIT", value: mapJIT, mono: false)
            DetailRow(label: "Debugger after setup",
                      value: JITBootstrap.detached ? "detached" : "attached",
                      mono: false)
            if let why = JITBootstrap.lastFailure {
                Text(why).font(.caption).foregroundColor(.orange)
            }
            if !JITBootstrap.ready {
                Button {
                    jit.enable()
                } label: {
                    Label("Enable JIT with \(jit.resolvedMethod.title)", systemImage: "bolt.fill")
                }
                .disabled(jit.busy)
                Button {
                    _ = JITBootstrap.requestTrollStoreAttach()
                } label: {
                    Label("Enable JIT with TrollStore", systemImage: "sparkles")
                }
            }
        } header: {
            Text("JIT")
        } footer: {
            let text: String = "Husk needs memory it can write and then execute, which on iOS "
                + "takes an attached debugger. There are two ways to get it: a "
                + "debugger that services trap requests, or a MAP_JIT mapping, "
                + "which the kernel allows any debugged process. Either one is "
                + "enough — which is available depends on the device and the iOS "
                + "version, so Husk tests both rather than assuming."
            Text(text)
        }
    }

    private var autoJITSection: some View {
        Section {
            Toggle("Turn On JIT at Launch", isOn: $autoJIT)
                .disabled(!HuskBuiltInJIT.isAvailable)
        } footer: {
            Text(HuskBuiltInJIT.isAvailable
                 ? "Each time Husk opens without JIT, it asks the built-in StikJIT to turn it on, so games are ready "
                   + "without a tap. Needs StikJIT set up once (paired) first."
                 : "Needs the built-in StikJIT, which is available on iOS 26 and later.")
        }
    }

    private var keepAttachedSection: some View {
        Section {
            Toggle("Keep debugger attached", isOn: $keepAttached)
                .onChange(of: keepAttached) { v in JITBootstrap.keepDebuggerAttached = v }
        } footer: {
            Text("Off by default. Husk detaches StikDebug as soon as the "
               + "JIT region is held, because a debugger that iOS has suspended "
               + "stops the whole app the next time it is needed. Turn this on "
               + "only to collect StikDebug's own logs.")
        }
    }

    private var sideloadingSection: some View {
        Section {
            Text("APKs install from the Library's + button or from the Files tab. "
               + "Split sets — a base APK plus its config pieces — must be picked "
               + "together; installing the base alone fails on missing native "
               + "libraries.")
                .font(.footnote).foregroundColor(.secondary)
        } header: {
            Text("Sideloading")
        }
    }

}

// MARK: - Saved machine

struct AppearanceSettings: View {
    @State private var appIcon = HuskAppIcon.current
    @AppStorage(Theme.Appearance.key) private var appearance = Theme.Appearance.system
    @AppStorage(Holiday.key) private var holiday = true
    @ObservedObject private var theme = AppTheme.shared
    @Environment(\.colorScheme) private var scheme
    @State private var custom: Color = AppTheme.shared.accentColor

    private let iconColumns = [GridItem(.adaptive(minimum: 92), spacing: 14)]

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Theme.Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { v in
                    HuskLog.log("ui", "appearance: \(v.rawValue)")
                }
                Toggle("Holiday Decorations", isOn: $holiday)
            } header: {
                Text("Theme")
            } footer: {
                Text("System follows the phone: light by day, dark by night. The guest's own "
                   + "screen stays dark either way — it is a picture of another phone.")
            }

            Section {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 14) {
                    ForEach(AppTheme.presets) { preset in
                        Button {
                            theme.accentColor = preset.color
                            custom = preset.color
                        } label: {
                            swatch(preset.color, selected: preset.color.themeHex == theme.accentColor.themeHex)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset.name)
                    }
                }
                .padding(.vertical, 6)

                ColorPicker("Custom Colour", selection: $custom, supportsOpacity: false)
                    .onChange(of: custom) { theme.accentColor = $0 }
            } header: {
                Text("Accent Colour")
            } footer: {
                Text("Tints buttons, switches and selected states throughout the app.")
            }

            Section {
                LazyVGrid(columns: iconColumns, spacing: 14) {
                    ForEach(HuskAppIcon.allCases) { icon in
                        Button {
                            appIcon = icon
                            HuskAppIcon.apply(icon)
                        } label: {
                            VStack(spacing: 8) {
                                if let art = icon.preview(dark: scheme == .dark) {
                                    Image(uiImage: art)
                                        .resizable().scaledToFit()
                                        .frame(width: 60, height: 60)
                                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .strokeBorder(appIcon == icon ? Color.accentColor : .clear, lineWidth: 3))
                                }
                                Text(icon.title)
                                    .font(.caption)
                                    .foregroundColor(appIcon == icon ? Color.accentColor : .primary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 6)
            } header: {
                Text("App Icon")
            } footer: {
                Text("Automatic follows the system appearance — light, dark and tinted. The others pin "
                   + "one look. iOS shows its own confirmation after a change; that alert cannot be turned off.")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func swatch(_ color: Color, selected: Bool) -> some View {
        Circle()
            .fill(color)
            .frame(width: 34, height: 34)
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.9), lineWidth: selected ? 2 : 0).padding(-4))
            .huskOverlay {
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(color.isLight ? .black : .white)
                }
            }
            .frame(maxWidth: .infinity)
    }
}

// MARK: - About

struct AboutSettings: View {
    @State private var showLogs = false
    @AppStorage(TranslationLayer.devInfoKey) private var devInfo = false

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    HuskMark(size: 84)
                    Text("Husk").font(.title2.weight(.semibold))
                    Text("Version \(Bundle.main.version)")
                        .font(.subheadline).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .listRowBackground(Color.clear)
            }

            Section {
                HuskLabeledContent("Build", value: Bundle.main.commit)
            }

            Section {
                Toggle(isOn: $devInfo) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Developer Info")
                        Text("Technical detail in the Android Translation Layer screens: "
                           + "library reports, device checks and run logs.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
                if devInfo {
                    NavigationLink { TLChecksView() } label: {
                        Label("Device Checks", systemImage: "stethoscope")
                    }
                    NavigationLink { MassTestView() } label: {
                        Label("Mass Test", systemImage: "square.stack.3d.down.forward")
                    }
                }
                Button { showLogs = true } label: {
                    Label("Open Console", systemImage: "terminal")
                }
            } footer: {
                Text("Husk runs unmodified Android APKs in a real Android system on your iPhone. "
                   + "The console shows Husk's live log, the guest's serial output and QEMU's own "
                   + "output — the three files any problem here is diagnosed from.")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLogs) { LogView() }
    }
}

extension Bundle {
    var version: String {
        (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }
    var commit: String {
        (infoDictionary?["HuskBuildCommit"] as? String) ?? "?"
    }
}
