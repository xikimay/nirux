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
}
