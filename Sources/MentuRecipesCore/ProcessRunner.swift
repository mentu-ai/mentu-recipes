import Foundation

public enum ProcessRunner {
    public static func findExecutable(_ name: String) -> String? {
        if name.contains("/") && FileManager.default.isExecutableFile(atPath: name) {
            return name
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":").map(String.init) {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    public static func run(
        executable: String,
        arguments: [String],
        env: [String: String],
        workingDirectory: URL,
        timeout: Int,
        maxOutputBytes: Int,
        eventSink: @escaping (String) -> Void
    ) async throws -> AdapterResult {
        try await run(
            executable: executable,
            arguments: arguments,
            env: env,
            workingDirectory: workingDirectory,
            timeout: timeout,
            maxOutputBytes: maxOutputBytes,
            stdoutSink: { eventSink($0) },
            stderrSink: { eventSink($0) }
        )
    }

    public static func run(
        executable: String,
        arguments: [String],
        env: [String: String],
        workingDirectory: URL,
        timeout: Int,
        maxOutputBytes: Int,
        stdoutSink: @escaping (String) -> Void,
        stderrSink: @escaping (String) -> Void
    ) async throws -> AdapterResult {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = stdin

        let buffer = OutputBuffer(maxBytes: maxOutputBytes)
        let readers = DispatchGroup()

        let cancellation = ProcessCancellation(process)
        return try await withTaskCancellationHandler {
            try cancellation.start()
            defer { cancellation.finish() }
            try? stdin.fileHandleForWriting.close()

            startReader(
                handle: stdout.fileHandleForReading,
                group: readers,
                append: buffer.appendStdout,
                sink: stdoutSink
            )
            startReader(
                handle: stderr.fileHandleForReading,
                group: readers,
                append: buffer.appendStderr,
                sink: stderrSink
            )

            let exitTask = Task {
                await waitForExit(process)
            }

            let timedOut: Bool
            if timeout > 0 {
                timedOut = !(await completedBeforeTimeout(exitTask, seconds: timeout))
            } else {
                await exitTask.value
                timedOut = false
            }

            if timedOut {
                process.terminate()
                if !(await completedBeforeTimeout(exitTask, seconds: 2)) {
                    kill(process.processIdentifier, SIGKILL)
                    await exitTask.value
                }
            }

            if timedOut {
                try? stdout.fileHandleForReading.close()
                try? stderr.fileHandleForReading.close()
            }
            await waitForReaders(readers, timeout: 2)

            let snapshot = buffer.snapshot()
            let cancelled = cancellation.wasCancelled
            let code = cancelled ? Int32(130) : timedOut ? Int32(124) : process.terminationStatus
            let stderrText = cancelled ? snapshot.stderr + "\n[mentu-recipes] execution cancelled\n"
                : timedOut ? snapshot.stderr + "\n[mentu-recipes] timeout after \(timeout)s\n" : snapshot.stderr

            return AdapterResult(
                stdout: snapshot.stdout,
                stderr: stderrText,
                exitCode: code,
                providerCompleted: !cancelled && !timedOut && code == 0,
                inputTokens: nil,
                outputTokens: nil
            )
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func startReader(
        handle: FileHandle,
        group: DispatchGroup,
        append: @escaping (String) -> Void,
        sink: @escaping (String) -> Void
    ) {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { group.leave() }
            while true {
                let data = handle.readData(ofLength: 8192)
                if data.isEmpty { break }
                guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { continue }
                append(text)
                sink(text)
            }
        }
    }

    private static func waitForExit(_ process: Process) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let box = ContinuationBox(continuation)
            process.terminationHandler = { _ in
                process.terminationHandler = nil
                box.resume()
            }
            if !process.isRunning {
                process.terminationHandler = nil
                box.resume()
            }
        }
    }

    private static func waitForReaders(_ group: DispatchGroup, timeout: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .utility).async {
                _ = group.wait(timeout: .now() + .seconds(timeout))
                continuation.resume()
            }
        }
    }

    private static func completedBeforeTimeout(_ exitTask: Task<Void, Never>, seconds: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            let race = TimeoutContinuation(continuation)
            let timer = DispatchWorkItem { race.resolve(false) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .seconds(max(seconds, 0)), execute: timer)
            Task {
                await exitTask.value
                timer.cancel()
                race.resolve(true)
            }
        }
    }

    private final class TimeoutContinuation: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func resolve(_ value: Bool) {
            lock.lock()
            let current = continuation
            continuation = nil
            lock.unlock()
            current?.resume(returning: value)
        }
    }

    private final class ContinuationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func resume() {
            lock.lock()
            let current = continuation
            continuation = nil
            lock.unlock()
            current?.resume()
        }
    }
}
