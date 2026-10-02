import XCTest
@testable import Nirux

/// Which launches RealStateGuard lets open the real state. Every path lives
/// in a temporary folder standing in for the disk: `Applications/Nirux.app`
/// plays /Applications/Nirux.app.
final class RealStateGuardTests: XCTestCase {
    private var root: URL!
    private var installedBundle: String { root.appendingPathComponent("Applications/Nirux.app").path }
    private var installedExecutable: String { installedBundle + "/Contents/MacOS/Nirux" }

    override func setUpWithError() throws {
        try super.setUpWithError()
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("nirux-real-state-guard-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        // The guard resolves symlinks (/var is /private/var), so do the expectations.
        root = URL(fileURLWithPath: try XCTUnwrap(realpathOf(path)))
        try makeExecutable(installedExecutable)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    private func realpathOf(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func makeExecutable(_ path: String) throws {
        try makeDirectory((path as NSString).deletingLastPathComponent)
        XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: Data()))
    }

    private func refused(
        _ executable: String,
        environment: [String: String] = [:],
        originalPath: (String) -> String? = { _ in nil }
    ) -> String? {
        RealStateGuard.refusedExecutable(
            environment: environment, executablePath: executable,
            installedBundlePath: installedBundle, originalPath: originalPath
        )
    }

    func testOnlyTheInstalledAppOpensTheRealState() throws {
        XCTAssertNil(refused(installedExecutable))

        // Same name, same layout, another folder: the stray bundle of 2026-09-28.
        let copy = root.appendingPathComponent("Projects/nirux.old/Nirux.app/Contents/MacOS/Nirux").path
        try makeExecutable(copy)
        XCTAssertEqual(refused(copy), copy)

        let swiftPM = root.appendingPathComponent("Projects/nirux/.build/debug/Nirux").path
        try makeExecutable(swiftPM)
        XCTAssertEqual(refused(swiftPM), swiftPM)

        // No installed app at all: nothing is it.
        try FileManager.default.removeItem(atPath: installedBundle)
        XCTAssertEqual(refused(copy), copy)
    }

    func testSymlinksAndLetterCaseDontHideTheInstalledApp() throws {
        let link = root.appendingPathComponent("bin/nirux").path
        try makeDirectory((link as NSString).deletingLastPathComponent)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: installedExecutable)
        XCTAssertNil(refused(link))

        // The install location spelled in another case than on disk, or
        // itself a link to the bundle: still the same folder.
        let otherCase = root.appendingPathComponent("applications/NIRUX.APP").path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: otherCase), "case-sensitive volume")
        XCTAssertNil(RealStateGuard.refusedExecutable(
            environment: [:], executablePath: installedExecutable,
            installedBundlePath: otherCase, originalPath: { _ in nil }
        ))
        let linkedInstall = root.appendingPathComponent("Linked/Nirux.app").path
        try makeDirectory((linkedInstall as NSString).deletingLastPathComponent)
        try FileManager.default.createSymbolicLink(atPath: linkedInstall, withDestinationPath: installedBundle)
        XCTAssertNil(RealStateGuard.refusedExecutable(
            environment: [:], executablePath: installedExecutable,
            installedBundlePath: linkedInstall, originalPath: { _ in nil }
        ))
    }

    func testATranslocatedAppIsJudgedByWhereItWasOpenedFrom() throws {
        // Gatekeeper's read-only mirror is another path, with other inodes.
        let mirror = root.appendingPathComponent("AppTranslocation/1234/d/Nirux.app").path
        try makeExecutable(mirror + "/Contents/MacOS/Nirux")
        let downloaded = root.appendingPathComponent("Downloads/Nirux.app").path
        try makeExecutable(downloaded + "/Contents/MacOS/Nirux")

        XCTAssertNil(refused(mirror + "/Contents/MacOS/Nirux") { $0 == mirror ? self.installedBundle : nil })
        XCTAssertEqual(
            refused(mirror + "/Contents/MacOS/Nirux") { $0 == mirror ? downloaded : nil },
            downloaded + "/Contents/MacOS/Nirux"
        )
    }

    func testAStateOfItsOwnOrAnExplicitOptInLetsACopyStart() throws {
        let copy = root.appendingPathComponent("Projects/nirux/Nirux.app/Contents/MacOS/Nirux").path
        try makeExecutable(copy)

        XCTAssertNil(refused(copy, environment: ["NIRUX_STATE_DIR": "/tmp/nirux-dev"]))
        XCTAssertNil(refused(copy, environment: ["NIRUX_ALLOW_REAL_STATE": "1"]))
        // An empty NIRUX_STATE_DIR leaves Persistence on the real state.
        XCTAssertEqual(refused(copy, environment: ["NIRUX_STATE_DIR": ""]), copy)
        XCTAssertEqual(refused(copy, environment: ["NIRUX_ALLOW_REAL_STATE": "0"]), copy)
    }

    /// The SPI is looked up at run time: if a macOS dropped it, a
    /// translocated install would be refused. Called on a plain bundle, it
    /// must answer "not translocated" rather than crash.
    func testTranslocationLookupRunsOnThisMacOS() throws {
        XCTAssertTrue(RealStateGuard.translocationLookupIsAvailable)
        XCTAssertNil(RealStateGuard.translocationOriginalPath(installedBundle))
    }
}
