import XCTest
@testable import MentuRecipesCore

/// Only a deterministic local executable is launched. These tests never call a model.
final class CodexCLIAdapterTests: XCTestCase {
    private var roots: [URL] = []
    private let completed = #"{"type":"turn.completed","usage":{"input_tokens":11,"output_tokens":7}}"#
    private let message = #"{"type":"item.completed","item":{"type":"agent_message","text":"FIXTURE_COMPLETE"}}"#

    override func tearDownWithError() throws {
        for root in roots { try FileManager.default.removeItem(at: root) }
    }

    private func fixture(events: String = "", final: String? = nil, stderr: String = "") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mentu-codex-fixture-\(UUID().uuidString)")
        roots.append(root)
        for directory in ["bin", ".mentu/recipes", ".mentu/tmp"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        try put(events, "events.jsonl", in: root)
        try put(stderr, "stderr.txt", in: root)
        if let final { try put(final, "next-final.txt", in: root) }
        try put(#"""
        #!/bin/sh
        printf '%s\000' "$@" > arguments.bin
        previous=''
        last=''
        for argument in "$@"; do
            if [ "$previous" = '--output-last-message' ]; then last="$argument"; fi
            previous="$argument"
        done
        printf '%s\n' "$last" >> output-paths.txt
        if [ -f next-final.txt ]; then /bin/cp next-final.txt "$last"; fi
        /bin/cat events.jsonl
        /bin/cat stderr.txt >&2
        exit 0
        """#, "bin/codex", in: root)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("bin/codex").path)
        return root
    }

    private func put(_ text: String, _ path: String, in root: URL) throws {
        try text.write(to: root.appendingPathComponent(path), atomically: true, encoding: .utf8)
    }

    private func environment(_ root: URL) -> [String: String] {
        ["PATH": root.appendingPathComponent("bin").path + ":/usr/bin:/bin", "HOME": root.path, "CODEX_HOME": root.path]
    }

    private func execute(_ root: URL, sandbox: CodexSandboxMode? = nil, prompt: String = "task") async throws -> AdapterResult {
        try await CodexCLIAdapter().execute(AdapterRequest(prompt: prompt, systemContext: "context",
            model: "fixture-model", env: environment(root), timeout: 5, maxOutputBytes: 100_000,
            reasoning: "max", sandbox: sandbox, sessionName: "mentu-recipes-demo-observe", workingDirectory: root),
            eventSink: { _ in })
    }

    private func arguments(_ root: URL) throws -> [String] {
        try Data(contentsOf: root.appendingPathComponent("arguments.bin"))
            .split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    func testDefaultSandboxAndLiteralPromptPreserveModelAndReasoning() async throws {
        let root = try fixture(events: message + "\n" + completed + "\n")
        let result = try await execute(root, prompt: "--help\n@literal $VALUE")
        XCTAssertTrue(result.providerCompleted)
        XCTAssertEqual(result.inputTokens, 11)
        XCTAssertEqual(result.outputTokens, 7)
        let args = try arguments(root)
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--sandbox")) + 1], "workspace-write")
        XCTAssertFalse(args.contains("--dangerously-bypass-approvals-and-sandbox"))
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--model")) + 1], "fixture-model")
        XCTAssertTrue(args.contains("model_reasoning_effort=\"xhigh\""))
        XCTAssertEqual(args.suffix(2), ["--", "Context:\ncontext\n\n---\n\nTask:\n--help\n@literal $VALUE"])
    }

    func testExplicitSandboxModesAreForwardedWithoutImplicitBypass() async throws {
        let root = try fixture(events: completed + "\n")
        for mode in [CodexSandboxMode.readOnly, .dangerFullAccess] {
            _ = try await execute(root, sandbox: mode)
            let args = try arguments(root)
            XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--sandbox")) + 1], mode.rawValue)
            XCTAssertFalse(args.contains("--dangerously-bypass-approvals-and-sandbox"))
        }
    }

    func testPreviousFinalMessageCannotSupplyAnEmptySuccessfulProcess() async throws {
        let root = try fixture()
        try put("FIXTURE_COMPLETE", ".mentu/tmp/mentu-recipes-demo-observe-last-message.txt", in: root)
        let result = try await execute(root)
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertFalse(result.providerCompleted)
        XCTAssertEqual(result.stdout, "")
    }

    func testFinalMessageFallbackBelongsToOneCompletedInvocationOnly() async throws {
        let root = try fixture(events: completed + "\n", final: "FIXTURE_COMPLETE")
        let first = try await execute(root)
        XCTAssertEqual(first.stdout, "FIXTURE_COMPLETE\n")
        try FileManager.default.removeItem(at: root.appendingPathComponent("next-final.txt"))
        let second = try await execute(root)
        XCTAssertTrue(second.providerCompleted)
        XCTAssertEqual(second.stdout, "")
        let paths = try String(contentsOf: root.appendingPathComponent("output-paths.txt"))
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(paths.count, 2)
        XCTAssertNotEqual(paths[0], paths[1])
        XCTAssertTrue(paths.allSatisfy { !FileManager.default.fileExists(atPath: $0) })
    }

    func testCurrentFinalFileWithoutTerminalCompletionIsNotAccepted() async throws {
        let root = try fixture(final: "FIXTURE_COMPLETE")
        let result = try await execute(root)
        XCTAssertFalse(result.providerCompleted)
        XCTAssertEqual(result.stdout, "")
    }

    func testTypedFailureWinsOverCompletionAndKeyword() async throws {
        for failure in [
            #"{"type":"turn.failed","error":{"message":"fixture failed"}}"#,
            #"{"type":"error","message":"fixture failed"}"#
        ] {
            let root = try fixture(events: message + "\n" + completed + "\n" + failure + "\n")
            let result = try await execute(root)
            XCTAssertNotEqual(result.exitCode, 0)
            XCTAssertFalse(result.providerCompleted)
            XCTAssertTrue(result.stderr.contains("fixture failed"))
        }
    }

    func testParserHandlesSplitFailureAndIncompleteJSONWithoutInventingCompletion() {
        var parser = CodexJSONParser()
        XCTAssertEqual(parser.parse(#"{"type":"turn.failed","error":{"message":"fi"#), [])
        XCTAssertEqual(parser.parse("xture failed\"}}\n"), [.failure("fixture failed")])
        XCTAssertEqual(parser.parse(#"{"type":"turn.completed"#), [])
        XCTAssertEqual(parser.finish(), [])
    }

    func testUnsupportedControlsAreRejectedBeforeSpawnAndCapabilitiesAgree() async throws {
        let root = try fixture(events: completed + "\n")
        let requests = [
            AdapterRequest(prompt: "task", env: environment(root), timeout: 5, maxOutputBytes: 1000, allowedTools: [], workingDirectory: root),
            AdapterRequest(prompt: "task", env: environment(root), timeout: 5, maxOutputBytes: 1000, disallowedTools: ["shell"], workingDirectory: root),
            AdapterRequest(prompt: "task", env: environment(root), timeout: 5, maxOutputBytes: 1000, maxOutputTokens: 10, workingDirectory: root),
            AdapterRequest(prompt: "task", env: environment(root), timeout: 5, maxOutputBytes: 1000, thinking: "off", workingDirectory: root)
        ]
        for request in requests {
            do {
                _ = try await CodexCLIAdapter().execute(request, eventSink: { _ in })
                XCTFail("Unsupported control was accepted")
            } catch { XCTAssertTrue(String(describing: error).contains("does not enforce")) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("arguments.bin").path))
        let caps = CodexCLIAdapter().capabilities
        XCTAssertFalse(caps.supportsToolAllowList)
        XCTAssertFalse(caps.supportsToolDenyList)
        XCTAssertFalse(caps.supportsMaxOutputTokens)
        XCTAssertFalse(caps.supportsThinking)
        XCTAssertTrue(caps.supportsReasoning)
    }

    func testCredentialEnvironmentPolicyPreservesCodexAuthOnly() {
        let filtered = CodexCLIAdapter.agentEnvironment(from: ["OPENAI_API_KEY": "fixture-only", "CODEX_HOME": "/fixture",
            "CONSTRUCT_CREDENTIAL": "private", "MENTU_TOKEN": "private", "PATH": "/bin"])
        XCTAssertEqual(filtered["OPENAI_API_KEY"], "fixture-only")
        XCTAssertEqual(filtered["CODEX_HOME"], "/fixture")
        XCTAssertNil(filtered["CONSTRUCT_CREDENTIAL"])
        XCTAssertNil(filtered["MENTU_TOKEN"])
    }

    private func recipe(in root: URL, stepExtra: [String: Any] = [:], backend: String = "codex") throws {
        var step: [String: Any] = ["label": "observe", "backend": backend, "model": "fixture-model",
            "prompt": "Return FIXTURE_COMPLETE", "completion_keyword": "FIXTURE_COMPLETE", "timeout": 5]
        step.merge(stepExtra) { _, new in new }
        let definition: [String: Any] = ["name": "demo", "env": environment(root), "steps": [step]]
        try JSONSerialization.data(withJSONObject: definition).write(to: root.appendingPathComponent(".mentu/recipes/demo.json"))
    }

    func testAdmittedRunnerRequiresAssistantKeywordAndSuccessfulTerminalEvent() async throws {
        for (events, stderr, expected) in [
            (message + "\n", "", "failed"),
            (completed + "\n", "FIXTURE_COMPLETE", "failed"),
            (message + "\n" + completed + "\n", "", "ok")
        ] {
            let root = try fixture(events: events, stderr: stderr)
            try recipe(in: root, stepExtra: ["sandbox": "read-only"])
            let options = RunOptions(workspace: root, home: root, quiet: true)
            let plan = try ExecutionPlan.resolve("demo", options: options)
            let admitted = RunOptions(workspace: root, home: root, quiet: true, planDigest: plan.digest, requestKey: "fixture")
            let record = try await RecipeRunner(options: admitted).run("demo")
            XCTAssertEqual(record.outcome, expected)
            XCTAssertEqual(record.steps.first?.localComplete, expected == "ok")
            let args = try arguments(root)
            XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--sandbox")) + 1], "read-only")
        }
    }

    func testNonAssistantMessageCannotSatisfyAdmittedCompletionKeyword() async throws {
        for role in ["user", "system", "developer", "tool"] {
            let echoed = "{\"type\":\"item.completed\",\"item\":{\"type\":\"message\",\"role\":\"\(role)\",\"text\":\"FIXTURE_COMPLETE\"}}"
            let root = try fixture(events: echoed + "\n" + completed + "\n")
            try recipe(in: root, stepExtra: ["sandbox": "read-only"])
            let options = RunOptions(workspace: root, home: root, quiet: true)
            let plan = try ExecutionPlan.resolve("demo", options: options)
            let admitted = RunOptions(workspace: root, home: root, quiet: true,
                                      planDigest: plan.digest, requestKey: "fixture")
            let record = try await RecipeRunner(options: admitted).run("demo")
            XCTAssertEqual(record.outcome, "failed", "\(role) content supplied the completion keyword")
            XCTAssertEqual(record.steps.first?.localComplete, false)
        }
    }

    func testGenericMessageRequiresExplicitAssistantRole() {
        XCTAssertEqual(CodexJSONParser.parseLine(#"{"type":"item.completed","item":{"type":"message","role":"assistant","text":"ok"}}"#), [.text("ok\n")])
        for item in [
            #"{"type":"message","text":"not attributed"}"#,
            #"{"type":"message","role":true,"text":"invalid role"}"#,
            #"{"type":"agent_message","role":"user","text":"conflicting role"}"#
        ] {
            XCTAssertTrue(CodexJSONParser.parseLine("{\"type\":\"item.completed\",\"item\":\(item)}").isEmpty)
        }
    }

    func testCheckAndPlanRejectInvalidSandboxAndUnsupportedConstraints() throws {
        let root = try fixture()
        for extra: [String: Any] in [["sandbox": "typo"], ["allowed_tools": []], ["disallowed_tools": []], ["max_output_tokens": 10]] {
            try recipe(in: root, stepExtra: extra)
            XCTAssertThrowsError(try RecipeStore(paths: RecipePaths(workspace: root, home: root)).load("demo"))
            XCTAssertThrowsError(try ExecutionPlan.resolve("demo", options: RunOptions(workspace: root, home: root)))
        }
        try recipe(in: root, stepExtra: ["sandbox": "read-only"], backend: "shell")
        XCTAssertThrowsError(try RecipeStore(paths: RecipePaths(workspace: root, home: root)).load("demo"))
        XCTAssertThrowsError(try ExecutionPlan.resolve("demo", options: RunOptions(workspace: root, home: root)))
    }

    func testCLIBackendOverrideControlsValidationDuringLoadPlanAndRun() async throws {
        let root = try fixture(events: message + "\n" + completed + "\n")
        let definition: [String: Any] = ["name": "demo", "backend": "claude", "model": "fixture-model",
            "env": environment(root), "cloud": ["enabled": false], "steps": [
                ["label": "observe", "prompt": "Return FIXTURE_COMPLETE", "sandbox": "read-only",
                 "completion_keyword": "FIXTURE_COMPLETE", "timeout": 5]
            ]]
        try JSONSerialization.data(withJSONObject: definition).write(to: root.appendingPathComponent(".mentu/recipes/demo.json"))
        let store = RecipeStore(paths: RecipePaths(workspace: root, home: root))
        XCTAssertThrowsError(try store.load("demo"))
        XCTAssertNoThrow(try store.load("demo", backendOverride: "codex"))
        let options = RunOptions(workspace: root, home: root, backend: "codex", quiet: true)
        let plan = try ExecutionPlan.resolve("demo", options: options)
        XCTAssertEqual(plan.steps.first?.backend, "codex")
        let run = try await RecipeRunner(options: options).run("demo")
        XCTAssertEqual(run.outcome, "ok")
        XCTAssertEqual(run.steps.first?.backend, "codex")
        let args = try arguments(root)
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--sandbox")) + 1], "read-only")
    }

    func testCLIOverridePreservesStepPrecedenceAndRejectsControlsForTheResolvedBackend() throws {
        let root = try fixture()
        let cases: [(String, String, String?, [String: Any], Bool)] = [
            ("codex", "claude", nil, ["allowed_tools": []], true),
            ("claude", "codex", nil, ["max_output_tokens": 10], false),
            ("claude", "codex", "claude", ["sandbox": "read-only"], false),
            ("claude", "claude", "codex", ["sandbox": "read-only"], true)
        ]
        for (defaultBackend, override, explicitBackend, extra, accepted) in cases {
            var step: [String: Any] = ["label": "observe", "prompt": "fixture"]
            step.merge(extra) { _, new in new }
            if let explicitBackend { step["backend"] = explicitBackend }
            let definition: [String: Any] = ["name": "demo", "backend": defaultBackend,
                "model": "fixture-model", "steps": [step]]
            try JSONSerialization.data(withJSONObject: definition).write(to: root.appendingPathComponent(".mentu/recipes/demo.json"))
            let store = RecipeStore(paths: RecipePaths(workspace: root, home: root))
            let options = RunOptions(workspace: root, home: root, backend: override, quiet: true)
            if accepted {
                XCTAssertNoThrow(try store.load("demo", backendOverride: override))
                XCTAssertNoThrow(try ExecutionPlan.resolve("demo", options: options))
            } else {
                XCTAssertThrowsError(try store.load("demo", backendOverride: override))
                XCTAssertThrowsError(try ExecutionPlan.resolve("demo", options: options))
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("arguments.bin").path))
    }
}
