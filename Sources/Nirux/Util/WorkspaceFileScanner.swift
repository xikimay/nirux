import Foundation

/// Lists files under a directory for the editor's file picker. Skips heavy /
/// generated directories (node_modules, .build, .git, …) so the scan stays
/// fast even on chunky monorepos.
enum WorkspaceFileScanner {

    /// Directory names to never descend into.
    static let skipDirs: Set<String> = [
        ".git", ".build", ".swiftpm", ".next", ".nuxt", ".turbo",
        "node_modules", "build", "dist", "target", "out", "bin", "obj",
        "Pods", "DerivedData", "vendor", ".venv", "venv", "__pycache__",
        ".idea", ".vscode", ".gradle", "coverage", ".cache", ".parcel-cache"
    ]

    /// Filenames to skip outright.
    static let skipFiles: Set<String> = [
        ".DS_Store"
    ]

    /// Hard caps to keep the picker snappy on huge trees.
    static let maxFiles = 5000
    static let maxDepth = 8

    /// Returns relative paths (POSIX-style) under `cwd`, sorted by name.
    static func scan(cwd: String) -> [String] {
        var results: [String] = []
        results.reserveCapacity(512)
        scanRecursive(absRoot: cwd, relativePath: "", depth: 0, results: &results)
        results.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return results
    }

    private static func scanRecursive(
        absRoot: String,
        relativePath: String,
        depth: Int,
        results: inout [String]
    ) {
        guard depth <= maxDepth, results.count < maxFiles else { return }

        let absDir = relativePath.isEmpty
            ? absRoot
            : (absRoot as NSString).appendingPathComponent(relativePath)

        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: absDir) else { return }

        for entry in entries {
            if entry.hasPrefix(".") && depth > 0 {
                // Skip dotfiles deeper than root to avoid noise (.git/, .vscode/, …).
                // At root we already filter via skipDirs, but allow visible dotfiles
                // there if they survive the filter.
            }
            if skipFiles.contains(entry) { continue }

            let absPath = (absDir as NSString).appendingPathComponent(entry)
            let relPath = relativePath.isEmpty ? entry : "\(relativePath)/\(entry)"

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: absPath, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                if skipDirs.contains(entry) { continue }
                if entry.hasPrefix(".") { continue }
                scanRecursive(absRoot: absRoot, relativePath: relPath, depth: depth + 1, results: &results)
            } else {
                results.append(relPath)
                if results.count >= maxFiles { return }
            }
        }
    }
}
