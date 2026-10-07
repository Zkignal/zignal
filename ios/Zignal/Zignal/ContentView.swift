import SwiftUI
import ZcashLightClientKit

struct ContentView: View {
    @State private var status = "Running self-test..."

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .imageScale(.large)
                .foregroundStyle(.tint)
            Text("Welcome to Zignal!")
                .font(.title2)
            Text("Core: \(protocolVersion())")
                .font(.footnote)
                .monospaced()
            Text(status)
                .font(.footnote)
                .multilineTextAlignment(.center)
        }
        .padding()
        .task { status = Self.selfTest() }
    }

    /// Smoke test: Swift -> Rust core. Alice opens a post-quantum session with Bob
    /// from an invite, and Bob decrypts the first message. No network involved.
    static func selfTest() -> String {
        do {
            let now = UInt64(Date().timeIntervalSince1970)
            let alice = try ZkwInbox(seed: Data(repeating: 0x41, count: 32), now: now)
            let bob = try ZkwInbox(seed: Data(repeating: 0x42, count: 32), now: now)
            let invite = try bob.createInvite(myAddress: Data("utest1bob".utf8))
            let out = try alice.startFromInvite(
                invite: invite, myAddress: Data("utest1alice".utf8), firstText: "hello from Swift")
            for memo in out.memos {
                if case let .newSession(_, text)? = try bob.receive(memo: memo, now: now) {
                    return "Self-test passed: Bob decrypted \"\(text)\" from \(out.memos.count) memos"
                }
            }
            return "Self-test failed: nothing decrypted"
        } catch {
            return "Self-test error: \(error)"
        }
    }
}

#Preview {
    ContentView()
}
