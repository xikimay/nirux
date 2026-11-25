import AppKit
import Sparkle

// MARK: - Sparkle Auto-Update

extension NiruxApp {
    func setupUpdater() {
        // Nor is a shutdown's or a restart's: the Mac's update at night.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.quitIsUsers = false }
        }
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
        let build = Int(item.versionString) ?? 0
        Task { @MainActor in
            self.isManualUpdateCheck = false
            self.showUpdateAvailable(build: build, installNow: nil)
        }
    }

    /// Downloaded, the update installs on quit; Nirux also takes it from
    /// Sparkle, so the status bar's popover installs it at once, without
    /// Sparkle's alert. Sparkle then looks for no newer build until it
    /// installs. Sparkle calls it on the main thread.
    nonisolated func updater(
        _ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let build = Int(item.versionString) ?? 0
        // Sparkle's, called back on the main thread like this method.
        nonisolated(unsafe) let installNow = immediateInstallHandler
        return MainActor.assumeIsolated {
            showUpdateAvailable(build: build, installNow: installNow)
            return true
        }
    }

    /// The quit that follows isn't the user's: a relaunch resumes the work
    /// that was going on (`RelaunchResume`). Sparkle calls it on the main
    /// thread, before it terminates the app.
    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { self.quitIsUsers = false }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in
            self.isManualUpdateCheck = false
        }
    }

    /// `installNow`: Sparkle's, once the update is downloaded; without it,
    /// Install and Relaunch goes through Sparkle's alert.
    func showUpdateAvailable(build: Int, installNow: (() -> Void)?) {
        shell?.showAvailableUpdate(AvailableUpdate(build: build, isReady: installNow != nil) { [weak self] in
            guard let self else { return }
            if let installNow {
                // A relaunch cancelled earlier (unsaved edits, a queue) left
                // the quit marked as the user's.
                quitIsUsers = false
                installNow()
            } else if updaterController?.updater.sessionInProgress == true {
                shell?.showToast("The update is still downloading.")
            } else {
                updaterController?.checkForUpdates(nil)
            }
        })
    }

    @objc func installUpdate(_ sender: Any?) {
        manualCheckForUpdates(sender)
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
        // Sparkle, which handed over the downloaded update, checks nothing
        // more until it installs.
        if let shell, shell.availableUpdate?.isReady == true { return shell.showUpdatePopover() }
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
