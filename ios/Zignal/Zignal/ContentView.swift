import SwiftUI

/// Root view: setup, lock screen, or the unlocked profile.
struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.phase {
        case .starting:
            ProgressView()
        case .setup:
            OnboardingView()
        case .locked:
            UnlockView()
        case .unlocked(let session):
            ChatListView(session: session)
        }
    }
}
