import AppKit
import XCTest
@testable import Nirux

/// The canary's way into a packaged copy (see CanaryChannel): only a canary
/// run opens it, and only its runner gets through.
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

    private func request(token: String?) -> LeadChannel.Request {
        LeadChannel.Request(
            id: UUID().uuidString, tool: "menu", arguments: token.map { "{\"token\":\"\($0)\"}" } ?? "{}",
            workspaceID: "", agentUUID: "", createdAt: Date().timeIntervalSince1970 + 1
        )
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
        let folder = LeadChannel.requestsFolder(stateDirectory: stateDirectory, root: CanaryChannel.root)
        for item in [runner] + strangers { XCTAssertTrue(LeadChannel.write(item, id: item.id, in: folder)) }
        center.drain()

        XCTAssertEqual(handled, [runner.id])
        let responses = LeadChannel.responsesFolder(stateDirectory: stateDirectory, root: CanaryChannel.root)
        XCTAssertEqual(LeadChannel.take(LeadChannel.Response.self, id: runner.id, from: responses)?.isError, false)
        for stranger in strangers {
            XCTAssertEqual(LeadChannel.take(LeadChannel.Response.self, id: stranger.id, from: responses)?.isError, true, stranger.arguments)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateDirectory.appendingPathComponent(LeadChannel.root).path), "the Lead's folder")
    }

    /// What the app's terminals run never sees the token.
    func testTerminalsDontInheritTheToken() {
        let terminal = WorkspaceState.makeTerminalEnvironment(
            profileID: "p", workspaceID: "w", agentUUID: "u", missionID: nil, missionHandoffsEnabled: false,
            executablePath: nil, launchID: "l", inherited: canaryEnvironment
        )
        XCTAssertEqual(terminal[CanaryChannel.tokenKey], "")
    }

    /// A path picks the item its titles name once its menu validated it; a
    /// disabled, missing or submenu item says so and does nothing.
    @MainActor
    func testAMenuPathPicksItsItem() {
        let target = MenuTarget()
        let bar = NSMenu()
        let space = NSMenu(title: "Space")
        space.autoenablesItems = false
        bar.addItem(withTitle: "Space", action: nil, keyEquivalent: "").submenu = space
        for (title, enabled) in [("Previous Space", true), ("Next Space", false)] {
            let item = space.addItem(withTitle: title, action: #selector(MenuTarget.pick(_:)), keyEquivalent: "")
            item.target = target
            item.isEnabled = enabled
        }

        XCTAssertEqual(NiruxApp.pickMenuItem(path: ["Space", "Previous Space"], in: bar).isError, false)
        XCTAssertEqual(target.picked, ["Previous Space"])
        for path in [["Space", "Next Space"], ["Space", "Missing"], ["Space"], []] {
            XCTAssertTrue(NiruxApp.pickMenuItem(path: path, in: bar).isError, "\(path)")
        }
        XCTAssertEqual(target.picked, ["Previous Space"])
    }
}

private final class MenuTarget: NSObject {
    var picked: [String] = []

    @objc func pick(_ sender: NSMenuItem) { picked.append(sender.title) }
}
