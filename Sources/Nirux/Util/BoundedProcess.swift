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
        environment: [String: String] = [:],
        timeout: TimeInterval = 30,
        captureStandardError: Bool = false,
        maxStandardOutputBytes: Int? = nil
    ) -> BoundedProcessResult? {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return nil
        }
        // Past 4,096 arguments `Process.run()` raises an Objective-C
        // exception, which Swift can't catch: the app would crash.
        guard arguments.count < maxArguments else { return nil }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment
                .merging(environment) { _, override in override }
        }

        let output = Pipe()
        let errorOutput = captureStandardError ? Pipe() : nil
        // Keep terminals forked meanwhile (forkpty) from inheriting a write
        // end and holding the pipe open for their whole lifetime.
        for pipe in [output, errorOutput].compactMap({ $0 }) {
            setCloseOnExec(pipe)
        }
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
        PollingDiagnostics.recordLaunch(executableURL: executableURL)
        try? output.fileHandleForWriting.close()
        try? errorOutput?.fileHandleForWriting.close()

        guard let (standardOutput, standardError) = drain(
            output: output,
            errorOutput: errorOutput,
            from: process,
            didTerminate: didTerminate,
            timeout: timeout,
            maxStandardOutputBytes: maxStandardOutputBytes
        ) else { return nil }
        return BoundedProcessResult(
            standardOutput: standardOutput,
            standardError: standardError,
            terminationStatus: process.terminationStatus
        )
    }

    static let maxArguments = 4_096

    /// Darwin's FIONREAD, `_IOR('f', 127, int)`; Swift does not import it.
    private static let bytesBufferedRequest: UInt = 0x4004_667F

    /// How much a descendant still holding a pipe may write, after the
    /// process exits, before the pipe is closed on it. Enough for a hook's
    /// background job, not for a runaway writer to burn CPU indefinitely.
    private static let descendantDiscardLimit = 8 << 20

    private static let discardQueue = DispatchQueue(
        label: "BoundedProcess.discard",
        qos: .utility
    )

    private static func setCloseOnExec(_ pipe: Pipe) {
        for descriptor in [
            pipe.fileHandleForReading.fileDescriptor,
            pipe.fileHandleForWriting.fileDescriptor
        ] {
            _ = fcntl(descriptor, F_SETFD, fcntl(descriptor, F_GETFD) | FD_CLOEXEC)
        }
    }

    /// Reads every pipe until EOF, polling them together so a child that
    /// fills one pipe while another is being read can never stall. Once the
    /// process has exited, only what it left buffered is taken: later bytes
    /// come from descendants still holding the pipe, and waiting for their
    /// EOF would wait on them (a hook's background job, say). Standard
    /// output past `maxStandardOutputBytes` stops the process, as a timeout
    /// does.
    private static func drain(
        output: Pipe,
        errorOutput: Pipe?,
        from process: Process,
        didTerminate: DispatchSemaphore,
        timeout: TimeInterval,
        maxStandardOutputBytes: Int?
    ) -> (standardOutput: Data, standardError: Data)? {
        let readHandles = [output, errorOutput].compactMap { $0?.fileHandleForReading }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var data = [Data](repeating: Data(), count: readHandles.count)
        var openIndices = Array(readHandles.indices)
        var hasExited = false
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        func isOverLimit() -> Bool {
            guard let maxStandardOutputBytes else { return false }
            return data[0].count > maxStandardOutputBytes
        }

        func fail() -> (standardOutput: Data, standardError: Data)? {
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
            if didTerminate.wait(timeout: .now()) == .success {
                hasExited = true
                guard readLeftovers(
                    readHandles,
                    openIndices: &openIndices,
                    into: &data,
                    buffer: &buffer
                ), !isOverLimit() else { return fail() }
                break
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return fail() }

            var descriptorStates = openIndices.map { index in
                pollfd(
                    fd: readHandles[index].fileDescriptor,
                    events: Int16(POLLIN | POLLHUP | POLLERR),
                    revents: 0
                )
            }
            let waitMilliseconds = Int32(min(max(remaining * 1_000, 1), 50))
            let pollResult = Darwin.poll(
                &descriptorStates,
                nfds_t(descriptorStates.count),
                waitMilliseconds
            )
            if pollResult < 0 {
                if errno == EINTR { continue }
                return fail()
            }
            guard pollResult > 0 else { continue }

            guard readReadyPipes(
                descriptorStates,
                openIndices: &openIndices,
                into: &data,
                buffer: &buffer
            ), !isOverLimit() else { return fail() }
        }

        if !hasExited {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0,
                  didTerminate.wait(timeout: .now() + remaining) == .success
            else { return fail() }
        }
        for index in readHandles.indices {
            if openIndices.contains(index) {
                discardDescendantOutput(readHandles[index])
            } else {
                try? readHandles[index].close()
            }
        }
        return (data[0], data.count > 1 ? data[1] : Data())
    }

    /// Reads once from each pipe `poll` reported ready, dropping pipes at
    /// EOF. Returns false on a read error.
    private static func readReadyPipes(
        _ descriptorStates: [pollfd],
        openIndices: inout [Int],
        into data: inout [Data],
        buffer: inout [UInt8]
    ) -> Bool {
        var reachedEnd: Set<Int> = []
        for (slot, index) in openIndices.enumerated()
        where descriptorStates[slot].revents != 0 {
            let descriptor = descriptorStates[slot].fd
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if bytesRead > 0 {
                data[index].append(contentsOf: buffer[..<bytesRead])
            } else if bytesRead == 0 {
                reachedEnd.insert(index)
            } else if errno != EINTR {
                return false
            }
        }
        openIndices.removeAll { reachedEnd.contains($0) }
        return true
    }

    /// After exit: reads exactly the bytes each pipe held at that moment,
    /// then drops pipes that are at EOF (readable, nothing buffered).
    /// Returns false on a read error.
    private static func readLeftovers(
        _ readHandles: [FileHandle],
        openIndices: inout [Int],
        into data: inout [Data],
        buffer: inout [UInt8]
    ) -> Bool {
        var reachedEnd: Set<Int> = []
        for index in openIndices {
            let descriptor = readHandles[index].fileDescriptor
            var buffered: Int32 = 0
            guard ioctl(descriptor, bytesBufferedRequest, &buffered) == 0 else { return false }
            var remaining = Int(buffered)
            while remaining > 0 {
                let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, min(remaining, bytes.count))
                }
                if bytesRead > 0 {
                    data[index].append(contentsOf: buffer[..<bytesRead])
                    remaining -= bytesRead
                } else if bytesRead == 0 {
                    break
                } else if errno != EINTR {
                    return false
                }
            }
            var state = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
            if Darwin.poll(&state, 1, 0) > 0,
               ioctl(descriptor, bytesBufferedRequest, &buffered) == 0,
               buffered == 0 {
                reachedEnd.insert(index)
            }
        }
        openIndices.removeAll { reachedEnd.contains($0) }
        return true
    }

    /// Keeps reading, and dropping, what descendants still write to a pipe
    /// after the process exits, so their writes don't fail with SIGPIPE,
    /// without making the caller wait. Past `descendantDiscardLimit` the
    /// pipe is closed so a runaway writer cannot spin forever.
    private static func discardDescendantOutput(_ handle: FileHandle) {
        let descriptor = handle.fileDescriptor
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor,
            queue: discardQueue
        )
        var scratch = [UInt8](repeating: 0, count: 16 * 1024)
        var allowance = descendantDiscardLimit
        // The handler retains the source until it cancels itself.
        source.setEventHandler {
            let bytesRead = scratch.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if bytesRead > 0 { allowance -= bytesRead }
            if bytesRead == 0 || (bytesRead < 0 && errno != EINTR) || allowance <= 0 {
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
