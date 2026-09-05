import Foundation

public struct PiCLIAdapter: BackendAdapter {
    public let name: String
    public let executionKind = "agent-cli"
    public let streamFormat: StreamFormat = .piJSON
    public let completionPolicy: CompletionPolicy = .providerCompleteEvent
    public let systemContextHandling: SystemContextHandling = .native
    public let isAutoDetectable = false
    private let config: ProviderConfig?

    public init(name: String = "pi", config: ProviderConfig? = nil) {
        self.name = name
        self.config = config
    }

    public var capabilities: AdapterCapability {
        AdapterCapability(name: name, executionKind: executionKind, streamFormat: streamFormat,
            completionPolicy: "provider_complete_event", systemContextHandling: systemContextHandling,
            isLocal: true, requiresNetwork: true, requiresCredential: true, supportsTools: true,
            supportsToolAllowList: true, supportsToolDenyList: true, supportsReasoning: false,
            supportsThinking: false, supportsMaxOutputTokens: true, reportsTokenUsage: true,
            supportsStructuredCompletion: true, canRunOffline: false)
    }

    public func isAvailable(env: [String: String]) -> Bool {
        ProcessRunner.findExecutable("pi") != nil && ProcessRunner.findExecutable("node") != nil
    }

    public func execute(_ request: AdapterRequest, eventSink: @escaping (String) -> Void) async throws -> AdapterResult {
        guard let config, let baseURL = config.baseURL,
              let model = request.model ?? config.model, !model.isEmpty else {
            throw RecipeError.failed("Pi requires an explicit provider with api pi, base_url, and exact model ID")
        }
        guard let destination = URLComponents(string: baseURL),
              ["http", "https"].contains(destination.scheme), destination.host?.isEmpty == false,
              destination.user == nil, destination.password == nil,
              destination.query == nil, destination.fragment == nil else {
            throw RecipeError.failed("Pi requires an HTTP(S) base_url without embedded credentials, query or fragment")
        }
        try ProviderCredentialPolicy.validateDestination(name: name, baseURL: baseURL,
            apiKeyEnv: config.apiKeyEnv ?? "", apiKeyVault: config.apiKeyVault)
        guard request.reasoning == nil, request.thinking == nil || request.thinking == "off" else {
            throw RecipeError.failed("The Pi adapter does not support reasoning/thinking overrides")
        }
        guard let pi = ProcessRunner.findExecutable("pi"), let node = ProcessRunner.findExecutable("node") else {
            throw RecipeError.backendUnavailable("Pi and Node.js 22.19 or newer are required")
        }
        try await Self.requireVersion(executable: pi, minimum: [0, 84, 1], env: request.env, workspace: request.workingDirectory)
        try await Self.requireVersion(executable: node, minimum: [22, 19, 0], env: request.env, workspace: request.workingDirectory)
        let skills = try (config.skills ?? []).map { value -> String in
            let url = RecipePaths(workspace: request.workingDirectory).expand(value).standardizedFileURL.resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: url.path) else { throw RecipeError.failed("Configured Pi skill is unavailable") }
            return url.path
        }
        guard config.contextWindow ?? 32768 > 0 else { throw RecipeError.failed("Pi context window must be positive") }
        let tools = Set(["read", "bash", "edit", "write", "grep", "find", "ls"])
        let allowed = request.allowedTools ?? ["read", "bash", "edit", "write"]
        let denied = request.disallowedTools ?? []
        guard (allowed + denied).allSatisfy(tools.contains), request.maxOutputTokens ?? 1 > 0 else {
            throw RecipeError.failed("Invalid Pi tool policy or output token limit")
        }
        let key = config.apiKeyEnv.flatMap { request.env[$0] }
            ?? config.apiKeyVault.flatMap { CredentialResolver.resolveSecret(key: $0) }
        guard let key, !key.isEmpty else { throw RecipeError.failed("The configured Pi provider credential is unavailable") }
        let profile = FileManager.default.temporaryDirectory.appendingPathComponent("mentu-pi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: profile) }
        let arguments = try PiProfile.prepare(directory: profile, config: config, request: request,
            baseURL: baseURL, model: model, skills: skills, allowed: allowed, denied: denied)
        var env = Self.runtimeEnvironment(request.env)
        env["MENTU_PI_PROVIDER_KEY"] = key
        env["PI_CODING_AGENT_DIR"] = profile.path
        env["PI_CODING_AGENT_SESSION_DIR"] = profile.appendingPathComponent("sessions").path
        env["PI_OFFLINE"] = "1"
        env["PI_TELEMETRY"] = "0"
        env["NO_COLOR"] = "1"
        let parser = PiStreamCollector(maxBytes: request.maxOutputBytes)
        let result = try await ProcessRunner.run(executable: pi,
            arguments: arguments,
            env: env, workingDirectory: request.workingDirectory,
            timeout: request.timeout,
            maxOutputBytes: request.maxOutputBytes,
            standardInputFile: profile.appendingPathComponent("prompt.txt"),
            stdoutSink: { chunk in parser.append(chunk).forEach(eventSink) }, stderrSink: { _ in })
        let parsed = parser.finish()
        let complete = result.exitCode == 0 && parsed.completed && !parsed.failed
        let diagnostics = complete ? result.stderr : result.stderr + "\nPi did not produce a successful structured completion.\n"
        return AdapterResult(stdout: parsed.text, stderr: diagnostics,
            exitCode: complete ? 0 : (result.exitCode == 0 ? 1 : result.exitCode), providerCompleted: complete,
            inputTokens: parsed.inputTokens, outputTokens: parsed.outputTokens)
    }

    static func runtimeEnvironment(_ input: [String: String]) -> [String: String] {
        let keys: Set<String> = ["PATH", "HOME", "SHELL", "USER", "LOGNAME", "TMPDIR", "TMP", "TEMP", "LANG", "LC_ALL"]
        return input.filter { keys.contains($0.key) }
    }

    private static func requireVersion(executable: String, minimum: [Int], env: [String: String], workspace: URL) async throws {
        var environment = runtimeEnvironment(env)
        environment["PI_OFFLINE"] = "1"
        environment["PI_TELEMETRY"] = "0"
        let result = try await ProcessRunner.run(executable: executable, arguments: ["--version"], env: environment,
            workingDirectory: workspace, timeout: 5, maxOutputBytes: 1000, eventSink: { _ in })
        let raw = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "^v", with: "", options: .regularExpression)
        let parts = raw.split(separator: ".").compactMap { Int($0) }
        guard result.exitCode == 0, parts.count == 3, !parts.lexicographicallyPrecedes(minimum) else {
            throw RecipeError.failed("Unsupported Pi/Node runtime version; Pi 0.84.1+ and Node 22.19+ are required")
        }
    }
}

private final class PiStreamCollector {
    private let lock = NSLock()
    private var parser: PiJSONParser
    init(maxBytes: Int) { parser = PiJSONParser(maxBytes: maxBytes) }
    func append(_ chunk: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return parser.parse(chunk)
    }
    func finish() -> PiJSONParser {
        lock.lock(); defer { lock.unlock() }
        parser.finish()
        return parser
    }
}
