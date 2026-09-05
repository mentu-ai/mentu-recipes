import Foundation

public struct RecipeDefinition: Codable, Sendable {
    public let type: RecipeType?
    public let name: String
    public let description: String?
    public let backend: String?
    public let model: String?
    public let env: [String: String]?
    public let providers: [String: ProviderConfig]?
    public let cloud: CloudRecipeConfig?
    public let hooks: HookConfig?
    public let maxParallel: Int?
    public let steps: [RecipeStep]
    public let recipes: [RecipeNode]?

    public init(
        type: RecipeType? = nil,
        name: String,
        description: String? = nil,
        backend: String? = nil,
        model: String? = nil,
        env: [String: String]? = nil,
        providers: [String: ProviderConfig]? = nil,
        cloud: CloudRecipeConfig? = nil,
        hooks: HookConfig? = nil,
        maxParallel: Int? = nil,
        steps: [RecipeStep] = [],
        recipes: [RecipeNode]? = nil
    ) {
        self.type = type
        self.name = name
        self.description = description
        self.backend = backend
        self.model = model
        self.env = env
        self.providers = providers
        self.cloud = cloud
        self.hooks = hooks
        self.maxParallel = maxParallel
        self.steps = steps
        self.recipes = recipes
    }

    enum CodingKeys: String, CodingKey {
        case type, name, description, backend, model, env, providers, cloud, hooks, steps, recipes
        case maxParallel = "max_parallel"
    }
}

public enum RecipeType: String, Codable, Sendable {
    case formula
    case sequence
    case compound
    case pipeline
    case parallel
}

public struct RecipeNode: Codable, Sendable {
    public let label: String?
    public let recipe: String
    public let dependsOn: [String]?
    public let vars: [String: String]?

    enum CodingKeys: String, CodingKey {
        case label, recipe, vars
        case dependsOn = "depends_on"
    }
}

public struct HookConfig: Codable, Sendable {
    public let beforeRun: [String]?
    public let beforeStep: [String]?
    public let afterStep: [String]?
    public let onError: [String]?
    public let afterRun: [String]?

    enum CodingKeys: String, CodingKey {
        case beforeRun = "before_run"
        case beforeStep = "before_step"
        case afterStep = "after_step"
        case onError = "on_error"
        case afterRun = "after_run"
    }
}

public struct CloudRecipeConfig: Codable, Sendable {
    public let enabled: Bool?
    public let evaluateSteps: Bool?

    enum CodingKeys: String, CodingKey {
        case enabled
        case evaluateSteps = "evaluate_steps"
    }
}

public struct ProviderConfig: Codable, Sendable {
    public let api: ProviderAPI?
    public let baseURL: String?
    public let apiKeyEnv: String?
    public let apiKeyVault: String?
    public let model: String?
    /// Which agent CLI an `api: "cli"` provider drives: `claude` (default),
    /// `codex`, or `pi`. One neutral field instead of one API case per vendor.
    public let agent: String?
    public let maxTokensField: ChatCompletionTokenField?
    public let contextWindow: Int?
    public let skills: [String]?

    enum CodingKeys: String, CodingKey {
        case api
        case baseURL = "base_url"
        case apiKeyEnv = "api_key_env"
        case apiKeyVault = "api_key_vault"
        case model
        case agent
        case maxTokensField = "max_tokens_field"
        case contextWindow = "context_window"
        case skills
    }
}

public enum ProviderAPI: String, Codable, Sendable {
    case responses
    case chatCompletions = "chat_completions"
    case cli
    case shell
}

public enum ChatCompletionTokenField: String, Codable, Sendable {
    case maxTokens = "max_tokens"
    case maxCompletionTokens = "max_completion_tokens"
}

public struct RecipeStep: Codable, Sendable {
    public let label: String
    public let backend: String?
    public let model: String?
    public let prompt: String?
    public let promptFile: String?
    public let dir: String?
    public let env: [String: String]?
    public let timeout: Int?
    public let completionKeyword: String?
    public let dependsOn: [String]?
    public let maxRetries: Int?
    public let retryBackoffMs: Int?
    public let maxOutputBytes: Int?
    public let reasoning: String?
    public let thinking: String?
    public let maxOutputTokens: Int?
    public let allowedTools: [String]?
    public let disallowedTools: [String]?
    public let expectedChanges: [String]?
    public let verify: VerifyRequirements?

    public init(
        label: String,
        backend: String? = nil,
        model: String? = nil,
        prompt: String? = nil,
        promptFile: String? = nil,
        dir: String? = nil,
        env: [String: String]? = nil,
        timeout: Int? = nil,
        completionKeyword: String? = nil,
        dependsOn: [String]? = nil,
        maxRetries: Int? = nil,
        retryBackoffMs: Int? = nil,
        maxOutputBytes: Int? = nil,
        reasoning: String? = nil,
        thinking: String? = nil,
        maxOutputTokens: Int? = nil,
        allowedTools: [String]? = nil,
        disallowedTools: [String]? = nil,
        expectedChanges: [String]? = nil,
        verify: VerifyRequirements? = nil
    ) {
        self.label = label
        self.backend = backend
        self.model = model
        self.prompt = prompt
        self.promptFile = promptFile
        self.dir = dir
        self.env = env
        self.timeout = timeout
        self.completionKeyword = completionKeyword
        self.dependsOn = dependsOn
        self.maxRetries = maxRetries
        self.retryBackoffMs = retryBackoffMs
        self.maxOutputBytes = maxOutputBytes
        self.reasoning = reasoning
        self.thinking = thinking
        self.maxOutputTokens = maxOutputTokens
        self.allowedTools = allowedTools
        self.disallowedTools = disallowedTools
        self.expectedChanges = expectedChanges
        self.verify = verify
    }

    enum CodingKeys: String, CodingKey {
        case label, backend, model, prompt, dir, env, timeout
        case promptFile = "prompt_file"
        case completionKeyword = "completion_keyword"
        case dependsOn = "depends_on"
        case maxRetries = "max_retries"
        case retryBackoffMs = "retry_backoff_ms"
        case maxOutputBytes = "max_output_bytes"
        case reasoning
        case thinking
        case maxOutputTokens = "max_output_tokens"
        case allowedTools = "allowed_tools"
        case disallowedTools = "disallowed_tools"
        case expectedChanges = "expected_changes"
        case verify
    }
}

public struct VerifyRequirements: Codable, Sendable {
    public struct GrepPresent: Codable, Sendable {
        public let file: String
        public let pattern: String
        public let min: Int?
        public let max: Int?
        public let description: String?
    }

    public struct GrepAbsent: Codable, Sendable {
        public let file: String
        public let pattern: String
        public let description: String?
    }

    public struct FileAbsent: Codable, Sendable {
        public let file: String
        public let description: String?
    }

    public let grepPresent: [GrepPresent]?
    public let grepAbsent: [GrepAbsent]?
    public let fileAbsent: [FileAbsent]?
    public let gitCleanOutside: [String]?
    public let commands: [String]?

    enum CodingKeys: String, CodingKey {
        case grepPresent = "grep_present"
        case grepAbsent = "grep_absent"
        case fileAbsent = "file_absent"
        case gitCleanOutside = "git_clean_outside"
        case commands
    }
}

public struct RunOptions: Sendable {
    public let workspace: URL
    public let home: URL
    public let backend: String?
    public let model: String?
    public let vars: [String: String]
    public let cloudEnabled: Bool
    public let cloudBaseURL: URL
    public let quiet: Bool
    public let maxParallel: Int?
    public let planDigest: String?
    public let requestKey: String?

    public init(
        workspace: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        backend: String? = nil,
        model: String? = nil,
        vars: [String: String] = [:],
        cloudEnabled: Bool = false,
        cloudBaseURL: URL = URL(string: "https://api.mentu.ai")!,
        quiet: Bool = false,
        maxParallel: Int? = nil,
        planDigest: String? = nil,
        requestKey: String? = nil
    ) {
        self.workspace = workspace
        self.home = home
        self.backend = backend
        self.model = model
        self.vars = vars
        self.cloudEnabled = cloudEnabled
        self.cloudBaseURL = cloudBaseURL
        self.quiet = quiet
        self.maxParallel = maxParallel
        self.planDigest = planDigest
        self.requestKey = requestKey
    }
}

public enum RecipeError: Error, CustomStringConvertible {
    case recipeNotFound(String)
    case invalidRecipe(String)
    case missingPrompt(label: String)
    case missingBackend(label: String)
    case backendUnavailable(String)
    case dependencyCycle
    case duplicateStep(String)
    case failed(String)

    public var description: String {
        switch self {
        case .recipeNotFound(let name): return "Recipe not found: \(name)"
        case .invalidRecipe(let message): return "Invalid recipe: \(message)"
        case .missingPrompt(let label): return "Step '\(label)' has no prompt or prompt_file"
        case .missingBackend(let label): return "Step '\(label)' has no backend and no neutral backend is available"
        case .backendUnavailable(let name): return "Backend unavailable: \(name)"
        case .dependencyCycle: return "Recipe dependency graph contains a cycle"
        case .duplicateStep(let label): return "Duplicate step label: \(label)"
        case .failed(let message): return message
        }
    }
}
