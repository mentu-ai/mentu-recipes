import Foundation

enum PiProfile {
    static func prepare(directory: URL, config: ProviderConfig, request: AdapterRequest,
                        baseURL: String, model: String, skills: [String], allowed: [String], denied: [String]) throws -> [String] {
        let provider: [String: Any] = [
            "api": "openai-completions", "baseUrl": baseURL, "apiKey": "$MENTU_PI_PROVIDER_KEY",
            "compat": ["maxTokensField": (config.maxTokensField ?? .maxTokens).rawValue,
                       "supportsDeveloperRole": false, "supportsReasoningEffort": false,
                       "supportsStore": false, "supportsUsageInStreaming": true],
            "models": [["id": model, "name": model, "reasoning": false, "input": ["text"],
                        "contextWindow": config.contextWindow ?? 32768,
                        "maxTokens": request.maxOutputTokens ?? 16384,
                        "cost": ["input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0]]]
        ]
        try writeJSON(["providers": ["mentu-pi": provider]], to: directory.appendingPathComponent("models.json"))
        var providerRetry: [String: Any] = ["maxRetries": 0]
        if request.timeout > 0 { providerRetry["timeoutMs"] = Double(request.timeout) * 1000 }
        try writeJSON(["retry": ["enabled": false, "maxRetries": 0, "provider": providerRetry],
                       "compaction": ["enabled": false], "packages": [], "extensions": [], "skills": []],
                      to: directory.appendingPathComponent("settings.json"))
        try writeJSON([:], to: directory.appendingPathComponent("auth.json"))
        let prompt = directory.appendingPathComponent("prompt.txt")
        try writePrivate(Data(request.prompt.utf8), to: prompt)
        var args = ["--mode", "json", "--print", "--provider", "mentu-pi", "--model", model,
                    "--no-session", "--no-extensions", "--no-skills", "--no-context-files",
                    "--no-prompt-templates", "--no-themes", "--no-approve", "--offline", "--thinking", "off"]
        args += allowed.isEmpty ? ["--no-tools"] : ["--tools", allowed.joined(separator: ",")]
        if !denied.isEmpty { args += ["--exclude-tools", denied.joined(separator: ",")] }
        for skill in skills { args += ["--skill", skill] }
        if let context = request.systemContext, !context.isEmpty {
            let file = directory.appendingPathComponent("system.txt")
            try writePrivate(Data(context.utf8), to: file)
            args += ["--append-system-prompt", file.path]
        }
        return args
    }

    private static func writeJSON(_ value: [String: Any], to file: URL) throws {
        try writePrivate(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), to: file)
    }

    private static func writePrivate(_ data: Data, to file: URL) throws {
        try data.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
