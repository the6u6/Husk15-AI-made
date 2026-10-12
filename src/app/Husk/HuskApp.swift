// SPDX-License-Identifier: GPL-2.0-or-later
import SwiftUI

/// Which way the app may turn. The app follows the device, except while a landscape game is on screen:
/// Geometry Dash is a landscape game, and a fixed-size surface cannot follow a rotation.
enum HuskOrientation {
    static var standard: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : [.portrait, .landscapeLeft, .landscapeRight]
    }
    static var mask: UIInterfaceOrientationMask = standard

    /// Allow only `new`, and turn the screen to it if it is not already there.
    ///
    /// A game's screen asks as it appears, while its full-screen cover is still being presented, and iOS can refuse then
    /// ("Supported: portrait") because it has not yet asked the cover what it allows. So a refusal is retried a few times,
    /// a moment apart, for as long as `new` is still what is wanted.
    @MainActor static func set(_ new: UIInterfaceOrientationMask, attempt: Int = 0) {
        mask = new
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            if #available(iOS 16.0, *) {
                huskRequestGeometryUpdate(scene, new) { error in
                    HuskLog.log("ui", "orientation change refused (attempt \(attempt + 1)): \(error.localizedDescription)")
                    guard attempt < 5 else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        if mask == new { set(new, attempt: attempt + 1) }
                    }
                }
            } else {
                // iOS 15 and earlier have neither requestGeometryUpdate nor
                // setNeedsUpdateOfSupportedInterfaceOrientations. The delegate
                // method above already returns the new mask -- that half is
                // unchanged -- but iOS 15 only re-reads it when something asks
                // the device to rotate, which is what setting `orientation` on
                // UIDevice does. This is the long-standing KVO nudge rather than
                // a documented API; it is the only mechanism available below
                // iOS 16. The retry loop above does not apply, because it exists
                // to handle the refusal requestGeometryUpdate can return, which
                // has no equivalent here.
                var target: UIInterfaceOrientation = .portrait
                if new.contains(.landscapeRight) { target = .landscapeRight }
                else if new.contains(.landscapeLeft) { target = .landscapeLeft }
                else if new.contains(.portraitUpsideDown) { target = .portraitUpsideDown }
                UIDevice.current.setValue(target.rawValue, forKey: "orientation")
                HuskLog.log("ui", "orientation set to \(target.rawValue) via the iOS 15 path")
            }
        }
    }
}

final class HuskAppDelegate: NSObject, UIApplicationDelegate {
    /// The window, created here rather than by a Scene.
    ///
    /// `App`, `WindowGroup` and `@UIApplicationDelegateAdaptor` are all iOS 14.
    /// Below that the entry point is a UIApplicationDelegate that owns a
    /// UIWindow and puts a UIHostingController in it -- which is exactly what
    /// SwiftUI's App lifecycle does on 14, written out. The delegate was already
    /// here for the orientation mask and the background-download handoff, so
    /// this is that same delegate gaining the three lines it was missing.
    var window: UIWindow?

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        HuskOrientation.mask
    }

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // The download session reconnects to whatever was running before Husk was closed or relaunched in the background.
        _ = Downloads.shared

        // Everything that used to happen in HuskApp.init(). Order matters and is
        // unchanged: HuskLog.redirects stderr, so anything that logs before
        // HuskLog.start() is lost, and the JIT path is exactly what we cannot
        // afford to lose the first line of.
        launch()

        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = UIHostingController(rootView: ContentView())
        window.makeKeyAndVisible()
        self.window = window
        return true
    }

    /// The iOS 13 entry point. The order is the same as the one it replaced:
    /// logging first, then the JIT state, then the trap guard, then the leftovers
    /// and the controllers.
    private func launch() {
        UIScrollView.appearance().showsVerticalScrollIndicator = false
        UIScrollView.appearance().showsHorizontalScrollIndicator = false

        HuskLog.start()
        HuskLog.logFootprint("app-launch")
        JITBootstrap.noteLaunchState()
        HuskLog.log("jit", "debugged at launch: \(JITBootstrap.debuggedAtLaunch); TrollStore install: \(JITBootstrap.isInstalledWithTrollStore); jailbreak: \(JITBootstrap.isJailbroken); can grant its own JIT: \(JITBootstrap.canGrantOwnJIT)")

        JITBootstrap.installTrapGuard()

        IncomingFiles.clearLeftovers()

        DispatchQueue.main.async { HuskGamepads.shared.start() }
    }

    /// An APK shared to Husk, or opened in it from Files.
    ///
    /// `.onOpenURL` on a Scene is iOS 14; this is the delegate method it calls,
    /// and it has existed at every version.
    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        // husk://open_app?unique_identifier=… from a Home Screen clip; anything
        // else may be a shared APK
        if !AppClip.handle(url) { IncomingFiles.shared.receive(url) }
        return true
    }

    /// iOS woke Husk because background downloads finished or need attention: handle them, then say so.
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == Downloads.sessionID else { completionHandler(); return }
        HuskLog.log("downloads", "woken for background download events")
        Downloads.shared.backgroundCompletion = completionHandler
    }
}

/// The entry point.
///
/// `@main` on a type conforming to `App` is iOS 14, and with it go `Scene`,
/// `WindowGroup` and `@UIApplicationDelegateAdaptor`. `@main` itself is not 14 --
/// it is any type with a `static func main()`, and this is the iOS 13 form:
/// UIApplicationMain, pointed at the delegate that owns the window.
///
/// The first version of this was a second delegate forwarding to the first,
/// because two delegates cannot both be registered. There is only ever one.
@main
enum HuskMain {
    static func main() {
        UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil,
                          NSStringFromClass(HuskAppDelegate.self))
    }
}
