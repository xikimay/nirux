import Foundation

/// Whether Nirux may come to the front. A canary copy (CanaryChannel) never
/// does, so nothing it does reaches the user's screen. How it comes forward
/// is the app's (NiruxApp.bringNiruxForward).
@MainActor
struct AppPresence {
    let mayComeForward: Bool
    var bringForward: @MainActor () -> Void

    init(launchEnvironment: [String: String], bringForward: @escaping @MainActor () -> Void) {
        mayComeForward = CanaryChannel.token(in: launchEnvironment) == nil
        self.bringForward = bringForward
    }

    func comeForward() {
        if mayComeForward { bringForward() }
    }
}
