import Foundation

extension NiruxShellView {
    nonisolated static func currentClaudeMissionHook() -> Bool {
        PersistedSettings.effective(Persistence.load()?.settings).claudeMissionHook
    }
}
