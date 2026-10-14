// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit

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
/// Husk's `LabeledContent`: a label leading, its value trailing.
///
/// Deliberately NOT generic, and that is the whole point of the shape. The
/// obvious version is `struct HuskLabeledContent<Label: View, Value: View>` with
/// SwiftUI's overloads as constrained extensions, copied over as closely as they
/// can be. That does not compile:
///
///     extension HuskLabeledContent where Value == Text {
///         init<S>(_ title: S, value: S) ... {
///             self.init(_value: Text(value), _label: Text(title))   // <- here
///         }
///     }
///     error: cannot convert value of type 'Text' to expected argument type 'Label'
///
/// A constrained extension cannot make the solver substitute an unbound generic
/// parameter. Constraining `Value` leaves `Label` abstract, so `Text` will not
/// convert to it; constraining `Label` instead leaves `Value` abstract and gives
/// the mirror-image `cannot convert value of type 'V' to expected argument type
/// 'Value'`. Constraining both is not possible, because the custom-value
/// overloads genuinely need `Value` open.
///
/// Two `AnyView` boxes and a `String`-free label sidestep the whole problem:
/// nothing is abstract, so there is nothing to substitute. These rows are a
/// label and a leaf value, so the erasure costs nothing worth measuring.
struct HuskLabeledContent: View {
    private let label: AnyView
    private let value: AnyView

    init<S: StringProtocol, V: StringProtocol>(_ title: S, value: V) {
        self.label = AnyView(Text(title))
        self.value = AnyView(Text(value))
    }

    init<S: StringProtocol, V: View>(_ title: S, @ViewBuilder value: () -> V) {
        self.label = AnyView(Text(title))
        self.value = AnyView(value())
    }

    // `value` comes first, exactly as SwiftUI declares it: with more than one
    // trailing closure the first binds to the first parameter, and
    // `HuskLabeledContent { value } label: { label }` has to read that way.
    init(@ViewBuilder value: () -> some View, @ViewBuilder label: () -> some View) {
        self.value = AnyView(value())
        self.label = AnyView(label())
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
            value
                .multilineTextAlignment(.trailing)
                // Compat15 stands in for iOS 16 and 17, but it is still compiled
                // at whatever floor the app has -- 14.0 in the experiment -- so
                // it may not reach for anything above that either. The iOS 15
                // port wrote foregroundStyle here, which was correct at 15.0 and
                // is not at 14.0. The file is excluded from the sweep for the
                // same reason it is excluded from the banned-API grep: it is
                // where the shims live.
                .foregroundColor(.secondary)
        }
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

    /// `.presentationDetents(...)` with more than one detent. huskDetent takes
    /// one; upstream's `.presentationDetents([.medium, .large])` means the user
    /// may pick either, and collapsing the set to .large would take the
    /// half-height sheet away on iOS 16+ for nothing.
    @ViewBuilder
    func huskDetents(_ detents: HuskDetent...) -> some View {
        if #available(iOS 16.0, *) {
            self.presentationDetents(
                detents.reduce(into: Set<PresentationDetent>()) { $0.formUnion($1.swiftUIDetents) })
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

// MARK: - Orientation (iOS 16.0)

/// iOS 16's way of asking the window to rotate.
///
/// It lives here rather than inline in `HuskOrientation` for two reasons. Below
/// iOS 16 there is nothing to call, so the caller has to branch; and both names
/// here are iOS 16, so keeping them out of the caller's file is what lets a
/// grep-based check assert that no iOS 16 API survives outside this file at all
/// (see `assert no iOS 16/17-only API crept back in` in the build workflow).
@available(iOS 16.0, *)
func huskRequestGeometryUpdate(_ scene: UIWindowScene,
                               _ mask: UIInterfaceOrientationMask,
                               onRefused: @escaping (Error) -> Void) {
    var vc = scene.keyWindow?.rootViewController
    while let v = vc {
        v.setNeedsUpdateOfSupportedInterfaceOrientations()
        vc = v.presentedViewController
    }
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask), errorHandler: onRefused)
}


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

// MARK: - Persistent system overlays (iOS 16.0)

extension View {
    /// `.persistentSystemOverlays(.hidden)`, which is iOS 16.
    ///
    /// Not a spelling change: there is no SwiftUI modifier before iOS 16 that
    /// does this. What it asks for is the home indicator hidden, and that has
    /// always been reachable -- on `UIViewController`, as
    /// `prefersHomeIndicatorAutoHidden` (iOS 11) plus
    /// `setNeedsUpdateOfHomeIndicatorAutoHidden()`.
    ///
    /// The first version of this drove `UIApplication.isHomeIndicatorAutoHidden`,
    /// which does not exist. The home indicator's auto-hide is a property of a
    /// view controller, not of the application, and there is no application-level
    /// counterpart to set.
    ///
    /// So it goes through a representable whose controller carries the flag and,
    /// once it is on screen, walks up to the controller that is actually
    /// presenting. The walk is the part that matters: a representable in a
    /// `.background()` is a child of whatever presented the sheet or cover, and
    /// the home indicator follows the *topmost* controller, not this one. Setting
    /// only the representable's own controller would hide nothing.
    ///
    /// This is a best effort and not the same mechanism iOS 16 uses -- SwiftUI
    /// can ask for this before anything is presented, and a background view
    /// cannot. It works for a fullScreenCover, which is the only thing that uses
    /// it here.
    func huskPersistentOverlaysHidden() -> some View {
        background(HuskHomeIndicatorHider().frame(width: 0, height: 0))
    }
}

/// Carries `prefersHomeIndicatorAutoHidden` up to whatever is presenting.
private final class HuskHomeIndicatorController: UIViewController {
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyToPresenter()
    }

    fileprivate func applyToPresenter() {
        var vc: UIViewController = self
        while let next = vc.presentedViewController { vc = next }
        guard vc !== self else { return }
        vc.prefersHomeIndicatorAutoHidden = true
        vc.setNeedsUpdateOfHomeIndicatorAutoHidden()
    }
}

private struct HuskHomeIndicatorHider: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> HuskHomeIndicatorController {
        HuskHomeIndicatorController()
    }

    func updateUIViewController(_ controller: HuskHomeIndicatorController, context: Context) {
        // Re-applied on every update: the presenter can change under us if the
        // view is still around when something new is presented over it, and the
        // flag does not survive that on its own.
        controller.applyToPresenter()
    }
}
