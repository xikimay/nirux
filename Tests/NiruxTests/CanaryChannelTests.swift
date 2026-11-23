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

    private func request(token: String?, tool: String = "menu") -> LeadChannel.Request {
        LeadChannel.Request(
            id: UUID().uuidString, tool: tool, arguments: token.map { "{\"token\":\"\($0)\"}" } ?? "{}",
            workspaceID: "", agentUUID: "", createdAt: Date().timeIntervalSince1970 + 1
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

    /// Nothing the app starts inherits the token: it leaves the process's
    /// environment at launch.
    func testTheTokenLeavesTheProcessEnvironment() {
        setenv(CanaryChannel.tokenKey, token, 1)
        defer { unsetenv(CanaryChannel.tokenKey) }
        XCTAssertEqual(CanaryChannel.takeLaunchEnvironment()[CanaryChannel.tokenKey], token)
        XCTAssertNil(getenv(CanaryChannel.tokenKey))
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
        var inModal = false
        var released = false
        var finished: [String] = []
        let center = try XCTUnwrap(CanaryChannel.start(environment: canaryEnvironment, stateDirectory: stateDirectory) { request, answer in
            answer("ok", false)
            if request.tool == "modal" {
                inModal = true
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
        waitUntil("the modal action started", timeout: 10) { inModal }
        let next = request(token: token, tool: "menu")
        XCTAssertTrue(LeadChannel.write(next, id: next.id, in: requests))
        waitUntil("both actions ended", timeout: 10) { finished.count == 2 }
        XCTAssertEqual(finished, ["menu", "modal"])
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

        let found = try NiruxApp.menuItem(path: ["Space", "Previous Space"], in: bar).get()
        found.menu.performActionForItem(at: found.index)
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

    /// Keys reach the view that has the keyboard, or are refused when
    /// nothing has it: never a false "delivered".
    @MainActor
    func testKeysReachTheFocusedViewOrAreRefused() {
        let window = window()
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))
        window.contentView?.addSubview(text)
        XCTAssertTrue(NiruxApp.deliver([("a", 0, [])], to: window).isError, "nothing focused")
        XCTAssertEqual(text.string, "")

        XCTAssertTrue(window.makeFirstResponder(text))
        let delivered = NiruxApp.deliver([("a", 0, []), ("b", 11, [])], to: window)
        XCTAssertFalse(delivered.isError, delivered.text)
        XCTAssertEqual(text.string, "ab")
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
