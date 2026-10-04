import Darwin
import Foundation

struct BoundedProcessResult: Sendable {
    let standardOutput: Data
    /// Empty unless the run was asked to capture standard error.
    let standardError: Data
    let terminationStatus: Int32
}

enum BoundedProcess {
    /// Runs a process and returns what it wrote, or nil when it couldn't
    /// start, or was stopped: timed out, or past `maxStandardOutputBytes`.
    /// `environment` is set over Nirux's own.
    static func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        environment: [String: String] = [:],
        timeout: TimeInterval = 30,
        captureStandardError: Bool = false,
        maxStandardOutputBytes: Int? = nil
    ) -> BoundedProcessResult? {
        guard let outcome = execute(
            executableURL: executableURL,
            arguments: arguments,
            currentDirectoryURL: currentDirectoryURL,
            environment: .inherited(adding: environment),
            timeout: timeout,
            captureStandardError: captureStandardError,
            maxStandardOutputBytes: maxStandardOutputBytes
        ), outcome.stop == nil, let terminationStatus = outcome.terminationStatus else { return nil }
        return BoundedProcessResult(
            standardOutput: outcome.standardOutput,
            standardError: outcome.standardError,
            terminationStatus: terminationStatus
        )
    }

    /// The child's environment.
    enum Environment: Sendable {
        /// Nirux's own, with these set over it.
        case inherited(adding: [String: String])
        /// These variables and nothing else: none of Nirux's reach it.
        case replaced([String: String])
    }

    /// Stops a run from any thread, as a timeout does, within the 50 ms the
    /// run waits on its pipes at a time. Cancelled with its `parent` too.
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private let parent: Cancellation?

        init(parent: Cancellation? = nil) {
            self.parent = parent
        }

        func cancel() {
            lock.withLock { cancelled = true }
        }

        var isCancelled: Bool {
            lock.withLock { cancelled } || parent?.isCancelled == true
        }
    }

    /// Why a run was stopped before it exited.
    enum Stop: Equatable, Sendable {
        case timedOut
        /// Its standard output stayed silent past `idleTimeout`.
        case idle
        case cancelled
        /// Its standard output went past `maxStandardOutputBytes`.
        case outputLimit
        /// A pipe couldn't be read.
        case readFailed
    }

    struct Outcome: Sendable {
        /// What it wrote until it exited, or until it was stopped; empty
        /// when the run doesn't keep it.
        let standardOutput: Data
        /// Empty unless the run was asked to capture standard error; its
        /// end only, past `maxStandardErrorBytes`.
        let standardError: Data
        /// Nil when it was stopped.
        let terminationStatus: Int32?
        let stop: Stop?
    }

    /// `run`, keeping what a stopped process wrote, with `standardInput`
    /// written to its standard input (none: it inherits Nirux's), a
    /// `cancellation` to stop it, an `idleTimeout` past which a silent
    /// standard output stops it, and `onStandardOutput` called with each
    /// chunk of standard output as it is read, on the waiting thread (the
    /// output isn't kept too unless `keepsStandardOutput`). Nil only when
    /// it couldn't start. It waits for the process: call it off the main
    /// thread.
    static func execute(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        environment: Environment = .inherited(adding: [:]),
        standardInput: Data? = nil,
        timeout: TimeInterval = 30,
        idleTimeout: TimeInterval? = nil,
        captureStandardError: Bool = false,
        maxStandardOutputBytes: Int? = nil,
        maxStandardErrorBytes: Int? = nil,
        cancellation: Cancellation? = nil,
        onStandardOutput: (@Sendable (Data) -> Void)? = nil,
        keepsStandardOutput: Bool = true
    ) -> Outcome? {
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            return nil
        }
        // Past 4,096 arguments `Process.run()` raises an Objective-C
        // exception, which Swift can't catch: the app would crash.
        guard arguments.count < maxArguments else { return nil }
        if cancellation?.isCancelled == true {
            return Outcome(standardOutput: Data(), standardError: Data(), terminationStatus: nil, stop: .cancelled)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        switch environment {
        case .inherited(let adding):
            if !adding.isEmpty {
                process.environment = ProcessInfo.processInfo.environment
                    .merging(adding) { _, override in override }
            }
        case .replaced(let variables):
            process.environment = variables
        }

        let output = Pipe()
        let errorOutput = captureStandardError ? Pipe() : nil
        let input = standardInput == nil ? nil : Pipe()
        // Keep terminals forked meanwhile (forkpty) from inheriting a write
        // end and holding the pipe open for their whole lifetime.
        for pipe in [output, errorOutput, input].compactMap({ $0 }) {
            setCloseOnExec(pipe)
        }
        let didTerminate = DispatchSemaphore(value: 0)
        process.standardOutput = output
        process.standardError = errorOutput ?? FileHandle.nullDevice
        if let input {
            process.standardInput = input
        }
        process.terminationHandler = { _ in
            didTerminate.signal()
        }

        do {
            try process.run()
        } catch {
            for pipe in [output, errorOutput, input].compactMap({ $0 }) {
                try? pipe.fileHandleForReading.close()
                try? pipe.fileHandleForWriting.close()
            }
            return nil
        }
        PollingDiagnostics.recordLaunch(executableURL: executableURL)
        try? output.fileHandleForWriting.close()
        try? errorOutput?.fileHandleForWriting.close()
        let writer = input.flatMap { input in
            standardInput.map { InputWriter(data: $0, pipe: input) }
        }
        writer?.start()
        defer { writer?.finish() }

        let (standardOutput, standardError, stop) = drain(
            output: output,
            errorOutput: errorOutput,
            from: process,
            didTerminate: didTerminate,
            timeout: timeout,
            idleTimeout: idleTimeout,
            maxStandardOutputBytes: maxStandardOutputBytes,
            maxStandardErrorBytes: maxStandardErrorBytes,
            cancellation: cancellation,
            onStandardOutput: onStandardOutput,
            keepsStandardOutput: keepsStandardOutput
        )
        return Outcome(
            standardOutput: standardOutput,
            standardError: standardError,
            terminationStatus: stop == nil ? process.terminationStatus : nil,
            stop: stop
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

    /// Writes a run's standard input on a thread of its own while the run
    /// reads the child's output, so neither side waits on a full pipe, nor
    /// on a queue whose threads are all busy.
    /// Never SIGPIPE: a child that exits without reading it all just ends
    /// the write. It gives up once the run is over, even if a descendant
    /// still holds the pipe without reading.
    private final class InputWriter: @unchecked Sendable {
        private let data: Data
        private let handle: FileHandle
        private let lock = NSLock()
        private var isFinished = false

        init(data: Data, pipe: Pipe) {
            self.data = data
            handle = pipe.fileHandleForWriting
            try? pipe.fileHandleForReading.close()
            let descriptor = handle.fileDescriptor
            _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }

        func start() {
            let thread = Thread { [self] in write() }
            thread.name = "BoundedProcess.input"
            thread.start()
        }

        func finish() {
            lock.withLock { isFinished = true }
        }

        private var shouldStop: Bool {
            lock.withLock { isFinished }
        }

        private func write() {
            defer { try? handle.close() }
            let descriptor = handle.fileDescriptor
            var offset = 0
            while offset < data.count, !shouldStop {
                let written = data.withUnsafeBytes { bytes in
                    Darwin.write(descriptor, bytes.baseAddress! + offset, data.count - offset)
                }
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EAGAIN {
                    var state = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    _ = Darwin.poll(&state, 1, 50)
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    return
                }
            }
        }
    }

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
    /// or a cancellation does; what it wrote until then is kept.
    private static func drain(
        output: Pipe,
        errorOutput: Pipe?,
        from process: Process,
        didTerminate: DispatchSemaphore,
        timeout: TimeInterval,
        idleTimeout: TimeInterval?,
        maxStandardOutputBytes: Int?,
        maxStandardErrorBytes: Int?,
        cancellation: Cancellation?,
        onStandardOutput: (@Sendable (Data) -> Void)?,
        keepsStandardOutput: Bool
    ) -> (standardOutput: Data, standardError: Data, stop: Stop?) {
        let readHandles = [output, errorOutput].compactMap { $0?.fileHandleForReading }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var data = [Data](repeating: Data(), count: readHandles.count)
        var openIndices = Array(readHandles.indices)
        var hasExited = false
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        var reported = 0
        // Standard output's size, kept or not.
        var outputBytes = 0
        var lastOutputAt = ProcessInfo.processInfo.systemUptime
        func report() {
            if let maxStandardErrorBytes, data.count > 1, data[1].count > maxStandardErrorBytes {
                data[1] = Data(data[1].suffix(maxStandardErrorBytes))
            }
            guard data[0].count > reported else { return }
            lastOutputAt = ProcessInfo.processInfo.systemUptime
            outputBytes += data[0].count - reported
            onStandardOutput?(data[0].subdata(in: reported..<data[0].count))
            if keepsStandardOutput {
                reported = data[0].count
            } else {
                data[0] = Data()
                reported = 0
            }
        }
        func isIdle() -> Bool {
            guard let idleTimeout else { return false }
            return ProcessInfo.processInfo.systemUptime - lastOutputAt > idleTimeout
        }

        func isOverLimit() -> Bool {
            guard let maxStandardOutputBytes else { return false }
            return outputBytes > maxStandardOutputBytes
        }

        func stopped(_ stop: Stop) -> (standardOutput: Data, standardError: Data, stop: Stop?) {
            // After exit the semaphore is spent and the pid may be reused.
            if !hasExited {
                terminate(process, didTerminate: didTerminate)
            }
            for handle in readHandles {
                try? handle.close()
            }
            return (data[0], data.count > 1 ? data[1] : Data(), stop)
        }

        while !openIndices.isEmpty {
            if didTerminate.wait(timeout: .now()) == .success {
                hasExited = true
                guard readLeftovers(
                    readHandles,
                    openIndices: &openIndices,
                    into: &data,
                    buffer: &buffer
                ) else { return stopped(.readFailed) }
                report()
                guard !isOverLimit() else { return stopped(.outputLimit) }
                break
            }
            if cancellation?.isCancelled == true { return stopped(.cancelled) }
            if isIdle() { return stopped(.idle) }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return stopped(.timedOut) }

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
                return stopped(.readFailed)
            }
            guard pollResult > 0 else { continue }

            guard readReadyPipes(
                descriptorStates,
                openIndices: &openIndices,
                into: &data,
                buffer: &buffer
            ) else { return stopped(.readFailed) }
            report()
            guard !isOverLimit() else { return stopped(.outputLimit) }
        }

        // The pipes closed; the process may still be running.
        while !hasExited {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return stopped(.timedOut) }
            if cancellation?.isCancelled == true { return stopped(.cancelled) }
            hasExited = didTerminate.wait(timeout: .now() + min(remaining, 0.05)) == .success
        }
        for index in readHandles.indices {
            if openIndices.contains(index) {
                discardDescendantOutput(readHandles[index])
            } else {
                try? readHandles[index].close()
            }
        }
        return (data[0], data.count > 1 ? data[1] : Data(), nil)
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
