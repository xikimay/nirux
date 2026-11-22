import Foundation
import ImageIO
import UniformTypeIdentifiers

struct BrowserCapture: Codable {
    static let limit = 20

    let url: String
    let timestamp: Date
    let viewport: CGSize
    let consoleErrorCount: Int

    init(url: URL?, timestamp: Date = Date(), viewport: CGSize, consoleErrorCount: Int) {
        if let url, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
           ["http", "https"].contains(parts.scheme?.lowercased() ?? "") {
            parts.user = nil
            parts.password = nil
            parts.query = nil
            parts.fragment = nil
            self.url = BrowserDiagnostics.sanitized(parts.string ?? "")
        } else {
            self.url = url?.scheme.map { BrowserDiagnostics.sanitized($0) + ":" } ?? ""
        }
        self.timestamp = timestamp
        self.viewport = viewport
        self.consoleErrorCount = consoleErrorCount
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
        guard let id = UUID(uuidString: workspaceID) else { throw CocoaError(.fileWriteInvalidFileName) }
        let manager = FileManager.default
        let captures = stateDirectory.appendingPathComponent("captures", isDirectory: true)
        let folder = captures.appendingPathComponent(id.uuidString, isDirectory: true)
        for directory in [captures, folder] {
            if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw Self.fileError }
            let fd = open(directory.path, O_DIRECTORY | O_NOFOLLOW | O_RDONLY | O_CLOEXEC)
            guard fd >= 0 else { throw Self.fileError }
            defer { close(fd) }
            guard fchmod(fd, 0o700) == 0 else { throw Self.fileError }
        }

        let files = try manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("capture-") && $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let name = "capture-\(Int64(Date().timeIntervalSince1970 * 1_000_000))-\(UUID().uuidString).png"
        let target = folder.appendingPathComponent(name)
        let staging = folder.appendingPathComponent(".capture.tmp")
        let data = try png(image)
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
