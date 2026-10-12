// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

// MARK: - one library

/// Anything Husk can open: a game, run on the translation layer.
///
/// The person never has to know which way something runs -- Husk does -- so the launcher sorts by what a thing is (a game,
/// an app), not by how it is run.
enum LibraryItem: Identifiable, Hashable {
    case game(TLApp)

    var id: String {
        switch self {
        case .game(let g): return "tl:" + g.id
        }
    }

    static func == (a: LibraryItem, b: LibraryItem) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var title: String {
        switch self {
        case .game(let g): return g.label
        }
    }

    var iconPath: String? {
        switch self {
        case .game(let g): return g.iconPath
        }
    }

    /// Games on the translation layer (a Flutter app is an app unless it calls itself a game), and what Android itself files as a game.
    var isGame: Bool {
        switch self {
        case .game(let g): return (g.report?.nativeEngine != .flutter && g.report?.engine != "Flutter" && g.report?.webKind == nil) || g.isGameCategory
        }
    }

    var packageName: String? {
        switch self {
        case .game(let g): return g.packageName
        }
    }

    /// A gameplay picture, for apps that have been run on an iPhone (fetched from GitHub; see ShowcaseStore).
    @MainActor var artworkPath: String? { ShowcaseStore.shared.pictures(for: packageName).first }

    var runsInAndroid: Bool {
        return false
    }

    var lastUsed: Date? {
        switch self {
        case .game(let g): return g.lastPlayed
        }
    }

    var route: LibraryRoute {
        switch self {
        case .game(let g): return .game(g.id)
        }
    }

    /// "Played 2 hours ago", or nothing for what was never opened from Husk.
    var usedText: String? {
        guard let date = lastUsed else { return nil }
        let rel = RelativeDateTimeFormatter()
        rel.unitsStyle = .full
        let ago = date.timeIntervalSinceNow > -60 ? "just now" : rel.localizedString(for: date, relativeTo: Date())
        return (isGame ? "Played " : "Opened ") + ago
    }
}

/// Which items a library page shows.
enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, games, apps
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All"
        case .games: return "Games"
        case .apps: return "Apps"
        }
    }
}

/// Everything, from both stores, in one list.
@MainActor
enum Launcher {
    /// Every game Husk can run: the translation layer's apps. It was the union
    /// of these and the guest's packages, and the guest is gone.
    static func items(store: TranslationLayerStore) -> [LibraryItem] {
        store.apps.map(LibraryItem.game)
    }

    /// Most recently used first; never-used ones after, by name.
    static func byRecent(_ items: [LibraryItem]) -> [LibraryItem] {
        items.sorted { a, b in
            switch (a.lastUsed, b.lastUsed) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
    }

    static var jitOn: Bool { JITBootstrap.ready }
}

// MARK: - Home

/// Home as tiles: what you used last, the two things a game needs (JIT and its
/// files), and the rest of the library.
struct HomeView: View {
    @ObservedObject private var router = Router.shared
    @ObservedObject private var store = TranslationLayerStore.shared
    @ObservedObject private var jit = JITCoordinator.shared
    @ObservedObject private var incoming = IncomingFiles.shared
    @Environment(\.colorScheme) private var scheme
    @huskAppStorage(Holiday.key) private var holiday = true

    /// Everything, most recent first.
    private var all: [LibraryItem] { Launcher.byRecent(Launcher.items(store: store)) }

    var body: some View {
        // NavigationStack is iOS 16. Upstream inlines the Home screen inside one;
        // here it lives in homeContent and is handed over as a closure. The tree
        // they add next to the title moved into homeContent below.
        HuskNavStack(path: $router.home, backTitle: "Husk",
                     root: { homeContent },
                     page: { LibraryRouteView(route: $0) })
    }

    /// The stack's root, lifted out because HuskNavStack takes it as a
    /// closure parameter rather than as a child view.
    private var homeContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    if let icon = HuskAppIcon.current.preview(dark: scheme == .dark) {
                        Image(uiImage: icon)
                            .resizable()
                            .frame(width: 34, height: 34)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    Text("Husk")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                    if holiday { ChristmasTree(size: 30).padding(.leading, 2) }
                    Spacer()
                    HeaderButton(systemImage: "plus") { router.addSomething() }
                        .accessibility(label: "Add a Game or App")
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 6)

                if let busy = incoming.preparing { BusyStrip(text: busy) }
                if let busy = store.busy { BusyStrip(text: busy) }
        
                let items = all
                let lead = items.first { $0.lastUsed != nil } ?? items.first
                VStack(spacing: 12) {
                    if let lead { LeadTile(item: lead) } else { WelcomeCard() }
                    HStack(spacing: 12) {
                        JITTile()
                        DownloadsTile()
                    }
                        }
                if let error = jit.error, !Launcher.jitOn {
                    Text(error).font(.caption).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }

                let rest = items.filter { $0 != lead }
                if !rest.isEmpty {
                    ShelfHeader(title: "Library") { router.showLibrary(.all) }
                        .padding(.horizontal, 4)
                        .padding(.top, 6)
                    huskLazyVGrid(count: 4, spacing: 10) {
                        ForEach(rest.prefix(UIDevice.current.userInterfaceIdiom == .pad ? 16 : 8)) { item in
                            NavigationLink(destination: libraryDestination(item.route)) { LibrarySquare(item: item) }
                                .buttonStyle(CardButtonStyle())
                                .accessibility(label: item.title)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .id(jit.attachGeneration)
        }
        .background(Color(.systemBackground).huskIgnoresSafeArea())
        .navigationBarHidden(true)
    }
}

/// The surface every Home tile sits on.
private struct Tile<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .huskBackground(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

/// A tile's glyph: a small rounded square in the tile's own colour.
private struct TileGlyph: View {
    let systemImage: String
    let color: Color
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.48, weight: .bold))
            .foregroundColor(color)
            .frame(width: size, height: size)
            .huskBackground(color.opacity(0.16), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

/// The thing you used last: its picture, its name, and Play.
private struct LeadTile: View {
    let item: LibraryItem
    @ObservedObject private var router = Router.shared

    var body: some View {
        VStack(spacing: 0) {
            NavigationLink(destination: libraryDestination(item.route)) {
                ItemBackdrop(item: item)
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 12) {
                NavigationLink(destination: libraryDestination(item.route)) {
                    HStack(spacing: 12) {
                        ItemIcon(item: item, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.headline)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                            Text(item.usedText ?? (item.isGame ? "Ready to play" : "Ready to open"))
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Button(action: play) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 46, height: 46)
                        .huskBackground(Color.accentColor, in: Circle())
                }
                .buttonStyle(CardButtonStyle())
                .accessibility(label: (item.isGame ? "Play " : "Open ") + item.title)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    /// Games start as soon as their page is up; anything else just opens its page.
    private func play() {
        if case .game(let g) = item { router.autoPlay = g.id }
        router.home.append(item.route)
    }
}

/// Whether JIT is on, and the way to turn it on when it is not.
private struct JITTile: View {
    @ObservedObject private var jit = JITCoordinator.shared

    private var isOn: Bool { Launcher.jitOn }
    private var via: String {
        let m = jit.resolvedMethod
        return m == .builtIn ? "StikJIT" : m.title
    }

    var body: some View {
        Button(action: tap) {
            Tile {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        TileGlyph(systemImage: "bolt.fill", color: isOn ? .green : .orange)
                        Spacer()
                        if jit.busy { huskProgress() }
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isOn ? "JIT on" : "JIT off").font(.headline).foregroundColor(.primary)
                        Text(isOn ? "via \(via)" : jit.busy ? (jit.status ?? "Turning on…") : "Tap to turn on")
                            .font(.footnote).foregroundColor(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(CardButtonStyle())
        .disabled(jit.busy)
    }

    private func tap() {
        if isOn { jit.showSetup = true; return }
        if HuskBuiltInJIT.isAvailable, jit.resolvedMethod == .builtIn { jit.method = .builtIn }
        jit.enable()
    }
}

/// Downloads at a glance: what is coming in, or that Husk is current.
private struct DownloadsTile: View {
    @ObservedObject private var downloads = Downloads.shared
    @ObservedObject private var updates = AppUpdates.shared
    @ObservedObject private var router = Router.shared

    private var status: String {
        let running = downloads.jobs.filter { !$0.complete && !$0.paused && !$0.failed }
        if !running.isEmpty {
            let total = running.reduce(Int64(0)) { $0 + $1.total }
            let got = running.reduce(Int64(0)) { $0 + $1.received }
            let pct = total > 0 ? " · \(Int(Double(got) / Double(total) * 100))%" : ""
            return "\(running.count) downloading\(pct)"
        }
        if downloads.jobs.contains(where: \.failed) { return "Something failed" }
        if let release = updates.available { return "Husk \(release.version) is out" }
        return "Up to date"
    }

    var body: some View {
        Button { router.showDownloads = true } label: {
            Tile {
                VStack(alignment: .leading, spacing: 18) {
                    TileGlyph(systemImage: "arrow.down", color: Color(.systemIndigo))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Downloads").font(.headline).foregroundColor(.primary)
                        Text(status).font(.footnote).foregroundColor(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .buttonStyle(CardButtonStyle())
    }
}

/// Android itself, for what the translation layer cannot run yet.
private struct LibrarySquare: View {
    let item: LibraryItem

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .huskOverlay {
                GeometryReader { geo in ItemIcon(item: item, size: geo.size.width) }
            }
            .huskOverlay(alignment: .topTrailing) { if item.runsInAndroid { AndroidBadge().padding(5) } }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// The first time: nothing added yet, and the two ways to start.
private struct WelcomeCard: View {
    @ObservedObject private var router = Router.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(Color.accentColor)
                .frame(width: 60, height: 60)
                .huskBackground(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text("Add your first game")
                    .font(.system(.title, design: .rounded).weight(.bold))
                Text("Pick an APK or a bundle (.xapk, .apkm, .apks), or share one to Husk from Files or Safari. Games run "
                   + "straight on your iPhone. Other apps run inside Android.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button { router.addSomething() } label: {
                Text("Add a Game or App").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
        }
        .padding(20)
        .huskBackground(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct ShelfHeader: View {
    let title: String
    let seeAll: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.system(.headline, design: .rounded).weight(.bold))
            Spacer()
            Button("See All", action: seeAll).font(.subheadline.weight(.semibold))
        }
        .padding(.bottom, -10)
    }
}

// MARK: - artwork

/// A picture to stand in for artwork, made from the icon: the icon itself, enlarged and blurred to fill the space,
/// under a dark fade so text on it reads. Android icons are all most apps carry, and this is what makes them big.
struct IconBackdrop: View {
    let path: String?
    var fallback: Color = Color(.secondarySystemBackground)

    var body: some View {
        ZStack {
            fallback
            if path != nil {
                AppIcon(path: path, size: 120)
                    .scaleEffect(3.2)
                    .blur(radius: 28)
                    .saturation(1.3)
                    .opacity(0.9)
            }
        }
        .clipped()
        // Scaled up, the icon reaches far past the card; clipping hides that but does not stop it taking touches, and a
        // tap on one cover used to land on its neighbour's backdrop.
        .allowsHitTesting(false)
    }
}

/// What sits behind an item's name: its gameplay picture when Husk ships one, its blurred icon otherwise.
struct ItemBackdrop: View {
    let item: LibraryItem
    var pixels: Int = 1200
    var fallback: Color = Color(.secondarySystemBackground)
    @ObservedObject private var showcase = ShowcaseStore.shared

    var body: some View {
        Group {
            if let art = item.artworkPath {
                Color.clear.huskOverlay { PictureView(path: art, pixels: pixels) }.clipped()
            } else {
                IconBackdrop(path: item.iconPath, fallback: fallback)
            }
        }
        .allowsHitTesting(false)
    }
}

/// An item's icon: the app's own, or Android's mark for Android itself.
struct ItemIcon: View {
    let item: LibraryItem
    let size: CGFloat

    var body: some View {
        if false {
            EmptyView()
        } else {
            AppIcon(path: item.iconPath, size: size)
                .huskOverlay {
                    RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
                }
        }
    }
}

/// Android itself, as an icon.
struct AndroidMark: View {
    static let green = Color(red: 0.24, green: 0.86, blue: 0.52)
    var size: CGFloat = 64

    var body: some View {
        Image(systemName: "apps.iphone")
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .huskBackground(Self.green, in: RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
    }
}

/// "Opens inside Android".
struct AndroidBadge: View {
    var body: some View {
        Text("ANDROID")
            .font(.system(size: 8, weight: .heavy, design: .rounded))
            .tracking(0.4)
            .foregroundColor(Color(red: 0.03, green: 0.13, blue: 0.06))
            .padding(.horizontal, 5).padding(.vertical, 2)
            .huskBackground(AndroidMark.green, in: Capsule())
    }
}

// MARK: - Library

/// Every game and app, in one grid: search, and All / Games / Apps.
struct LibraryScreen: View {
    @ObservedObject private var router = Router.shared
    @ObservedObject private var store = TranslationLayerStore.shared
    @State private var query = ""

    var body: some View {
        HuskNavStack(path: $router.library, backTitle: "Library",
                     root: { libraryContent },
                     page: { LibraryRouteView(route: $0) })
    }

    /// The stack's root, lifted out because HuskNavStack takes it as a
    /// closure parameter rather than as a child view.
    private var libraryContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Library")
                        .font(.system(size: 28, weight: .heavy, design: .rounded))
                    Spacer()
                    HeaderButton(systemImage: "plus") { router.addSomething() }
                        .accessibility(label: "Add a Game or App")
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 6)
                SearchField(text: $query, prompt: "Search games and apps")
                Picker("Show", selection: $router.libraryFilter) {
                    ForEach(LibraryFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if let busy = store.busy { BusyStrip(text: busy) }
        
                let items = Launcher.items(store: store)
                    .filter { matches(query, $0.title) }
                    .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
                let games = items.filter(\.isGame)
                let apps = items.filter { !$0.isGame }

                if router.libraryFilter != .apps {
                    section("Games", games, empty: query.isEmpty ? "Add a game with the + button." : nil)
                }
                if router.libraryFilter != .games {
                    section("Apps", apps, empty: nil)
                }
                if !query.isEmpty, games.isEmpty, apps.isEmpty { NoResults(query: query) }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .background(Color(.systemBackground).huskIgnoresSafeArea())
        .navigationBarHidden(true)
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [LibraryItem], empty: String?) -> some View {
        if !items.isEmpty || empty != nil {
            Tile {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title).font(.headline)
                        Text("\(items.count)").font(.subheadline).foregroundColor(.secondary)
                    }
                    if items.isEmpty, let empty {
                        Text(empty).font(.subheadline).foregroundColor(.secondary)
                    } else {
                        huskLazyVGrid(count: UIDevice.current.userInterfaceIdiom == .pad ? 8 : 4, spacing: 18) {
                            ForEach(items) { item in
                                NavigationLink(destination: libraryDestination(item.route)) {
                                    LauncherTile(title: item.title, iconPath: item.iconPath, item: item, caption: caption(item), size: 60)
                                }
                                .buttonStyle(CardButtonStyle())
                            }
                        }
                    }
                }
            }
        }
    }

    private func caption(_ item: LibraryItem) -> String? {
        switch item {
        case .game(let g):
            if g.packageName == GeodeSupport.launcherPackage { return "Geode" }
            return g.report?.canRun == true ? nil : "May not run"
        }
    }
}

// MARK: - shared pieces

/// One app in a grid, as a home screen draws it: the icon, and its name under it.
struct LauncherTile: View {
    let title: String
    let iconPath: String?
    var item: LibraryItem? = nil
    var caption: String? = nil
    var size: CGFloat = 64
    @ObservedObject private var statuses = GameStatusStore.shared

    /// How the game did last time it was played, when Husk has seen it played.
    private var result: GameStatusStore.Result? {
        guard case .game(let g)? = item else { return nil }
        return statuses.status(g.id)?.result
    }

    var body: some View {
        VStack(spacing: 7) {
            Group {
                Group { if let item { ItemIcon(item: item, size: size) } else { AppIcon(path: iconPath, size: size) } }.snowCap(height: 7)
            }
            .shadow(color: .black.opacity(0.14), radius: 6, y: 3)
            .huskOverlay(alignment: .bottom) {
                if item?.runsInAndroid == true { AndroidBadge().offset(y: 6) }
            }
            .huskOverlay(alignment: .topTrailing) {
                if let result { GameStatusBadge(result: result).offset(x: 5, y: -5) }
            }
            VStack(spacing: 1) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let caption {
                    Text(caption).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            }
            .padding(.top, item?.runsInAndroid == true ? 3 : 0)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }
}

/// A round glyph button in a screen's header.
struct HeaderButton: View {
    let systemImage: String
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(enabled ? Color.accentColor : Color.secondary)
                .frame(width: 38, height: 38)
                .huskBackground(Color(.tertiarySystemFill), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Work under way, said in one line.
struct BusyStrip: View {
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            huskProgress()
            Text(text).font(.subheadline).lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(14)
        .huskBackground(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// A search field as the system draws one.
///
/// Four iOS 15 modifiers are gone: `.focused`, `.submitLabel`,
/// `.autocorrectionDisabled` and `.textInputAutocapitalization`. The first is
/// the one that costs something. iOS 14 has no way to ask a SwiftUI TextField
/// whether it has focus, so there is nothing to drive the Cancel button that
/// slid in on focus -- it is dropped rather than faked, because a button that
/// never appears is worse than no button. The clear button inside the field
/// covers the same need: it empties the search and is visible whenever there is
/// anything to clear.
struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.secondary)
                TextField(prompt, text: $text)
                if !text.isEmpty {
                    Button { text = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(Color(.tertiaryLabel))
                    }
                    .buttonStyle(.plain)
                    .accessibility(label: "Clear")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .huskBackground(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }
}

/// Nothing matches the search.
struct NoResults: View {
    let query: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 28, weight: .light)).foregroundColor(.secondary)
            Text("No Results").font(.headline)
            Text("Nothing here is called “\(query)”.").font(.subheadline).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

/// Whether a name matches what was searched for.
func matches(_ query: String, _ names: String...) -> Bool {
    let q = query.trimmingCharacters(in: .whitespaces)
    return q.isEmpty || names.contains { $0.localizedCaseInsensitiveContains(q) }
}

    /// This was a `.navigationDestination(for: LibraryRoute.self)` modifier,
    /// which is iOS 16 and only resolves on a path-based stack. Call sites now
    /// hand the route straight to `NavigationLink(destination:)`.
    func libraryDestination(_ route: LibraryRoute) -> some View {
        LibraryRouteView(route: route).navigationBarHidden(false)
    }

private struct LibraryRouteView: View {
    let route: LibraryRoute
    @ObservedObject private var store = TranslationLayerStore.shared

    var body: some View {
        switch route {
        case .game(let id):
            if let app = store.apps.first(where: { $0.id == id }) { GamePage(app: app) } else { GoneView() }
        case .gameSettings(let id):
            if let app = store.apps.first(where: { $0.id == id }) { TLAppSettingsView(app: app) } else { GoneView() }
        case .gameReport(let id):
            if let app = store.apps.first(where: { $0.id == id }) { TLTechnicalView(app: app) } else { GoneView() }
        }
    }
}

private struct GoneView: View {
    var body: some View {
        Text("This was removed.").foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
