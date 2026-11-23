import AppKit

/// Whether Nirux may come to the front, and how it does. A canary copy
/// (CanaryChannel) never does, so nothing it does reaches the user's screen.
@MainActor
struct AppPresence {
    let mayComeForward: Bool
    var bringForward: @MainActor () -> Void = {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    init(launchEnvironment: [String: String]) {
        mayComeForward = CanaryChannel.token(in: launchEnvironment) == nil
    }

    func comeForward() {
        if mayComeForward { bringForward() }
    }
}
