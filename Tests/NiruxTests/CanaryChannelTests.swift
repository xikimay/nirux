import AppKit
import XCTest
@testable import Nirux

/// The canary's way into a packaged copy (see CanaryChannel): only a canary
/// run opens it, only its runner gets through, and what it answers is what
/// happened.
final class CanaryChannelTests: XCTestCase {
    private var stateDirectory: URL!
    private let token = String(repeating: "0123456789abcdef", count: 4)

    override func setUpWithError() throws {
        try super.setUpWithError()
        // NSApp, which the menu and window code reads, exists once this runs.
        _ = NSApplication.shared
        stateDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("nirux-canary-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: stateDirectory)
        super.tearDown()
    }

    private var canaryEnvironment: [String: String] {
        ["NIRUX_STATE_DIR": stateDirectory.path, CanaryChannel.tokenKey: token]
    }

    private var requests: URL { LeadChannel.requestsFolder(stateDirectory: stateDirectory, root: CanaryChannel.root) }
    private var responses: URL { LeadChannel.responsesFolder(stateDirectory: stateDirectory, root: CanaryChannel.root) }

    private func request(token: String?, tool: String = "menu", arguments: [String: Any] = [:]) -> LeadChannel.Request {
        var all = arguments
        if let token { all["token"] = token }
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: all)) ?? Data(), as: UTF8.self)
        return LeadChannel.Request(
            id: UUID().uuidString, tool: tool, arguments: json, workspaceID: "", agentUUID: "", createdAt: Date().timeIntervalSince1970 + 1
        )
    }

    private func window() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 120), styleMask: [.titled], backing: .buffered, defer: true)
    }

    func testOnlyACanaryRunOnAStateOfItsOwnHasAToken() {
        XCTAssertEqual(CanaryChannel.token(in: canaryEnvironment), token)
        XCTAssertNil(CanaryChannel.token(in: [:]), "a normal launch")
        XCTAssertNil(CanaryChannel.token(in: [CanaryChannel.tokenKey: token]), "the real state")
        XCTAssertNil(CanaryChannel.token(in: ["NIRUX_STATE_DIR": "", CanaryChannel.tokenKey: token]), "an empty NIRUX_STATE_DIR is the real state")
        for bad in ["", "1", String(token.dropLast()), token + "0", token.uppercased(), String(token.dropLast()) + "g"] {
            XCTAssertNil(CanaryChannel.token(in: ["NIRUX_STATE_DIR": stateDirectory.path, CanaryChannel.tokenKey: bad]), bad)
        }
    }

    /// The launch's call opens nothing without a canary run's token: no
    /// center, no folder.
    @MainActor
    func testANormalLaunchNeverOpensTheChannel() {
        for environment in [[:], ["NIRUX_STATE_DIR": stateDirectory.path], [CanaryChannel.tokenKey: token]] {
            let center = CanaryChannel.start(environment: environment, stateDirectory: stateDirectory) { _, _ in
                XCTFail("acted on a request")
            }
            XCTAssertNil(center, "\(environment)")
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: stateDirectory.path), [])
    }

    /// What the app runs never gets the token, while the app's own
    /// environment stays as it is (Ghostty reads it).
    func testChildProcessesNeverGetTheToken() throws {
        let result = try XCTUnwrap(BoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: [], currentDirectoryURL: stateDirectory,
            environment: [CanaryChannel.tokenKey: token, "CANARY_PROBE": "1"]
        ))
        let output = String(decoding: result.standardOutput, as: UTF8.self)
        XCTAssertTrue(output.contains("CANARY_PROBE=1"), output)
        XCTAssertFalse(output.contains(CanaryChannel.tokenKey), output)
    }

    @MainActor
    func testOnlyTheRunnersRequestsAreActedOn() throws {
        var handled: [String] = []
        let center = try XCTUnwrap(CanaryChannel.start(environment: canaryEnvironment, stateDirectory: stateDirectory) { request, answer in
            handled.append(request.id)
            answer("ok", false)
        })
        defer { center.stop() }
        let runner = request(token: token)
        let strangers = [request(token: nil), request(token: String(repeating: "f", count: 64)), request(token: String(token.dropLast()))]
        for item in [runner] + strangers { XCTAssertTrue(LeadChannel.write(item, id: item.id, in: requests)) }
        center.drain()

        waitUntil("the runner's request handled") { handled == [runner.id] }
        XCTAssertEqual(LeadChannel.take(LeadChannel.Response.self, id: runner.id, from: responses)?.isError, false)
        for stranger in strangers {
            XCTAssertEqual(LeadChannel.take(LeadChannel.Response.self, id: stranger.id, from: responses)?.isError, true, stranger.arguments)
        }
        XCTAssertEqual(handled, [runner.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent(LeadChannel.root).path), "the Lead's folder")
    }

    /// An action stuck in a modal loop (an alert) doesn't hold back the
    /// next request: it runs inside that loop.
    @MainActor
    func testAModalActionDoesntHoldBackTheNextRequest() throws {
        var released = false
        var finished: [String] = []
        let next = request(token: token, tool: "menu")
        let center = try XCTUnwrap(CanaryChannel.start(environment: canaryEnvironment, stateDirectory: stateDirectory) { request, answer in
            answer("ok", false)
            if request.tool == "modal" {
                // The runner sends its next request while the alert is up.
                XCTAssertTrue(LeadChannel.write(next, id: next.id, in: self.requests))
                let deadline = Date().addingTimeInterval(5)
                while !released, Date() < deadline { RunLoop.current.run(mode: .modalPanel, before: Date().addingTimeInterval(0.02)) }
            } else {
                released = true
            }
            finished.append(request.tool)
        })
        defer { center.stop() }
        let modal = request(token: token, tool: "modal")
        XCTAssertTrue(LeadChannel.write(modal, id: modal.id, in: requests))
        waitUntil("both actions ended", timeout: 15) { finished.count == 2 }
        XCTAssertEqual(finished, ["menu", "modal"], "the next request ran inside the modal loop")
    }

    /// What the app's terminals run never sees the token.
    func testTerminalsDontInheritTheToken() {
        let terminal = WorkspaceState.makeTerminalEnvironment(
            profileID: "p", workspaceID: "w", agentUUID: "u", missionID: nil, missionHandoffsEnabled: false,
            executablePath: nil, launchID: "l", inherited: canaryEnvironment
        )
        XCTAssertEqual(terminal[CanaryChannel.tokenKey], "")
    }

    /// A path finds the item its titles name once its menu validated it; a
    /// disabled, missing or submenu item is refused.
    @MainActor
    func testAMenuPathFindsItsItem() throws {
        let target = Target()
        let bar = NSMenu()
        let space = NSMenu(title: "Space")
        space.autoenablesItems = false
        bar.addItem(withTitle: "Space", action: nil, keyEquivalent: "").submenu = space
        for (title, enabled) in [("Previous Space", true), ("Next Space", false)] {
            let item = space.addItem(withTitle: title, action: #selector(Target.pick(_:)), keyEquivalent: "")
            item.target = target
            item.isEnabled = enabled
        }

        NiruxApp.pick(try NiruxApp.menuItem(path: ["Space", "Previous Space"], in: bar).get())
        XCTAssertEqual(target.picked, ["Previous Space"])
        for path in [["Space", "Next Space"], ["Space", "Missing"], ["Space"], []] {
            XCTAssertThrowsError(try NiruxApp.menuItem(path: path, in: bar).get(), "\(path)")
        }
    }

    /// The snapshot lists what an assistive app reads, disabled controls
    /// included; a press clicks an enabled control once, in a window never
    /// shown too.
    @MainActor
    func testASnapshotShowsTheControlsAndAPressClicksOnce() throws {
        let target = Target()
        let window = window()
        for (index, (title, enabled)) in [("Board", true), ("Merge", false)].enumerated() {
            let button = NSButton(title: title, target: target, action: #selector(Target.pick(_:)))
            button.frame = NSRect(x: 20 + index * 120, y: 40, width: 100, height: 30)
            button.isEnabled = enabled
            window.contentView?.addSubview(button)
        }

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(NiruxApp.snapshotJSON(of: [window]).utf8)) as? [String: Any])
        let elements = ((json["windows"] as? [[String: Any]])?.first?["elements"] as? [[String: Any]]) ?? []
        let buttons = elements.filter { $0["role"] as? String == NSAccessibility.Role.button.rawValue }
        XCTAssertEqual(buttons.map { $0["title"] as? String }, ["Board", "Merge"])
        XCTAssertEqual(buttons.map { $0["enabled"] as? Bool }, [true, false])

        NiruxApp.press(try XCTUnwrap(NiruxApp.pressTarget(label: "Board", in: [window])))
        XCTAssertNil(NiruxApp.pressTarget(label: "Merge", in: [window]), "disabled")
        XCTAssertNil(NiruxApp.pressTarget(label: "Missing", in: [window]))
        XCTAssertEqual(target.picked, ["Board"])
    }

    /// The runner hears that the press happened, in a window never shown too,
    /// where the accessibility press reports false although its action ran.
    @MainActor
    func testAPressAnswersThatItPressed() {
        let target = Target()
        let window = window()
        window.contentView?.addSubview(NSButton(title: "Board", target: target, action: #selector(Target.pick(_:))))
        let app = NiruxApp()
        app.mainWindow = window
        var answers: [(String, Bool)] = []
        app.performCanaryRequest(request(token: token, tool: "press", arguments: ["label": "Board"])) { answers.append(($0, $1)) }
        XCTAssertEqual(answers.map { $0.0 }, ["Pressed Board."])
        XCTAssertEqual(answers.map { $0.1 }, [false])
        XCTAssertEqual(target.picked, ["Board"])
    }

    /// Whatever unhides or activates a canary copy hides it again.
    @MainActor
    func testACanaryCopyHidesAgainWhenUnhiddenOrActivated() {
        let center = NotificationCenter()
        var hides = 0
        let observers = CanaryPresentation.keepHidden(on: center) { hides += 1 }
        defer { observers.forEach(center.removeObserver) }
        center.post(name: NSApplication.didUnhideNotification, object: nil)
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        waitUntil("hidden again twice", timeout: 5) { hides == 2 }
    }

    /// An element off every screen has no frame rather than breaking the JSON.
    @MainActor
    func testAnElementWithoutAFiniteFrameStillSnapshots() throws {
        let window = window()
        window.contentView?.addSubview(NowhereView(frame: NSRect(x: 0, y: 0, width: 10, height: 10)))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(NiruxApp.snapshotJSON(of: [window]).utf8)) as? [String: Any])
        let elements = ((json["windows"] as? [[String: Any]])?.first?["elements"] as? [[String: Any]]) ?? []
        let nowhere = try XCTUnwrap(elements.first { $0["label"] as? String == "Nowhere" })
        XCTAssertTrue(nowhere["frame"] is NSNull)
    }

    /// A terminal's keys go through the key interceptor, as typed keys do;
    /// other keys go to the view with the keyboard; with neither, refused.
    @MainActor
    func testKeysTakeTheRouteATypedKeyWould() throws {
        let window = window()
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        window.contentView?.addSubview(text)
        guard case .interceptor? = NiruxApp.keyRoute(interceptorTakesKeys: true, in: window) else { return XCTFail("a terminal's keys") }
        XCTAssertNil(NiruxApp.keyRoute(interceptorTakesKeys: false, in: window), "nothing focused")

        XCTAssertTrue(window.makeFirstResponder(text))
        guard case .responder? = NiruxApp.keyRoute(interceptorTakesKeys: false, in: window) else { return XCTFail("the text view") }
        // No shell: the interceptor hands every key back, and the view with the keyboard gets it.
        NiruxApp().send(NiruxApp.keys(typing: "aB"), to: window)
        XCTAssertEqual(text.string, "aB")
    }

    /// Text answers "sent, unconfirmed" before any key is sent, so a key
    /// that opens an alert can't hold the answer back.
    @MainActor
    func testTextAnswersBeforeItTypes() {
        let window = window()
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        window.contentView?.addSubview(text)
        XCTAssertTrue(window.makeFirstResponder(text))
        let app = NiruxApp()
        app.mainWindow = window
        var answered: [(text: String, isError: Bool, typedSoFar: String)] = []
        app.performCanaryRequest(request(token: token, tool: "text", arguments: ["text": "hi"])) { answered.append(($0, $1, text.string)) }
        XCTAssertEqual(answered.count, 1)
        XCTAssertTrue(answered.first?.text.hasPrefix("Sent, unconfirmed, to NSTextView") == true, answered.first?.text ?? "")
        XCTAssertEqual(answered.first?.isError, false)
        XCTAssertEqual(answered.first?.typedSoFar, "", "answered before typing")
        XCTAssertEqual(text.string, "hi")
    }

    /// A canary launch never comes forward: not for a link, a question of
    /// the shell's, nor a notification; a normal launch does.
    @MainActor
    func testACanaryLaunchNeverComesForward() {
        for (environment, comesForward) in [(canaryEnvironment, false), ([:], true)] {
            var brought = 0
            let app = NiruxApp()
            app.presence = AppPresence(launchEnvironment: environment) { brought += 1 }
            app.mainWindow = window()
            var effects = ShellSideEffects()
            app.installPresence(on: &effects, notifier: nil)
            effects.comeToFront()
            app.bringMainWindowForward()
            XCTAssertEqual(brought, comesForward ? 2 : 0, "\(environment)")
            XCTAssertEqual(app.mainWindow?.isVisible, comesForward, "\(environment)")
            app.mainWindow?.orderOut(nil)
        }
    }

    /// Text is typed with each character's US key code and Shift, as KeyMapper expects.
    @MainActor
    func testTextTypesEachCharactersKey() {
        let keys = NiruxApp.keys(typing: "aB1!\r é")
        XCTAssertEqual(keys.map { $0.keyCode }, [0, 11, 18, 18, 36, 49, 0])
        XCTAssertEqual(keys.map { $0.modifiers.contains(.shift) }, [false, true, false, true, false, false, false])
        XCTAssertEqual(keys.map { $0.characters }, ["a", "B", "1", "!", "\r", " ", "é"])
    }
}

private final class Target: NSObject {
    var picked: [String] = []

    @objc func pick(_ sender: Any) {
        picked.append((sender as? NSMenuItem)?.title ?? (sender as? NSButton)?.title ?? "")
    }
}

private final class NowhereView: NSView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { "Nowhere" }
    override func accessibilityFrame() -> NSRect { NSRect(x: CGFloat.nan, y: .infinity, width: 1, height: 1) }
}
