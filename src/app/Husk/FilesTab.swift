// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UniformTypeIdentifiers

/// The guest's storage, browsable.
///
/// Husk could already push a file into Android's Download folder and never show
/// you what happened to it, which is a one-way street: you cannot check a game
/// found its data pack, or get a screenshot back, or see why an install failed
/// on a file that is not where you think it is. Everything here is `stat` and
/// `find` over the same bridge the rest of the app uses — no agent, no adb.
struct FilesTab: View {
    static let root = "/sdcard"

    @ObservedObject private var host = AndroidHost.shared
    @ObservedObject private var router = Router.shared
    @Environment(\.presentationMode) private var huskPM

    var body: some View {
        // `router.files` is the path itself, so "Open in Files" from an app's
        // page lands in that app's folder on the very first frame: the router
        // writes it before the sheet is presented.
        HuskNavStack(path: $router.files, backTitle: "Files",
                     root: { directory(at: Self.root) },
                     page: { path in directory(at: path) })
    }

    /// iOS 15's `NavigationView` has no path, so the directory in front is a
    /// page rather than a push: `DirectoryView` reports the tap back out here,
    /// which writes the path the stack is reading.
    private func directory(at path: String) -> some View {
        DirectoryView(path: path,
                      title: path == Self.root ? "Files" : (path as NSString).lastPathComponent,
                      onOpen: { router.files = [$0] })
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { huskPM.wrappedValue.dismiss() } }
            }
    }
}

/// One directory.
struct DirectoryView: View {
    let path: String
    let title: String
    /// The directory that was tapped. There is no `NavigationLink(value:)` to
    /// push from -- that is iOS 16 -- so the row reports out and `FilesTab`
    /// swaps the page. Defaults to a no-op so a preview can still be built.
    var onOpen: (String) -> Void = { _ in }

    @ObservedObject private var host = AndroidHost.shared
    @State private var entries: [AndroidHost.GuestEntry] = []
    @State private var space: (free: Int64, total: Int64)?
    @State private var loading = true
    @State private var failure: String?
    @State private var importing = false
    @State private var showImportSheet = false
    @State private var installing: AndroidHost.GuestEntry?

    var body: some View {
        List {
            if let space {
                Section { storage(space) }
            }
            if !entries.isEmpty {
                Section {
                    ForEach(entries, id: \.id) { e in row(e) }
                } footer: {
                    if path != FilesTab.root {
                        Text(path).font(.footnote).lineLimit(1).truncationMode(.head)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .huskOverlay {
            if loading && entries.isEmpty {
                ProgressView()
            } else if let failure {
                EmptyState(title: "Cannot Read This Folder", message: failure, systemImage: "lock")
            } else if entries.isEmpty {
                EmptyState(title: "Empty", message: "Nothing is in this folder yet.",
                           systemImage: "folder", actionTitle: "Import Files",
                           action: { showImportSheet = true })
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(path == FilesTab.root ? .large : .inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { load() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                Button { showImportSheet = true } label: { Label("Import", systemImage: "plus") }
            }
        }
        .sheet(isPresented: $showImportSheet) {
            ImportSheet(destination: path) { showImportSheet = false; importing = true }
                .huskDetent(.height(340))
        }
        .huskFilePicker(isPresented: $importing) { urls in
            host.sendFiles(urls, to: path)
        }
        .confirmationDialog(String("Install \(installing?.name ?? "")?"),
                            isPresented: Binding(get: { installing != nil },
                                                 set: { if !$0 { installing = nil } }),
                            titleVisibility: .visible) {
            Button("Install") {
                if let apk = installing { host.installFromGuest(apk.path, name: apk.name) }
                installing = nil
            }
Button("Cancel") { installing = nil }
        } message: {
            Text("Android installs it from where it already is — nothing is copied.")
        }
        // .task(id:) and .refreshable are both iOS 15. There is no
        // pull-to-refresh before that, so refreshing is manual: the
        // directory reloads when it changes or appears.
        .onAppear { load() }
        .onChange(of: path) { _ in load() }
    }

    @ViewBuilder private func row(_ e: AndroidHost.GuestEntry) -> some View {
        if e.isDirectory {
            Button { onOpen(e.path) } label: {
                HStack {
                    fileLabel(icon: "folder.fill", tint: .accentColor, title: e.name,
                              subtitle: e.modified.map(Self.when))
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(Color(UIColor.tertiaryLabel))
                }
            }
            .foregroundColor(.primary)
        } else {
            Button {
                if e.name.lowercased().hasSuffix(".apk") { installing = e }
            } label: {
                HStack {
                    fileLabel(icon: icon(for: e.name), tint: .secondary, title: e.name, subtitle: subtitle(e))
                    if e.name.lowercased().hasSuffix(".apk") {
                        Spacer()
                        Image(systemName: "arrow.down.circle").foregroundColor(Color.accentColor)
                    }
                }
            }
            .foregroundColor(.primary)
        }
    }

    private func fileLabel(icon: String, tint: Color, title: String, subtitle: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1).truncationMode(.middle)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundColor(.secondary).lineLimit(1)
                }
            }
        }
    }

    private func storage(_ s: (free: Int64, total: Int64)) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Storage")
                Spacer()
                Text("\(AppDetailView.bytes(s.total - s.free)) of \(AppDetailView.bytes(s.total))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            ProgressView(value: Double(used(s)))
        }
        .padding(.vertical, 4)
    }

    private func used(_ s: (free: Int64, total: Int64)) -> CGFloat {
        guard s.total > 0 else { return 0 }
        return min(max(CGFloat(s.total - s.free) / CGFloat(s.total), 0.02), 1)
    }

    private func subtitle(_ e: AndroidHost.GuestEntry) -> String {
        let size = AppDetailView.bytes(e.size)
        guard let m = e.modified else { return size }
        return "\(size) · \(Self.when(m))"
    }

    private func icon(for name: String) -> String {
        let n = name.lowercased()
        if n.hasSuffix(".apk") { return "shippingbox.fill" }
        if n.hasSuffix(".png") || n.hasSuffix(".jpg") || n.hasSuffix(".jpeg")
            || n.hasSuffix(".webp") { return "photo" }
        if n.hasSuffix(".mp4") || n.hasSuffix(".mkv") { return "film" }
        if n.hasSuffix(".mp3") || n.hasSuffix(".ogg") || n.hasSuffix(".wav") {
            return "music.note"
        }
        if n.hasSuffix(".zip") || n.hasSuffix(".obb") { return "archivebox" }
        if n.hasSuffix(".txt") || n.hasSuffix(".log") || n.hasSuffix(".json") {
            return "doc.text"
        }
        return "doc"
    }

    static func when(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = Calendar.current.isDateInToday(d) ? .short : .none
        return f.string(from: d)
    }

    private func load() {
        loading = true
        let where_ = path
        Task.detached {
            var rows: [AndroidHost.GuestEntry] = []
            var why: String?
            do { rows = try AndroidHost.shared.list(where_) }
            catch { why = error.localizedDescription }
            let s = AndroidHost.shared.freeSpace(at: where_)
            // `rows` and `why` are vars; capturing them in the @Sendable body of
            // MainActor.run is the same diagnostic as capturing self. Snapshot them.
            let foundRows = rows, foundWhy = why
            await MainActor.run {
                entries = foundRows
                space = s
                failure = foundRows.isEmpty ? foundWhy : nil
                loading = false
            }
        }
    }
}

/// The import screen: one target, one button.
struct ImportSheet: View {
    let destination: String
    let onBrowse: () -> Void

    @Environment(\.presentationMode) private var huskPM

    var body: some View {
        NavigationView {
            VStack(spacing: 18) {
                VStack(spacing: 10) {
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 34, weight: .light))
                        .foregroundColor(Color.accentColor)
                    Text("Import Files").font(.headline)
                    Text("They go to \((destination as NSString).lastPathComponent). "
                       + "Unmodified APKs install from here too.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .huskCard()

                Button("Browse Files", action: onBrowse)
                    .huskBorderedProminent()
                Spacer(minLength: 0)
            }
            .padding(16)
            .background(Theme.backdrop)
            .navigationTitle("Import")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { huskPM.wrappedValue.dismiss() } }
            }
        }
    }
}
