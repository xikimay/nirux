import AppKit

/// Keeps every Nirux but the installed app off the real state
/// (~/Library/Application Support/nirux). LaunchServices may hand a
/// `nirux://` link to any Nirux.app it has seen, such as an old development
/// bundle left in a checkout. That copy would restore the real workspaces,
/// relaunch their agent sessions, install the agent hooks pointing at itself
/// and save the state back in its own format. Any other copy starts only on
/// a state of its own (NIRUX_STATE_DIR) or with NIRUX_ALLOW_REAL_STATE=1;
/// otherwise it says why and quits before reading or writing anything.
/// Copies built before this check existed are not covered.
enum RealStateGuard {
    static let systemBundlePath = "/Applications/Nirux.app"

    /// ~/Applications/Nirux.app, for an account that can't write
    /// /Applications. The account's real home: HOME is ignored.
    static var userBundlePath: String {
        FileManager.default.urls(for: .applicationDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Nirux.app").path
    }

    /// The installed app: /Applications/Nirux.app, or ~/Applications/Nirux.app
    /// when /Applications has none, so an old copy left in ~/Applications
    /// doesn't count once Nirux is installed system-wide. Nil when neither
    /// exists.
    static func installedBundlePath(system: String = systemBundlePath, user: String = userBundlePath) -> String? {
        [system, user].first { FileManager.default.fileExists(atPath: $0) }
    }

    /// The executable of this launch when it must not use the real state
    /// (symlinks resolved, translocated back to where it was opened from);
    /// nil when it may. Files are compared by identity, so a symlink, a
    /// firmlink or another letter case still match the installed app.
    static func refusedExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executablePath: String = Bundle.main.executablePath ?? CommandLine.arguments[0],
        installedBundlePath: String? = installedBundlePath(),
        originalPath: (String) -> String? = translocationOriginalPath
    ) -> String? {
        if Persistence.stateDirectoryOverride(in: environment) != nil { return nil }
        if environment["NIRUX_ALLOW_REAL_STATE"] == "1" { return nil }
        // realpath also spells the path as it is on disk.
        let executable = realPath(executablePath) ?? executablePath
        // A SwiftPM build (`swift run`, .build/debug/Nirux) has no bundle.
        guard let bundle = enclosingBundle(ofExecutable: executable) else { return executable }
        // Gatekeeper runs a quarantined app from a read-only mirror (App
        // Translocation): judge the bundle it was opened from.
        let opened = originalPath(bundle) ?? bundle
        if let installedBundlePath, isSameFile(opened, installedBundlePath) { return nil }
        return (opened as NSString).appendingPathComponent(
            "Contents/MacOS/" + (executable as NSString).lastPathComponent
        )
    }

    /// `…/Name.app` for `…/Name.app/Contents/MacOS/Name`.
    static func enclosingBundle(ofExecutable path: String) -> String? {
        let macOS = URL(fileURLWithPath: path).deletingLastPathComponent()
        let contents = macOS.deletingLastPathComponent()
        let bundle = contents.deletingLastPathComponent()
        guard macOS.lastPathComponent == "MacOS", contents.lastPathComponent == "Contents",
              bundle.pathExtension == "app" else { return nil }
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

    /// What a terminal runs to try this copy on a state of its own (in the
    /// account's own temporary folder). The hooks stay put too: an app
    /// bundle would point them at itself.
    static func isolatedLaunchCommand(executablePath: String) -> String {
        #"NIRUX_STATE_DIR="$TMPDIR/nirux-dev" NIRUX_SKIP_HOOK_INSTALL=1 "#
            + AgentHookInstaller.shellQuoted(executablePath)
    }

    /// Says on stderr why this copy won't start, and in an alert too when
    /// LaunchServices started it; then quits. Runs before anything of
    /// Nirux's is set up.
    @MainActor
    static func refuseLaunch(executablePath: String, installedBundlePath: String? = installedBundlePath()) -> Never {
        let copy = enclosingBundle(ofExecutable: executablePath) ?? executablePath
        let command = isolatedLaunchCommand(executablePath: executablePath)
        let installed = installedBundlePath ?? "\(systemBundlePath) (not found)"
        FileHandle.standardError.write(Data("""
            Nirux: not starting. Only the installed app, \(installed), opens your workspaces; this copy is \(copy).
            Run it on a state of its own: \(command)
            NIRUX_ALLOW_REAL_STATE=1 lets it use the real state instead.

            """.utf8))
        // A terminal, a script or an agent's tool started it: stderr says it
        // all, and an alert would steal the focus and wait for a click. Apps
        // that LaunchServices starts are children of launchd.
        guard getppid() == 1 else { exit(EXIT_FAILURE) }
        let app = NSApplication.shared
        let delegate = RefusedLaunchDelegate(copy: copy, installed: installedBundlePath, command: command)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
        exit(EXIT_FAILURE)
    }
}

/// Runs a launch RealStateGuard refused: one alert, then quit.
@MainActor
final class RefusedLaunchDelegate: NSObject, NSApplicationDelegate {
    private let copy: String
    private let installed: String?
    private let command: String
    private var openedByLink = false

    init(copy: String, installed: String?, command: String) {
        self.copy = copy
        self.installed = installed
        self.command = command
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        respond(to: makeAlert().runModal())
        exit(EXIT_FAILURE)
    }

    /// A `nirux://` link that launched this copy was meant for the installed
    /// app: never acted on, only mentioned. It arrives before
    /// applicationDidFinishLaunching.
    func application(_ application: NSApplication, open urls: [URL]) {
        openedByLink = true
    }

    func respond(to response: NSApplication.ModalResponse, pasteboard: NSPasteboard = .general) {
        guard response == .alertSecondButtonReturn else { return }
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
    }

    func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "This copy of Nirux can't open your workspaces"
        let link = openedByLink
            ? "A nirux:// link opened it instead of the installed app and was ignored. Links can keep "
                + "reaching this copy until it is deleted.\n\n"
            : ""
        let use = installed.map {
            "Only the installed app, \($0), opens your workspaces, so an older or development copy "
                + "can't overwrite them or relaunch their agent sessions. To use Nirux, open \($0)."
        } ?? "Nirux opens your workspaces only once installed in /Applications (or in the Applications "
            + "folder of your home folder), so an older or development copy can't overwrite them or "
            + "relaunch their agent sessions. To use Nirux, move it there."
        alert.informativeText = "It runs from \(copy).\n\n" + link + use
            + "\n\nTo try this copy on a state of its own, run in Terminal:"
        let field = NSTextField(wrappingLabelWithString: command)
        field.isSelectable = true
        field.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        field.lineBreakMode = .byCharWrapping
        field.preferredMaxLayoutWidth = 300
        field.frame.size = field.fittingSize
        alert.accessoryView = field
        alert.addButton(withTitle: "Quit")
        // No Edit menu here, so Command-C can't copy the field.
        alert.addButton(withTitle: "Copy Command and Quit")
        return alert
    }
}
