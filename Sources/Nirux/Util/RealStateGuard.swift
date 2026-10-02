import AppKit

/// Keeps every Nirux but the installed app off the real state
/// (~/Library/Application Support/nirux). LaunchServices may hand a
/// `nirux://` link to any Nirux.app it has seen, such as an old development
/// bundle left in a checkout. That copy would restore the real workspaces,
/// relaunch their agent sessions, install the agent hooks pointing at itself
/// and save the state back in its own format. A copy that isn't
/// /Applications/Nirux.app starts only on a state of its own
/// (NIRUX_STATE_DIR) or with NIRUX_ALLOW_REAL_STATE=1; otherwise it says why
/// and quits before reading or writing anything.
enum RealStateGuard {
    static let installedBundlePath = "/Applications/Nirux.app"

    /// The executable of this launch when it must not use the real state
    /// (symlinks resolved, translocated back to where it was opened from);
    /// nil when it may. Files are compared by identity, so a symlink to the
    /// installed app or a different letter case still matches it.
    static func refusedExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executablePath: String = Bundle.main.executablePath ?? CommandLine.arguments[0],
        installedBundlePath: String = installedBundlePath,
        originalPath: (String) -> String? = translocationOriginalPath
    ) -> String? {
        if Persistence.stateDirectoryOverride(in: environment) != nil { return nil }
        if environment["NIRUX_ALLOW_REAL_STATE"] == "1" { return nil }
        let executable = realPath(executablePath) ?? executablePath
        // A SwiftPM build (`swift run`, .build/debug/Nirux) has no bundle.
        guard let bundle = enclosingBundle(ofExecutable: executable) else { return executable }
        // Gatekeeper runs a quarantined app from a read-only mirror (App
        // Translocation): judge the bundle it was opened from.
        let original = originalPath(bundle)
        if isSameFile(original ?? bundle, installedBundlePath) { return nil }
        return original.map { $0 + executable.dropFirst(bundle.count) } ?? executable
    }

    /// `…/Name.app` for `…/Name.app/Contents/MacOS/Name`, matched without
    /// regard to letter case like the default APFS volume.
    static func enclosingBundle(ofExecutable path: String) -> String? {
        let macOS = URL(fileURLWithPath: path).deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent.lowercased() == "macos",
              contents.lastPathComponent.lowercased() == "contents",
              bundle.pathExtension.lowercased() == "app" else { return nil }
        return bundle.path
    }

    /// Same device and inode: follows symlinks and firmlinks, ignores case.
    static func isSameFile(_ lhs: String, _ rhs: String) -> Bool {
        var left = stat()
        var right = stat()
        guard stat(lhs, &left) == 0, stat(rhs, &right) == 0 else { return false }
        return left.st_dev == right.st_dev && left.st_ino == right.st_ino
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    // MARK: - App Translocation

    /// `Boolean SecTranslocateIsTranslocatedURL(CFURLRef, bool *, CFErrorRef *)`
    private typealias IsTranslocated = @convention(c) (
        CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> DarwinBoolean
    /// `CFURLRef SecTranslocateCreateOriginalPathForURL(CFURLRef, CFErrorRef *)`
    private typealias CreateOriginalPath = @convention(c) (
        CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?
    ) -> Unmanaged<CFURL>?

    /// Security SPI, exported since macOS 10.12 but without a public header:
    /// looked up at run time, so a macOS without it reads as "not
    /// translocated".
    private static func translocationFunctions() -> (IsTranslocated, CreateOriginalPath)? {
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let isTranslocated = dlsym(security, "SecTranslocateIsTranslocatedURL"),
              let createOriginalPath = dlsym(security, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        return (unsafeBitCast(isTranslocated, to: IsTranslocated.self),
                unsafeBitCast(createOriginalPath, to: CreateOriginalPath.self))
    }

    static var translocationLookupIsAvailable: Bool { translocationFunctions() != nil }

    /// Where the translocated bundle at `path` was opened from; nil when it
    /// isn't translocated.
    static func translocationOriginalPath(_ path: String) -> String? {
        guard let (isTranslocated, createOriginalPath) = translocationFunctions() else { return nil }
        let url = URL(fileURLWithPath: path) as CFURL
        var translocated = false
        guard isTranslocated(url, &translocated, nil).boolValue, translocated,
              let original = createOriginalPath(url, nil)?.takeRetainedValue() else { return nil }
        return (original as URL).path
    }

    // MARK: - Refusal

    /// What a terminal runs to try this copy on a state of its own. The
    /// hooks stay put too: an app bundle would point them at itself.
    static func isolatedLaunchCommand(executablePath: String) -> String {
        "NIRUX_STATE_DIR=/tmp/nirux-dev NIRUX_SKIP_HOOK_INSTALL=1 " + AgentHookInstaller.shellQuoted(executablePath)
    }

    /// Explains on stderr (`swift run`) and in an alert why this copy won't
    /// start, then quits. Runs before anything of Nirux's is set up.
    @MainActor
    static func refuseLaunch(executablePath: String) -> Never {
        let copy = enclosingBundle(ofExecutable: executablePath) ?? executablePath
        let command = isolatedLaunchCommand(executablePath: executablePath)
        FileHandle.standardError.write(Data("""
            Nirux: not starting. Only \(installedBundlePath) uses your workspaces, and this copy is \(copy).
            Run it on a state of its own: \(command)
            (NIRUX_ALLOW_REAL_STATE=1 lets it use the real state anyway.)

            """.utf8))
        let app = NSApplication.shared
        let delegate = RefusedLaunchDelegate(copy: copy, command: command)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        exit(EXIT_FAILURE)
    }
}

/// Runs a launch RealStateGuard refused: one alert, then quit.
@MainActor
final class RefusedLaunchDelegate: NSObject, NSApplicationDelegate {
    private let copy: String
    private let command: String

    init(copy: String, command: String) {
        self.copy = copy
        self.command = command
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        makeAlert().runModal()
        exit(EXIT_FAILURE)
    }

    /// The `nirux://` link that launched this copy was meant for the
    /// installed app: it is dropped, never acted on.
    func application(_ application: NSApplication, open urls: [URL]) {}

    func makeAlert() -> NSAlert {
        let installed = RealStateGuard.installedBundlePath
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This copy of Nirux can't open your workspaces"
        alert.informativeText = """
            It runs from \(copy).

            Only the installed app, \(installed), uses your workspaces, so an older or \
            development copy can't overwrite them or relaunch their agent sessions. To use \
            Nirux, open \(installed); if you just downloaded it, move it to the Applications \
            folder first.

            To try this copy on a state of its own, run in Terminal:
            """
        let field = NSTextField(wrappingLabelWithString: command)
        field.isSelectable = true
        field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.lineBreakMode = .byCharWrapping
        field.preferredMaxLayoutWidth = 300
        field.frame.size = field.fittingSize
        alert.accessoryView = field
        alert.addButton(withTitle: "Quit")
        return alert
    }
}
