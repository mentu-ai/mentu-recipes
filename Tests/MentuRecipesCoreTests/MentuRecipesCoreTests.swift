import XCTest
@testable import MentuRecipesCore

final class MentuRecipesCoreTests: XCTestCase {
    func testPromptRendering() {
        let rendered = PromptRenderer.render("Hello $NAME from ${PLACE}", vars: ["NAME": "Mentu", "PLACE": "recipes"])
        XCTAssertEqual(rendered, "Hello Mentu from recipes")
    }

    func testRecipeDiscoveryAndValidation() throws {
        let root = try tempDir()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".mentu/recipes"), withIntermediateDirectories: true)
        let recipeURL = root.appendingPathComponent(".mentu/recipes/demo.json")
        try """
        {"name":"demo","steps":[{"label":"one","backend":"shell","prompt":"echo ok"}]}
        """.write(to: recipeURL, atomically: true, encoding: .utf8)

        let store = RecipeStore(paths: RecipePaths(workspace: root, home: root))
        let (recipe, url) = try store.load("demo")
        XCTAssertEqual(recipe.name, "demo")
        XCTAssertEqual(url.path, recipeURL.path)
    }

    func testRecipeFilesStayInRecipeRoots() throws {
        let root = try tempDir()
        let recipeURL = root.appendingPathComponent("outside.json")
        try """
        {"name":"outside","steps":[{"label":"one","backend":"shell","prompt":"echo no"}]}
        """.write(to: recipeURL, atomically: true, encoding: .utf8)
        let paths = RecipePaths(workspace: root, home: root)
        XCTAssertNil(paths.resolveRecipe(recipeURL.path))
    }

    func testDependencyCycleFails() throws {
        let steps = [
            RecipeStep(label: "a", backend: "shell", model: nil, prompt: "echo a", promptFile: nil, dir: nil, env: nil, timeout: nil, completionKeyword: nil, dependsOn: ["b"], maxRetries: nil, retryBackoffMs: nil, maxOutputBytes: nil, reasoning: nil, maxOutputTokens: nil, verify: nil),
            RecipeStep(label: "b", backend: "shell", model: nil, prompt: "echo b", promptFile: nil, dir: nil, env: nil, timeout: nil, completionKeyword: nil, dependsOn: ["a"], maxRetries: nil, retryBackoffMs: nil, maxOutputBytes: nil, reasoning: nil, maxOutputTokens: nil, verify: nil)
        ]
        let store = RecipeStore(paths: RecipePaths(workspace: try tempDir()))
        XCTAssertThrowsError(try store.topologicalOrder(steps))
    }

    func testPromptFilesStayInPromptRoots() throws {
        let root = try tempDir()
        let secret = root.appendingPathComponent("secret.txt")
        try "do-not-read".write(to: secret, atomically: true, encoding: .utf8)
        let paths = RecipePaths(workspace: root, home: root)
        XCTAssertNil(paths.resolvePrompt("../secret.txt"))
        XCTAssertNil(paths.resolvePrompt(secret.path))
    }

    func testPromptSymlinksCannotEscapePromptRoots() throws {
        let root = try tempDir()
        let prompts = root.appendingPathComponent(".mentu/prompts")
        try FileManager.default.createDirectory(at: prompts, withIntermediateDirectories: true)
        let secret = root.appendingPathComponent("secret.txt")
        try "do-not-read".write(to: secret, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: prompts.appendingPathComponent("linked.md"),
            withDestinationURL: secret
        )
        let paths = RecipePaths(workspace: root, home: root)
        XCTAssertNil(paths.resolvePrompt("linked.md"))
    }

    func testUnsafeStepLabelFailsValidation() throws {
        let recipe = RecipeDefinition(
            name: "bad-label",
            steps: [
                RecipeStep(label: "../escape", backend: "shell", model: nil, prompt: "echo bad", promptFile: nil, dir: nil, env: nil, timeout: nil, completionKeyword: nil, dependsOn: nil, maxRetries: nil, retryBackoffMs: nil, maxOutputBytes: nil, reasoning: nil, maxOutputTokens: nil, verify: nil)
            ]
        )
        let store = RecipeStore(paths: RecipePaths(workspace: try tempDir()))
        XCTAssertThrowsError(try store.validate(recipe))
    }

    func testShellRecipeRunsOffline() async throws {
        let root = try tempDir()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".mentu/recipes"), withIntermediateDirectories: true)
        try """
        {
          "name": "shell-test",
          "steps": [
            {
              "label": "one",
              "backend": "shell",
              "prompt": "echo SHELL_TEST_COMPLETE",
              "completion_keyword": "SHELL_TEST_COMPLETE",
              "timeout": 5
            }
          ]
        }
        """.write(to: root.appendingPathComponent(".mentu/recipes/shell-test.json"), atomically: true, encoding: .utf8)

        let runner = RecipeRunner(options: RunOptions(workspace: root, home: root, cloudEnabled: false, quiet: true))
        let result = try await runner.run("shell-test")
        XCTAssertEqual(result.outcome, "ok")
        XCTAssertEqual(result.steps.first?.localComplete, true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".mentu/runs/\(result.runId)/run.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".mentu/runs/\(result.runId)/events.jsonl").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".mentu/runs/\(result.runId)/state.json").path))
        XCTAssertFalse(RunReporter.loadEvents(runId: result.runId, workspace: root).isEmpty)
    }

    func testStepDirCannotEscapeWorkspace() async throws {
        let root = try tempDir()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".mentu/recipes"), withIntermediateDirectories: true)
        try """
        {
          "name": "dir-escape",
          "steps": [
            {
              "label": "one",
              "backend": "shell",
              "dir": "../",
              "prompt": "echo should-not-run"
            }
          ]
        }
        """.write(to: root.appendingPathComponent(".mentu/recipes/dir-escape.json"), atomically: true, encoding: .utf8)

        let runner = RecipeRunner(options: RunOptions(workspace: root, home: root, cloudEnabled: false, quiet: true))
        let result = try await runner.run("dir-escape")
        XCTAssertEqual(result.outcome, "failed")
        XCTAssertEqual(result.steps.first?.attempts, 0)
    }

    func testCredentialEnvAliases() {
        XCTAssertTrue(CredentialResolver.keychainCandidates(for: "OPENAI_API_KEY").contains("openai-api-key"))
        XCTAssertTrue(CredentialResolver.keychainCandidates(for: "DEEPSEEK_API_KEY").contains("deepseek-api-key"))
        XCTAssertTrue(CredentialResolver.keychainCandidates(for: "MENTU_API_KEY").contains("mentu-api-key"))
    }

    func testAdapterRegistryMetadata() {
        XCTAssertEqual(AdapterRegistry.adapter(named: "shell")?.completionPolicy, .shellExitCode)
        XCTAssertEqual(AdapterRegistry.adapter(named: "shell")?.systemContextHandling, .ignored)
        XCTAssertEqual(AdapterRegistry.adapter(named: "shell")?.capabilities.canRunOffline, true)
        XCTAssertEqual(AdapterRegistry.adapter(named: "openai")?.executionKind, "llm-http")
        XCTAssertEqual(AdapterRegistry.adapter(named: "openai")?.streamFormat, .openAISSE)
        XCTAssertEqual(AdapterRegistry.adapter(named: "openai")?.capabilities.requiresCredential, true)
        XCTAssertEqual(AdapterRegistry.adapter(named: "deepseek")?.executionKind, "llm-http")
        XCTAssertEqual(AdapterRegistry.adapter(named: "claude")?.executionKind, "agent-cli")
        XCTAssertEqual(AdapterRegistry.adapter(named: "claude")?.streamFormat, .claudeJSON)
        XCTAssertEqual(AdapterRegistry.adapter(named: "codex")?.executionKind, "agent-cli")
        XCTAssertEqual(AdapterRegistry.adapter(named: "codex")?.streamFormat, .codexJSON)
        XCTAssertEqual(AdapterRegistry.adapter(named: "codex")?.completionPolicy, .providerCompleteEvent)
    }

    func testCodexJSONParserSuppressesCLIChrome() {
        XCTAssertTrue(CodexJSONParser.parseLine("OpenAI Codex v0.130.0").isEmpty)
        XCTAssertTrue(CodexJSONParser.parseLine("2026-05-18T02:08:44Z  WARN codex_core_plugins::manifest: ignoring interface.defaultPrompt").isEmpty)
        XCTAssertTrue(CodexJSONParser.parseLine("<html>").isEmpty)

        let message = CodexJSONParser.parseLine(#"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"hello from codex"}}"#)
        XCTAssertEqual(message, [.text("hello from codex\n")])

        let complete = CodexJSONParser.parseLine(#"{"type":"turn.completed","usage":{"input_tokens":11,"output_tokens":7}}"#)
        XCTAssertEqual(complete, [.complete(inputTokens: 11, outputTokens: 7)])

        let nestedError = CodexJSONParser.parseLine(#"{"type":"error","message":"{\"error\":{\"message\":\"model is not supported\"}}"}"#)
        XCTAssertEqual(nestedError, [.failure("model is not supported")])
    }

    func testClaudeJSONParserStreamsTextAndSuppressesDiagnostics() {
        XCTAssertTrue(ClaudeJSONParser.parseLineForTest("2026-05-18T02:08:44Z  WARN claude_core::session: noisy").isEmpty)
        XCTAssertTrue(ClaudeJSONParser.parseLineForTest("event: message_start").isEmpty)

        let message = ClaudeJSONParser.parseLineForTest(#"{"type":"assistant","message":{"content":[{"type":"text","text":"hello from claude\n"}]}}"#)
        XCTAssertEqual(message, [.text("hello from claude\n")])

        let complete = ClaudeJSONParser.parseLineForTest(#"{"type":"result","usage":{"input_tokens":3,"output_tokens":5}}"#)
        XCTAssertEqual(complete, [.complete(inputTokens: 3, outputTokens: 5)])
    }

    func testProviderLogSanitizerSuppressesAgentDiagnosticsButKeepsShellRaw() {
        XCTAssertTrue(ProviderLogSanitizer.isSuppressibleAgentDiagnostic("OpenAI Codex v0.130.0", backend: "codex"))
        XCTAssertTrue(ProviderLogSanitizer.isSuppressibleAgentDiagnostic("2026-05-18T02:08:44Z ERROR codex_core::session: failed to load skill x", backend: "codex"))
        XCTAssertTrue(ProviderLogSanitizer.isSuppressibleAgentDiagnostic("2026-05-18T02:08:44Z WARN codex_core::session_startup_prewarm: startup websocket prewarm setup failed: {\"error\":{\"message\":\"model is not supported\"}}", backend: "codex"))
        XCTAssertEqual(ProviderLogSanitizer.userActionableError("ERROR: API key auth is missing"), "ERROR: API key auth is missing")
        XCTAssertEqual(ShellAdapter().streamFormat, .plainText)
    }

    func testClaudeAgentEnvironmentDoesNotInheritOtherProviderSecrets() {
        let sanitized = ClaudeCLIAdapter.agentEnvironment(from: [
            "PATH": "/usr/bin",
            "HOME": "/tmp/home",
            "OPENAI_API_KEY": "sk-test",
            "DEEPSEEK_API_KEY": "deepseek-test",
            "CLAUDE_CODE_OAUTH_TOKEN": "claude-token",
            "ANTHROPIC_API_KEY": "anthropic-key"
        ])
        XCTAssertEqual(sanitized["PATH"], "/usr/bin")
        XCTAssertEqual(sanitized["ANTHROPIC_API_KEY"], "anthropic-key")
        XCTAssertNil(sanitized["OPENAI_API_KEY"])
        XCTAssertNil(sanitized["DEEPSEEK_API_KEY"])
        XCTAssertNil(sanitized["CLAUDE_CODE_OAUTH_TOKEN"])
    }

    func testProviderCredentialsCannotBeSentToUnexpectedHosts() async throws {
        let adapter = OpenAIChatAdapter(
            name: "evil",
            baseURL: "https://example.com/v1",
            apiKeyEnv: "OPENAI_API_KEY",
            apiKeyVault: nil,
            defaultModel: "gpt-test",
            requiresAuth: true
        )
        do {
            _ = try await adapter.execute(
                AdapterRequest(
                    prompt: "hello",
                    systemContext: nil,
                    model: nil,
                    env: ["OPENAI_API_KEY": "sk-test-secret"],
                    timeout: 1,
                    maxOutputBytes: 1024,
                    reasoning: nil,
                    maxOutputTokens: nil,
                    workingDirectory: try tempDir()
                ),
                eventSink: { _ in }
            )
            XCTFail("Expected provider credential policy failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("cannot send OpenAI credentials"))
        }
    }

    func testReleaseScannerFindsProtectedContent() throws {
        let root = try tempDir()
        let file = root.appendingPathComponent("bad.txt")
        let localPath = ["/Users", "rashid", "Desktop"].joined(separator: "/")
        let protected = ["Sub", "trace"].joined()
        try "hello \(localPath)/\(protected)".write(to: file, atomically: true, encoding: .utf8)
        let findings = ReleaseScanner.scan(root: root)
        XCTAssertFalse(findings.isEmpty)
    }

    func testReleaseScannerFindsProtectedPaths() throws {
        let root = try tempDir()
        let protectedDir = root
            .appendingPathComponent(".mentu")
            .appendingPathComponent(["c", "ir"].joined())
            .appendingPathComponent("signals")
        try FileManager.default.createDirectory(at: protectedDir, withIntermediateDirectories: true)
        let file = protectedDir.appendingPathComponent("signal.json")
        try #"{"ok":true}"#.write(to: file, atomically: true, encoding: .utf8)
        let findings = ReleaseScanner.scan(root: root)
        XCTAssertTrue(findings.contains { $0.reason == "protected internal path" })
    }

    func testReleaseScannerFindsBinaryArtifactLeaks() throws {
        let root = try tempDir()
        let artifact = root.appendingPathComponent("mentu-recipes.bin")
        var data = Data([0x00, 0xff, 0x7f, 0x01])
        data.append(Data("safe prefix ".utf8))
        data.append(Data(["Ghi", "dra"].joined().utf8))
        data.append(Data(" suffix".utf8))
        try data.write(to: artifact)

        let findings = ReleaseScanner.scan(paths: [artifact])
        XCTAssertTrue(findings.contains { $0.file == "mentu-recipes.bin" && $0.reason.contains("protected internal term") })
    }

    func testMockCloudClient() async throws {
        MockURLProtocol.responses = [
            "/v1/recipes/runs/start": #"{"runId":"cloud-run","windowStart":"2026-01-01T00:00:00Z"}"#,
            "/v1/recipes/evaluate-step": #"{"complete":true,"trust_score":0.91,"trust_mode":"MONITORED","flags":[],"recommendation":"advance"}"#,
            "/v1/recipes/runs/end": #"{"runId":"cloud-run","status":"updated"}"#
        ]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = MentuCloudClient(baseURL: URL(string: "https://api.test")!, apiKey: "mk_test", session: session)

        let start = try await client.startRun(recipeName: "demo", workspaceID: "w")
        XCTAssertEqual(start.runId, "cloud-run")
        let verdict = try await client.evaluateStep(.init(run_id: start.runId, recipe_name: "demo", step_label: "one", backend: "shell", model: nil, exit_code: 0, local_complete: true, output_tail: "ok", duration_seconds: 1))
        XCTAssertEqual(verdict.complete, true)
        XCTAssertEqual(verdict.trust_score, 0.91)
        let end = try await client.endRun(runId: start.runId, outcome: "ok")
        XCTAssertEqual(end.status, "updated")
    }

    func testGitAutoCommitAndQuarantine() async throws {
        let root = try tempDir()
        _ = try await git(["init"], cwd: root)
        _ = try await git(["config", "user.name", "Mentu Recipes Test"], cwd: root)
        _ = try await git(["config", "user.email", "recipes-test@mentu.ai"], cwd: root)
        try "seed\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try await git(["add", "README.md"], cwd: root)
        _ = try await git(["commit", "-m", "seed"], cwd: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".mentu/recipes"), withIntermediateDirectories: true)
        try """
        {
          "name": "git-safety",
          "steps": [
            {
              "label": "write",
              "backend": "shell",
              "prompt": "echo EXPECTED_COMPLETE > expected.txt && echo surprise > unexpected.txt && echo EXPECTED_COMPLETE",
              "completion_keyword": "EXPECTED_COMPLETE",
              "expected_changes": ["expected.txt"],
              "timeout": 5
            }
          ]
        }
        """.write(to: root.appendingPathComponent(".mentu/recipes/git-safety.json"), atomically: true, encoding: .utf8)

        let result = try await RecipeRunner(options: RunOptions(workspace: root, home: root, cloudEnabled: false, quiet: true)).run("git-safety")
        XCTAssertEqual(result.outcome, "ok")
        let step = try XCTUnwrap(result.steps.first)
        XCTAssertNotNil(step.git?.committedHash)
        XCTAssertEqual(step.git?.quarantineFiles.count, 1)
        let committed = try await git(["show", "--name-only", "--format=", "HEAD"], cwd: root)
        XCTAssertTrue(committed.stdout.contains("expected.txt"))
        XCTAssertFalse(committed.stdout.contains("unexpected.txt"))
    }

    func testHooksAreRecorded() async throws {
        let root = try tempDir()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".mentu/recipes"), withIntermediateDirectories: true)
        try """
        {
          "name": "hooks",
          "hooks": {
            "before_step": ["echo before > hook-before.txt"],
            "after_step": ["echo after > hook-after.txt"]
          },
          "steps": [
            {
              "label": "one",
              "backend": "shell",
              "prompt": "echo HOOK_COMPLETE",
              "completion_keyword": "HOOK_COMPLETE",
              "timeout": 5
            }
          ]
        }
        """.write(to: root.appendingPathComponent(".mentu/recipes/hooks.json"), atomically: true, encoding: .utf8)

        let result = try await RecipeRunner(options: RunOptions(workspace: root, home: root, cloudEnabled: false, quiet: true)).run("hooks")
        XCTAssertEqual(result.outcome, "ok")
        XCTAssertEqual(result.steps.first?.hooks?.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("hook-before.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("hook-after.txt").path))
    }

    func testDAGStepsRunInParallelWaves() async throws {
        let root = try tempDir()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".mentu/recipes"), withIntermediateDirectories: true)
        try """
        {
          "name": "dag",
          "max_parallel": 2,
          "steps": [
            {"label":"a","backend":"shell","prompt":"sleep 1; echo A > a.txt","timeout":5},
            {"label":"b","backend":"shell","prompt":"sleep 1; echo B > b.txt","timeout":5},
            {"label":"c","backend":"shell","depends_on":["a","b"],"prompt":"cat a.txt b.txt > c.txt","timeout":5}
          ]
        }
        """.write(to: root.appendingPathComponent(".mentu/recipes/dag.json"), atomically: true, encoding: .utf8)

        let start = Date()
        let result = try await RecipeRunner(options: RunOptions(workspace: root, home: root, cloudEnabled: false, quiet: true, maxParallel: 2)).run("dag")
        XCTAssertEqual(result.outcome, "ok")
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("c.txt").path))
    }

    func testEventLogToleratesMalformedTrailingLine() async throws {
        let root = try tempDir()
        let runDir = root.appendingPathComponent(".mentu/runs/run_test")
        let writer = RunEventWriter(runId: "run_test", recipeName: "demo", runDir: runDir)
        await writer.emit(.runStarted, status: "running")
        let url = runDir.appendingPathComponent("events.jsonl")
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{not-json".utf8))
        try handle.close()
        XCTAssertEqual(RunEventWriter.load(from: url).count, 1)
    }

    func testBookkeepingVerificationWarningUnblocksDownstream() async throws {
        let root = try tempDir()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".mentu/recipes"), withIntermediateDirectories: true)
        try """
        {
          "name": "warn-contract",
          "steps": [
            {
              "label": "write",
              "backend": "shell",
              "prompt": "echo OK > actual.txt && echo WRITE_COMPLETE",
              "completion_keyword": "WRITE_COMPLETE",
              "verify": {
                "grep_present": [
                  {"file":"missing-bookkeeping.txt","pattern":"STALE"}
                ]
              }
            },
            {
              "label": "after",
              "backend": "shell",
              "depends_on": ["write"],
              "prompt": "echo AFTER_COMPLETE > after.txt && echo AFTER_COMPLETE",
              "completion_keyword": "AFTER_COMPLETE"
            }
          ]
        }
        """.write(to: root.appendingPathComponent(".mentu/recipes/warn-contract.json"), atomically: true, encoding: .utf8)

        let result = try await RecipeRunner(options: RunOptions(workspace: root, home: root, cloudEnabled: false, quiet: true)).run("warn-contract")
        XCTAssertEqual(result.outcome, "ok")
        XCTAssertEqual(result.steps.first?.outcome, StepExecutionState.warnBookkeeping.rawValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("after.txt").path))
    }

    func testGitCleanOutsideIgnoresPreexistingDirtyFiles() async throws {
        let root = try tempDir()
        _ = try await git(["init"], cwd: root)
        _ = try await git(["config", "user.name", "Mentu Recipes Test"], cwd: root)
        _ = try await git(["config", "user.email", "recipes-test@mentu.ai"], cwd: root)
        try "seed\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try await git(["add", "README.md"], cwd: root)
        _ = try await git(["commit", "-m", "seed"], cwd: root)
        try "preexisting\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".mentu/recipes"), withIntermediateDirectories: true)
        try """
        {
          "name": "baseline-clean",
          "steps": [
            {
              "label": "write",
              "backend": "shell",
              "prompt": "echo OK > allowed.txt && echo BASELINE_COMPLETE",
              "completion_keyword": "BASELINE_COMPLETE",
              "expected_changes": ["allowed.txt"],
              "verify": {"git_clean_outside": ["allowed.txt"]}
            }
          ]
        }
        """.write(to: root.appendingPathComponent(".mentu/recipes/baseline-clean.json"), atomically: true, encoding: .utf8)

        let result = try await RecipeRunner(options: RunOptions(workspace: root, home: root, cloudEnabled: false, quiet: true)).run("baseline-clean")
        XCTAssertEqual(result.outcome, "ok")
        XCTAssertEqual(result.steps.first?.git?.preexistingPaths?.contains("README.md"), true)
    }

    func testResumeRerunsOnlyIncompleteSteps() async throws {
        let root = try tempDir()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".mentu/recipes"), withIntermediateDirectories: true)
        try """
        {
          "name": "resume-demo",
          "steps": [
            {"label":"first","backend":"shell","prompt":"echo first >> first.txt && echo FIRST_COMPLETE","completion_keyword":"FIRST_COMPLETE"},
            {"label":"second","backend":"shell","prompt":"test -f marker && echo SECOND_COMPLETE > second.txt && echo SECOND_COMPLETE","completion_keyword":"SECOND_COMPLETE"}
          ]
        }
        """.write(to: root.appendingPathComponent(".mentu/recipes/resume-demo.json"), atomically: true, encoding: .utf8)

        let runner = RecipeRunner(options: RunOptions(workspace: root, home: root, cloudEnabled: false, quiet: true))
        let failed = try await runner.run("resume-demo")
        XCTAssertEqual(failed.outcome, "failed")
        try "go\n".write(to: root.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
        let resumed = try await runner.resume(runId: failed.runId)
        XCTAssertEqual(resumed.outcome, "ok")
        let first = try String(contentsOf: root.appendingPathComponent("first.txt"), encoding: .utf8)
        XCTAssertEqual(first.split(separator: "\n").count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("second.txt").path))
    }

    func testDoctorAndAnalyzerProduceLocalIntelligence() async throws {
        let root = try tempDir()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".mentu/recipes"), withIntermediateDirectories: true)
        try """
        {"name":"doctor-demo","backend":"ollama","steps":[{"label":"ask","prompt":"Write a file called output.txt"}]}
        """.write(to: root.appendingPathComponent(".mentu/recipes/doctor-demo.json"), atomically: true, encoding: .utf8)
        let report = RecipeDoctor.inspect("doctor-demo", store: RecipeStore(paths: RecipePaths(workspace: root, home: root)))
        XCTAssertTrue(report.findings.contains { $0.code == "missing_completion_signal" })

        try """
        {"name":"analysis-demo","steps":[{"label":"one","backend":"shell","prompt":"echo ANALYSIS_COMPLETE","completion_keyword":"ANALYSIS_COMPLETE"}]}
        """.write(to: root.appendingPathComponent(".mentu/recipes/analysis-demo.json"), atomically: true, encoding: .utf8)
        _ = try await RecipeRunner(options: RunOptions(workspace: root, home: root, cloudEnabled: false, quiet: true)).run("analysis-demo")
        let summary = RunAnalyzer.analyze(workspace: root)
        XCTAssertEqual(summary.runs, 1)
        XCTAssertEqual(summary.workspace, "redacted")
    }

    func testGitCleanOutsideSatisfiesWriteBoundaryCheck() throws {
        let root = try tempDir()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".mentu/recipes"), withIntermediateDirectories: true)
        let store = RecipeStore(paths: RecipePaths(workspace: root, home: root))

        try """
        {"name":"unbounded","steps":[{"label":"write","backend":"shell","prompt":"printf x > out/a.txt","completion_keyword":"OK"}]}
        """.write(to: root.appendingPathComponent(".mentu/recipes/unbounded.json"), atomically: true, encoding: .utf8)
        XCTAssertTrue(RecipeDoctor.inspect("unbounded", store: store).findings.contains { $0.code == "missing_expected_changes" })

        // `verify.git_clean_outside` bounds the writes without committing, which is the
        // only boundary concurrent steps can safely declare. The doctor recommends it, so
        // it has to count as a declared boundary.
        try """
        {"name":"bounded","steps":[{"label":"write","backend":"shell","prompt":"printf x > out/a.txt","completion_keyword":"OK","verify":{"git_clean_outside":["out"]}}]}
        """.write(to: root.appendingPathComponent(".mentu/recipes/bounded.json"), atomically: true, encoding: .utf8)
        XCTAssertFalse(RecipeDoctor.inspect("bounded", store: store).findings.contains { $0.code == "missing_expected_changes" })
    }

    func testRunReporterRendersMarkdownAndCSV() async throws {
        let root = try tempDir()
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".mentu/recipes"), withIntermediateDirectories: true)
        try """
        {"name":"report-demo","steps":[{"label":"one","backend":"shell","prompt":"echo REPORT_COMPLETE","completion_keyword":"REPORT_COMPLETE"}]}
        """.write(to: root.appendingPathComponent(".mentu/recipes/report-demo.json"), atomically: true, encoding: .utf8)

        let result = try await RecipeRunner(options: RunOptions(workspace: root, home: root, cloudEnabled: false, quiet: true)).run("report-demo")
        let loaded = try RunReporter.load(runId: result.runId, workspace: root)
        XCTAssertTrue(try RunReporter.render(loaded, format: .markdown).contains("report-demo"))
        let csv = try RunReporter.render(loaded, format: .csv)
        XCTAssertTrue(csv.contains("report-demo"))
        XCTAssertTrue(csv.contains("one"))
    }

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mentu-recipes-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func git(_ args: [String], cwd: URL) async throws -> AdapterResult {
        try await ProcessRunner.run(
            executable: ProcessRunner.findExecutable("git") ?? "/usr/bin/git",
            arguments: args,
            env: ProcessInfo.processInfo.environment,
            workingDirectory: cwd,
            timeout: 30,
            maxOutputBytes: 1_000_000,
            eventSink: { _ in }
        )
    }
}

final class MockURLProtocol: URLProtocol {
    static var responses: [String: String] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let body = Self.responses[path] ?? "{}"
        let data = Data(body.utf8)
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
