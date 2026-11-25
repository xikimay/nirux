import AppKit
import WebKit
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
        // As the app builds its menu bar: the item untitled, its menu titled.
        let spaceItem = NSMenuItem()
        spaceItem.submenu = space
        bar.addItem(spaceItem)
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
        // A custom view's AXEnabled reads false, yet a person clicks it.
        let custom = PressableView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        window.contentView?.addSubview(custom)
        let snapshotted = NiruxApp.accessibilitySnapshot(of: window)["elements"] as? [[String: Any]] ?? []
        XCTAssertEqual(snapshotted.first { $0["label"] as? String == "Custom" }?["pressable"] as? Bool, true)
        XCTAssertEqual(buttons.map { $0["pressable"] as? Bool }, [true, false])
        window.contentView?.addSubview(NowhereView(frame: NSRect(x: 0, y: 0, width: 10, height: 10)))
        XCTAssertNil(NiruxApp.pressTarget(label: "Nowhere", in: [window]), "a view without a press of its own")
        NiruxApp.press(try XCTUnwrap(NiruxApp.pressTarget(label: "Custom", in: [window])))
        XCTAssertEqual(custom.presses, 1)
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
        let inert = PressableView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        inert.label = "Inert"
        inert.action = false
        window.contentView?.addSubview(inert)
        for label in ["Board", "Inert"] {
            app.performCanaryRequest(request(token: token, tool: "press", arguments: ["label": label])) { answers.append(($0, $1)) }
        }
        XCTAssertEqual(answers.map { $0.0 }, ["Pressed Board.", "Inert has nothing to do on a press."])
        XCTAssertEqual(answers.map { $0.1 }, [false, true])
        XCTAssertEqual(inert.presses, 1)
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

    /// The canary's keys take a typed key's route, with the app's menus: a
    /// terminal's through the key interceptor to its PTY; in an editor, ⌘Z
    /// reaches Monaco before Edit › Undo, and ⌘W closes the tab, not the
    /// column.
    @MainActor
    func testKeysTakeTheRouteATypedKeyWould() throws {
        XCTAssertNil(NiruxApp.keyRoute(interceptorTakesKeys: false, in: window()), "nothing has the keyboard")
        try UIFlowHarness.run { harness in
            try harness.withApp {
                let app = NiruxApp()
                app.shell = harness.shell
                app.mainWindow = harness.window
                guard case .interceptor? = NiruxApp.keyRoute(interceptorTakesKeys: app.interceptorTakesKeys, in: harness.window) else {
                    return XCTFail("a terminal's keys")
                }
                let workspace = try XCTUnwrap(harness.shell.activeWorkspace)
                let terminal = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.pty)
                let standIn = AgentStandIn()
                defer { standIn.remove() }
                harness.waitUntil("the terminal's shell") { terminal.shellPID != nil }
                terminal.sendRaw(standIn.command(named: "cat") + "\n")
                harness.waitUntil("the stand-in") { terminal.foregroundProcess(snapshot: ProcessSnapshot())?.name == "cat" }
                app.send(NiruxApp.keys(typing: "hi"), to: harness.window)
                harness.waitUntil("the keys in the terminal") { standIn.input == "hi" }
                harness.shell.openEditorColumn()
                let editor = try XCTUnwrap(workspace.columns[safe: workspace.focusedIndex]?.editorColumn)
                harness.waitUntil("the editor to open README.md") { editor.activePath == harness.repo + "/README.md" }
                let webView = try XCTUnwrap(UIFlowHarness.descendant(of: editor, as: WKWebView.self))
                harness.window.makeFirstResponder(webView)
                harness.waitUntil("Monaco to take text") { webView.inputContext != nil }
                guard case .responder(let responder)? = NiruxApp.keyRoute(interceptorTakesKeys: app.interceptorTakesKeys, in: harness.window) else {
                    return XCTFail("the editor's keys")
                }
                XCTAssertIdentical(responder, webView)

                let monaco = "monaco.editor.getEditors().filter(function (e) { return e.hasTextFocus(); })[0]"
                let text = "(function () { var e = \(monaco); return e ? e.getValue() : ''; })()"
                var original = ""
                UIFlowHarness.waitForAnswer("Monaco's text", to: text, in: webView) {
                    original = $0
                    return !$0.isEmpty
                }
                UIFlowHarness.run("\(monaco).trigger('keyboard', 'type', {text: 'typed'})", in: webView)
                UIFlowHarness.waitForAnswer("the typed text", to: text, in: webView) { $0 != original }
                app.send([("z", 0x06, .command)], to: harness.window)
                UIFlowHarness.waitForAnswer("⌘Z to undo it in Monaco", to: text, in: webView) { $0 == original }

                let columns = workspace.columns.count
                app.send([("w", 0x0D, .command)], to: harness.window)
                harness.waitUntil("⌘W to close the tab") { editor.openPaths.isEmpty }
                XCTAssertEqual(workspace.columns.count, columns, "the column stays")
            }
        }
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

    /// What brings Nirux forward goes through its presence, as the launch
    /// connects it: a clicked notification, a reply that couldn't go in (a
    /// question of the shell's), a link's confirmation and the link. A
    /// canary launch never comes forward; a normal launch does each time.
    @MainActor
    func testACanaryLaunchNeverComesForward() throws {
        for (environment, comesForward) in [(canaryEnvironment, false), ([:], true)] {
            try UIFlowHarness.run { harness in
                var brought = 0
                let app = NiruxApp()
                app.presence = AppPresence(launchEnvironment: environment) { brought += 1 }
                app.shell = harness.shell
                app.mainWindow = harness.window
                let notifier = NiruxNotifier()
                app.connect(harness.shell, to: notifier)
                let workspaceID = try XCTUnwrap(harness.shell.activeWorkspace?.id)
                var link = URLComponents()
                link.scheme = "nirux"
                link.host = "new-workspace"
                link.queryItems = [URLQueryItem(name: "cwd", value: harness.worktree), URLQueryItem(name: "title", value: "Linked")]
                let reply = NiruxNotifier.QuickReplyTarget(agentUUID: UUID().uuidString, turnEndedAt: 0).userInfo
                let steps: [(String, @MainActor () throws -> Void)] = [
                    ("a clicked notification", {
                        notifier.open(.init(userInfo: ["workspaceID": workspaceID], actionIdentifier: "", userText: nil))
                    }),
                    ("a reply for an agent gone", {
                        notifier.open(.init(
                            userInfo: reply.merging(["workspaceID": workspaceID]) { $1 },
                            actionIdentifier: NiruxNotifier.quickReplyAction, userText: ""
                        ))
                    }),
                    ("a link's confirmation", {
                        app.application(NSApp, open: [try XCTUnwrap(link.url)])
                        harness.waitUntil("the link's confirmation") { harness.window.attachedSheet != nil }
                    }),
                    ("the link, confirmed", {
                        harness.window.endSheet(try XCTUnwrap(harness.window.attachedSheet), returnCode: .alertFirstButtonReturn)
                        harness.waitUntil("the linked workspace") { harness.shell.workspaces.contains { $0.title == "Linked" } }
                    }),
                ]
                for (index, (what, step)) in steps.enumerated() {
                    try step()
                    XCTAssertEqual(brought, comesForward ? index + 1 : 0, "\(what), \(comesForward ? "normal" : "canary") launch")
                }
            }
        }
    }

    /// Every open terminal's text, the focused one marked, as the app's
    /// global search reads it.
    @MainActor
    func testTerminalTextAnswersEachTerminal() throws {
        try UIFlowHarness.run { harness in
            let app = NiruxApp()
            app.shell = harness.shell
            app.mainWindow = harness.window
            let terminal = try XCTUnwrap(harness.shell.activeWorkspace?.columns.first?.pty)
            harness.waitUntil("the terminal's shell") { terminal.shellPID != nil }
            terminal.sendRaw("echo canary-$((6 * 7))\n")
            var answers: [(text: String, isError: Bool)] = []
            var asked = 0
            harness.waitUntil("the command's output in the answer") {
                guard answers.count == asked else { return false }
                if answers.last?.text.contains("canary-42") == true { return true }
                asked += 1
                app.performCanaryRequest(request(token: token, tool: "terminal")) { answers.append(($0, $1)) }
                return false
            }
            let answer = try XCTUnwrap(answers.last)
            XCTAssertFalse(answer.isError)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(answer.text.utf8)) as? [String: Any])
            let focused = try XCTUnwrap(json["terminals"] as? [[String: Any]]).filter { $0["focused"] as? Bool == true }
            XCTAssertEqual(focused.count, 1)
            XCTAssertEqual(focused.first?["workspace"] as? String, harness.shell.activeWorkspace?.title)
            XCTAssertEqual(focused.first?["active"] as? Bool, true)
            XCTAssertTrue((focused.first?["text"] as? String)?.contains("canary-42") == true)
        }
    }

    /// A canary copy is hidden, so a popover closing never reads as its last
    /// window closing and quits it; a normal launch quits with its window.
    @MainActor
    func testOnlyANormalLaunchQuitsWithItsLastWindow() {
        for (environment, quits) in [(canaryEnvironment, false), ([:], true)] {
            let app = NiruxApp()
            app.presence = AppPresence(launchEnvironment: environment) {}
            XCTAssertEqual(app.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared), quits, "\(environment)")
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

private final class PressableView: NSView {
    var presses = 0
    var label = "Custom"
    /// Whether a press does something, as SidebarSectionToggleView's with an onPress.
    var action = true
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityPerformPress() -> Bool {
        presses += 1
        return action
    }
}

private final class NowhereView: NSView {
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { "Nowhere" }
    override func accessibilityFrame() -> NSRect { NSRect(x: CGFloat.nan, y: .infinity, width: 1, height: 1) }
}
