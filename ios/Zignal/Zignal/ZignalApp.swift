import SwiftUI
import UIKit

@main
struct ZignalApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel()
    @State private var shield = PrivacyShield()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .overlay {
                    // Fallback under the shield window, in case it can't be shown.
                    if scenePhase != .active { PrivacyCover() }
                }
                .task { model.start() }
        }
        .onChange(of: scenePhase) { _, newPhase in
            shield.update(for: newPhase)
            model.scenePhaseChanged(newPhase)
        }
    }
}

/// Only Apple's keyboard is allowed inside Zignal. Third-party keyboards can record
/// keystrokes and may have network access.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        shouldAllowExtensionPointIdentifier extensionPointIdentifier: UIApplication.ExtensionPointIdentifier
    ) -> Bool {
        extensionPointIdentifier != .keyboard
    }
}

/// Puts a cover window above everything Zignal shows, including sheets and alerts, whenever
/// the app is not active. The app-switcher snapshot then shows only the cover.
@MainActor
final class PrivacyShield {
    private var window: UIWindow?

    func update(for phase: ScenePhase) {
        if phase == .active { hide() } else { show() }
    }

    private func show() {
        // The keyboard sits above every app window, so dismiss it too.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first
        else { return }
        let cover = UIWindow(windowScene: scene)
        cover.rootViewController = UIHostingController(rootView: PrivacyCover())
        cover.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 1)
        cover.isHidden = false
        window = cover
    }

    private func hide() {
        window?.isHidden = true
        window = nil
    }
}
