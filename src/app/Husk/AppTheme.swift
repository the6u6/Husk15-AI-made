// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI
import UIKit

/// The app's accent colour, chosen by the user and remembered.
///
/// Light and dark are not chosen here: they are the system's, unless the user pins one in
/// Settings > Appearance (`Theme.Appearance`). This is only the colour that buttons, toggles, selected
/// states and links are tinted with. It is applied once at the root with `.tint(...)`, which SwiftUI
/// hands down to every control, so no screen has to know about it.
///
/// Husk's own indigo, the colour of its icon, is the default; it is a preset like any other.
final class AppTheme: ObservableObject {
    static let shared = AppTheme()

    struct Preset: Identifiable {
        let id: String
        let name: String
        let color: Color
        /// The colour's hex, carried alongside it.
        ///
        /// `themeHex` used to ask UIKit: `UIColor(self).getRed(...)`.
        /// `UIColor(Color)` is iOS 14, and `Color.getRed` is 14 as well, so
        /// there is no way to ask at this floor.
        ///
        /// Carrying the hex on the preset is not a workaround so much as the
        /// truth now: the custom colour picker was removed for this same port --
        /// there is no ColorPicker on 13 and nothing to wrap -- so the accent is
        /// always one of these ten, or a hex this file read back out of
        /// UserDefaults. The colour a preset was built from is known where the
        /// preset is written down.
        let hex: String
    }

    static let husk = Color(red: 0.353, green: 0.322, blue: 0.945)
    static let huskHex = "#5A52F1"

    /// Light-appearance values, which is what these names are for and what a
    /// stored hex has always held.
    static let presets: [Preset] = [
        Preset(id: "husk", name: "Husk", color: husk, hex: huskHex),
        Preset(id: "blue", name: "Blue", color: .blue, hex: "#007AFF"),
        Preset(id: "purple", name: "Purple", color: .purple, hex: "#AF52DE"),
        Preset(id: "pink", name: "Pink", color: .pink, hex: "#FF2D55"),
        Preset(id: "red", name: "Red", color: .red, hex: "#FF3B30"),
        Preset(id: "orange", name: "Orange", color: .orange, hex: "#FF9500"),
        Preset(id: "yellow", name: "Yellow", color: .yellow, hex: "#FFCC00"),
        Preset(id: "green", name: "Green", color: .green, hex: "#34C759"),
        Preset(id: "teal", name: "Teal", color: Color(.systemCyanFallback), hex: "#30B0C7"),
        Preset(id: "mint", name: "Mint", color: Color(.systemMintFallback), hex: "#00C7BE"),
    ]

    /// The hex for a colour the app knows, or nil if it is not one of the presets.
    static func hex(of color: Color) -> String? {
        presets.first { $0.hex == color.themeHex }?.hex
    }

    @Published var accentColor: Color {
        didSet { persist() }
    }

    private static let key = "husk.accentColorHex"

    private init() {
        if let hex = UserDefaults.standard.string(forKey: Self.key), let color = Color(themeHex: hex) {
            accentColor = color
        } else {
            accentColor = Self.husk
        }
    }

    func reset() { accentColor = Self.husk }

    private func persist() {
        UserDefaults.standard.set(accentColor.themeHex, forKey: Self.key)
    }
}

extension Color {
    init?(themeHex hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self = Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }

    /// The hex for a colour, when the app knows one.
///
/// Both this and `isLight` used to ask UIKit for the components, which needs
/// `UIColor(Color)` or `Color.getRed` -- iOS 14, both. At this floor the answer
/// comes from the preset table instead, and a colour that is not in the table
/// falls back to Husk's own indigo rather than to a wrong guess.
///
/// `init?(themeHex:)` above is the way back, so a hex read out of UserDefaults
/// becomes a Color that this table can identify again.
var themeHex: String {
    AppTheme.hex(of: self) ?? AppTheme.huskHex
}

/// Whether text on this colour should be dark.
var isLight: Bool {
    var s = themeHex
    if s.hasPrefix("#") { s.removeFirst() }
    guard let value = UInt32(s, radix: 16) else { return false }
    let r = Double((value >> 16) & 0xFF) / 255
    let g = Double((value >> 8) & 0xFF) / 255
    let b = Double(value & 0xFF) / 255
    return 0.299 * r + 0.587 * g + 0.114 * b > 0.6
}
}
