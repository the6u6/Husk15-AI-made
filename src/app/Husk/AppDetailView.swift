// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// A page pushed onto Home or the Library: a game's page, its settings, or its
/// technical details.
enum LibraryRoute: Hashable {
    case game(String)
    case gameSettings(String)
    case gameReport(String)
// Upstream adds `androidSystem` here and `ps4(String)`. One is ours to drop
    // and one is ours to take: androidSystem was the route to the Android system
    // image, which went with the VM, and nothing in this tree refers to it any
    // more. ps4 is new upstream work and is kept.
    case ps4(String)              // a PS4 game, by title ID
}

/// Where the tabs and their stacks are steered from.
///
/// One page can send you somewhere else -- Home's "See All" opens the Library -- and
/// a stack cannot be pushed from outside itself without somewhere to keep the path.
/// This is that somewhere.
@MainActor final class Router: ObservableObject {
    static let shared = Router()

    @Published var tab: HuskTab = .home
    @Published var home: [LibraryRoute] = []
    @Published var library: [LibraryRoute] = []
    @Published var libraryFilter: LibraryFilter = .all
    /// Downloads, as a sheet: Home's Downloads tile opens it.
    @Published var showDownloads = false

    /// A game to start as soon as its page is up: the one Husk was closed to switch to (see `switchTo`).
    @Published var autoPlay: String?

    private static let switchKey = "husk.switchToGame"

    /// Only one game can be loaded per run of Husk. Closing Husk to play another remembers which, and the next launch opens
    /// its page and starts it, so switching is: close, open, playing.
    func switchTo(_ appID: String) { UserDefaults.standard.set(appID, forKey: Self.switchKey) }

    /// At launch: the game Husk was closed to switch to, opened and started.
    func resumeSwitch() {
        guard let id = UserDefaults.standard.string(forKey: Self.switchKey) else { return }
        UserDefaults.standard.removeObject(forKey: Self.switchKey)
        HuskLog.log("ui", "opening \(id), which Husk was closed to switch to")
        tab = .library
        library = id.hasPrefix("ps4:") ? [.ps4(String(id.dropFirst(4)))] : [.game(id)]
        autoPlay = id
    }

    func showLibrary(_ filter: LibraryFilter) {
        libraryFilter = filter
        tab = .library
    }

    /// Pick APKs or bundles; Husk then asks where they go.
    func addSomething() {
        HuskFilePicker.present { urls in IncomingFiles.shared.receive(urls) }
    }
}
