import Darwin
import Foundation

extension BoundedProcess {
    /// Standard input written while a run goes on, for a child that answers
    /// each message before the next (`claude -p --input-format
    /// stream-json`): each `send` is written in order, and `close` ends the
    /// input, which ends such a child. Sendable: the run's output handler,
    /// on the waiting thread, sends and closes while the writer writes.
    final class StreamingInput: @unchecked Sendable {
        private let condition = NSCondition()
        private var pending: [Data] = []
        private var closed = false

        init() {}

        func send(_ data: Data) {
            condition.lock()
            if !closed { pending.append(data) }
            condition.signal()
            condition.unlock()
        }

        func close() {
            condition.lock()
            closed = true
            condition.broadcast()
            condition.unlock()
        }

        /// The next bytes to write: nil once closed with nothing left, or
        /// once `shouldStop` says so (asked every 50 ms while waiting).
        func next(shouldStop: () -> Bool) -> Data? {
            condition.lock()
            defer { condition.unlock() }
            while pending.isEmpty, !closed {
                if shouldStop() { return nil }
                _ = condition.wait(until: Date().addingTimeInterval(0.05))
            }
            return pending.isEmpty ? nil : pending.removeFirst()
        }
    }

    /// Writes a `StreamingInput` to a run's standard input on a thread of
    /// its own, as `InputWriter` writes a fixed one: never SIGPIPE, and it
    /// gives up once the run is over.
    final class StreamWriter: @unchecked Sendable {
        private let input: StreamingInput
        private let handle: FileHandle
        private let lock = NSLock()
        private var isFinished = false

        init(input: StreamingInput, pipe: Pipe) {
            self.input = input
            handle = pipe.fileHandleForWriting
            try? pipe.fileHandleForReading.close()
            let descriptor = handle.fileDescriptor
            _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
            _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        }

        /// The body is typed before it reaches `Thread`, as InputWriter's
        /// is (see ThreadClosureGuardTests).
        func start() {
            let body: @Sendable () -> Void = { [self] in run() }
            let thread = Thread(block: body)
            thread.name = "BoundedProcess.streamingInput"
            thread.start()
        }

        func finish() {
            lock.withLock { isFinished = true }
            input.close()
        }

        private var shouldStop: Bool {
            lock.withLock { isFinished }
        }

        private func run() {
            defer { try? handle.close() }
            let descriptor = handle.fileDescriptor
            while let data = input.next(shouldStop: { shouldStop }) {
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
    }
}
