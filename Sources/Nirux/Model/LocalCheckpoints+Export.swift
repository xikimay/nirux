import Darwin
import Foundation

extension LocalCheckpoints {
    func exportCopy(_ id: UUID, to destination: URL, worktree: String) throws {
        let directories = O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
        guard destination.isFileURL, !destination.pathComponents.contains(".."),
              !destination.pathComponents.contains(where: { $0.lowercased() == ".git" }) else {
            throw Problem("Choose an empty folder outside the workspace and Git directories.")
        }
        let root = open(destination.path.expandingSystemAliases, directories)
        guard root >= 0 else { throw Self.fileError }
        defer { close(root) }
        guard flock(root, LOCK_EX | LOCK_NB) == 0 else { throw Problem("The export folder is in use.") }

        let protected = try Self.repositoryPaths(in: worktree) + [folder.deletingLastPathComponent().path]
        try Self.checkDestination(root, outside: protected)
        let saved = try manifest(id)
        guard saved.files.count <= limits.maxFilesPerCapture, saved.size <= limits.maxWorkspaceBytes else {
            throw Problem("This checkpoint exceeds the export limit.")
        }

        struct Created {
            let parent: String
            let name: String
            let inode: ino_t
            let isDirectory: Bool
        }
        var created: [Created] = []
        var folders = Set<String>()
        do {
            for file in saved.files {
                guard Self.safeFilePath(file.path) else { throw Problem("Unsafe path in checkpoint.") }
                guard file.size <= limits.maxSingleFileBytes else { throw Problem("Checkpoint file exceeds the size limit.") }
                guard let data = try payload(for: file, in: id) else { continue }
                var parent = "."
                var directory = dup(root)
                guard directory >= 0 else { throw Self.fileError }
                defer { close(directory) }
                let parts = file.path.components(separatedBy: "/")
                for name in parts.dropLast() {
                    let path = parent + "/" + name
                    let new = folders.insert(path).inserted
                    if new, mkdirat(directory, name, 0o700) != 0 { throw Self.fileError }
                    let child = openat(directory, name, directories)
                    guard child >= 0 else { throw Self.fileError }
                    close(directory)
                    directory = child
                    if new {
                        var info = stat()
                        guard fstat(child, &info) == 0 else { throw Self.fileError }
                        created.append(Created(parent: parent, name: name, inode: info.st_ino, isDirectory: true))
                    }
                    parent = path
                }
                let name = parts[parts.count - 1]
                let fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW_ANY | O_CLOEXEC, 0o400)
                guard fd >= 0 else { throw Self.fileError }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                var info = stat()
                guard fstat(fd, &info) == 0 else { throw Self.fileError }
                created.append(Created(parent: parent, name: name, inode: info.st_ino, isDirectory: false))
                try handle.write(contentsOf: data)
                try handle.close()
            }
        } catch {
            // Leave concurrent additions and replacements in the user's directory alone.
            for item in created.reversed() {
                let parent = openat(root, item.parent, directories)
                guard parent >= 0 else { continue }
                defer { close(parent) }
                var info = stat()
                if fstatat(parent, item.name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_ino == item.inode {
                    unlinkat(parent, item.name, item.isDirectory ? AT_REMOVEDIR : 0)
                }
            }
            throw error
        }
    }

    private static func checkDestination(_ root: Int32, outside paths: [String]) throws {
        let protected = try paths.map { path in
            var info = stat()
            guard stat(path, &info) == 0 else { throw fileError }
            return info
        }
        var directory = dup(root)
        guard directory >= 0 else { throw fileError }
        defer { close(directory) }
        while true {
            var info = stat(), parentInfo = stat()
            guard fstat(directory, &info) == 0, fstatat(directory, "..", &parentInfo, 0) == 0 else { throw fileError }
            guard !protected.contains(where: { $0.st_dev == info.st_dev && $0.st_ino == info.st_ino }) else {
                throw Problem("Choose a folder outside the workspace, Git directories and checkpoint store.")
            }
            if info.st_dev == parentInfo.st_dev, info.st_ino == parentInfo.st_ino { break }
            let parent = openat(directory, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard parent >= 0 else { throw fileError }
            close(directory)
            directory = parent
        }
        let fd = dup(root)
        guard fd >= 0 else { throw fileError }
        guard let entries = fdopendir(fd) else {
            let error = fileError
            close(fd)
            throw error
        }
        defer { closedir(entries) }
        errno = 0
        while let entry = readdir(entries) {
            let isDot = withUnsafeBytes(of: entry.pointee.d_name) { name in
                name[0] == 46 && (name[1] == 0 || (name[1] == 46 && name[2] == 0))
            }
            guard isDot else { throw Problem("Choose an empty folder for the export.") }
        }
        if errno != 0 { throw fileError }
    }

}
