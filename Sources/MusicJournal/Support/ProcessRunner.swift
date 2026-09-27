import Foundation

enum ProcessRunner {
    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data

        var stderrText: String { String(data: stderr, encoding: .utf8) ?? "" }
    }

    struct TimedOut: Error {}

    /// Shared between the caller, the timeout timer, the cancellation handler and the pipe
    /// readers, so the flags sit behind a lock. stdout/stderr are written once by their reader
    /// before the DispatchGroup notifies, which orders them before they're read.
    private final class State: @unchecked Sendable {
        let process = Process()
        var stdout = Data()
        var stderr = Data()
        private let lock = NSLock()
        private var _timedOut = false
        private var _stopped = false

        var timedOut: Bool { lock.withLock { _timedOut } }
        var stopped: Bool { lock.withLock { _stopped } }

        /// Marks the run as stopped and terminates the process if it has started. A process
        /// launched after this is terminated right away by `run` (see the re-check there).
        func stop(timedOut: Bool = false) {
            lock.withLock {
                _stopped = true
                if timedOut { _timedOut = true }
            }
            if process.isRunning { process.terminate() }
        }
    }

    /// Runs an executable to completion, collecting stdout/stderr. Terminates it on
    /// timeout or task cancellation.
    static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: Duration
    ) async throws -> Output {
        let state = State()
        let process = state.process
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let timer = Task {
            try await Task.sleep(for: timeout)
            state.stop(timedOut: true)
        }
        defer { timer.cancel() }

        let output: Output = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Enter before launching so a process that exits instantly still waits for its output.
                let readers = DispatchGroup()
                readers.enter()
                readers.enter()
                process.terminationHandler = { proc in
                    readers.notify(queue: .global()) {
                        continuation.resume(returning: Output(
                            status: proc.terminationStatus, stdout: state.stdout, stderr: state.stderr))
                    }
                }
                // Cancelled before we even started: don't launch at all.
                if state.stopped {
                    process.terminationHandler = nil
                    continuation.resume(throwing: CancellationError())
                    return
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                // Cancelled in the gap between the check above and launch.
                if state.stopped { process.terminate() }
                // Drain both pipes concurrently so a full pipe buffer can't stall the child.
                DispatchQueue.global().async {
                    state.stdout = outPipe.fileHandleForReading.readDataToEndOfFile()
                    readers.leave()
                }
                DispatchQueue.global().async {
                    state.stderr = errPipe.fileHandleForReading.readDataToEndOfFile()
                    readers.leave()
                }
            }
        } onCancel: {
            state.stop()
        }

        if state.timedOut { throw TimedOut() }
        try Task.checkCancellation()
        return output
    }
}
