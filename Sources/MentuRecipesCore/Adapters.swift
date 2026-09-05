import Foundation

public enum CompletionPolicy: Sendable, Equatable {
    case providerCompleteEvent
    case keywordRequired
    case shellExitCode
}

public enum StreamFormat: String, Sendable, Codable {
    case claudeJSON = "claude_json"
    case codexJSON = "codex_json"
    case openAISSE = "openai_sse"
    case plainText = "plain_text"
    case ollamaJSON = "ollama_json"
    case piJSON = "pi_json"
}

public enum SystemContextHandling: String, Sendable, Codable {
    case native
    case foldedIntoPrompt = "folded_into_prompt"
    case ignored
}

public struct AdapterRequest: Sendable {
    public let prompt: String
    public let systemContext: String?
    public let model: String?
    public let env: [String: String]
    public let timeout: Int
    public let maxOutputBytes: Int
    public let reasoning: String?
    public let thinking: String?
    public let maxOutputTokens: Int?
    public let allowedTools: [String]?
    public let disallowedTools: [String]?
    public let sessionName: String?
    public let workingDirectory: URL

    public init(
        prompt: String,
        systemContext: String? = nil,
        model: String? = nil,
        env: [String: String],
        timeout: Int,
        maxOutputBytes: Int,
        reasoning: String? = nil,
        thinking: String? = nil,
        maxOutputTokens: Int? = nil,
        allowedTools: [String]? = nil,
        disallowedTools: [String]? = nil,
        sessionName: String? = nil,
        workingDirectory: URL
    ) {
        self.prompt = prompt
        self.systemContext = systemContext
        self.model = model
        self.env = env
        self.timeout = timeout
        self.maxOutputBytes = maxOutputBytes
        self.reasoning = reasoning
        self.thinking = thinking
        self.maxOutputTokens = maxOutputTokens
        self.allowedTools = allowedTools
        self.disallowedTools = disallowedTools
        self.sessionName = sessionName
        self.workingDirectory = workingDirectory
    }
}

public struct AdapterResult: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
    public let providerCompleted: Bool
    public let inputTokens: Int?
    public let outputTokens: Int?
}

public struct AdapterCapability: Codable, Sendable {
    public let name: String
    public let executionKind: String
    public let streamFormat: StreamFormat
    public let completionPolicy: String
    public let systemContextHandling: SystemContextHandling
    public let isLocal: Bool
    public let requiresNetwork: Bool
    public let requiresCredential: Bool
    public let supportsTools: Bool
    public let supportsToolAllowList: Bool
    public let supportsToolDenyList: Bool
    public let supportsReasoning: Bool
    public let supportsThinking: Bool
    public let supportsMaxOutputTokens: Bool
    public let reportsTokenUsage: Bool
    public let supportsStructuredCompletion: Bool
    public let canRunOffline: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case executionKind = "execution_kind"
        case streamFormat = "stream_format"
        case completionPolicy = "completion_policy"
        case systemContextHandling = "system_context_handling"
        case isLocal = "is_local"
        case requiresNetwork = "requires_network"
        case requiresCredential = "requires_credential"
        case supportsTools = "supports_tools"
        case supportsToolAllowList = "supports_tool_allow_list"
        case supportsToolDenyList = "supports_tool_deny_list"
        case supportsReasoning = "supports_reasoning"
        case supportsThinking = "supports_thinking"
        case supportsMaxOutputTokens = "supports_max_output_tokens"
        case reportsTokenUsage = "reports_token_usage"
        case supportsStructuredCompletion = "supports_structured_completion"
        case canRunOffline = "can_run_offline"
    }
}

public protocol BackendAdapter: Sendable {
    var name: String { get }
    var executionKind: String { get }
    var streamFormat: StreamFormat { get }
    var completionPolicy: CompletionPolicy { get }
    var systemContextHandling: SystemContextHandling { get }
    var isAutoDetectable: Bool { get }
    var capabilities: AdapterCapability { get }
    func isAvailable(env: [String: String]) -> Bool
    func execute(_ request: AdapterRequest, eventSink: @escaping (String) -> Void) async throws -> AdapterResult
}

public extension BackendAdapter {
    var capabilities: AdapterCapability {
        let isAgent = executionKind == "agent-cli"
        let isShell = executionKind == "shell"
        let isOllama = name == "ollama"
        let isHTTP = executionKind == "llm-http"
        return AdapterCapability(
            name: name,
            executionKind: executionKind,
            streamFormat: streamFormat,
            completionPolicy: {
                switch completionPolicy {
                case .providerCompleteEvent: return "provider_complete_event"
                case .keywordRequired: return "keyword_required"
                case .shellExitCode: return "shell_exit_code"
                }
            }(),
            systemContextHandling: systemContextHandling,
            isLocal: isShell || isAgent || isOllama,
            requiresNetwork: isHTTP && !isOllama,
            requiresCredential: isHTTP && !isOllama,
            supportsTools: isAgent,
            supportsToolAllowList: isAgent,
            supportsToolDenyList: isAgent,
            supportsReasoning: isAgent || name == "openai",
            supportsThinking: name == "claude",
            supportsMaxOutputTokens: isHTTP || name == "openai",
            reportsTokenUsage: streamFormat != .plainText,
            supportsStructuredCompletion: completionPolicy == .providerCompleteEvent,
            canRunOffline: isShell || isOllama
        )
    }
}

public enum AdapterRegistry {
    public static func adapter(
        named requestedName: String,
        providers: [String: ProviderConfig] = [:]
    ) -> BackendAdapter? {
        let name = normalize(requestedName)
        if let config = providers[requestedName] ?? providers[name] {
            return adapterFromProviderConfig(name: requestedName, config: config)
        }
        switch name {
        case "shell":
            return ShellAdapter()
        case "openai", "openai-responses", "chatgpt":
            return OpenAIResponsesAdapter()
        case "openai-chat":
            return OpenAIChatAdapter.openAIChat()
        case "deepseek":
            return OpenAIChatAdapter.deepSeek()
        case "ollama":
            return OpenAIChatAdapter.ollama()
        case "claude":
            return ClaudeCLIAdapter()
        case "codex":
            return CodexCLIAdapter()
        case "pi":
            return PiCLIAdapter()
        default:
            return nil
        }
    }

    public static func autoDetect(env: [String: String]) -> BackendAdapter? {
        let candidates: [BackendAdapter] = [
            OpenAIResponsesAdapter(),
            ClaudeCLIAdapter(),
            CodexCLIAdapter(),
            OpenAIChatAdapter.deepSeek(),
            OpenAIChatAdapter.ollama()
        ]
        return candidates.first { $0.isAutoDetectable && $0.isAvailable(env: env) }
    }

    public static func allAdapters() -> [BackendAdapter] {
        [
            ShellAdapter(),
            OpenAIResponsesAdapter(),
            OpenAIChatAdapter.openAIChat(),
            OpenAIChatAdapter.deepSeek(),
            OpenAIChatAdapter.ollama(),
            ClaudeCLIAdapter(),
            CodexCLIAdapter(),
            PiCLIAdapter()
        ]
    }

    public static func capabilities(providers: [String: ProviderConfig] = [:]) -> [AdapterCapability] {
        allAdapters().map(\.capabilities)
    }

    private static func adapterFromProviderConfig(name: String, config: ProviderConfig) -> BackendAdapter {
        let api = config.api ?? .chatCompletions
        switch api {
        case .responses:
            return OpenAIResponsesAdapter(
                name: name,
                baseURL: config.baseURL ?? "https://api.openai.com/v1",
                apiKeyEnv: config.apiKeyEnv ?? "OPENAI_API_KEY",
                apiKeyVault: config.apiKeyVault,
                defaultModel: config.model ?? "gpt-5.5"
            )
        case .chatCompletions:
            return OpenAIChatAdapter(
                name: name,
                baseURL: config.baseURL ?? "https://api.openai.com/v1",
                apiKeyEnv: config.apiKeyEnv ?? "OPENAI_API_KEY",
                apiKeyVault: config.apiKeyVault,
                defaultModel: config.model ?? "gpt-4o",
                requiresAuth: true
            )
        case .shell:
            return ShellAdapter()
        case .cli:
            switch normalize(config.agent ?? name) {
            case "codex": return CodexCLIAdapter()
            case "pi": return PiCLIAdapter(name: name, config: config)
            default: return ClaudeCLIAdapter(name: name)
            }
        }
    }

    private static func normalize(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
    }
}
