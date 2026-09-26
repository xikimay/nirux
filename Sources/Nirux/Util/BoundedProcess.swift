import Darwin
import Foundation

struct BoundedProcessResult: Sendable {
    let standardOutput: Data
    /// Empty unless the run was asked to capture standard error.
    let standardError: Data
    let terminationStatus: Int32
}

enum BoundedProcess {
    static func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        timeout: TimeInterval = 30,
        captureStandardError: Bool = false
    ) -> BoundedProcessResult? {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return nil
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL

        let output = Pipe()
        let errorOutput = captureStandardError ? Pipe() : nil
        let didTerminate = DispatchSemaphore(value: 0)
        process.standardOutput = output
        process.standardError = errorOutput ?? FileHandle.nullDevice
        process.terminationHandler = { _ in
            didTerminate.signal()
        }

        do {
            try process.run()
        } catch {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            try? errorOutput?.fileHandleForReading.close()
            try? errorOutput?.fileHandleForWriting.close()
            return nil
        }
        try? output.fileHandleForWriting.close()
        try? errorOutput?.fileHandleForWriting.close()

        guard let data = drain(
            [output, errorOutput].compactMap { $0 },
            from: process,
            didTerminate: didTerminate,
            timeout: timeout
        ) else { return nil }
        return BoundedProcessResult(
            standardOutput: data[0],
            standardError: data.count > 1 ? data[1] : Data(),
            terminationStatus: process.terminationStatus
        )
    }

    /// Caps what is still read once the process has exited. Its own output
    /// is already buffered by then (one pipe buffer at most per pipe), so
    /// anything past that comes from descendants writing to inherited pipes.
    private static let postExitReadLimit = 1 << 20

    private static let discardQueue = DispatchQueue(
        label: "BoundedProcess.discard",
        qos: .utility
    )

    /// Reads every pipe until EOF, polling them together so a child that
    /// fills one pipe while another is being read can never stall.
    private static func drain(
        _ pipes: [Pipe],
        from process: Process,
        didTerminate: DispatchSemaphore,
        timeout: TimeInterval
    ) -> [Data]? {
        let readHandles = pipes.map(\.fileHandleForReading)
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var data = [Data](repeating: Data(), count: readHandles.count)
        var openIndices = Array(readHandles.indices)
        var hasExited = false
        var postExitBytes = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        func fail() -> [Data]? {
            // After exit the semaphore is spent and the pid may be reused.
            if !hasExited {
                terminate(process, didTerminate: didTerminate)
            }
            for handle in readHandles {
                try? handle.close()
            }
            return nil
        }

        while !openIndices.isEmpty {
            if !hasExited, didTerminate.wait(timeout: .now()) == .success {
                hasExited = true
            }
            let waitMilliseconds: Int32
            if hasExited {
                // Take only what is already buffered; waiting for EOF would
                // wait on descendants (a hook's background job, say).
                guard postExitBytes < postExitReadLimit else { break }
                waitMilliseconds = 0
            } else {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { return fail() }
                waitMilliseconds = Int32(min(max(remaining * 1_000, 1), 50))
            }

            var descriptorStates = openIndices.map { index in
                pollfd(
                    fd: readHandles[index].fileDescriptor,
                    events: Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0
                )
            }
            let pollResult = Darwin.poll(
                &descriptorStates,
                nfds_t(descriptorStates.count),
                waitMilliseconds
            )
            if pollResult < 0 {
                if errno == EINTR { continue }
                return fail()
            }
            guard pollResult > 0 else {
                if hasExited { break }
                continue
            }

            guard let bytesRead = readReadyPipes(
                descriptorStates,
                openIndices: &openIndices,
                into: &data,
                buffer: &buffer
            ) else { return fail() }
            if hasExited { postExitBytes += bytesRead }
        }

        if !hasExited {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0,
                  didTerminate.wait(timeout: .now() + remaining) == .success
            else { return fail() }
        }
        for index in readHandles.indices {
            if openIndices.contains(index) {
                discardUntilEndOfFile(readHandles[index])
            } else {
                try? readHandles[index].close()
            }
        }
        return data
    }

    /// Reads once from each pipe `poll` reported ready, dropping pipes at
    /// EOF. Returns the bytes read, or nil on a read error.
    private static func readReadyPipes(
        _ descriptorStates: [pollfd],
        openIndices: inout [Int],
        into data: inout [Data],
        buffer: inout [UInt8]
    ) -> Int? {
        var totalBytesRead = 0
        var reachedEnd: Set<Int> = []
        for (slot, index) in openIndices.enumerated()
        where descriptorStates[slot].revents != 0 {
            let descriptor = descriptorStates[slot].fd
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if bytesRead > 0 {
                data[index].append(contentsOf: buffer[..<bytesRead])
                totalBytesRead += bytesRead
            } else if bytesRead == 0 {
                reachedEnd.insert(index)
            } else if errno != EINTR {
                return nil
            }
        }
        openIndices.removeAll { reachedEnd.contains($0) }
        return totalBytesRead
    }

    /// Keeps reading a pipe that descendants still hold open, so their
    /// writes never fail with SIGPIPE, without making the caller wait.
    private static func discardUntilEndOfFile(_ handle: FileHandle) {
        let descriptor = handle.fileDescriptor
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: discardQueue
        )
        // The handler retains the source until it cancels itself at EOF.
        source.setEventHandler {
            var scratch = [UInt8](repeating: 0, count: 16 * 1024)
            let bytesRead = scratch.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if bytesRead == 0 || (bytesRead < 0 && errno != EINTR) {
                source.cancel()
            }
        }
        source.setCancelHandler {
            try? handle.close()
        }
        source.resume()
    }

    private static func terminate(
        _ process: Process,
        didTerminate: DispatchSemaphore
    ) {
        if didTerminate.wait(timeout: .now()) == .success {
            return
        }
        process.terminate()
        if didTerminate.wait(timeout: .now() + 0.25) == .timedOut {
            Darwin.kill(process.processIdentifier, SIGKILL)
            _ = didTerminate.wait(timeout: .now() + 1)
        }
    }
}
