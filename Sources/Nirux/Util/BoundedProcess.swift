import Darwin
import Foundation

struct BoundedProcessResult: Sendable {
    let standardOutput: Data
    let terminationStatus: Int32
}

enum BoundedProcess {
    static func run(
        executableURL: URL,
        arguments: [String],
        currentDirectoryURL: URL,
        timeout: TimeInterval = 30
    ) -> BoundedProcessResult? {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try? output.fileHandleForReading.close()
            try? output.fileHandleForWriting.close()
            return nil
        }
        try? output.fileHandleForWriting.close()

        guard let data = drain(output, from: process, timeout: timeout) else { return nil }
        return BoundedProcessResult(
            standardOutput: data,
            terminationStatus: process.terminationStatus
        )
    }

    private static func drain(
        _ output: Pipe,
        from process: Process,
        timeout: TimeInterval
    ) -> Data? {
        let readHandle = output.fileHandleForReading
        let descriptor = readHandle.fileDescriptor
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var data = Data()
        var reachedEnd = false
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)

        while process.isRunning || !reachedEnd {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                terminate(process)
                try? readHandle.close()
                return nil
            }

            if reachedEnd {
                Thread.sleep(forTimeInterval: min(0.01, remaining))
                continue
            }

            var descriptorState = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let waitMilliseconds = Int32(min(max(remaining * 1_000, 1), 50))
            let pollResult = Darwin.poll(&descriptorState, 1, waitMilliseconds)
            if pollResult < 0 {
                if errno == EINTR { continue }
                terminate(process)
                try? readHandle.close()
                return nil
            }
            guard pollResult > 0 else { continue }

            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            }
            if bytesRead > 0 {
                data.append(contentsOf: buffer[..<bytesRead])
            } else if bytesRead == 0 {
                reachedEnd = true
            } else if errno != EINTR {
                terminate(process)
                try? readHandle.close()
                return nil
            }
        }

        process.waitUntilExit()
        try? readHandle.close()
        return data
    }

    private static func terminate(_ process: Process) {
        guard process.isRunning else {
            process.waitUntilExit()
            return
        }
        process.terminate()
        let graceDeadline = ProcessInfo.processInfo.systemUptime + 0.25
        while process.isRunning, ProcessInfo.processInfo.systemUptime < graceDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}
