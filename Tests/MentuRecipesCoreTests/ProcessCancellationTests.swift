import XCTest
@testable import MentuRecipesCore

final class ProcessCancellationTests: XCTestCase {
    private let environment = ["PATH": "/usr/bin:/bin"]

    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mentu-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func waitForFile(_ file: URL) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: file.path), Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "Fixture did not become ready")
    }

    func testCancellationBeforeLaunchDoesNotStartProcess() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "touch forbidden"],
                env: environment, workingDirectory: root, timeout: 5, maxOutputBytes: 1000, eventSink: { _ in })
        }
        do { _ = try await task.value; XCTFail("Cancelled task launched") }
        catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("forbidden").path))
    }

    func testTaskCancellationReachesTheStepAndCannotBecomeSuccess() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            try await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c",
                "trap 'echo HANDLED; exit 0' TERM INT; echo ready > ready; while :; do sleep 0.1; done"],
                env: environment, workingDirectory: root, timeout: 10, maxOutputBytes: 1000, eventSink: { _ in })
        }
        try await waitForFile(root.appendingPathComponent("ready"))
        let start = Date()
        task.cancel()
        let result = try await task.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        XCTAssertEqual(result.exitCode, 130)
        XCTAssertFalse(result.providerCompleted)
        XCTAssertTrue(result.stdout.contains("HANDLED"), "The child's graceful handler must run")
        XCTAssertTrue(result.stderr.contains("execution cancelled"))
    }

    func testNonCooperativeStepHasBoundedCancellation() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = Task {
            try await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c",
                "trap '' TERM INT; echo ready > ready; sleep 10"],
                env: environment, workingDirectory: root, timeout: 20, maxOutputBytes: 1000, eventSink: { _ in })
        }
        try await waitForFile(root.appendingPathComponent("ready"))
        let start = Date()
        task.cancel()
        let result = try await task.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 4)
        XCTAssertEqual(result.exitCode, 130)
        XCTAssertFalse(result.providerCompleted)
    }

    func testCLISignalsPreserveFailedAdmissionEvidenceAndStopDependentWork() async throws {
        for cancellationSignal in [SIGINT, SIGTERM] {
            try await assertCLICancellation(cancellationSignal)
        }
    }

    private func assertCLICancellation(_ cancellationSignal: Int32) async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recipes = root.appendingPathComponent(".mentu/recipes")
        try FileManager.default.createDirectory(at: recipes, withIntermediateDirectories: true)
        let definition: [String: Any] = ["name": "cancel", "type": "sequence", "cloud": ["enabled": false],
            "steps": [
                ["label": "wait", "backend": "shell", "timeout": 20, "max_retries": 2,
                 "prompt": "if [ -f .mentu/allow-finish ]; then echo COMPLETE; exit 0; fi; trap 'echo handled > stopped; echo COMPLETE; exit 0' TERM INT; echo $$ > ready; while :; do sleep 0.1; done",
                 "completion_keyword": "COMPLETE", "expected_changes": ["ready", "stopped"],
                 "verify": ["commands": ["touch forbidden-verify"]]],
                ["label": "later", "backend": "shell", "prompt": "touch forbidden-later", "expected_changes": ["forbidden-later"]]
            ]]
        try JSONSerialization.data(withJSONObject: definition).write(to: recipes.appendingPathComponent("cancel.json"))
        #if DEBUG
        let configuration = "debug"
        #else
        let configuration = "release"
        #endif
        let executable = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/\(configuration)/mentu-recipes")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path), "Build the CLI before testing")
        let plan = try await ProcessRunner.run(executable: executable.path,
            arguments: ["plan", "cancel", "--workspace", root.path], env: environment,
            workingDirectory: root, timeout: 5, maxOutputBytes: 100_000, eventSink: { _ in })
        let planned = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(plan.stdout.utf8)) as? [String: Any])
        let digest = try XCTUnwrap(planned["digest"] as? String)
        let process = Process()
        process.executableURL = executable
        process.arguments = ["run", "cancel", "--workspace", root.path, "--plan-digest", digest, "--request-key", UUID().uuidString]
        process.currentDirectoryURL = root
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
        try await waitForFile(root.appendingPathComponent("ready"))
        kill(process.processIdentifier, cancellationSignal)
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertFalse(process.isRunning, "CLI cancellation must finish boundedly")
        guard !process.isRunning else { return }
        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertEqual(process.terminationStatus, 128 + cancellationSignal)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("stopped").path))
        for file in ["forbidden-verify", "forbidden-later"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path))
        }
        let runs = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(".mentu/runs"), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("run_") }
        XCTAssertEqual(runs.count, 1)
        let run = try RunReporter.load(runId: XCTUnwrap(runs.first).lastPathComponent, workspace: root)
        XCTAssertEqual(run.outcome, "failed")
        XCTAssertNotNil(run.endedAt)
        XCTAssertEqual(run.steps.count, 1)
        XCTAssertEqual(run.steps.first?.attempts, 1)
        XCTAssertEqual(run.steps.first?.exitCode, 130)
        XCTAssertFalse(run.steps.first?.localComplete ?? true)
        let persisted = try String(contentsOf: XCTUnwrap(runs.first).appendingPathComponent("wait.attempt-1.stdout"), encoding: .utf8)
        XCTAssertTrue(persisted.contains("COMPLETE"), "Partial output is evidence, not a success signal")

        try Data().write(to: root.appendingPathComponent(".mentu/allow-finish"))
        let resumed = try await ProcessRunner.run(executable: executable.path,
            arguments: ["resume", run.runId, "--workspace", root.path, "--plan-digest", digest, "--request-key", UUID().uuidString],
            env: environment, workingDirectory: root, timeout: 5, maxOutputBytes: 100_000, eventSink: { _ in })
        XCTAssertEqual(resumed.exitCode, 0, resumed.stderr)
        let recovered = try RunReporter.load(runId: run.runId, workspace: root)
        XCTAssertEqual(recovered.outcome, "ok")
        XCTAssertEqual(recovered.steps.last(where: { $0.label == "wait" })?.attempts, 2)
        for file in ["forbidden-verify", "forbidden-later"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(file).path))
        }
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(runs.first).appendingPathComponent("wait.attempt-1.stdout"), encoding: .utf8), persisted)
    }
}
