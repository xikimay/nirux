import Foundation

extension MergeQueue.Files {
    private func withJournalFile<T>(_ url: URL, read: (FileHandle, stat) -> T) -> T? {
        let root = open(stateDirectory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard root >= 0 else { return nil }
        defer { close(root) }
        let path = url.pathComponents.dropFirst(stateDirectory.pathComponents.count).joined(separator: "/")
        let fd = openat(root, path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return read(handle, info)
    }

    private var journalFiles: [URL] { [journal, MergeQueue.Journal(url: journal).previousURL] }

    var hasJournal: Bool { journalFiles.contains { withJournalFile($0) { _, _ in true } == true } }

    func recentEntries(limit: Int = 200) -> [MergeQueue.Journal.Line] {
        var bytesLeft = 256 * 1024
        var linesLeft = limit
        var entries: [MergeQueue.Journal.Line] = []
        var currentInode: ino_t?
        let decoder = JSONDecoder()
        for file in journalFiles where bytesLeft > 0 && linesLeft > 0 {
            withJournalFile(file) { handle, info in
                // Another process may rotate the file between the two opens.
                guard info.st_ino != currentInode else { return }
                currentInode = info.st_ino
                let count = min(Int(info.st_size), bytesLeft)
                guard count > 0 else { return }
                let offset = Int(info.st_size) - count
                guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
                      let data = try? handle.read(upToCount: count) else { return }
                bytesLeft -= count
                // Only newline-terminated records. When starting mid-file, the first newline
                // also ends a record whose beginning may be outside the budget.
                var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast()
                if offset > 0 { lines = lines.dropFirst() }
                let recent = lines.suffix(linesLeft)
                linesLeft -= recent.count
                entries.insert(contentsOf: recent.compactMap { try? decoder.decode(MergeQueue.Journal.Line.self, from: $0) }, at: 0)
            }
        }
        return entries
    }
}

extension MergeQueue {
    struct JournalSnapshot: Sendable {
        let title: String
        let status: String
        let link: URL?
        let entriesText: String
        var copyText: String {
            [title, status, link?.absoluteString, entriesText].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        }

        init(repository: GitHubRepository, dryRun: Bool, engine: Engine?, saved: SavedQueue?, entries: [Journal.Line]) {
            title = Self.displayText("\(repository.ownerAndName) · Merge Queue Journal" + (dryRun ? " · Dry Run" : ""))
            let saved = saved.flatMap { GitHubRepository(ownerAndName: $0.repository) == repository && $0.dryRun == dryRun ? $0 : nil }
            let reason: StopReason?
            let number: Int?
            if let engine {
                if case .stopped(let cause) = engine.phase { reason = cause } else { reason = nil }
                number = engine.currentEntry?.number
            } else {
                reason = saved?.status == .stopped ? saved?.stopReason : nil
                number = saved?.current.flatMap { saved?.entries[safe: $0]?.number }
            }
            let lastStop = entries.last.flatMap { $0.result.hasPrefix("Stopped: ") ? $0 : nil }
            status = Self.displayText(engine?.statusText ?? saved?.statusText ?? lastStop?.result ?? "No saved queue status")
            if let reason {
                link = reason.url.flatMap { Self.stopURL($0, repository: repository) }
                    ?? Self.pullRequest(number, repository: repository, checks: reason.kind == .checks)
            } else if engine == nil, saved == nil {
                link = Self.pullRequest(lastStop?.pr, repository: repository, checks: false)
            } else {
                link = nil
            }
            entriesText = entries.map { line in
                [line.time, line.pr.map { "#\($0)" }, line.step, line.command, line.result]
                    .compactMap { $0 }.map(Self.displayText).joined(separator: " · ")
            }.joined(separator: "\n")
        }

        private static func displayText(_ text: String) -> String {
            let masked = Journal.redacted(text)
            return HistorySearch.holdsSecret(masked) ? "[redacted]" : masked
        }

        private static func pullRequest(_ number: Int?, repository: GitHubRepository, checks: Bool) -> URL? {
            guard let number, number > 0 else { return nil }
            let address = "https://\(repository.host)/\(repository.ownerAndName)/pull/\(number)"
            return stopURL(checks ? address + "/checks" : address, repository: repository)
        }

        static func stopURL(_ address: String, repository: GitHubRepository) -> URL? {
            guard var url = URLComponents(string: address), url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == repository.host, url.port == nil, url.user == nil, url.password == nil,
                  GitHubRepository.isValid(ownerAndName: repository.ownerAndName),
                  displayText(repository.ownerAndName) == repository.ownerAndName else { return nil }
            let parts = url.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count >= 5, parts[0].isEmpty, parts[1].lowercased() == repository.owner,
                  parts[2].lowercased() == repository.name else { return nil }
            let route = parts.dropFirst(3).joined(separator: "/")
            let routes = [
                #"^pull/[1-9][0-9]*(/checks(/[1-9][0-9]*)?)?$"#,
                #"^(checks|runs)/[1-9][0-9]*$"#,
                #"^actions/runs/[1-9][0-9]*(/(job|attempts)/[1-9][0-9]*)?$"#
            ]
            guard routes.contains(where: { route.range(of: $0, options: .regularExpression) != nil }) else { return nil }
            let checkID = url.queryItems?.first { $0.name == "check_run_id" }?.value
            url.query = nil
            if route.hasPrefix("pull/"), route.hasSuffix("/checks"), let checkID,
               checkID.range(of: #"^[1-9][0-9]*$"#, options: .regularExpression) != nil {
                url.queryItems = [URLQueryItem(name: "check_run_id", value: checkID)]
            }
            url.fragment = nil
            return url.url
        }
    }
}
