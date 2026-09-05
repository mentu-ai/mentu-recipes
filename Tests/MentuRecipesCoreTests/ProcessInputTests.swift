import XCTest
@testable import MentuRecipesCore

final class ProcessInputTests: XCTestCase {
    private func fixture(_ body: (URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mentu-stdin-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await body(root)
    }

    func testLargeFileInputIsVerbatimAndDoesNotNeedPipeBuffering() async throws {
        try await fixture { root in
            let file = root.appendingPathComponent("prompt.txt")
            let content = String(repeating: "--flag\n@file\n'quoted' $LITERAL 🐉\n", count: 10_000)
            try Data(content.utf8).write(to: file)
            let result = try await ProcessRunner.run(executable: "/bin/sh", arguments: ["-c", "cat > received.txt"],
                env: [:], workingDirectory: root, timeout: 5, maxOutputBytes: 1_000_000,
                standardInputFile: file, eventSink: { _ in })
            XCTAssertEqual(result.exitCode, 0, result.stderr)
            let received = try Data(contentsOf: root.appendingPathComponent("received.txt"))
            XCTAssertTrue(received == Data(content.utf8), "Child must receive every original UTF-8 input byte")
        }
    }

    func testDefaultInputAndEmptyFileBothReachEOF() async throws {
        try await fixture { root in
            let file = root.appendingPathComponent("empty.txt")
            try Data().write(to: file)
            for input in [nil, file] as [URL?] {
                let result = try await ProcessRunner.run(executable: "/bin/cat", arguments: [],
                    env: [:], workingDirectory: root, timeout: 2, maxOutputBytes: 100,
                    standardInputFile: input, eventSink: { _ in })
                XCTAssertEqual(result.exitCode, 0, result.stderr)
                XCTAssertEqual(result.stdout, "")
            }
        }
    }

    func testMissingInputFailsBeforeLaunchingChild() async throws {
        try await fixture { root in
            do {
                _ = try await ProcessRunner.run(executable: "/usr/bin/touch", arguments: ["started"],
                    env: [:], workingDirectory: root, timeout: 2, maxOutputBytes: 100,
                    standardInputFile: root.appendingPathComponent("missing.txt"), eventSink: { _ in })
                XCTFail("Missing input must not be replaced with an empty prompt")
            } catch {
                XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path))
            }
        }
    }
}
