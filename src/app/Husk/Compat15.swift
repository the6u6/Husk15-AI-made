// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

// The iOS 15 support layer. Husk's app target deploys to iOS 15.0 (see
// project.yml), and the SwiftUI it was originally written against needs 16.0
// and 17.0. Everything in this file stands in for one of those, so the call
// sites read as ordinary Husk code rather than as availability checks.
//
// What is deliberately NOT here:
//
//   * The two extensions. HuskDownloadsWidget keeps its 16.1 floor (Live
//     Activities are 16.1) and HuskJITHelper its 26.0 floor (Built-in StikJIT
//     needs it). Both are embedded in the app and both simply fail to load
//     below their own floor -- a plugin above the host's version is legal,
//     pluginkit just never registers it. Their sources are already guarded:
//     see @available(iOS 16.1, *) in Shared/HuskDownloadActivity.swift and the
//     #available(iOS 16.1, *) branches in Downloads.swift, which is what keeps
//     the Live Activity from starting on a phone that cannot draw one.
//
//   * JIT. It is not a SwiftUI problem. On iOS 15 there is no TXM, so the
//     debugger-writes-into-RX-pages trick in docs/02-jit-substrate.md has
//     nothing to fight, and TrollStore's checkm8 range covers 15.0-15.8.x.
//     A pre-15 build is no harder to give executable memory than a 26+ one.
//
// The one genuine behaviour loss is `NavigationLink(value:)` +
// `.navigationDestination(for:)`, which needs a path-based stack that only
// exists from iOS 16. `HuskNavStack` below replaces it; see the note there.

// MARK: - Navigation (iOS 16.0)

/// A stack of a root page and at most one pushed page.
///
/// `NavigationView(path:)` and `.navigationDestination(for:)` are both iOS 16,
/// and iOS 15's `NavigationView` has no path at all. Husk never stacks deeper
/// than one level -- a tile opens a page and Back returns to the list -- so the
/// whole thing collapses to "the head of the path, or nothing", with Back in
/// the toolbar doing what the system's chevron did.
///
/// `path` stays a `[T]` rather than a `T?` so the Router keeps its one
/// shape: `resumeSwitch()` and `openFiles(at:)` set it from outside, and this
/// reads it as a binding.
struct HuskNavStack<T: Hashable, Root: View, Page: View>: View {
    @Binding private var path: [T]
    private let backTitle: String
    private let makeRoot: () -> Root
    private let makePage: (T) -> Page

    // Explicit rather than a memberwise initialiser, so the two closures are
    // unambiguously `@ViewBuilder` parameters. They are stored and called from
    // `body`, never built eagerly: `page` is handed the route only once there
    // is a route to hand it.
    init(path: Binding<[T]>, backTitle: String,
         @ViewBuilder root: @escaping () -> Root,
         @ViewBuilder page: @escaping (T) -> Page) {
        self._path = path
        self.backTitle = backTitle
        self.makeRoot = root
        self.makePage = page
    }

    var body: some View {
        NavigationView {
            Group {
                if let head = path.first {
                    makePage(head)
                        .navigationBarHidden(false)
                        .toolbar {
                            ToolbarItem(placement: .navigationBarLeading) {
                                Button(backTitle) { path.removeAll() }
                            }
                        }
                } else {
                    makeRoot()
                }
            }
        }
    }
}


// MARK: - LabeledContent (iOS 16.0)

/// Husk's `LabeledContent`: a label leading, its value trailing.
///
/// The same three shapes SwiftUI vends, with SwiftUI's own overload set copied
/// across verbatim -- the `StringProtocol`/`LocalizedStringKey` pairing is what
/// lets `HuskLabeledContent("Size", value: someString)` resolve at all, and
/// picking the wrong one makes string literals silently ambiguous.
struct HuskLabeledContent<Label: View, Value: View>: View {
    private let label: Label
    private let value: Value

    // `value` comes first, exactly as SwiftUI declares it: with more than one
    // trailing closure the first binds to the first parameter, and
    // `HuskLabeledContent { value } label: { label }` has to read that way.
    init(@ViewBuilder value: () -> Value, @ViewBuilder label: () -> Label) {
        self.value = value()
        self.label = label()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
            value
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
        }
    }
}

// The overload set is SwiftUI's, copied across including the order and the
// `where Label == Text` / `where Value == Text` constraints. Resolving
// `HuskLabeledContent("Size", value: someString)` depends on exactly this
// shape -- a single-type-parameter `init(_:value:)` alongside the
// `LocalizedStringKey` one -- so it is not shortened here.
extension HuskLabeledContent where Value == Text {
    init<S>(_ title: S, value: S) where S: StringProtocol {
        self.init(value: { Text(value) }, label: { Text(title) })
    }

    init<S>(_ titleKey: LocalizedStringKey, value: S) where S: StringProtocol {
        self.init(value: { Text(value) }, label: { Text(titleKey) })
    }
}

extension HuskLabeledContent where Label == Text {
    init<S, V>(_ title: S, @ViewBuilder value: () -> V) where S: StringProtocol, V: View {
        self.init(value: value, label: { Text(title) })
    }

    init<V>(_ titleKey: LocalizedStringKey, @ViewBuilder value: () -> V) where V: View {
        self.init(value: value, label: { Text(titleKey) })
    }
}

// MARK: - Sheet detents (iOS 16.0)

/// The subset of `PresentationDetent` Husk asks for.
///
/// `PresentationDetent` itself is iOS 16, so it cannot appear in a signature
/// the 15.0 compiler has to check. Naming our own type keeps the `#available`
/// test in one place below.
enum HuskDetent {
    case medium
    case large
    case height(CGFloat)
}

extension View {
    /// `.presentationDetents(...)`. Below iOS 16 a sheet presents at the height
    /// its content wants, which is what every call site here already asks for,
    /// so this is a no-op rather than a fallback.
    @ViewBuilder
    func huskDetent(_ detent: HuskDetent) -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents(detent.swiftUIDetents)
        } else {
            self
        }
    }

    /// `.presentationDragIndicator(.visible)`.
    @ViewBuilder
    func huskDragIndicator() -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDragIndicator(.visible)
        } else {
            self
        }
    }
}

@available(iOS 16.0, *)
extension HuskDetent {
    var swiftUIDetents: Set<PresentationDetent> {
        switch self {
        case .medium: return [.medium]
        case .large: return [.large]
        case .height(let points): return [.height(points)]
        }
    }
}

// MARK: - Animation (iOS 17.0)

extension Animation {
    /// `Animation.huskSnappy`, which is iOS 17. `spring(duration:bounce:)` has been
    /// there since iOS 13, and these are the values Apple's own `snappy` uses.
    static var huskSnappy: Animation {
        .spring(duration: 0.5, bounce: 0.15)
    }

    static func huskSnappy(duration: TimeInterval) -> Animation {
        .spring(duration: duration, bounce: 0.15)
    }
}

extension View {
    /// `.animation(_:value:)`, which is iOS 17.
    ///
    /// The one-argument `.animation(_:)` underneath still works; it is merely
    /// soft-deprecated since iOS 15, and it is the only form that needs no
    /// restructuring of the state mutation it is watching. It differs in
    /// animating on any animatable change rather than only when `value` does,
    /// which is invisible at every call site here -- they are a log tailing, a
    /// toast fading, a page sliding.
    func huskAnimation<V: Equatable>(_ anim: Animation? = .default, value: V) -> some View {
        self.animation(anim)
    }
}

// MARK: - ShareLink (iOS 16.0)

/// `ShareLink(item:)`, built on the `ShareSheet` the app already had.
///
/// Rendered as a plain `Button` so whatever `.buttonStyle` the caller chained
/// onto `ShareLink` keeps working.
struct HuskShareButton<Label: View>: View {
    let items: [Any]
    private let label: Label
    @State private var showing = false

    init(items: [Any], @ViewBuilder label: () -> Label) {
        self.items = items
        self.label = label()
    }

    var body: some View {
        Button { showing = true } label: { label }
            .sheet(isPresented: $showing) { ShareSheet(items: items) }
    }
}
