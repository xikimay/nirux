import AppKit
import XCTest
@testable import Nirux

@MainActor
final class AutomaticUpdatesMenuTests: XCTestCase {
    private final class FakeSetting: AutomaticUpdatesSetting {
        var automaticallyDownloadsUpdates: Bool
        var allowsAutomaticUpdates: Bool

        init(downloads: Bool, allowed: Bool = true) {
            automaticallyDownloadsUpdates = downloads
            allowsAutomaticUpdates = allowed
        }
    }

    private func menuItem(state: NSControl.StateValue = .mixed) -> NSMenuItem {
        let item = NSMenuItem(title: "Install Updates Automatically", action: nil, keyEquivalent: "")
        item.state = state
        return item
    }

    func testCheckmarkMirrorsSetting() {
        let item = menuItem()
        XCTAssertTrue(AutomaticUpdatesMenu.validate(item, setting: FakeSetting(downloads: true)))
        XCTAssertEqual(item.state, .on)

        XCTAssertTrue(AutomaticUpdatesMenu.validate(item, setting: FakeSetting(downloads: false)))
        XCTAssertEqual(item.state, .off)
    }

    func testDisabledAndUncheckedWithoutRunningUpdater() {
        let item = menuItem(state: .on)
        XCTAssertFalse(AutomaticUpdatesMenu.validate(item, setting: nil))
        XCTAssertEqual(item.state, .off)
        // Toggling without an updater is a no-op rather than a crash.
        AutomaticUpdatesMenu.toggle(nil)
    }

    func testDisabledWhenSparkleDisallowsAutomaticUpdates() {
        let item = menuItem()
        let setting = FakeSetting(downloads: false, allowed: false)
        XCTAssertFalse(AutomaticUpdatesMenu.validate(item, setting: setting))
        XCTAssertEqual(item.state, .off)

        AutomaticUpdatesMenu.toggle(setting)
        XCTAssertFalse(setting.automaticallyDownloadsUpdates)
    }

    func testAppMenuWiresToggleThroughAppValidation() throws {
        let application = NSApplication.shared
        let previousMenu = application.mainMenu
        defer { application.mainMenu = previousMenu }

        let app = NiruxApp()
        app.setupMenus()
        let appMenu = try XCTUnwrap(application.mainMenu?.items.first?.submenu)
        let item = try XCTUnwrap(appMenu.items.first { $0.action == #selector(NiruxApp.toggleAutomaticUpdates(_:)) })
        XCTAssertEqual(item.title, "Install Updates Automatically")
        XCTAssertTrue(item.target === app)

        // Tests run without an SUFeedURL, so no updater is running.
        item.state = .on
        XCTAssertFalse(app.validateMenuItem(item))
        XCTAssertEqual(item.state, .off)
    }

    func testToggleFlipsSettingBothWays() {
        let setting = FakeSetting(downloads: true)
        AutomaticUpdatesMenu.toggle(setting)
        XCTAssertFalse(setting.automaticallyDownloadsUpdates)
        AutomaticUpdatesMenu.toggle(setting)
        XCTAssertTrue(setting.automaticallyDownloadsUpdates)
    }
}
