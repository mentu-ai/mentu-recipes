import XCTest
@testable import MentuRecipesCore

final class PiJSONParserTests: XCTestCase {
    private func event(_ message: String) -> String { "{\"type\":\"message_end\",\"message\":\(message)}\n" }
    private let tool = #"{"role":"assistant","stopReason":"toolUse","usage":{"input":6,"cacheRead":4,"cacheWrite":2,"output":8}}"#
    private let final = #"{"role":"assistant","stopReason":"stop","usage":{"input":7,"output":9},"content":[{"type":"text","text":"done"}]}"#

    func testUsageAddsEveryAssistantTurnWithoutCountingAgentEndAgain() {
        var parser = PiJSONParser()
        _ = parser.parse(event(tool) + event(final))
        _ = parser.parse("{\"type\":\"agent_end\",\"messages\":[\(tool),\(final)]}\n")
        XCTAssertEqual(parser.inputTokens, 19)
        XCTAssertEqual(parser.outputTokens, 17)
        XCTAssertTrue(parser.completed)
        XCTAssertFalse(parser.failed)
    }

    func testFinalEventOnlyCanReportUsageAndTextAcrossChunks() {
        var parser = PiJSONParser()
        _ = parser.parse("{\"type\":\"agent_end\",\"messages\":[")
        _ = parser.parse("\(tool),\(final)]}")
        parser.finish()
        XCTAssertEqual(parser.inputTokens, 19)
        XCTAssertEqual(parser.outputTokens, 17)
        XCTAssertEqual(parser.text, "done")
    }

    func testUnknownInvalidOrPartialUsageDoesNotBecomeZero() {
        for usage in ["null", "{}", #"{"input":0,"output":0}"#,
                      #"{"input":true,"output":8}"#, #"{"input":-1,"output":8}"#,
                      #"{"input":1.5,"output":8}"#, #"{"input":1e100,"output":8}"#,
                      #"{"input":6,"output":8,"cacheRead":-1}"#] {
            var parser = PiJSONParser()
            _ = parser.parse(event(tool) + event("{\"role\":\"assistant\",\"stopReason\":\"stop\",\"usage\":\(usage)}"))
            XCTAssertNil(parser.inputTokens, usage)
            XCTAssertNil(parser.outputTokens, usage)
        }
    }

    func testLengthErrorAndMissingFinalEventDoNotComplete() {
        for reason in ["length", "error", "aborted", "toolUse"] {
            var parser = PiJSONParser()
            _ = parser.parse("{\"type\":\"agent_end\",\"messages\":[{\"role\":\"assistant\",\"stopReason\":\"\(reason)\"}]}\n")
            XCTAssertFalse(parser.completed)
            XCTAssertTrue(parser.failed)
        }
        var parser = PiJSONParser()
        _ = parser.parse(event(final))
        parser.finish()
        XCTAssertFalse(parser.completed)
    }

    func testEarlierErrorCannotBeHiddenBySuccessfulAgentEnd() {
        var parser = PiJSONParser()
        _ = parser.parse(event(#"{"role":"assistant","stopReason":"error"}"#))
        _ = parser.parse("{\"type\":\"agent_end\",\"messages\":[\(final)]}\n")
        XCTAssertTrue(parser.failed)
        XCTAssertNil(parser.inputTokens)
    }

    func testMalformedAndOversizedStreamsFailClosed() {
        var malformed = PiJSONParser()
        _ = malformed.parse("not JSON\n")
        XCTAssertTrue(malformed.failed)
        var bounded = PiJSONParser(maxBytes: 2)
        _ = bounded.parse(#"{"type":"message_update","assistantMessageEvent":{"type":"text_delta","delta":"too large"}}"# + "\n")
        XCTAssertTrue(bounded.failed)
        XCTAssertEqual(bounded.text, "")
    }

    func testPiIsExplicitAndEnvironmentDropsForeignCredentialsAndExtensions() {
        let adapter = AdapterRegistry.adapter(named: "pi")
        XCTAssertEqual(adapter?.isAutoDetectable, false)
        XCTAssertEqual(adapter?.capabilities.reportsTokenUsage, true)
        let env = PiCLIAdapter.runtimeEnvironment(["HOME": "/fixture", "PATH": "/bin", "OPENAI_API_KEY": "foreign",
            "ANTHROPIC_API_KEY": "foreign", "PI_CODING_AGENT_DIR": "/unreviewed", "NODE_OPTIONS": "unreviewed", "HTTP_PROXY": "unreviewed"])
        XCTAssertEqual(env, ["HOME": "/fixture", "PATH": "/bin"])
    }

    func testProfileContainsOnlyCredentialReferenceAndExplicitResources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mentu-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = try JSONDecoder().decode(ProviderConfig.self, from: Data(#"{"api":"cli","agent":"pi","base_url":"http://localhost:9000/v1","model":"fixture"}"#.utf8))
        let request = AdapterRequest(prompt: "--provider foreign", systemContext: "context", env: [:], timeout: 20,
            maxOutputBytes: 10000, allowedTools: [], workingDirectory: root)
        let args = try PiProfile.prepare(directory: root, config: config, request: request,
            baseURL: "http://localhost:9000/v1", model: "fixture", skills: ["/explicit/SKILL.md"], allowed: [], denied: [])
        XCTAssertTrue(args.contains("--no-tools"))
        XCTAssertTrue(args.contains("--no-context-files"))
        XCTAssertTrue(args.contains("--no-extensions"))
        XCTAssertTrue(args.contains("/explicit/SKILL.md"))
        XCTAssertFalse(args.contains(request.prompt))
        XCTAssertFalse(args.contains { $0.hasPrefix("@") })
        let models = try String(contentsOf: root.appendingPathComponent("models.json"))
        XCTAssertTrue(models.contains("$MENTU_PI_PROVIDER_KEY"))
        XCTAssertFalse(models.contains("inference_budget"))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("prompt.txt")), request.prompt)
    }
}
