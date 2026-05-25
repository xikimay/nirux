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
        shell.showUpdateAvailable(version: version)
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
        return true
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
