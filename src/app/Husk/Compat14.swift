// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

// The iOS 14 support layer, on top of the iOS 15 one in Compat15.swift.
//
// Compat15.swift stands in for what iOS 16 and 17 added -- path-based
// navigation, LabeledContent, ShareLink, the snappy animations. This file stands
// in for what iOS 15 added, which is a much larger and duller list: mostly
// SwiftUI spelling changes that have an older equivalent.
//
// The replacements are grouped by how faithful they are:
//
//   Exact. huskBackground is the same shape and the same alignment; the older
//   API just spells it as `shape.fill(style)` inside `background(_:)`.
//
//   Approximate. The bordered button styles have no pre-iOS 15 equivalent at
//   all -- iOS 15 introduced them. These approximate with a tint fill and a
//   rounded clip, which is the right shape and roughly the right colour but not
//   the same rendering, and they carry `.buttonStyle(.plain)` because without it
//   iOS 14 draws its own border underneath.
//
//   Removed. controlSize, buttonBorderShape, submitLabel and
//   symbolRenderingMode have no equivalent that is worth writing, so the call
//   sites lost the modifier. That is visible: a control-size hint is gone, a
//   capsule border is square, a keyboard's return key reverts.
//
// One thing to know before reading the diff: `.foregroundColor`, `.accentColor`
// and `.animation(_:)` are all deprecated in the modern SDKs. At a 14.0
// deployment target they are the correct API and are what everything below is
// built on, but building with Xcode 15.4 will print deprecation warnings for
// them. Those warnings are expected and are not something to fix here.

// MARK: - Background (iOS 15.0)

extension View {
    /// `.background(_:in:)`, which is iOS 15.
    ///
    /// The older spelling is `.background(shape.fill(style))`. `AnyView` is
    /// deliberate: `Shape.fill` returns an opaque `some View`, and handing that
    /// straight to `background` leaves the compiler choosing between the
    /// `View` and `ShapeStyle` overloads. Erasing settles it.
    ///
    /// The default alignment is `.center`, which is what the iOS 15 overload
    /// defaults to too.
    func huskBackground<S: ShapeStyle, T: Shape>(_ content: S, in shape: T) -> some View {
        self.background(AnyView(shape.fill(content)))
    }
}

// MARK: - Overlay (iOS 15.0)

extension View {
    /// `.overlay(alignment:content:)`, which is iOS 15.
    ///
    /// iOS 14's `overlay(_:)` has no alignment parameter at all, so this is a
    /// `ZStack` carrying the alignment instead. That is not a general substitute
    /// -- a ZStack sizes to the union of its children where an overlay does not
    /// -- and it is safe here because every call site puts the overlay on a view
    /// that already has a fixed frame or a fixed-size child, so the ZStack comes
    /// out the same size. Badges that hang off an edge still do: an `offset`
    /// takes no part in layout.
    ///
    /// `Alignment` is a struct, not a protocol, so the parameter is concrete.
    /// Writing `<A: Alignment>` -- which is what this said first -- does not
    /// compile at all, and the three call sites failed with "cannot infer
    /// contextual base in reference to member 'topTrailing'" rather than with
    /// anything pointing at the declaration.
    func huskOverlay<C: View>(alignment: Alignment,
                              @ViewBuilder content: () -> C) -> some View {
        ZStack(alignment: alignment) {
            self
            content()
        }
    }

    /// `.overlay { ... }` with no arguments, which is iOS 15.
    ///
    /// Distinct from the aligned overload above, and the reason the first
    /// version of the sweep missed seven of these: only `.overlay(alignment:)`
    /// was counted, on the assumption that the trailing-closure form was older.
    /// It is not -- `View.overlay(_:alignment:)` taking a finished View is
    /// iOS 13, but the `@ViewBuilder` form is 15.0.
    ///
    /// `AnyView` picks the View overload deterministically; without it the
    /// compiler has to choose between it and the ShapeStyle one.
    func huskOverlay<C: View>(@ViewBuilder content: () -> C) -> some View {
        self.overlay(AnyView(content()))
    }
}

// MARK: - UIColours that are themselves iOS 15

extension UIColor {
    /// `UIColor.systemMint` is iOS 15, so substituting it for `Color.mint` moves
    /// the problem rather than solving it. These two are the closest iOS 13
    /// equivalents: UIColor.systemCyan does not exist at any version, but plain
    /// `.cyan` does and is what a system palette entry would have rendered.
    static let systemCyanFallback = UIColor.cyan
    static let systemMintFallback = UIColor(red: 0.40, green: 0.90, blue: 0.70, alpha: 1.0)
}

// MARK: - alert / confirmationDialog (iOS 15.0)

extension View {
    /// Two actions. `primaryDestructive` maps to `Alert.Button.destructive`,
    /// which is what the iOS 15 `role:` was doing.
    ///
    /// Named `huskDialog` rather than after the control it stands in for,
    /// because it is not that control rendered differently: on iOS 14 this is
    /// a centred dialog where a sheet would have come from the bottom. The
    /// name is meant to make that visible at the call site.
    func huskDialog(title: String, message: String, isPresented: Binding<Bool>,
                    primary: String, primaryDestructive: Bool = false,
                    primaryAction: @escaping () -> Void,
                    secondary: String) -> some View {
        alert(isPresented: isPresented, content: {
            Alert(title: Text(title),
                  message: Text(message),
                  primaryButton: primaryDestructive
                      ? .destructive(Text(primary), action: primaryAction)
                      : .default(Text(primary), action: primaryAction),
                  secondaryButton: .cancel(Text(secondary)))
        })
    }

    /// One action, for the dialogs that only ever had one.
    func huskDialog(title: String, message: String, isPresented: Binding<Bool>,
                    dismiss: String, dismissDestructive: Bool = false,
                    dismissAction: @escaping () -> Void) -> some View {
        alert(isPresented: isPresented, content: {
            Alert(title: Text(title), message: Text(message),
                  dismissButton: dismissDestructive
                      ? .destructive(Text(dismiss), action: dismissAction)
                      : .default(Text(dismiss), action: dismissAction))
        })
    }
}

// SettingsTab's "Which saved machine?" has three actions -- GPU machine,
// Software machine, Cancel. Alert has two button slots and no third, so it
// cannot be expressed here at all. It needs a sheet of its own rather than a
// third overload of this, and that is a UI decision rather than a porting one.
// Left as the iOS 15 call, which means the file will not compile at 14.0 until
// someone writes that sheet.

// MARK: - AsyncImage (iOS 15.0)

/// `AsyncImage`'s phase, so call sites keep reading the same shape.
///
/// A struct with `image` and `error` rather than an enum: SwiftUI's phase is a
/// struct with exactly those two properties, and every call site already does
/// `if let image = phase.image` / `else if phase.error != nil`. An enum would
/// have meant rewriting all four of them for no benefit.
struct HuskAsyncPhase {
    /// A SwiftUI `Image`, not a `UIImage`. Every call site does
    /// `image.resizable()`, which only exists on `Image` -- carrying a UIImage
    /// here produced "value of type 'UIImage' has no member 'resizable'" at all
    /// four sites. SwiftUI's own `AsyncImagePhase` holds an `Image` for the same
    /// reason.
    var image: Image?
    var error: Error?

    static let empty = HuskAsyncPhase()
    static func success(_ image: Image) -> HuskAsyncPhase { .init(image: image) }
    static func failure(_ error: Error) -> HuskAsyncPhase { .init(error: error) }
}

/// `AsyncImage`, which is iOS 15.
///
/// iOS 14 has no async image primitive. This is the same shape: a URL in, a
/// phase out, loaded once per URL. The differences are that it does not reuse
/// another view's in-flight request, and that it does nothing at all when the
/// URL is nil -- the `empty` phase is what the call sites already handle.
struct HuskAsyncImage<Content: View>: View {
    let url: URL?
    @ViewBuilder let content: (HuskAsyncPhase) -> Content

    @State private var phase: HuskAsyncPhase = .empty

    var body: some View {
        content(phase)
            .onAppear { load() }
            .onChange(of: url) { _ in load() }
    }

    private func load() {
        guard let url else {
            phase = .empty
            return
        }
        phase = .empty
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                guard let image = UIImage(data: data) else {
                    phase = .failure(HuskAsyncError.notAnImage)
                    return
                }
                phase = .success(Image(uiImage: image))
            } catch {
                phase = .failure(error)
            }
        }
    }
}

enum HuskAsyncError: Error { case notAnImage }

extension View {
    /// `.searchable(text:prompt:)`, which is iOS 15. There is no pre-15
    /// equivalent that attaches itself, so this is a field the caller places.
    func huskSearchField(text: Binding<String>, prompt: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
            TextField(prompt, text: text)
                .font(.system(size: 15))
                .autocapitalization(.none)
                .autocorrectionDisabled()
            if !text.wrappedValue.isEmpty {
                Button { text.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .huskBackground(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// `.searchable(text:prompt:)`, which is iOS 15.
    ///
    /// Nothing below iOS 15 attaches a search field to a navigation view, so
    /// this is a field in a VStack above the content.
    ///
    /// Apply it to the view *inside* the navigation modifiers. Chaining it after
    /// `.navigationTitle` wraps the navigation modifiers inside the VStack, and
    /// the title then decorates a child rather than the presented content.
    func huskSearchBar(text: Binding<String>, prompt: String) -> some View {
        VStack(spacing: 8) {
            huskSearchField(text: text, prompt: prompt)
                .padding(.horizontal, 12)
                .padding(.top, 6)
            self
        }
    }
}

// MARK: - Date formatting (iOS 15.0 FormatStyle)

/// `Date.formatted(date:time:)` with `.abbreviated`/`.shortened`.
func huskFormatDateTime(_ date: Date) -> String {
    let d = DateFormatter()
    d.dateStyle = .medium
    d.timeStyle = .short
    return d.string(from: date)
}

/// `Date.formatted(.iso8601.year().month().day())`.
///
/// Not ISO 8601 despite the name: the chained style formats *numerically* in
/// the current locale, so a user on a non-Gregorian calendar gets their own
/// calendar's y/M/d rather than the ISO string. Matching that matters, because
/// the stamp ends up in a filename users see.
func huskFormatDateStamp(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = .current
    f.setLocalizedDateFormatFromTemplate("yMd")
    return f.string(from: date)
}

// MARK: - URLSession.download(for:) (iOS 15.0)

extension URLSession {
    /// `download(for:delegate:)`, which is iOS 15, over the completion-handler
    /// form that exists in iOS 14.
    ///
    /// The file is copied before the continuation resumes: the temporary file
    /// the download task hands back is deleted as soon as the completion handler
    /// returns, and the caller resumes from another context.
    func huskDownload(for request: URLRequest) async throws -> (URL, URLResponse) {
        let box = TaskBox()
        return try await withCheckedThrowingContinuation { continuation in
            let task = downloadTask(with: request) { url, response, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url, let response {
                    let copy = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString)
                    do {
                        try FileManager.default.copyItem(at: url, to: copy)
                        continuation.resume(returning: (copy, response))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                } else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                }
            }
            box.task = task
            task.resume()
        }
    }
}

private final class TaskBox: @unchecked Sendable {
    var task: URLSessionDownloadTask?
}

// MARK: - Button styles (iOS 15.0)

extension View {
    /// `.buttonStyle(.borderedProminent)`. Filled with the tint, white label.
    func huskBorderedProminent() -> some View {
        self.buttonStyle(.plain)
            .background(Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .foregroundColor(.white)
    }

    /// `.buttonStyle(.bordered)`. Translucent tint fill, tint-coloured label.
    func huskBordered() -> some View {
        self.buttonStyle(.plain)
            .background(Color.accentColor.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .foregroundColor(Color.accentColor)
    }

    /// `.buttonStyle(.borderless)`. A plain button; iOS 14's default look is
    /// close enough that this is nearly a no-op.
    func huskBorderless() -> some View {
        self.buttonStyle(.plain)
    }
}
