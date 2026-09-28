import AppKit
import Sparkle

// MARK: - Sparkle Auto-Update

extension NiruxApp {
    func setupUpdater() {
        guard Bundle.main.infoDictionary?["SUFeedURL"] != nil else { return }

        updaterController = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: nil
        )
        do {
            try updaterController?.updater.start()
            updaterReady = updaterController != nil
        } catch {
            updaterReady = false
            NSLog("Sparkle updater failed to start: \(error.localizedDescription)")
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in
            self.isManualUpdateCheck = false
            self.showUpdateAvailable(version: version)
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            self.isManualUpdateCheck = false
        }
    }

    func showUpdateAvailable(version: String) {
        guard let shell else { return }
        shell.statusBar.showUpdate(version: version)
        shell.statusBar.onInstall = { [weak self] in
            self?.updaterController?.checkForUpdates(nil)
        }
    }

    @objc func installUpdate(_ sender: Any?) {
        updaterController?.checkForUpdates(sender)
    }

    func validateMenuItemForUpdate(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(manualCheckForUpdates(_:)) {
            return updaterReady
        }
        if menuItem.action == #selector(toggleAutomaticUpdates(_:)) {
            return AutomaticUpdatesMenu.validate(menuItem, setting: automaticUpdatesSetting)
        }
        return true
    }

    @objc func toggleAutomaticUpdates(_ sender: Any?) {
        AutomaticUpdatesMenu.toggle(automaticUpdatesSetting)
    }

    private var automaticUpdatesSetting: AutomaticUpdatesSetting? {
        updaterReady ? updaterController?.updater : nil
    }

    @objc func manualCheckForUpdates(_ sender: Any?) {
        isManualUpdateCheck = true
        updaterController?.checkForUpdates(sender)
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        Task { @MainActor in
            let wasManualCheck = self.isManualUpdateCheck
            self.isManualUpdateCheck = false
            guard wasManualCheck else { return }

            let alert = NSAlert()
            alert.messageText = "Update check failed"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.alertStyle = .warning
            alert.runModal()
        }
    }
}

// MARK: - Install Updates Automatically

/// The slice of Sparkle's updater behind the "Install Updates Automatically"
/// menu item, so the toggle is testable without a running `SPUUpdater`.
@MainActor
protocol AutomaticUpdatesSetting: AnyObject {
    var automaticallyDownloadsUpdates: Bool { get set }
    var allowsAutomaticUpdates: Bool { get }
}

extension SPUUpdater: AutomaticUpdatesSetting {}

/// Unchecking the item stops Sparkle from silently downloading newer builds, so
/// a manually installed (rolled-back) build stays put: Sparkle asks first
/// instead. An update it already downloaded may still install when the app
/// quits. Sparkle persists the choice in user defaults (`SUAutomaticallyUpdate`),
/// which take precedence over the Info.plist default.
@MainActor
enum AutomaticUpdatesMenu {
    /// Mirrors the setting as the item's checkmark; returns whether it is enabled.
    static func validate(_ menuItem: NSMenuItem, setting: AutomaticUpdatesSetting?) -> Bool {
        guard let setting else {
            menuItem.state = .off
            return false
        }
        menuItem.state = setting.automaticallyDownloadsUpdates ? .on : .off
        return setting.allowsAutomaticUpdates
    }

    static func toggle(_ setting: AutomaticUpdatesSetting?) {
        guard let setting, setting.allowsAutomaticUpdates else { return }
        setting.automaticallyDownloadsUpdates.toggle()
    }
}
