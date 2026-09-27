import Foundation

/// Reads a growing Claude transcript incrementally into its usage: each
/// read resumes where the previous one stopped, keeps an unfinished last
/// line for the next, and starts over when the file is replaced or
/// truncated. Memory stays bounded by the chunk size and the longest line
/// it will hold (longer lines are skipped whole). Not thread-safe — one
/// owner, off the main thread (see `ClaudeUsageFollower`).
struct ClaudeTranscriptReader {
    let path: String
    private(set) var parser = ClaudeTranscriptUsageParser()
    private var offset: off_t = 0
    private var fileIdentity: FileIdentity?
    private var partialLine = Data()
    private var isSkippingLine = false

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    static let defaultChunkSize = 256 * 1024
    /// A line longer than this is skipped: a response carrying a huge tool
    /// input loses its counts, the next response restores the context.
    static let defaultMaxLineBytes = 8 * 1024 * 1024
    /// Bytes one read may consume, so catching up on a long transcript
    /// doesn't hold the queue other columns share.
    static let defaultReadBudget = 16 * 1024 * 1024

    let chunkSize: Int
    let maxLineBytes: Int

    var usage: ClaudeSessionUsage { parser.usage }

    init(path: String, chunkSize: Int = defaultChunkSize, maxLineBytes: Int = defaultMaxLineBytes) {
        self.path = path
        self.chunkSize = max(1, chunkSize)
        self.maxLineBytes = maxLineBytes
    }

    /// Consume what was appended since the last read, at most `budget`
    /// bytes. Returns false when more is left to read. A missing or
    /// unreadable file leaves the usage as it was.
    mutating func readAppended(budget: Int = defaultReadBudget) -> Bool {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return true }

        let identity = FileIdentity(device: info.st_dev, inode: info.st_ino)
        if identity != fileIdentity || info.st_size < offset {
            self = ClaudeTranscriptReader(path: path, chunkSize: chunkSize, maxLineBytes: maxLineBytes)
            fileIdentity = identity
        }

        let end = min(info.st_size, offset + off_t(max(0, budget)))
        guard offset < end else { return offset >= info.st_size }
        var chunk = Data(count: chunkSize)
        while offset < end {
            let wanted = Int(min(off_t(chunkSize), end - offset))
            let count = chunk.withUnsafeMutableBytes { buffer in
                pread(fd, buffer.baseAddress, wanted, offset)
            }
            guard count > 0 else { return true } // shrank under us, or EIO: retry next read
            offset += off_t(count)
            consume(chunk.prefix(count))
        }
        return offset >= info.st_size
    }

    private mutating func consume(_ bytes: Data) {
        var start = bytes.startIndex
        while let newline = bytes[start...].firstIndex(of: 0x0A) {
            let piece = bytes[start..<newline]
            if isSkippingLine {
                isSkippingLine = false
            } else if partialLine.count + piece.count <= maxLineBytes {
                if partialLine.isEmpty {
                    parser.consume(line: piece)
                } else {
                    partialLine.append(piece)
                    parser.consume(line: partialLine)
                }
            }
            if !partialLine.isEmpty { partialLine = Data() }
            start = bytes.index(after: newline)
        }
        let rest = bytes[start...]
        guard !isSkippingLine, !rest.isEmpty else { return }
        if partialLine.count + rest.count > maxLineBytes {
            partialLine = Data()
            isSkippingLine = true
        } else {
            partialLine.append(rest)
        }
    }
}
