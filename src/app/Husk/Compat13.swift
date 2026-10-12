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
            Image(systemName: I(systemImage))
            Text(title)
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
        let v = UIProgressView(progressViewStyle: style)
        v.progressTintColor = UIColor(tint)
        return v
    }

    func updateUIView(_ v: UIProgressView, context: Context) {
        v.progressTintColor = UIColor(tint)
        if let fraction {
            // Determinate: the value, never animated. Animating it would mean a
            // bar still moving after the work it reports has finished.
            v.setProgress(Float(min(max(fraction, 0), 1)), animated: false)
        } else {
            // Indeterminate: progress stays at zero and the spinner spins. A
            // negative progress is the "unknown" sentinel in some contexts and
            // stops the animation in this one, so it is not used.
            v.setProgress(0, animated: false)
            v.startAnimating()
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

/// How a value gets into UserDefaults. Bool/Int/Double/String are stored as
/// themselves; anything RawRepresentable over String is stored as its raw value.
protocol huskStorable {
    static func huskRead(_ defaults: UserDefaults, _ key: String) -> Self?
    static func huskWrite(_ value: Self, _ defaults: UserDefaults, _ key: String)
}

extension huskStorable where Self: RawRepresentable, Self.RawValue == String {
    static func huskRead(_ defaults: UserDefaults, _ key: String) -> Self? {
        guard let raw = defaults.string(forKey: key) else { return nil }
        return Self(rawValue: raw)
    }
    static func huskWrite(_ value: Self, _ defaults: UserDefaults, _ key: String) {
        defaults.set(value.rawValue, forKey: key)
    }
}

extension huskStorable where Self == Bool {
    static func huskRead(_ d: UserDefaults, _ k: String) -> Bool? { d.object(forKey: k) as? Bool }
    static func huskWrite(_ v: Bool, _ d: UserDefaults, _ k: String) { d.set(v, forKey: k) }
}

extension huskStorable where Self == Int {
    static func huskRead(_ d: UserDefaults, _ k: String) -> Int? { d.object(forKey: k) as? Int }
    static func huskWrite(_ v: Int, _ d: UserDefaults, _ k: String) { d.set(v, forKey: k) }
}

extension huskStorable where Self == Double {
    static func huskRead(_ d: UserDefaults, _ k: String) -> Double? { d.object(forKey: k) as? Double }
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