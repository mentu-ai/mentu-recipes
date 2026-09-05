import Foundation

public struct OpenAIResponsesAdapter: BackendAdapter {
    public let name: String
    public let executionKind = "llm-http"
    public let streamFormat: StreamFormat = .openAISSE
    public let completionPolicy: CompletionPolicy = .providerCompleteEvent
    public let systemContextHandling: SystemContextHandling = .native
    public let isAutoDetectable = true
    public let baseURL: String
    public let apiKeyEnv: String
    public let apiKeyVault: String?
    public let defaultModel: String
    public let session: URLSession

    public init(
        name: String = "openai",
        baseURL: String = "https://api.openai.com/v1",
        apiKeyEnv: String = "OPENAI_API_KEY",
        apiKeyVault: String? = "openai-api-key",
        defaultModel: String = "gpt-5.5",
        session: URLSession = .shared
    ) {
        self.name = name
        self.baseURL = baseURL
        self.apiKeyEnv = apiKeyEnv
        self.apiKeyVault = apiKeyVault
        self.defaultModel = defaultModel
        self.session = session
    }

    public func isAvailable(env: [String: String]) -> Bool {
        env[apiKeyEnv]?.isEmpty == false
    }

    public func execute(_ request: AdapterRequest, eventSink: @escaping (String) -> Void) async throws -> AdapterResult {
        try ProviderCredentialPolicy.validateDestination(name: name, baseURL: baseURL, apiKeyEnv: apiKeyEnv, apiKeyVault: apiKeyVault)
        guard let apiKey = credential(from: request.env) else {
            throw RecipeError.backendUnavailable("\(name) requires \(apiKeyEnv) or vault key \(apiKeyVault ?? apiKeyEnv)")
        }

        struct Input: Encodable { let role: String; let content: String }
        struct Reasoning: Encodable { let effort: String }
        struct Body: Encodable {
            let model: String
            let input: [Input]
            let instructions: String?
            let stream: Bool
            let max_output_tokens: Int?
            let reasoning: Reasoning?
        }

        let model = normalizeModel(request.model ?? defaultModel)
        let body = Body(
            model: model,
            input: [Input(role: "user", content: request.prompt)],
            instructions: request.systemContext?.isEmpty == false ? request.systemContext : nil,
            stream: true,
            max_output_tokens: request.maxOutputTokens,
            reasoning: request.reasoning.map { Reasoning(effort: responsesEffort($0)) }
        )

        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/responses") else {
            throw RecipeError.failed("Invalid Responses API URL")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = TimeInterval(request.timeout)
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(body)

        return try await SSEClient.execute(
            request: urlRequest,
            session: session,
            timeout: request.timeout,
            maxOutputBytes: request.maxOutputBytes,
            eventSink: eventSink,
            parser: parseResponsesPayload
        )
    }

    private func credential(from env: [String: String]) -> String? {
        if let value = env[apiKeyEnv], !value.isEmpty { return value }
        if let apiKeyVault, let value = CredentialResolver.resolveSecret(key: apiKeyVault) { return value }
        return CredentialResolver.resolveSecret(key: apiKeyEnv)
    }

    private func normalizeModel(_ model: String) -> String {
        switch model.lowercased() {
        case "codex-5-5", "gpt-5-5": return "gpt-5.5"
        case "gpt-5-4-mini": return "gpt-5.4-mini"
        case "codex-5-3": return "gpt-5.3-codex"
        default: return model
        }
    }

    private func responsesEffort(_ effort: String) -> String {
        let normalized = effort.lowercased()
        if normalized == "max" { return "xhigh" }
        return normalized
    }

    private func parseResponsesPayload(_ payload: String) -> SSEClient.ParseResult {
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }
        let type = json["type"] as? String
        switch type {
        case "response.output_text.delta", "response.refusal.delta":
            let text = json["delta"] as? String ?? ""
            return .text(text)
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            return .empty
        case "response.completed":
            let response = json["response"] as? [String: Any]
            let usage = response?["usage"] as? [String: Any]
            return .complete(inputTokens: usage?["input_tokens"] as? Int, outputTokens: usage?["output_tokens"] as? Int)
        case "response.failed", "response.incomplete", "error":
            return .error(SSEClient.extractError(from: json) ?? "OpenAI response failed")
        default:
            if let message = SSEClient.extractError(from: json) { return .error(message) }
            return .empty
        }
    }
}

public struct OpenAIChatAdapter: BackendAdapter {
    public let name: String
    public let executionKind = "llm-http"
    public let streamFormat: StreamFormat = .openAISSE
    public let completionPolicy: CompletionPolicy = .providerCompleteEvent
    public let systemContextHandling: SystemContextHandling = .native
    public let isAutoDetectable: Bool
    public let baseURL: String
    public let apiKeyEnv: String
    public let apiKeyVault: String?
    public let defaultModel: String
    public let requiresAuth: Bool
    public let session: URLSession

    public init(
        name: String,
        baseURL: String,
        apiKeyEnv: String,
        apiKeyVault: String? = nil,
        defaultModel: String,
        requiresAuth: Bool,
        isAutoDetectable: Bool = true,
        session: URLSession = .shared
    ) {
        self.name = name
        self.baseURL = baseURL
        self.apiKeyEnv = apiKeyEnv
        self.apiKeyVault = apiKeyVault
        self.defaultModel = defaultModel
        self.requiresAuth = requiresAuth
        self.isAutoDetectable = isAutoDetectable
        self.session = session
    }

    public static func openAIChat() -> OpenAIChatAdapter {
        OpenAIChatAdapter(
            name: "openai-chat",
            baseURL: "https://api.openai.com/v1",
            apiKeyEnv: "OPENAI_API_KEY",
            apiKeyVault: "openai-api-key",
            defaultModel: "gpt-4o",
            requiresAuth: true
        )
    }

    public static func deepSeek() -> OpenAIChatAdapter {
        OpenAIChatAdapter(
            name: "deepseek",
            baseURL: "https://api.deepseek.com/v1",
            apiKeyEnv: "DEEPSEEK_API_KEY",
            apiKeyVault: "deepseek-api-key",
            defaultModel: "deepseek-chat",
            requiresAuth: true
        )
    }

    public static func ollama() -> OpenAIChatAdapter {
        OpenAIChatAdapter(
            name: "ollama",
            baseURL: "http://localhost:11434/v1",
            apiKeyEnv: "OLLAMA_API_KEY",
            apiKeyVault: nil,
            defaultModel: "llama3.2",
            requiresAuth: false
        )
    }

    public func isAvailable(env: [String: String]) -> Bool {
        if !requiresAuth { return true }
        return env[apiKeyEnv]?.isEmpty == false
    }

    public func execute(_ request: AdapterRequest, eventSink: @escaping (String) -> Void) async throws -> AdapterResult {
        try ProviderCredentialPolicy.validateDestination(name: name, baseURL: baseURL, apiKeyEnv: apiKeyEnv, apiKeyVault: apiKeyVault)
        guard !requiresAuth || credential(from: request.env) != nil else {
            throw RecipeError.backendUnavailable("\(name) requires \(apiKeyEnv) or vault key \(apiKeyVault ?? apiKeyEnv)")
        }

        struct Message: Encodable { let role: String; let content: String }
        struct StreamOptions: Encodable { let include_usage: Bool }
        struct Body: Encodable {
            let model: String
            let messages: [Message]
            let stream: Bool
            let stream_options: StreamOptions?
        }

        var messages: [Message] = []
        if let system = request.systemContext, !system.isEmpty {
            messages.append(Message(role: "system", content: system))
        }
        messages.append(Message(role: "user", content: request.prompt))

        let body = Body(
            model: request.model ?? defaultModel,
            messages: messages,
            stream: true,
            stream_options: StreamOptions(include_usage: true)
        )

        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else {
            throw RecipeError.failed("Invalid chat completions API URL")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = TimeInterval(request.timeout)
        if let key = credential(from: request.env) {
            urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(body)

        return try await SSEClient.execute(
            request: urlRequest,
            session: session,
            timeout: request.timeout,
            maxOutputBytes: request.maxOutputBytes,
            eventSink: eventSink,
            parser: parseChatPayload
        )
    }

    private func credential(from env: [String: String]) -> String? {
        if let value = env[apiKeyEnv], !value.isEmpty { return value }
        if let apiKeyVault, let value = CredentialResolver.resolveSecret(key: apiKeyVault) { return value }
        return CredentialResolver.resolveSecret(key: apiKeyEnv)
    }

    private func parseChatPayload(_ payload: String) -> SSEClient.ParseResult {
        if payload == "[DONE]" { return .complete(inputTokens: nil, outputTokens: nil) }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .empty
        }
        if let choices = json["choices"] as? [[String: Any]], let first = choices.first {
            if let delta = first["delta"] as? [String: Any],
               let content = delta["content"] as? String {
                return .text(content)
            }
            if let finish = first["finish_reason"] as? String, finish == "stop" || finish == "length" {
                return .complete(inputTokens: nil, outputTokens: nil)
            }
        }
        if let usage = json["usage"] as? [String: Any] {
            return .complete(
                inputTokens: usage["prompt_tokens"] as? Int,
                outputTokens: usage["completion_tokens"] as? Int
            )
        }
        if let message = SSEClient.extractError(from: json) {
            return .error(message)
        }
        return .empty
    }
}

enum ProviderCredentialPolicy {
    static func validateDestination(name: String, baseURL: String, apiKeyEnv: String, apiKeyVault: String?) throws {
        guard let host = URL(string: baseURL)?.host?.lowercased() else {
            throw RecipeError.failed("Invalid provider base_url for \(name): \(baseURL)")
        }
        let env = apiKeyEnv.uppercased()
        let vault = apiKeyVault?.lowercased()
        if (env == "OPENAI_API_KEY" || vault == "openai-api-key") && host != "api.openai.com" {
            throw RecipeError.failed("Provider \(name) cannot send OpenAI credentials to \(host); use a provider-specific api_key_env or api_key_vault")
        }
        if (env == "DEEPSEEK_API_KEY" || vault == "deepseek-api-key") && host != "api.deepseek.com" {
            throw RecipeError.failed("Provider \(name) cannot send DeepSeek credentials to \(host); use a provider-specific api_key_env or api_key_vault")
        }
    }
}

public enum SSEClient {
    public enum ParseResult {
        case empty
        case text(String)
        case complete(inputTokens: Int?, outputTokens: Int?)
        case error(String)
    }

    public static func execute(
        request: URLRequest,
        session: URLSession,
        timeout: Int,
        maxOutputBytes: Int,
        eventSink: @escaping (String) -> Void,
        parser: @escaping (String) -> ParseResult
    ) async throws -> AdapterResult {
        try await withThrowingTaskGroup(of: AdapterResult.self) { group in
            group.addTask {
                try await executeStream(
                    request: request,
                    session: session,
                    maxOutputBytes: maxOutputBytes,
                    eventSink: eventSink,
                    parser: parser
                )
            }
            if timeout > 0 {
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
                    throw RecipeError.failed("HTTP timeout after \(timeout)s")
                }
            }
            guard let result = try await group.next() else {
                throw RecipeError.failed("HTTP request did not start")
            }
            group.cancelAll()
            return result
        }
    }

    private static func executeStream(
        request: URLRequest,
        session: URLSession,
        maxOutputBytes: Int,
        eventSink: @escaping (String) -> Void,
        parser: @escaping (String) -> ParseResult
    ) async throws -> AdapterResult {
        let buffer = OutputBuffer(maxBytes: maxOutputBytes)
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RecipeError.failed("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            var body = ""
            for try await line in bytes.lines {
                body += line
                if body.count > 8000 { break }
            }
            throw RecipeError.failed("HTTP \(http.statusCode): \(body)")
        }

        var providerCompleted = false
        var inputTokens: Int?
        var outputTokens: Int?

        for try await rawLine in bytes.lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let payload: String
            if line.hasPrefix("data: ") {
                payload = String(line.dropFirst(6))
            } else if line.hasPrefix("event:") {
                continue
            } else if line.hasPrefix("{") {
                payload = line
            } else {
                continue
            }

            switch parser(payload) {
            case .empty:
                continue
            case .text(let text):
                buffer.appendStdout(text)
                eventSink(text)
            case .complete(let inTokens, let outTokens):
                providerCompleted = true
                inputTokens = inputTokens ?? inTokens
                outputTokens = outputTokens ?? outTokens
            case .error(let message):
                buffer.appendStderr("provider-error: \(message)\n")
                eventSink("Error: \(message)\n")
            }
        }

        let snapshot = buffer.snapshot()
        return AdapterResult(
            stdout: snapshot.stdout,
            stderr: snapshot.stderr,
            exitCode: snapshot.exceeded ? 1 : 0,
            providerCompleted: providerCompleted,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
    }

    public static func extractError(from json: [String: Any]) -> String? {
        if let error = json["error"] as? [String: Any] {
            return error["message"] as? String ?? error["code"] as? String
        }
        if let message = json["message"] as? String { return message }
        return nil
    }
}
