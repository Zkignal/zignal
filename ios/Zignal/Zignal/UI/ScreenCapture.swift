import Combine
import SwiftUI
import UIKit

/// Whether the screen is being recorded, mirrored or shared (Control Center recording, AirPlay,
/// a cable, screen sharing in a call). Views that show the recovery words hide them while it's
/// on. Uses the iOS 17 scene capture trait; `UIScreen.isCaptured` is deprecated.
/// Screenshots can't be blocked, so they are reported afterwards (`onScreenshot`).
struct ScreenCaptureWatcher: UIViewRepresentable {
    @Binding var isCaptured: Bool

    func makeUIView(context: Context) -> CaptureStateView {
        let view = CaptureStateView(frame: .zero)
        view.onChange = { isCaptured = $0 }
        return view
    }

    func updateUIView(_ view: CaptureStateView, context: Context) {
        view.onChange = { isCaptured = $0 }
    }
}

/// An invisible view that reports its scene's capture state when it joins a window and
/// whenever the state changes.
final class CaptureStateView: UIView {
    var onChange: ((Bool) -> Void)?
    private var reported: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        _ = registerForTraitChanges([UITraitSceneCaptureState.self]) { (view: CaptureStateView, _: UITraitCollection) in
            view.report()
        }
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        report()
    }

    private func report() {
        guard window != nil else { return }
        let captured = traitCollection.sceneCaptureState == .active
        guard captured != reported else { return }
        reported = captured
        // After SwiftUI's update pass: state must not change during it.
        Task { @MainActor [weak self] in self?.onChange?(captured) }
    }
}

/// Shown instead of the recovery words while the screen is captured.
struct CapturedScreenNotice: View {
    var body: some View {
        Label("Screen recording or mirroring is on, so the recovery words are hidden. Stop it to see them.",
              systemImage: "record.circle")
            .font(.callout)
    }
}

/// Shown after a screenshot was taken while the recovery words were on screen.
struct ScreenshotWarning: View {
    var body: some View {
        Label("A screenshot was taken while the words were showing. Delete it from Photos and from Recently Deleted.",
              systemImage: "camera.viewfinder")
            .font(.callout)
            .foregroundStyle(.red)
    }
}

extension View {
    /// Calls `action` after the user takes a screenshot (it can't be prevented).
    func onScreenshot(_ action: @escaping () -> Void) -> some View {
        onReceive(NotificationCenter.default.publisher(for: UIApplication.userDidTakeScreenshotNotification)) { _ in
            action()
        }
    }
}
