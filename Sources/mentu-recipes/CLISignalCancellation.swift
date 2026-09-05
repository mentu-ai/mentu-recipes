import Foundation

/// Signal ownership is scoped to the CLI; importing the library installs nothing.
final class CLISignalCancellation {
    private let lock = NSLock()
    private var received: Int32?
    private var task: Task<Int32, Never>?
    private var sources: [DispatchSourceSignal] = []
    private var restore: [() -> Void] = []

    func run(_ operation: @escaping () async -> Int32) async -> Int32 {
        for number in [SIGINT, SIGTERM] {
            // A caught no-op resets on exec; SIG_IGN would leak into child tools.
            let previous = signal(number) { _ in }
            restore.append { signal(number, previous) }
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
            source.setEventHandler { [weak self] in self?.cancel(number) }
            source.resume()
            sources.append(source)
        }
        let running = Task { await operation() }
        attach(running)
        let result = await running.value
        sources.forEach { $0.cancel() }
        restore.forEach { $0() }
        return receivedSignal().map { 128 + $0 } ?? result
    }

    private func attach(_ value: Task<Int32, Never>) {
        lock.lock(); defer { lock.unlock() }
        task = value
        if received != nil { value.cancel() }
    }

    private func cancel(_ number: Int32) {
        lock.lock(); defer { lock.unlock() }
        if received == nil { received = number }
        task?.cancel()
    }

    private func receivedSignal() -> Int32? {
        lock.lock(); defer { lock.unlock() }
        return received
    }
}
