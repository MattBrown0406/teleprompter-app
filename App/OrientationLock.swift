import UIKit

/// Lets one screen (the editor) pin the app to portrait while the recorder keeps rotating.
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor static var allowed: UIInterfaceOrientationMask = .allButUpsideDown

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { Self.allowed }
    }
}

enum OrientationLock {
    /// Editor layout is designed for an upright phone.
    @MainActor static func portrait() { set(.portrait) }
    /// Back to the app default (recorder can go sideways for 16:9).
    @MainActor static func release() { set(.allButUpsideDown) }

    @MainActor private static func set(_ mask: UIInterfaceOrientationMask) {
        AppDelegate.allowed = mask
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows {
                var vc = window.rootViewController
                while let current = vc {
                    current.setNeedsUpdateOfSupportedInterfaceOrientations()
                    vc = current.presentedViewController
                }
            }
            if mask == .portrait {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
            }
        }
    }
}
