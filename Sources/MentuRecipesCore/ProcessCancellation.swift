import Foundation

/// Keeps cancellation and launch serialized, including cancellation before spawn.
final class ProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var cancelled = false
    private var started = false
    private var finished = false
    private var escalation: DispatchWorkItem?

    init(_ process: Process) { self.process = process }

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try process.run()
        started = true
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true
        guard started, !finished, process.isRunning else { return }
        signalOwnedProcess(SIGTERM)
        guard escalation == nil else { return }
        let timer = DispatchWorkItem { [weak self] in self?.forceIfRunning() }
        escalation = timer
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: timer)
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        finished = true
        escalation?.cancel()
        escalation = nil
    }

    private func forceIfRunning() {
        lock.lock(); defer { lock.unlock() }
        guard started, !finished, process.isRunning else { return }
        signalOwnedProcess(SIGKILL)
    }

    private func signalOwnedProcess(_ value: Int32) {
        let pid = process.processIdentifier
        // Foundation creates a step group; never signal our parent's group.
        if getpgid(pid) == pid { kill(-pid, value) }
        else { kill(pid, value) }
    }
}
