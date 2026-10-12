// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// Apps from the repositories you add, installed into the translation layer. Pushed from Settings, so it has no navigation
/// stack of its own.
struct DiscoverView: View {
    @ObservedObject private var manager = SourceManager.shared
    @ObservedObject private var store = TranslationLayerStore.shared
    @ObservedObject private var router = Router.shared

    @State private var showingSources = false
    @State private var showingAddSource = false
    @State private var newSourceURL = ""
    @State private var searchText = ""
    @State private var debouncedSearchText = ""

    var body: some View {
        Group {
            if manager.isLoading && manager.sources.isEmpty {
                huskProgress("Fetching Repositories…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if manager.sources.isEmpty {
                EmptyState(title: "No Repositories",
                           message: "Add a source to start discovering apps.",
                           systemImage: "tray",
                           actionTitle: "Add Source",
                           action: { showingAddSource = true })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        // .searchable is iOS 15. Placed before the navigation modifiers, not
        // after: chained after .navigationTitle it would wrap the title inside
        // the VStack instead of sitting above the content.
        .huskSearchBar(text: $searchText, prompt: "Search \(totalAppCount) apps")
        .background(Theme.backdrop)
        .navigationTitle("Discover")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { Task { await manager.fetchSources() } } label: {
                    huskLabel("Refresh", systemImage: "arrow.clockwise")
                }
                Menu {
                    Button { showingAddSource = true } label: {
                        huskLabel("Add Source", systemImage: "plus")
                    }
                    Button { showingSources = true } label: {
                        huskLabel("Manage Repositories", systemImage: "list.bullet")
                    }
                } label: { huskLabel("Repositories", systemImage: "ellipsis.circle") }
            }
        }
        .sheet(isPresented: $showingSources) { sourcesSheet }
        .sheet(isPresented: $showingAddSource) { addSourceSheet }
        .onAppear {
            if manager.sources.isEmpty && !manager.isLoading {
                Task { await manager.fetchSources() }
            }
        }
        // .task(id:) is iOS 15. The debounce survives, but Task.sleep is no
        // longer cancelled between keystrokes, so the box updates a fixed
        // 200ms after the last one rather than as soon as typing stops.
        .onAppear { debounceSearch() }
        .huskOnChange(of: searchText) { _ in debounceSearch() }
    }

    private func debounceSearch() {
        Task {
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
                debouncedSearchText = searchText
            } catch {}
        }
    }

    private var list: some View {
        huskList {
            ForEach(manager.sources) { source in
                let filtered = filteredApps(for: source)
                if !filtered.isEmpty {
                    sourceSection(source, apps: filtered)
                }
            }
            if !manager.fetchErrors.isEmpty {
                huskSection {
                    ForEach(manager.fetchErrors.keys.sorted(), id: \.self) { url in
                        huskLabel {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(url).font(.footnote).lineLimit(1)
                                Text(manager.fetchErrors[url] ?? "").font(.caption).foregroundColor(.secondary)
                            }
                        } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange) }
                    }
                } header: { Text("Could Not Load") }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var totalAppCount: Int {
        manager.sources.reduce(0) { $0 + $1.apps.count }
    }

    // MARK: - Helpers

    private func filteredApps(for source: AppSource) -> [SourceApp] {
        if debouncedSearchText.isEmpty { return source.apps }
        let query = debouncedSearchText.lowercased()
        return source.apps.filter {
            $0.name.lowercased().contains(query) ||
            $0.bundleIdentifier.lowercased().contains(query)
        }
    }

    private func sourceSection(_ source: AppSource, apps: [SourceApp]) -> some View {
        let displayApps = debouncedSearchText.isEmpty ? Array(apps.prefix(50)) : apps
        return Section {
            ForEach(displayApps) { app in appRow(app) }
        } header: {
            Text(source.name)
        } footer: {
            if debouncedSearchText.isEmpty && apps.count > 50 {
                Text("Search to see \(apps.count - 50) more apps.")
            }
        }
    }

    private func appRow(_ app: SourceApp) -> some View {
        HStack(spacing: 14) {
            HuskAsyncImage(url: URL(string: app.iconURL)) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fit)
                } else if phase.error != nil {
                    Image(systemName: "app.dashed").font(.title).foregroundColor(.secondary)
                } else {
                    huskProgress()
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name).font(.body.weight(.medium)).lineLimit(1)
                Text(app.localizedDescription)
                    .font(.caption).foregroundColor(.secondary).lineLimit(2)
            }

            Spacer(minLength: 8)

            // The translation layer's list, matched on package name. It used to
            // ask the guest, which stopped being true the moment downloadAndInstall
            // stopped installing into it: the app went in, and the row still said
            // Get, so a successful download could be repeated indefinitely.
            let installed = store.apps.first { $0.packageName == app.bundleIdentifier }
            let progress = manager.downloadProgress[app.bundleIdentifier]

            if let installed = installed {
                Button("Open") {
                    router.tab = .library
                    router.library = [.game(installed.id)]
                    router.autoPlay = installed.id
                }
                .huskBordered()
            } else if let progress = progress {
                ZStack {
                    Circle().stroke(Color(.tertiarySystemFill), lineWidth: 3)
                    Circle().trim(from: 0, to: progress)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "stop.fill").font(.system(size: 9)).foregroundColor(.secondary)
                }
                .frame(width: 28, height: 28)
            } else {
                Button("Get") { manager.downloadAndInstall(app: app) }
                    .huskBorderedProminent()
            }
        }
        .huskBorderless()
        .padding(.vertical, 2)
    }

    // MARK: - Add Source Sheet

    private var addSourceSheet: some View {
        NavigationView {
            Form {
                Section {
                    TextField("https://f-droid.org/repo/index-v1.json", text: $newSourceURL)
                        .keyboardType(.URL).autocapitalization(.none).autocorrectionDisabled()
                } header: {
                    Text("Source URL")
                } footer: {
                    Text("Paste any F-Droid-compatible repository index URL.")
                }

                Section(header: Text("Presets")) {
                    ForEach([
                        ("F-Droid", "https://f-droid.org/repo/index-v1.json"),
                        ("IzzyOnDroid", "https://apt.izzysoft.de/fdroid/repo/index-v1.json"),
                        ("Guardian Project", "https://guardianproject.info/fdroid/repo/index-v1.json"),
                    ], id: \.0) { name, url in
                        Button { newSourceURL = url } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(name).foregroundColor(.primary)
                                    Text(url).font(.caption).foregroundColor(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if newSourceURL == url {
                                    Image(systemName: "checkmark").foregroundColor(Color.accentColor)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add Source")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { newSourceURL = ""; showingAddSource = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        let url = newSourceURL
                        newSourceURL = ""
                        showingAddSource = false
                        guard !url.isEmpty, URL(string: url) != nil else { return }
                        Task { await manager.addSource(urlString: url) }
                    }
                    .disabled(newSourceURL.isEmpty)
                    // Both `.bold()` and `View.fontWeight(_:)` are iOS 16, so
                    // neither is usable here. The pre-16 way to make a label
                    // bold is a font with a bold weight; 17pt is what a toolbar
                    // button uses by default, so only the weight changes.
                    .font(.system(size: 17, weight: .semibold))
                }
            }
        }
    }

    // MARK: - Manage Sources Sheet

    private var sourcesSheet: some View {
        NavigationView {
            huskList {
                huskSection {
                    ForEach(manager.sourceURLs, id: \.self) { url in
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                if let source = manager.sources.first(where: { $0.identifier == url }) {
                                    Text(source.name).font(.body.weight(.medium))
                                    Text("\(source.apps.count) apps").font(.caption).foregroundColor(.secondary)
                                }
                                Text(url).font(.caption).foregroundColor(.secondary).lineLimit(1)
                            }
                            // Swipe-to-delete belongs to List and has no
                            // counterpart on 13, so the row carries its own
                            // button. Deleting by value rather than by offset:
                            // remove(atOffsets:) is an extension List provides,
                            // and the index it would want is not knowable from
                            // inside a ForEach body.
                            Button {
                                manager.sourceURLs.removeAll { $0 == url }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 15))
                                    .foregroundColor(.red)
                                    .frame(width: 34, height: 34)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibility(label: Text("Remove \(url)"))
                        }
                        .padding(.vertical, 2)
                    }
                } header: { Text("Active Repositories") }
            }
            .navigationTitle("Repositories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { showingSources = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingSources = false; showingAddSource = true } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
    }
}
