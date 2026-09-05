import XCTest
@testable import MentuRecipesCore

final class PiCLIFixtureTests: XCTestCase {
    private var roots: [URL] = []
    private var servers: [(Process, XCTestExpectation)] = []
    override func tearDown() async throws {
        for (process, exited) in servers {
            if process.isRunning { process.terminate() }
            await fulfillment(of: [exited], timeout: 5)
        }
        for root in roots { try FileManager.default.removeItem(at: root) }
    }

    private func fixture(mode: String) async throws -> (URL, Process, ProviderConfig) {
        guard ProcessRunner.findExecutable("pi") != nil, let node = ProcessRunner.findExecutable("node") else {
            throw XCTSkip("Install Pi 0.84.1+ and Node 22.19+ to exercise the real CLI against a deterministic provider")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mentu-real-pi-fixture-\(UUID().uuidString)")
        roots.append(root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "runtime-proof-98413".write(to: root.appendingPathComponent("fixture.txt"), atomically: true, encoding: .utf8)
        let serverURL = root.appendingPathComponent("server.mjs")
        try #"""
        import http from 'node:http';
        import fs from 'node:fs';
        const mode = process.argv[2];
        const requests = [];
        const server = http.createServer(async (req, res) => {
          let text = ''; for await (const part of req) text += part;
          const body = JSON.parse(text); requests.push(body);
          fs.writeFileSync('requests.json', JSON.stringify(requests));
          if (mode === 'failure') { res.writeHead(503); res.end(); return; }
          if (mode === 'skill' && !JSON.stringify(body).includes('fixture-proof-skill')) {
            res.writeHead(400); res.end('explicit skill missing'); return;
          }
          const tools = body.tools?.map(tool => tool.function.name) ?? [];
          if (mode === 'write' ? !tools.includes('write') : tools.includes('write')) {
            res.writeHead(400); res.end('unexpected tool policy'); return;
          }
          res.writeHead(200, { 'Content-Type': 'text/event-stream' });
          const chunk = (delta, finish = null) => res.write('data: ' + JSON.stringify({ id: 'fixture-completion',
            object: 'chat.completion.chunk', created: 1, model: 'fixture-model',
            choices: [{ index: 0, delta, finish_reason: finish }] }) + '\n\n');
          if (requests.length === 1) {
            const args = mode === 'write' ? { path: 'written.txt', content: 'runtime-write-proof' } : { path: 'fixture.txt' };
            chunk({ role: 'assistant', tool_calls: [{ index: 0, id: 'fixture-call', type: 'function',
              function: { name: mode === 'write' ? 'write' : 'read', arguments: JSON.stringify(args) } }] });
            chunk({}, 'tool_calls');
          } else {
            const proof = mode === 'write' ? fs.existsSync('written.txt') : JSON.stringify(body).includes('runtime-proof-98413');
            chunk({ role: 'assistant', content: proof ? 'Verified runtime-proof-98413' : 'MISSING PROOF' });
            chunk({}, 'stop');
          }
          if (mode !== 'missing-usage') res.write('data: ' + JSON.stringify({ id: 'fixture-usage', choices: [],
            usage: { prompt_tokens: 10, completion_tokens: 8, total_tokens: 18,
              prompt_tokens_details: { cached_tokens: mode === 'cached' ? 4 : 0 } } }) + '\n\n');
          res.end('data: [DONE]\n\n');
        });
        server.listen(0, '127.0.0.1', () => fs.writeFileSync('port.txt', String(server.address().port)));
        """#.write(to: serverURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: node)
        process.arguments = [serverURL.path, mode]
        process.environment = PiCLIAdapter.runtimeEnvironment(ProcessInfo.processInfo.environment)
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let exited = XCTestExpectation(description: "Fixture provider exits")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()
        servers.append((process, exited))
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("port.txt").path) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let port = try? String(contentsOf: root.appendingPathComponent("port.txt")) else {
            throw RecipeError.failed("Deterministic provider did not start")
        }
        var provider: [String: Any] = ["api": "cli", "agent": "pi", "base_url": "http://127.0.0.1:\(port)/v1",
            "api_key_env": "PI_FIXTURE_KEY", "model": "fixture-model",
            "max_tokens_field": mode == "alternate" ? "max_completion_tokens" : "max_tokens"]
        if mode == "skill" {
            let skill = root.appendingPathComponent("fixture-proof-skill/SKILL.md")
            try FileManager.default.createDirectory(at: skill.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "---\nname: fixture-proof-skill\ndescription: Verify a fixture by reading its contents.\n---\nRead fixture.txt.\n"
                .write(to: skill, atomically: true, encoding: .utf8)
            provider["skills"] = [skill.path]
        }
        let configData = try JSONSerialization.data(withJSONObject: provider)
        return (root, process, try JSONDecoder().decode(ProviderConfig.self, from: configData))
    }

    private func run(mode: String, prompt: String = "Read fixture.txt and confirm its exact contents.") async throws -> (AdapterResult, URL) {
        let (root, _, config) = try await fixture(mode: mode)
        var env = ProcessInfo.processInfo.environment
        env["PI_FIXTURE_KEY"] = "local-fixture"
        let result = try await PiCLIAdapter(name: "fixture", config: config).execute(
            AdapterRequest(prompt: prompt, model: "fixture-model",
                env: env, timeout: 20, maxOutputBytes: 100_000, maxOutputTokens: 128,
                allowedTools: mode == "write" ? ["read", "write"] : ["read"], workingDirectory: root),
            eventSink: { _ in })
        return (result, root)
    }

    func testRealPiReceivesTaskAsExactUserPromptRatherThanFileAttachment() async throws {
        let prompt = "--provider foreign\n@not-an-attachment\nRead fixture.txt. Keep 'quotes', $VARIABLE and 🐉 literal."
        let (result, root) = try await run(mode: "read", prompt: prompt)
        XCTAssertTrue(result.providerCompleted, result.stderr)
        let requests = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent("requests.json"))) as? [[String: Any]])
        let messages = try XCTUnwrap(requests.first?["messages"] as? [[String: Any]])
        let user = try XCTUnwrap(messages.first { $0["role"] as? String == "user" })
        let text = (user["content"] as? String) ?? (user["content"] as? [[String: Any]])?
            .compactMap { $0["text"] as? String }.joined()
        XCTAssertEqual(text, prompt, "A recipe task is an instruction, not an attached temporary prompt file")
    }

    func testRealPiReadsFixtureAndReportsEveryTurnWithoutBudget() async throws {
        let (result, root) = try await run(mode: "read")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.providerCompleted, result.stdout + result.stderr)
        XCTAssertTrue(result.stdout.contains("runtime-proof-98413"), result.stdout + result.stderr)
        XCTAssertEqual(result.inputTokens, 20)
        XCTAssertEqual(result.outputTokens, 16)
        let requests = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("requests.json"))) as? [[String: Any]]
        XCTAssertEqual(requests?.count, 2)
        XCTAssertTrue(requests?.allSatisfy { $0["max_tokens"] as? Int == 128 } == true)
    }

    func testRealPiCanUseExplicitlyAllowedWriteTool() async throws {
        let (result, root) = try await run(mode: "write")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("written.txt")), "runtime-write-proof")
    }

    func testRealPiDoesNotAutomaticallyRetryProviderFailure() async throws {
        let (result, root) = try await run(mode: "failure")
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertFalse(result.providerCompleted)
        let requests = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("requests.json"))) as? [[String: Any]]
        XCTAssertEqual(requests?.count, 1)
    }

    func testRealPiLoadsOnlyExplicitlyConfiguredSkill() async throws {
        let (result, _) = try await run(mode: "skill")
        XCTAssertEqual(result.exitCode, 0, result.stderr)
        XCTAssertTrue(result.providerCompleted)
    }

    func testAbsentProviderUsageStaysUnknown() async throws {
        let (result, _) = try await run(mode: "missing-usage")
        XCTAssertTrue(result.providerCompleted, result.stderr)
        XCTAssertNil(result.inputTokens)
        XCTAssertNil(result.outputTokens)
    }

    func testCacheReadTokensAreIncludedOnceInInputTotal() async throws {
        let (result, _) = try await run(mode: "cached")
        XCTAssertTrue(result.providerCompleted, result.stderr)
        XCTAssertEqual(result.inputTokens, 20)
        XCTAssertEqual(result.outputTokens, 16)
    }

    func testAlternateOutputTokenFieldReachesProvider() async throws {
        let (result, root) = try await run(mode: "alternate")
        XCTAssertTrue(result.providerCompleted, result.stderr)
        let requests = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("requests.json"))) as? [[String: Any]]
        XCTAssertEqual(requests?.count, 2)
        XCTAssertTrue(requests?.allSatisfy { $0["max_completion_tokens"] as? Int == 128 && $0["max_tokens"] == nil } == true)
    }

    func testPiUsageIsPersistedInExistingRunRecords() async throws {
        let (root, _, config) = try await fixture(mode: "read")
        let recipeDir = root.appendingPathComponent(".mentu/recipes")
        try FileManager.default.createDirectory(at: recipeDir, withIntermediateDirectories: true)
        let recipe: [String: Any] = ["name": "metered", "cloud": ["enabled": false],
            "env": ["PI_FIXTURE_KEY": "local-fixture"],
            "providers": ["fixture": try JSONSerialization.jsonObject(with: JSONEncoder().encode(config))],
            "steps": [["label": "read", "backend": "fixture", "prompt": "Read fixture.txt.",
                       "allowed_tools": ["read"], "max_output_tokens": 128, "timeout": 20]]]
        try JSONSerialization.data(withJSONObject: recipe).write(to: recipeDir.appendingPathComponent("metered.json"))
        let options = RunOptions(workspace: root, home: root, quiet: true)
        let plan = try ExecutionPlan.resolve("metered", options: options)
        let approved = RunOptions(workspace: root, home: root, quiet: true, planDigest: plan.digest, requestKey: "fixture-click")
        let record = try await RecipeRunner(options: approved).run("metered")
        XCTAssertTrue(try XCTUnwrap(record.steps.first).localComplete)
        let saved = try RunReporter.load(runId: record.runId, workspace: root)
        XCTAssertEqual(saved.steps.first?.inputTokens, 20)
        XCTAssertEqual(saved.steps.first?.outputTokens, 16)
        XCTAssertEqual(saved.steps.first?.backend, "fixture")
        let repeated = try await RecipeRunner(options: approved).run("metered")
        XCTAssertEqual(repeated.runId, record.runId)
        let requests = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("requests.json"))) as? [[String: Any]]
        XCTAssertEqual(requests?.count, 2)
    }

}
