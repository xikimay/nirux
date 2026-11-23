import Foundation

/// What a transcript reader hands each whole line to.
public protocol TranscriptLineParser {
    init()
    mutating func consume(line: Data)
}

/// Reads a growing transcript incrementally, a whole line at a time: each
/// read resumes where the previous one stopped, keeps an unfinished last
/// line for the next, and starts over with the parser it began with when
/// the file is replaced or truncated, from its start or its last
/// `tailBytes`. Memory stays bounded by the chunk size and the longest
/// line it will hold (longer lines are skipped whole). A link or a
/// non-regular file is never read. Not thread-safe: one owner.
public struct TranscriptLineReader<Parser: TranscriptLineParser> {
    public let path: String
    public let tailBytes: Int?
    public let chunkSize: Int
    public let maxLineBytes: Int
    public var parser: Parser
    private let initialParser: Parser
    private var offset: off_t = 0
    private var fileIdentity: FileIdentity?
    private var partialLine = Data()
    private var isSkippingLine = false

    private struct FileIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    public static var defaultChunkSize: Int { 256 * 1024 }
    /// A line longer than this is skipped: a response carrying a huge tool
    /// input loses its counts, the next response restores the context.
    public static var defaultMaxLineBytes: Int { 8 * 1024 * 1024 }
    /// Bytes one read may consume, so catching up on a long transcript
    /// doesn't hold a queue other readers share.
    public static var defaultReadBudget: Int { 16 * 1024 * 1024 }

    public init(
        path: String,
        parser: Parser = Parser(),
        tailBytes: Int? = nil,
        chunkSize: Int = defaultChunkSize,
        maxLineBytes: Int = defaultMaxLineBytes
    ) {
        self.path = path
        self.parser = parser
        initialParser = parser
        self.tailBytes = tailBytes
        self.chunkSize = max(1, chunkSize)
        self.maxLineBytes = maxLineBytes
    }

    /// Consume what was appended since the last read, at most `budget`
    /// bytes. Returns false when more is left to read. A missing or
    /// unreadable file leaves the parser as it was.
    public mutating func readAppended(budget: Int = defaultReadBudget) -> Bool {
        var budget = budget
        return readAppended(budget: &budget)
    }

    /// The same, taking the bytes it reads off `budget`: readers that share
    /// one stop together.
    public mutating func readAppended(budget: inout Int) -> Bool {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return true }

        let identity = FileIdentity(device: info.st_dev, inode: info.st_ino)
        if identity != fileIdentity || info.st_size < offset {
            self = TranscriptLineReader(
                path: path, parser: initialParser, tailBytes: tailBytes, chunkSize: chunkSize, maxLineBytes: maxLineBytes
            )
            fileIdentity = identity
            if let tailBytes, info.st_size > off_t(tailBytes) {
                offset = info.st_size - off_t(tailBytes)
                // The line it starts in.
                isSkippingLine = true
            }
        }

        let start = offset
        defer { budget -= Int(offset - start) }
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
            // Frees what JSONSerialization autoreleased: a catch-up would
            // otherwise hold every parsed line until its read ends.
            autoreleasepool { consume(chunk.prefix(count)) }
        }
        return offset >= info.st_size
    }

    private mutating func consume(_ bytes: Data) {
        var start = bytes.startIndex
        while let newline = bytes.firstIndex(of: 0x0A, from: start) {
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

extension TranscriptLineReader: Sendable where Parser: Sendable {}
