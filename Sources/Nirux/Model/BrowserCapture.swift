import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct BrowserCapture: Codable, Equatable, Sendable {
    static let limit = 20
    static let maxScreenshotBytes = 25_000_000
    static let maxDiagnosticsBytes = 2_000_000
    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    enum ArtifactKind: String, Codable, Equatable, Sendable {
        case screenshot
        case diagnostics

        var pathExtension: String {
            switch self {
            case .screenshot: return "png"
            case .diagnostics: return "json"
            }
        }

        var maxBytes: Int {
            switch self {
            case .screenshot: return BrowserCapture.maxScreenshotBytes
            case .diagnostics: return BrowserCapture.maxDiagnosticsBytes
            }
        }
    }

    enum ArtifactCheck: Equatable, Sendable {
        case valid(URL)
        case missing
        case rejected
    }

    struct DiagnosticsSnapshot: Codable, Equatable, Sendable {
        let url: String
        let timestamp: Date
        let consoleErrorCount: Int
        let networkErrorCount: Int
        let events: [BrowserDiagnostics.Event]
    }

    let url: String
    let timestamp: Date
    let viewport: CGSize
    let consoleErrorCount: Int
    let networkErrorCount: Int

    init(
        url: URL?,
        timestamp: Date = Date(),
        viewport: CGSize,
        consoleErrorCount: Int,
        networkErrorCount: Int = 0
    ) {
        self.url = Self.sanitizedURL(url)
        self.timestamp = timestamp
        self.viewport = viewport
        self.consoleErrorCount = consoleErrorCount
        self.networkErrorCount = networkErrorCount
    }

    private enum CodingKeys: String, CodingKey {
        case url, timestamp, viewport, consoleErrorCount, networkErrorCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        viewport = try container.decode(CGSize.self, forKey: .viewport)
        consoleErrorCount = try container.decode(Int.self, forKey: .consoleErrorCount)
        networkErrorCount = try container.decodeIfPresent(Int.self, forKey: .networkErrorCount) ?? 0
    }

    static func sanitizedURL(_ url: URL?) -> String {
        if let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
           ["http", "https"].contains(parts.scheme?.lowercased() ?? "") {
            parts.user = nil
            parts.password = nil
            parts.query = nil
            parts.fragment = nil
            return BrowserDiagnostics.sanitized(parts.string ?? "")
        }
        return url?.scheme.map { BrowserDiagnostics.sanitized($0) + ":" } ?? ""
    }

    static func sanitizedURLString(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        if raw == "[redacted]" { return raw }
        return sanitizedURL(URL(string: raw))
    }

    /// Keep the metadata and pixels together when a user copies or deletes the PNG.
    private func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let description = String(decoding: try encoder.encode(self), as: UTF8.self)
        guard let writer = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(writer, image, [
            kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: description]
        ] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { throw CocoaError(.fileWriteUnknown) }
        return data as Data
    }

    @MainActor
    func save(_ image: CGImage, workspaceID: String, stateDirectory: URL) throws -> URL {
        let folder = try Self.prepareFolder(workspaceID: workspaceID, stateDirectory: stateDirectory)
        return try Self.writeRotatedFile(
            data: try png(image), prefix: "capture-", ext: "png", stagingName: ".capture.tmp", in: folder
        )
    }

    static func saveDiagnostics(
        _ snapshot: DiagnosticsSnapshot,
        workspaceID: String,
        stateDirectory: URL
    ) throws -> URL {
        let folder = try prepareFolder(workspaceID: workspaceID, stateDirectory: stateDirectory)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(snapshot)
        guard data.count <= maxDiagnosticsBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        return try writeRotatedFile(
            data: data, prefix: "diagnostics-", ext: "json", stagingName: ".diagnostics.tmp", in: folder
        )
    }

    /// Verifies that `path` stays strictly inside `<stateDirectory>/captures/<workspaceID>/`,
    /// with no symlinks, no path traversal, and a valid regular file for `kind`.
    static func checkArtifactPath(
        _ path: String,
        kind: ArtifactKind,
        workspaceID: String,
        stateDirectory: URL
    ) -> ArtifactCheck {
        guard let id = UUID(uuidString: workspaceID),
              path.hasPrefix("/"), !path.contains("\0") else { return .rejected }
        let rawComponents = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !rawComponents.contains(".."), !rawComponents.contains(".") else { return .rejected }

        let filename = (path as NSString).lastPathComponent
        guard !filename.isEmpty, !filename.hasPrefix("."), filename.utf8.count <= 255,
              (filename as NSString).pathExtension.lowercased() == kind.pathExtension else { return .rejected }

        let rawParent = (path as NSString).deletingLastPathComponent
        guard (rawParent as NSString).lastPathComponent == id.uuidString else { return .rejected }

        guard let canonicalState = stateDirectory.path.realPath else { return .rejected }
        let capturesPath = canonicalState + "/captures"
        let folderPath = capturesPath + "/" + id.uuidString

        for directory in [capturesPath, folderPath] {
            let fd = open(directory, O_DIRECTORY | O_NOFOLLOW | O_RDONLY | O_CLOEXEC)
            if fd < 0 {
                if errno == ENOENT, lexicalMatchesFolder(rawParent, folderPath: folderPath, stateDirectory: stateDirectory, id: id) {
                    return .missing
                }
                return .rejected
            }
            close(fd)
        }

        var parentStat = stat()
        guard lstat(rawParent, &parentStat) == 0,
              (parentStat.st_mode & S_IFMT) == S_IFDIR,
              rawParent.realPath == folderPath else { return .rejected }

        var rawStat = stat()
        if lstat(path, &rawStat) != 0 {
            return errno == ENOENT ? .missing : .rejected
        }
        guard (rawStat.st_mode & S_IFMT) == S_IFREG,
              let canonicalFile = path.realPath,
              canonicalFile == folderPath + "/" + filename else { return .rejected }

        let fd = open(canonicalFile, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return .rejected }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var openedStat = stat()
        guard fstat(fd, &openedStat) == 0,
              (openedStat.st_mode & S_IFMT) == S_IFREG,
              openedStat.st_dev == rawStat.st_dev,
              openedStat.st_ino == rawStat.st_ino,
              openedStat.st_size > 0,
              openedStat.st_size <= kind.maxBytes else { return .rejected }

        guard verifyArtifactContents(handle: handle, kind: kind) else { return .rejected }
        return .valid(URL(fileURLWithPath: canonicalFile))
    }

    private static func lexicalMatchesFolder(_ rawParent: String, folderPath: String, stateDirectory: URL, id: UUID) -> Bool {
        let normalizedRaw = URL(fileURLWithPath: rawParent.expandingSystemAliases).standardizedFileURL.path
        let normalizedState = URL(fileURLWithPath: stateDirectory.path.expandingSystemAliases).standardizedFileURL.path
        return normalizedRaw == folderPath || normalizedRaw == normalizedState + "/captures/" + id.uuidString
    }

    private static func verifyArtifactContents(handle: FileHandle, kind: ArtifactKind) -> Bool {
        switch kind {
        case .screenshot:
            guard let header = try? handle.read(upToCount: pngSignature.count),
                  header.elementsEqual(pngSignature) else { return false }
            return true
        case .diagnostics:
            guard let data = try? handle.read(upToCount: maxDiagnosticsBytes + 1),
                  data.count <= maxDiagnosticsBytes else { return false }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return (try? decoder.decode(DiagnosticsSnapshot.self, from: data)) != nil
        }
    }

    private static func prepareFolder(workspaceID: String, stateDirectory: URL) throws -> URL {
        guard let id = UUID(uuidString: workspaceID) else { throw CocoaError(.fileWriteInvalidFileName) }
        let captures = stateDirectory.appendingPathComponent("captures", isDirectory: true)
        let folder = captures.appendingPathComponent(id.uuidString, isDirectory: true)
        for directory in [captures, folder] {
            if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw Self.fileError }
            let fd = open(directory.path, O_DIRECTORY | O_NOFOLLOW | O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { throw Self.fileError }
            defer { close(fd) }
            guard fchmod(fd, 0o700) == 0 else { throw Self.fileError }
        }
        return folder
    }

    private static func writeRotatedFile(
        data: Data,
        prefix: String,
        ext: String,
        stagingName: String,
        in folder: URL
    ) throws -> URL {
        let manager = FileManager.default
        let files = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == ext }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let name = "\(prefix)\(Int64(Date().timeIntervalSince1970 * 1_000_000))-\(UUID().uuidString).\(ext)"
        let target = folder.appendingPathComponent(name)
        let staging = folder.appendingPathComponent(stagingName)
        if unlink(staging.path) != 0 && errno != ENOENT { throw Self.fileError }
        let fd = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Self.fileError }
        defer { unlink(staging.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
        for old in files.dropLast(Self.limit - 1) {
            guard unlink(old.path) == 0 else { throw Self.fileError }
        }
        try manager.moveItem(at: staging, to: target)
        return target
    }

    private static var fileError: NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
}
