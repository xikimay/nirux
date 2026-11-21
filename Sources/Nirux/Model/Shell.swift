import Foundation

/// Shell programs, as a process or a terminal title names them.
enum Shell {
    static let names: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "mksh", "fish", "tcsh", "csh", "nu", "xonsh", "elvish"]
    /// The shells that take the `-i -l -c` Nirux starts commands with.
    static let launchable: Set<String> = ["zsh", "bash", "sh", "dash", "ksh", "tcsh", "fish"]

    /// `name` is a shell's, a login shell's ("-zsh") included.
    static func isShell(_ name: String) -> Bool {
        names.contains(name.hasPrefix("-") ? String(name.dropFirst()) : name)
    }

    /// PATH to pass to child shells — includes standard locations so login
    /// shells can find Homebrew, fnm, starship, etc. even on first launch
    /// after Gatekeeper. Computed once per process on first access (must be
    /// triggered from the parent — FileManager is not safe after fork).
    static let effectivePath: String = computeEffectivePath()

    private static func computeEffectivePath() -> String {
        let current = String(cString: getenv("PATH") ?? strdup(""))
        var paths = current.split(separator: ":").map(String.init)

        // Read /etc/paths and /etc/paths.d/* (same thing path_helper does)
        if let etcPaths = try? String(contentsOfFile: "/etc/paths", encoding: .utf8) {
            for line in etcPaths.split(separator: "\n") {
                let pathEntry = String(line).trimmingCharacters(in: .whitespaces)
                if !pathEntry.isEmpty && !paths.contains(pathEntry) { paths.append(pathEntry) }
            }
        }
        let pathsD = "/etc/paths.d"
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: pathsD) {
            for entry in entries.sorted() {
                if let content = try? String(contentsOfFile: "\(pathsD)/\(entry)", encoding: .utf8) {
                    for line in content.split(separator: "\n") {
                        let pathEntry = String(line).trimmingCharacters(in: .whitespaces)
                        if !pathEntry.isEmpty && !paths.contains(pathEntry) { paths.append(pathEntry) }
                    }
                }
            }
        }

        // Also ensure common user paths
        let home = String(cString: getenv("HOME") ?? strdup(""))
        let extras = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "\(home)/.local/bin",
            "\(home)/.bun/bin"
        ]
        for pathEntry in extras where !paths.contains(pathEntry) {
            paths.append(pathEntry)
        }

        return paths.joined(separator: ":")
    }
}
