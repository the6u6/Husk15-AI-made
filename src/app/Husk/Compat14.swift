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
    func huskOverlay<A: Alignment, C: View>(alignment: A,
                                            @ViewBuilder content: () -> C) -> some View {
        ZStack(alignment: alignment) {
            self
            content()
        }
    }
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
