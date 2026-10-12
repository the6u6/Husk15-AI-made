// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// Google Play Store tab in Husk.
/// Lets users sign in with their Google account, browse/search Play Store, view app details,
/// and download/install apps (triggering the IncomingFiles chooser for translation layer or Android).
struct StoreView: View {
    @ObservedObject private var compat = CompatibilityStore.shared
    @ObservedObject private var manager = PlayStoreManager.shared
    @State private var searchText = ""
    @State private var debouncedSearchText = ""
    @State private var showSignIn = false
    @State private var selectedApp: PlayAPI.PlayApp?

    var body: some View {
        NavigationView {
            Group {
                if !manager.isSignedIn {
                    signedOutState
                } else if manager.isLoading && manager.featuredApps.isEmpty && !manager.isSearching {
                    huskProgress("Connecting to Google Play…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    storeContent
                }
            }
            // .searchable is iOS 15; see DiscoverTab for why this goes above
            // the navigation modifiers rather than below them.
            .huskSearchBar(text: $searchText, prompt: "Search Google Play")
            .background(Theme.backdrop)
            .navigationTitle("Store")
            .navigationBarTitleDisplayMode(.large)
            .navigationBarItems(
                leading: AnyView(EmptyView()),
                trailing: AnyView(
                    Group {
                        if manager.isSignedIn {
                            Menu {
                                if let s = manager.session {
                                    Text(s.isAnonymous ? "Guest Account (Aurora)" : s.email)
                                        .font(.caption)
                                    if s.isAnonymous {
                                        Text(s.email).font(.caption).foregroundColor(.secondary)
                                    }
                                    Divider()
                                }
                                Button(action: {
                                    manager.signOut()
                                }) {
                                    huskLabel("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                                }
                                .foregroundColor(Color.red)
                            } label: {
                                Image(systemName: manager.session?.isAnonymous == true
                                      ? "person.badge.shield.checkmark" : "person.crop.circle")
                                    .font(.system(size: 18))
                            }
                        } else {
                            Menu {
                                Button {
                                    Task { await manager.signInAsGuest() }
                                } label: {
                                    huskLabel("Use Guest Account (Aurora)", systemImage: "person.crop.circle.badge.checkmark")
                                }
                                Button {
                                    showSignIn = true
                                } label: {
                                    huskLabel("Sign In with Google", systemImage: "person.badge.key")
                                }
                            } label: {
                                Text("Sign In")
                                    .font(.subheadline.weight(.semibold))
                            }
                        }
                    }
                )
            )
            .sheet(isPresented: $showSignIn) {
                GoogleSignInSheet()
            }
            .sheet(item: $selectedApp) { app in
                PlayAppDetailSheet(app: app)
            }
            // .task(id:) is iOS 15. The debounce is kept, but Task.sleep's
            // cancellation no longer discards the trailing keystrokes -- the
            // sleep has to finish first, so a fast typist waits it out.
            .onAppear { runSearch() }
            .huskOnChange(of: searchText) { _ in runSearch() }
            .huskDialog(title: "Error", message: manager.errorMessage ?? "",
                        isPresented: Binding(
                            get: { manager.errorMessage != nil },
                            set: { if !$0 { manager.errorMessage = nil } }
                        ),
                        dismiss: "OK") { manager.errorMessage = nil }
        }
    }

    /// The debounced search `.task(id:)` used to run, called explicitly now.
    private func runSearch() {
        Task {
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
                debouncedSearchText = searchText
                if !searchText.isEmpty {
                    await manager.search(query: searchText)
                }
            } catch {}
        }
    }

    // MARK: - Signed Out State

    private var signedOutState: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "cart.fill")
                .font(.system(size: 64))
                .foregroundColor(Color.accentColor)

            VStack(spacing: 8) {
                Text("Google Play Store")
                    .font(.title.weight(.bold))
                    .foregroundColor(Theme.text)

                Text("Browse and download apps using an anonymous Aurora guest account, or sign in with your Google account.")
                    .font(.subheadline)
                    .foregroundColor(Theme.textDim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            if manager.isLoading {
                VStack(spacing: 12) {
                    huskProgress()
                    Text(manager.statusMessage ?? "Signing in…")
                        .font(.footnote)
                        .foregroundColor(Theme.textDim)
                }
                .padding(.top, 12)
            } else {
                VStack(spacing: 12) {
                    // Aurora Guest Button
                    Button {
                        Task {
                            await manager.signInAsGuest()
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "person.crop.circle.badge.checkmark")
                            Text("Use Guest Account")
                        }
                        .font(.headline)
                        .frame(maxWidth: 240)
                        .padding(.vertical, 12)
                    }
                    .huskBorderedProminent()

                    // Google Account Button
                    Button {
                        showSignIn = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "person.badge.key")
                            Text("Sign In with Google")
                        }
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: 240)
                        .padding(.vertical, 10)
                    }
                    .huskBordered()
                }
                .padding(.top, 8)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Store Content

    private var storeContent: some View {
        huskList {
            if !debouncedSearchText.isEmpty {
                huskSection {
                    if manager.isSearching {
                        HStack {
                            Spacer()
                            huskProgress("Searching…")
                            Spacer()
                        }
                        .padding(.vertical, 12)
                    } else if manager.searchResults.isEmpty {
                        Text("No apps found for \"\(debouncedSearchText)\".")
                            .font(.subheadline)
                            .foregroundColor(Theme.textDim)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(manager.searchResults) { app in
                            appRow(app)
                        }
                    }
                } header: {
                    Text("Search Results")
                }
            } else {
                if !manager.featuredApps.isEmpty {
                    huskSection {
                        ForEach(manager.featuredApps) { app in
                            appRow(app)
                        }
                    } header: {
                        Text("Featured Apps")
                    }
                } else {
                    huskSection {
                        Text("No featured apps available. Try searching above.")
                            .font(.subheadline)
                            .foregroundColor(Theme.textDim)
                    }
                }
            }
        }

// .listStyle(.insetGrouped) is iOS 14 and has no counterpart at
// this floor: huskList is a ScrollView of rows, so the rounded
// card the style drew is simply not there. See Compat13.swift.

        // .refreshable is iOS 15 and there is nothing to replace it with; the
        // list loads through runSearch() above instead.
    }

    // MARK: - App Row

    private func appRow(_ app: PlayAPI.PlayApp) -> some View {
        HStack(spacing: 14) {
            Button {
                selectedApp = app
            } label: {
                HStack(spacing: 14) {
                    // App Icon
                    HuskAsyncImage(url: URL(string: app.iconURL ?? "")) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fit)
                        } else if phase.error != nil {
                            Image(systemName: "app.fill")
                                .font(.title)
                                .foregroundColor(Color.accentColor.opacity(0.8))
                        } else {
                            Color(.tertiarySystemFill)
                        }
                    }
                    .frame(width: 52, height: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.title)
                            .font(.body.weight(.semibold))
                            .foregroundColor(Theme.text)
                            .lineLimit(1)

                        Text(app.developer.isEmpty ? app.id : app.developer)
                            .font(.caption)
                            .foregroundColor(Theme.textDim)
                            .lineLimit(1)

                        if let status = compat.entry(app.id)?.status { CompatBadge(status: status) }

                        if app.rating > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(.yellow)
                                Text(String(format: "%.1f", app.rating))
                                    .font(.caption.weight(.medium))
                                    .foregroundColor(Theme.textDim)
                            }
                        }
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer(minLength: 8)

            // Install Button / Progress
            installButton(for: app)
        }
        .padding(.vertical, 4)
    }

    private func installButton(for app: PlayAPI.PlayApp) -> some View {
        let progress = manager.downloadProgress[app.id]
        let isDownloading = manager.installingPackages.contains(app.id)

        return Group {
            if isDownloading || progress != nil {
                ZStack {
                    Circle()
                        .stroke(Color(.tertiarySystemFill), lineWidth: 3)
                    Circle()
                        .trim(from: 0, to: progress ?? 0.05)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    huskProgress()
                        .scaleEffect(0.6)
                }
                .frame(width: 32, height: 32)
            } else {
                Button {
                    manager.downloadAndInstall(app: app)
                } label: {
                    Text(app.isFree ? "GET" : app.formattedPrice)
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
                .huskBorderedProminent()
            }
        }
    }
}

// MARK: - App Detail Sheet

struct PlayAppDetailSheet: View {
    let app: PlayAPI.PlayApp
    @Environment(\.presentationMode) private var huskPM
    // Upstream adds @Environment(\.dismiss) here as well. Nothing in this file
    // calls it -- both dismiss sites go through huskPM -- and it is iOS 15, so on
    // this floor it is a compile error whether it is used or not.
    @ObservedObject private var compat = CompatibilityStore.shared
    @ObservedObject private var manager = PlayStoreManager.shared

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header: Icon, Title, Developer, Get Button
                    HStack(spacing: 16) {
                        HuskAsyncImage(url: URL(string: app.iconURL ?? "")) { phase in
                            if let image = phase.image {
                                image.resizable().aspectRatio(contentMode: .fit)
                            } else {
                                Color(.tertiarySystemFill)
                            }
                        }
                        .frame(width: 76, height: 76)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                        VStack(alignment: .leading, spacing: 4) {
                            Text(app.title)
                                .font(.headline.weight(.bold))
                                .foregroundColor(Theme.text)
                                .lineLimit(2)

                            Text(app.developer)
                                .font(.subheadline)
                                .foregroundColor(Theme.textDim)
                                .lineLimit(1)

                            if let status = compat.entry(app.id)?.status { CompatBadge(status: status) }

                            Spacer(minLength: 4)

                            installAction
                        }
                    }

                    Divider()

                    // Metrics row
                    HStack {
                        metricItem(title: "Rating", value: app.rating > 0 ? String(format: "%.1f ★", app.rating) : "N/A")
                        Spacer()
                        metricItem(title: "Downloads", value: app.downloads.isEmpty ? "—" : app.downloads)
                        Spacer()
                        metricItem(title: "Version", value: app.versionString.isEmpty ? "Current" : app.versionString)
                        if app.sizeBytes > 0 {
                            Spacer()
                            metricItem(title: "Size", value: ByteCountFormatter.string(fromByteCount: app.sizeBytes, countStyle: .file))
                        }
                    }
                    .padding(.horizontal, 8)

                    // Screenshots carousel
                    if !app.screenshotURLs.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Preview")
                                .font(.headline)
                                .foregroundColor(Theme.text)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(app.screenshotURLs, id: \.self) { url in
                                        HuskAsyncImage(url: URL(string: url)) { phase in
                                            if let image = phase.image {
                                                image.resizable().aspectRatio(contentMode: .fit)
                                            } else {
                                                Color(.tertiarySystemFill)
                                            }
                                        }
                                        .frame(height: 220)
                                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                    }
                                }
                            }
                        }
                    }

                    // Description
                    if !app.summary.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("About this app")
                                .font(.headline)
                                .foregroundColor(Theme.text)

                            Text(app.summary)
                                .font(.body)
                                .foregroundColor(Theme.textDim)
                        }
                    }
                }
                .padding(20)
            }
            .background(Theme.backdrop)
            .navigationTitle(app.title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarItems(
                leading: AnyView(
                    Button("Done") { huskPM.wrappedValue.dismiss() }
                )
            )
        }
    }

    private var installAction: some View {
        let progress = manager.downloadProgress[app.id]
        let isDownloading = manager.installingPackages.contains(app.id)

        return Group {
            if isDownloading || progress != nil {
                HStack(spacing: 8) {
                    huskProgress()
                    Text("Downloading…")
                        .font(.caption.weight(.medium))
                        .foregroundColor(Theme.textDim)
                }
            } else {
                Button {
                    manager.downloadAndInstall(app: app)
                    huskPM.wrappedValue.dismiss()
                } label: {
                    Text(app.isFree ? "GET" : app.formattedPrice)
                        .font(.headline)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 6)
                }
                .huskBorderedProminent()
            }
        }
    }

    private func metricItem(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(Theme.text)
            Text(title)
                .font(.caption)
                .foregroundColor(Theme.textDim)
        }
    }
}
