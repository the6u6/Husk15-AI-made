// SPDX-License-Identifier: GPL-2.0-or-later
//
// Compat13.swift -- the floor itself.
//
// iOS 13.0 is where SwiftUI begins, so this file is the boundary: everything
// below it does not exist, and everything above it is spelled here or at a call
// site. The iOS 14 gap is what this file is mostly about.
//
// Nothing in here is conditional on the deployment target. `huskLabel` is the
// same view on 13 and on 17, and that is deliberate: a shim that branched on
// `#available` would compile here and silently change behaviour on the devices
// people actually use. These are the older implementations, spelled
// unconditionally, so the app looks the same everywhere.
//
// What cannot be shimmed this way is a *type* that only exists above the floor.
// Label, ProgressView, List, LazyVStack and TextEditor are SwiftUI's own, so an
// extension cannot shadow the name and every call site says `husk` instead. That
// is why the renames are mechanical and visible rather than magic, and why a
// grep for these names is a real check instead of a formality.
import SwiftUI
import UIKit
import Combine
import Combine

// MARK: - Label (iOS 14.0)
//
// SwiftUI's Label is an HStack of icon and title that also participates in list
// row styling. On 13 the row *is* the HStack, so that is what this is.
//
// The StringProtocol and LocalizedStringKey pair is copied from SwiftUI on
// purpose. One overload taking StringProtocol would make a string literal
// ambiguous against the LocalizedStringKey one, and the compiler resolves that
// ambiguity by refusing to guess -- which is the same reason HuskLabeledContent
// is not generic (see Compat15.swift). The seven call sites that pass a String
// variable and the fifty-six that pass a literal both resolve here.
extension View {
    func huskLabel<S: StringProtocol, I: StringProtocol>(_ title: S,
                                                        systemImage: I) -> some View {
        HStack(spacing: 6) {
            // String(...) on both: Image(systemName:) takes a String, and
            // Text(title) would be Text's LocalizedStringKey overload, which a
            // StringProtocol-constrained generic cannot be.
            Image(systemName: String(systemImage))
            Text(String(title))
        }
    }

    func huskLabel(_ title: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
            Text(title)
        }
    }

    func huskLabel<Icon: View, Title: View>(@ViewBuilder title: () -> Title,
                                           @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 6) {
            icon()
            title()
        }
    }
}

// MARK: - ProgressView (iOS 14.0)
//
// Three shapes are used: a bare spinner, a spinner with a title beside it, and a
// determinate bar. UIProgressView is iOS 2 and covers all three, which is why
// the determinate case needs no geometry of its own.
//
// The tint is the accent colour rather than the environment's: there is no
// ProgressView below 14 to read an accent colour from, and every call site in
// the app either set `.accentColor` on it or wanted the app's accent anyway.
extension View {
    func huskProgress() -> some View {
        HuskUIKitProgress(style: .spinner, tint: Color.accentColor, fraction: nil)
    }

    func huskProgress(_ title: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            HuskUIKitProgress(style: .spinner, tint: Color.accentColor, fraction: nil)
            Text(title)
        }
    }

    func huskProgress<F: BinaryFloatingPoint>(value: F) -> some View {
        HuskUIKitProgress(style: .bar, tint: Color.accentColor, fraction: Double(value))
    }

    func huskProgress<V: BinaryFloatingPoint, T: BinaryFloatingPoint>(value: V,
                                                                      total: T) -> some View {
        HuskUIKitProgress(style: .bar, tint: Color.accentColor,
                          fraction: T.zero == total ? 0 : Double(value) / Double(total))
    }
}

/// UIProgressView, which is old enough to be here.
private struct HuskUIKitProgress: UIViewRepresentable {
    let style: UIProgressView.Style
    let tint: Color
    var fraction: Double?

    func makeUIView(context: Context) -> UIProgressView {
        UIProgressView(progressViewStyle: style)
    }

    func updateUIView(_ v: UIProgressView, context: Context) {
        if let fraction {
            // Determinate: the value, never animated. Animating it would mean a
            // bar still moving after the work it reports has finished.
            v.setProgress(Float(min(max(fraction, 0), 1)), animated: false)
        } else {
            // Indeterminate. UIProgressView has no startAnimating -- that is
            // UIActivityIndicatorView -- and an indeterminate bar is simply
            // progress left at zero. There is no tint either: UIColor(Color) is
            // iOS 14, and the bar takes the window's tint, which the app sets.
            v.setProgress(0, animated: false)
        }
    }
}

// MARK: - .onChange (iOS 14.0)
//
// The 14.0 spelling fires on every change; the pre-17 two-parameter form fires
// once when the value first differs. Both call sites use the single-argument
// form, so this keeps that meaning rather than quietly weakening it to fire
// once.
//
// The previous value has to be remembered somewhere to compare against, and
// below 14 there was no built-in place, so it is @State on the modifier.
// Appearing is not a change and does not fire -- the pre-14 idiom did not
// either, and firing on appear would run every one of these once per screen
// load for no reason.
extension View {
    func huskOnChange<V: Equatable>(of value: V,
                                    perform action: @escaping (V) -> Void) -> some View {
        modifier(HuskOnChange(value: value, action: action))
    }
}

private struct HuskOnChange<V: Equatable>: ViewModifier {
    let value: V
    let action: (V) -> Void
    @State private var previous: V?

    func body(content: Content) -> some View {
        content
            .onAppear { previous = value }
            .onReceive(Just(value)) { new in
                guard let old = previous else { previous = new; return }
                guard old != new else { return }
                previous = new
                action(new)
            }
    }
}

// MARK: - @AppStorage (iOS 14.0)
//
// A property wrapper over UserDefaults that also invalidates the view, which is
// the part that is not obvious: writing to UserDefaults notifies nobody, so a
// wrapper that only persisted would show the right value on the next launch and
// never again in this one.
//
// @State inside is what makes a write invalidate the view. Its setter is
// nonmutating, which is why `wrappedValue`'s setter has to be too.
//
// The four scalars and RawRepresentable are covered by a protocol rather than by
// a type test on the value, so Theme.Appearance -- a String-backed enum stored
// through the same wrapper, in two files -- round-trips as itself and not as its
// description.
@propertyWrapper
struct huskAppStorage<Value: huskStorable> {
    @State private var stored: Value
    private let key: String

    init(wrappedValue: Value, _ key: String) {
        self.key = key
        let defaults = UserDefaults.standard
        if let existing = Value.huskRead(defaults, key) {
            _stored = State(initialValue: existing)
        } else {
            Value.huskWrite(wrappedValue, defaults, key)
            _stored = State(initialValue: wrappedValue)
        }
    }

    var wrappedValue: Value {
        get { stored }
        nonmutating set {
            stored = newValue
            Value.huskWrite(newValue, UserDefaults.standard, key)
        }
    }

    /// A Binding, which is what `$appearance` inside a Picker resolves to.
    var projectedValue: Binding<Value> {
        Binding(get: { stored }, set: { self.wrappedValue = $0 })
    }
}

/// How a value gets into UserDefaults, specialised per type rather than through
/// a `Self`-typed requirement.
///
/// The first version declared `static func huskRead(_:_:) -> Self?` and
/// `huskWrite(_ value: Self, ...)` and tried to satisfy them from
/// `where Self == Bool` extensions. Swift cannot do that: a `Self`-typed
/// requirement cannot be witnessed from an extension constrained to a concrete
/// type, and it says so once per scalar -- "no type for 'Self' can satisfy both
/// 'Self == Bool' and 'Self : huskStorable'".
///
/// The conformances below are therefore ordinary concrete conformances on
/// *constrained extensions of the protocol*, which is the form that works. Storing
/// the scalars as themselves is what makes this interchangeable with what
/// `@AppStorage` wrote before it: the same key holds the same type of value, so an
/// install that has been through either one reads correctly.
protocol huskStorable {
    static func huskRead(_ defaults: UserDefaults, _ key: String) -> Self?
    static func huskWrite(_ value: Self, _ defaults: UserDefaults, _ key: String)
}
extension huskStorable where Self: RawRepresentable, Self.RawValue == String {
    static func huskRead(_ d: UserDefaults, _ k: String) -> Self? {
        guard let raw = d.string(forKey: k) else { return nil }
        return Self(rawValue: raw)
    }

    static func huskWrite(_ v: Self, _ d: UserDefaults, _ k: String) {
        d.set(v.rawValue, forKey: k)
    }
}

extension huskStorable where Self == Bool {
    static func huskRead(_ d: UserDefaults, _ k: String) -> Bool? {
        d.object(forKey: k) as? Bool
    }
    static func huskWrite(_ v: Bool, _ d: UserDefaults, _ k: String) { d.set(v, forKey: k) }
}

extension huskStorable where Self == Int {
    static func huskRead(_ d: UserDefaults, _ k: String) -> Int? {
        d.object(forKey: k) as? Int
    }
    static func huskWrite(_ v: Int, _ d: UserDefaults, _ k: String) { d.set(v, forKey: k) }
}

extension huskStorable where Self == Double {
    static func huskRead(_ d: UserDefaults, _ k: String) -> Double? {
        d.object(forKey: k) as? Double
    }
    static func huskWrite(_ v: Double, _ d: UserDefaults, _ k: String) { d.set(v, forKey: k) }
}

extension huskStorable where Self == String {
    static func huskRead(_ d: UserDefaults, _ k: String) -> String? { d.string(forKey: k) }
    static func huskWrite(_ v: String, _ d: UserDefaults, _ k: String) { d.set(v, forKey: k) }
}

// MARK: - @StateObject (iOS 14.0)
//
// The pre-14 idiom is `@ObservedObject private var x = ObservedObject(wrappedValue: X())`,
// and `ObservedObject.init(wrappedValue:)` is iOS 13, so no shim type is needed --
// only the spelling at the four call sites. It does not keep the object across
// view rebuilds the way @StateObject does; it keeps it for the lifetime of the
// view struct. None of these four are rebuilt more often than once per screen,
// so the difference does not show.

// MARK: - ignoresSafeArea (iOS 14.0)
//
// `edgesIgnoringSafeArea` is iOS 11 and is the same instruction under an older
// name -- deprecated in 14 in favour of exactly this, which is why the shim needs
// no version test.
extension View {
    func huskIgnoresSafeArea(_ edges: Edge.Set = .all) -> some View {
        edgesIgnoringSafeArea(edges)
    }
}

// MARK: - Navigation bar chrome (iOS 14.0)
//
// `.navigationTitle`, `.navigationBarTitleDisplayMode` and `View.toolbar` with
// `ToolbarItem` are all iOS 14 in their SwiftUI form. Their iOS 13 equivalents
// have different names, and there are 38 call sites for the first two across 15
// files.
//
// So these are extensions under the iOS 14 names rather than renames at the call
// sites. At a 13 floor SwiftUI's own declarations are version-gated out of
// existence, so the module's `navigationTitle` is the only one in scope and the
// call sites keep their exact spelling. Renaming 38 sites would have been 38
// chances to mistype one; this is zero.
//
// The display mode is a no-op, and that is a real loss: iOS 13 has
// navigationBarTitleTextFormatMode, and SwiftUI's own navigation title never
// took one. The 17 sites asking for .inline will get iOS 13's default sizing,
// which is the same trade every SwiftUI app made before 14.
extension View {
    func navigationTitle(_ title: Text) -> some View { navigationBarTitle(title) }

    func navigationTitle(_ title: LocalizedStringKey) -> some View {
        navigationBarTitle(Text(title))
    }

    func navigationTitle(_ title: String) -> some View {
        navigationBarTitle(Text(title))
    }

    func navigationTitle<S: StringProtocol>(_ title: S) -> some View {
        navigationBarTitle(Text(title))
    }

    /// Accepted and ignored -- see above.
    func navigationBarTitleDisplayMode(_ mode: HuskTitleDisplayMode) -> some View {
        self
    }
}

/// Stand-in for NavigationBarItem.TitleDisplayMode, iOS 13. Named apart from
/// SwiftUI's because that one is version-gated at 14 and the call sites pass
/// `.inline` unqualified, which resolves against whichever enum the parameter
/// asks for.
enum HuskTitleDisplayMode {
    case automatic, inline, large
}

// MARK: - Menu (iOS 14.0)
//
// SwiftUI's Menu is version-gated, so at a 13 floor this module's own type is
// what the name resolves to and the three call sites keep their spelling.
//
// iOS 13 has no menu and nothing to wrap: no SwiftUI actionSheet (that is 15),
// no Menu. The buttons inside are ordinary Buttons and they still work, so this
// presents the content in a sheet instead of a popup. That is a real
// behavioural difference -- one more tap, and the menu is modal rather than
// anchored -- and it is the honest ceiling: a control that behaves like Menu on
// 13 would mean building the popover presentation by hand for three call sites.
struct Menu<Label: View, Content: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let label: () -> Label
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: { label() }
            .sheet(isPresented: $showing) {
                NavigationView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) { content() }
                            .padding()
                    }
                    .navigationTitle("Menu")
                }
            }
    }
}

/// `Link` is iOS 14. The older spelling is a Button that opens the URL, which is
/// what Link does anyway -- it exists so a link looks like a link, not to change
/// what happens on tap.
extension View {
    func Link<D: View>(destination: URL, @ViewBuilder label: () -> D) -> some View {
        Button {
            guard UIApplication.shared.canOpenURL(destination) else { return }
            UIApplication.shared.open(destination)
        } label: {
            label()
        }
    }
}

// MARK: - LazyVGrid / LazyHGrid (iOS 14.0)
//
// iOS 13 has no grid at all -- LazyVGrid, LazyHGrid, Grid and GridRow all arrive
// at 14, with Grid at 16. So the replacement is a plain VStack/HStack of equally
// weighted cells, which for a fixed column count is the same arrangement at the
// cost of a fixed height instead of one derived from the content.
//
// `Grid` was in the census and `LazyVGrid` was not, which is the rule-list
// lesson again: a family is not covered because its better-known sibling is.
extension View {
    // A column *count*, not [GridItem]: GridItem is iOS 14, so a shim whose own
    // signature named it could not compile at the floor it exists for. Every use
    // in the app is a uniform flexible grid, which a count expresses exactly.
    func huskLazyVGrid<C: View>(count: Int,
                                spacing: CGFloat? = nil,
                                @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .center, spacing: spacing) {
            HStack(alignment: .top, spacing: spacing) { content() }
        }
        .frame(maxWidth: .infinity)
    }
}

extension View {
    // `Section(header:footer:content:)` exists on 13, so this shape only arises
    // where a Form's Section was turned into a huskSection. It is here so that a
    // section with a footer keeps its footer instead of failing to compile.
    func huskSection<F: View, C: View>(@ViewBuilder header: () -> some View,
                                      @ViewBuilder footer: () -> F,
                                      @ViewBuilder content: () -> C) -> some View {
        HuskSectionGroup(header: header, content: {
            content()
            footer()
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 6)
        })
    }
}

// MARK: - LazyVStack (iOS 14.0)
//
// iOS 13 has no lazy stacks, so the laziness is dropped and a plain VStack is
// used. That is a real cost -- every row is built before the first frame -- and it
// is the one place where supporting 13 is visibly worse than supporting 14. It is
// acceptable here because these stacks hold tens of rows, not thousands, and a
// lazy stack over that many rows buys very little anyway.
extension View {
    func huskLazyVStack<C: View>(alignment: HorizontalAlignment = .center,
                                 spacing: CGFloat? = nil,
                                 @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: alignment, spacing: spacing, content: content)
    }
}

// MARK: - List (iOS 14.0)
//
// The largest single thing supporting 13 costs.
//
// A List is a lazily-built collection of rows with separators, section headers
// that stick, swipe actions, and a style that decides its own insets. None of
// that survives as a plain stack. What is here is the part the app actually
// uses: a scroll view of rows, a hairline between them, and a title per group.
//
// Two consequences, both real:
//
//   * rows are all built up front, so a very long list would be slow to appear.
//     Every list in the app is bounded -- a repository's apps, the FAQ, the
//     settings -- so this does not bite.
//
//   * `Section` is NOT reused for the groups. Section is iOS 13, but it only
//     draws its header inside a List or a Form; in a VStack it renders the
//     content and drops the title. That is why huskSection exists rather than a
//     List that happens to contain Sections.
extension View {
    func huskList<C: View>(@ViewBuilder content: () -> C) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                content()
                // The last separator. A list draws one between rows and not one
                // after the last; without this the bottom row has a rule under it
                // that nothing else has.
                HStack(spacing: 0) { Spacer().frame(height: 1) }
                    .background(Color(white: 0, opacity: 0.12))
            }
        }
    }
}

/// A titled group of rows, for inside huskList.
private struct HuskSectionGroup<Header: View, Content: View>: View {
    // Stored closures are escaping; the extension methods below hand these
    // non-escaping builders straight through, and without the annotation that is
    // four errors rather than none.
    @ViewBuilder let header: @escaping () -> Header
    @ViewBuilder let content: @escaping () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header()
                .font(.footnote)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 6)
            content()
        }
    }
}

/// A group of rows with no title, which is how several of the call sites use
/// Section today.
private struct HuskPlainSection<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View { VStack(alignment: .leading, spacing: 0) { content() } }
}

extension View {
    // Three shapes, because the call sites use three: `Section { } header: { }`,
    // `Section(header: Text(...)) { }`, and a bare `Section { }`. The struct is
    // named HuskSectionGroup rather than huskSection because the method and the
    // type cannot share a name -- the first version did, and the method called
    // itself.
    func huskSection<H: View, C: View>(@ViewBuilder header: () -> H,
                                      @ViewBuilder content: () -> C) -> some View {
        HuskSectionGroup(header: header, content: content)
    }

    func huskSection<C: View>(header: Text,
                              @ViewBuilder content: () -> C) -> some View {
        HuskSectionGroup(header: { header }, content: content)
    }

    func huskSection<C: View>(@ViewBuilder content: () -> C) -> some View {
        HuskPlainSection(content: content)
    }
}

// MARK: - listRowInsets / listRowBackground (iOS 14.0)
//
// Inside a real List these position and paint the row cell. On a plain stack
// there is no cell, so they become padding and a background -- which is the same
// effect for every row in the app. `.listStyle(...)` has no counterpart at all
// and is dropped at the call site; the insets this shim applies are the plain
// ones, which is a visible difference on the settings rows that relied on
// `.insetGrouped` for its rounded card.
extension View {
    func listRowInsetsCompat(_ insets: EdgeInsets) -> some View {
        padding(insets)
    }

    func listRowBackgroundCompat<C: View>(_ background: C) -> some View {
        background(background)
    }
}

// MARK: - TextEditor (iOS 14.0)
//
// A real multi-line editor, because iOS 13's TextField is one line and the
// notes field this replaced wants three to eight lines. UITextView is old enough
// to be here, and wrapping it is the honest answer: the alternative -- a tall
// TextField that scrolls sideways -- is a worse control pretending to be this one.
//
// The first responder handover matters: the keyboard must appear when this
// appears, which is what the becomeFirstResponder on mount is for.
extension View {
    func huskTextEditor(text: Binding<String>, height: CGFloat) -> some View {
        HuskTextView(text: text).frame(height: height)
    }
}

private struct HuskTextView: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.font = .preferredFont(forTextStyle: .body)
        v.text = text
        v.delegate = context.coordinator
        v.backgroundColor = .clear
        v.isScrollEnabled = true
        // The SwiftUI TextEditor is focusable when it appears; so is this.
        DispatchQueue.main.async { v.becomeFirstResponder() }
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) {
        // Only write back when they differ. Writing unconditionally would move
        // the caret to the end on every keystroke, because setting `text` resets
        // the selection -- which is the bug this guard exists to avoid.
        if v.text != text { v.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let parent: HuskTextView
        init(_ parent: HuskTextView) { self.parent = parent }

        func textViewDidChange(_ v: UITextView) { parent.text = v.text }
    }
}

// MARK: - scenePhase (iOS 14.0)
//
// SwiftUI's scenePhase is a property of the scene, and scenes arrive at 13.
// Below that the app has one window and no scene, so the equivalent signal is
// the four UIApplication notifications that have always existed. They are
// bridged into an environment value so the call site reads the same way.
enum HuskScenePhase {
    case active, inactive, background
}

private struct HuskScenePhaseKey: EnvironmentKey {
    static let defaultValue: HuskScenePhase = .active
}

extension EnvironmentValues {
    var huskScenePhase: HuskScenePhase {
        get { self[HuskScenePhaseKey.self] }
        set { self[HuskScenePhaseKey.self] = newValue }
    }
}

extension View {
    /// Reports the app's foreground state through the environment. Put this on
    /// the root; read it with `@Environment(\.huskScenePhase)`.
    func huskScenePhaseTracking() -> some View {
        HuskScenePhaseProvider(content: self)
    }
}

/// A View rather than a ViewModifier: a modifier's `body(content:)` and a
/// provider's `body` are easy to confuse when reading, and the compiler's
/// complaints about this one were about the wrapper, not the phase.
private struct HuskScenePhaseProvider<Content: View>: View {
    let content: Content
    @State private var phase: HuskScenePhase = .active

    var body: some View {
        content
        content
            .environment(\.huskScenePhase, phase)
            .onReceive(NotificationCenter.default
                        .publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                phase = .active
            }
            .onReceive(NotificationCenter.default
                        .publisher(for: UIApplication.willResignActiveNotification)) { _ in
                phase = .inactive
            }
            .onReceive(NotificationCenter.default
                        .publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                phase = .background
            }
            .onReceive(NotificationCenter.default
                        .publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                phase = .inactive
            }
    }
}

// MARK: - ScrollViewReader (iOS 14.0)
//
// All three uses are "keep this log pinned to the bottom", which is one job:
// find the scroll view this view sits in and move its content offset. The
// sentinel walks up from a zero-size view planted in the content, which is how
// it finds the scroll view without needing the proxy that 14 introduced.
extension View {
    /// Scrolls the enclosing scroll view to its bottom whenever `token` changes.
    /// The token is anything Equatable that changes when the content grows --
    /// the log's length, or its line count.
    func huskScrollToBottom<V: Equatable>(_ token: V) -> some View {
        background(HuskScrollToBottomSentinel(token: token))
    }
}

private struct HuskScrollToBottomSentinel: View {
    let token: AnyEquatableToken

    init<V: Equatable>(token: V) { self.token = AnyEquatableToken(token) }

    var body: some View {
        HuskScrollSentinel(token: token)
            .frame(width: 0, height: 0)
            .clipped()
    }
}

/// Type-erases an Equatable so one representable can take any of them.
struct AnyEquatableToken: Equatable {
    private let value: Any
    private let isEqual: (Any, Any) -> Bool

    init<V: Equatable>(_ value: V) {
        self.value = value
        self.isEqual = { a, b in
            guard let x = a as? V, let y = b as? V else { return false }
            return x == y
        }
    }

    static func == (lhs: AnyEquatableToken, rhs: AnyEquatableToken) -> Bool {
        lhs.isEqual(lhs.value, rhs.value)
    }
}

private struct HuskScrollSentinel: UIViewRepresentable {
    let token: AnyEquatableToken

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ v: UIView, context: Context) {
        guard context.coordinator.last != token else { return }
        context.coordinator.last = token
        // The content height is only final after layout, so the scroll is asked
        // for on the next pass rather than now -- scrolling to a height that is
        // still the old one leaves it at the bottom of the previous log.
        DispatchQueue.main.async {
            guard let scroll = v.enclosingScrollView else { return }
            let bottom = max(0, scroll.contentSize.height - scroll.bounds.height
                             + scroll.adjustedContentInset.bottom)
            scroll.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var last: AnyEquatableToken?
    }
}

extension UIView {
    /// The nearest enclosing UIScrollView, or nil if there is none. Walking up
    /// rather than down is what makes this work: the sentinel is inside the
    /// content, so the scroll view is above it.
    var enclosingScrollView: UIScrollView? {
        var next = superview
        while let candidate = next {
            if let scroll = candidate as? UIScrollView { return scroll }
            next = candidate.superview
        }
        return nil
    }
}