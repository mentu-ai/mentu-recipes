import XCTest
@testable import MentuRecipesCore

final class QuarantineWarningTests: XCTestCase {
    func testFailedProcessDoesNotClaimAQuarantinePatch() async throws {
        let (root, record) = try await runFixture(exitCode: 7)
        XCTAssertEqual(record.steps.first?.exitCode, 7)
        try assertUncapturedChanges(root: root, record: record)
    }

    func testFailedVerificationDoesNotClaimAQuarantinePatch() async throws {
        let (root, record) = try await runFixture(verificationFails: true)
        XCTAssertEqual(record.steps.first?.exitCode, 0)
        XCTAssertFalse(try XCTUnwrap(record.steps.first?.verification).passed)
        try assertUncapturedChanges(root: root, record: record)
    }

    func testRecordedQuarantinePatchIsReportedWithoutMovingFiles() async throws {
        let (root, record) = try await runFixture()
        let step = try XCTUnwrap(record.steps.first)
        XCTAssertEqual(record.outcome, "ok")
        let patches = try XCTUnwrap(step.git?.quarantineFiles)
        XCTAssertEqual(patches.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(patches.first)))
        XCTAssertTrue(step.warnings?.contains(
            "Quarantine patch recorded for changes outside expected_changes: unexpected.txt"
        ) == true)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("unexpected.txt"), encoding: .utf8), "unexpected\n")
        let events = try eventText(root: root, record: record)
        XCTAssertTrue(events.contains("quarantine_written"))
        let committed = try await git(["show", "--name-only", "--format=", "HEAD"], in: root)
        XCTAssertTrue(committed.contains("expected.txt"))
        XCTAssertFalse(committed.contains("unexpected.txt"))
    }

    private func assertUncapturedChanges(root: URL, record: RecipeRunRecord) throws {
        let step = try XCTUnwrap(record.steps.first)
        XCTAssertEqual(record.outcome, "failed")
        XCTAssertFalse(step.localComplete)
        XCTAssertNil(step.git)
        XCTAssertEqual(step.drift?.unexpectedPaths, ["unexpected.txt"])
        XCTAssertTrue(step.warnings?.contains(
            "Changes outside expected_changes (no quarantine patch recorded): unexpected.txt"
        ) == true)
        let runDir = root.appendingPathComponent(".mentu/runs/\(record.runId)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: runDir.appendingPathComponent("quarantine").path))
        XCTAssertFalse(try eventText(root: root, record: record).contains("quarantine_written"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("unexpected.txt"), encoding: .utf8), "unexpected\n")
        let stored = try JSONDecoder().decode(RecipeRunRecord.self, from: Data(contentsOf: runDir.appendingPathComponent("run.json")))
        XCTAssertEqual(stored.steps.first?.warnings, step.warnings)
    }

    private func eventText(root: URL, record: RecipeRunRecord) throws -> String {
        try String(contentsOf: root.appendingPathComponent(".mentu/runs/\(record.runId)/events.jsonl"), encoding: .utf8)
    }

    private func runFixture(exitCode: Int = 0, verificationFails: Bool = false) async throws -> (URL, RecipeRunRecord) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mentu-quarantine-warning-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".mentu/recipes"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var step: [String: Any] = [
            "label": "write", "backend": "shell",
            "prompt": "echo expected > expected.txt; echo unexpected > unexpected.txt; echo WARNING_COMPLETE; exit \(exitCode)",
            "completion_keyword": "WARNING_COMPLETE", "expected_changes": ["expected.txt"], "timeout": 5
        ]
        if verificationFails { step["verify"] = ["commands": ["exit 9"]] }
        let recipe: [String: Any] = ["name": "warning", "steps": [step]]
        try JSONSerialization.data(withJSONObject: recipe).write(to: root.appendingPathComponent(".mentu/recipes/warning.json"))
        try "seed\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try await git(["init", "--quiet"], in: root)
        _ = try await git(["config", "user.name", "Mentu Test"], in: root)
        _ = try await git(["config", "user.email", "recipes-test@mentu.ai"], in: root)
        _ = try await git(["add", "README.md", ".mentu/recipes/warning.json"], in: root)
        _ = try await git(["commit", "--quiet", "-m", "fixture"], in: root)
        let record = try await RecipeRunner(options: RunOptions(workspace: root, home: root, cloudEnabled: false, quiet: true)).run("warning")
        return (root, record)
    }

    private func git(_ arguments: [String], in root: URL) async throws -> String {
        let result = try await ProcessRunner.run(
            executable: ProcessRunner.findExecutable("git") ?? "/usr/bin/git", arguments: arguments,
            env: ProcessInfo.processInfo.environment, workingDirectory: root,
            timeout: 15, maxOutputBytes: 100_000, eventSink: { _ in }
        )
        guard result.exitCode == 0 else { throw RecipeError.failed("Fixture git command failed: \(result.stderr)") }
        return result.stdout
    }
}
