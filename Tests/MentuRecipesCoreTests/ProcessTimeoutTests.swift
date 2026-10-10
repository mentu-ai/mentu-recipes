import XCTest
@testable import MentuRecipesCore

final class ProcessTimeoutTests: XCTestCase {
    func testTimeoutSignalsOwnedGroupAndRetainsTimeoutOutcome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mentu-timeout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            // Only the child created by this fixture is eligible for cleanup.
            if let text = try? String(contentsOf: root.appendingPathComponent("child-pid"), encoding: .utf8),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               !FileManager.default.fileExists(atPath: root.appendingPathComponent("child-stopped").path) {
                kill(pid, SIGKILL)
            }
            try? FileManager.default.removeItem(at: root)
        }
        let script = """
        /bin/sh -c 'trap "echo stopped > child-stopped; exit 0" TERM; echo ready > child-ready; while :; do sleep 0.05; done' &
        echo $! > child-pid
        trap '' TERM INT
        wait
        """
        let result = try await ProcessRunner.run(
            executable: "/bin/sh", arguments: ["-c", script],
            env: ["PATH": "/usr/bin:/bin"], workingDirectory: root,
            timeout: 1, maxOutputBytes: 1000, eventSink: { _ in })
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("child-ready").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("child-stopped").path),
                      "Timeout must reach a descendant in the owned process group")
        XCTAssertEqual(result.exitCode, 124)
        XCTAssertFalse(result.providerCompleted)
        XCTAssertTrue(result.stderr.contains("timeout after 1s"))
        XCTAssertFalse(result.stderr.contains("execution cancelled"))
    }
}
