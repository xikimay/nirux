import Foundation

extension Process {
    /// Runs it to its end, and returns what `pipe` got. `waitUntilExit()`
    /// spins the run loop and sees the end up to 70 ms late, each call.
    @discardableResult
    func runToEnd(reading pipe: Pipe? = nil) throws -> Data {
        let ended = DispatchSemaphore(value: 0)
        terminationHandler = { _ in ended.signal() }
        try run()
        let data = pipe?.fileHandleForReading.readDataToEndOfFile() ?? Data()
        ended.wait()
        return data
    }
}
