import XCTest
@testable import MentuRecipesCore

final class AgentProviderWiringTests: XCTestCase {
    private func adapter(_ json: String, name: String = "local-agent") throws -> BackendAdapter? {
        let config = try JSONDecoder().decode(ProviderConfig.self, from: Data(json.utf8))
        return AdapterRegistry.adapter(named: name, providers: [name: config])
    }

    func testCLIProviderWithoutAgentStillDrivesClaude() throws {
        XCTAssertTrue(try adapter(#"{"api":"cli"}"#) is ClaudeCLIAdapter)
    }

    func testCLIProviderNamedCodexKeepsWorking() throws {
        XCTAssertTrue(try adapter(#"{"api":"cli"}"#, name: "codex") is CodexCLIAdapter)
    }

    func testCLIProviderWithAgentPiDrivesPi() throws {
        let a = try adapter(#"{"api":"cli","agent":"pi","base_url":"http://127.0.0.1:9/v1","model":"m"}"#)
        XCTAssertTrue(a is PiCLIAdapter)
        XCTAssertEqual(a?.name, "local-agent")
        XCTAssertFalse(a?.isAutoDetectable ?? true)
    }

    func testThereIsNoVendorAPICase() {
        XCTAssertNil(ProviderAPI(rawValue: "pi"))
    }
}
