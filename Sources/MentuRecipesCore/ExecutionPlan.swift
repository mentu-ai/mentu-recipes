import CryptoKit
import Foundation

/// A review digest, not authentication or a sandbox for recipe code.
public struct ExecutionPlan: Codable, Sendable {
    public let version: Int
    public let digest: String
    public let recipe: String
    public let source: String
    public let workspace: String
    public let steps: [Step]
    public let children: [ExecutionPlan]
    /// Environment variable names the digest deliberately does not bind. They
    /// change between terminal sessions without changing what a step does.
    public let unboundEnvironment: [String]

    public struct Step: Codable, Sendable {
        public let label: String
        public let backend: String
        public let model: String?
        public let digest: String
    }

    public static func resolve(_ recipe: String, options: RunOptions) throws -> ExecutionPlan {
        try ExecutionPlanResolver(options: options).capture(recipe).review
    }
}

struct CapturedStep {
    let prompt: String
    let environment: [String: String]
    let directory: URL
}

final class CapturedRecipe {
    let recipe: RecipeDefinition
    let source: URL
    let environment: [String: String]
    let steps: [String: CapturedStep]
    let children: [String: CapturedRecipe]
    let review: ExecutionPlan

    init(recipe: RecipeDefinition, source: URL, environment: [String: String],
         steps: [String: CapturedStep], children: [String: CapturedRecipe], review: ExecutionPlan) {
        self.recipe = recipe
        self.source = source
        self.environment = environment
        self.steps = steps
        self.children = children
        self.review = review
    }
}

enum ExecutionDigest {
    static func bytes(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func value<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return bytes(try encoder.encode(value))
    }
}

final class ExecutionPlanResolver {
    private let options: RunOptions
    private let paths: RecipePaths
    private let ambient: [String: String]
    private var bytesRead = 0
    private var nodesRead = 0

    /// Session-scoped variables every macOS terminal, SSH session or login sets
    /// differently, none of which change what a step does. Binding them made a
    /// plan taken in one terminal tab fail in the next. Everything else in the
    /// environment is bound, because the step will read it.
    static let sessionScopedEnvironment: Set<String> = [
        "_", "SHLVL", "OLDPWD", "PWD", "TMPDIR",
        "TERM_SESSION_ID", "ITERM_SESSION_ID", "ITERM_PROFILE", "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
        "LC_TERMINAL", "LC_TERMINAL_VERSION", "COLORTERM", "WINDOWID", "COLUMNS", "LINES",
        "SECURITYSESSIONID", "XPC_SERVICE_NAME", "XPC_FLAGS", "__CF_USER_TEXT_ENCODING", "__CFBundleIdentifier",
        "SSH_AUTH_SOCK", "SSH_AGENT_PID", "SSH_TTY", "SSH_CONNECTION", "SSH_CLIENT",
        "Apple_PubSub_Socket_Render", "DISPLAY",
    ]

    init(options: RunOptions, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.options = options
        paths = RecipePaths(workspace: options.workspace, home: options.home)
        ambient = environment.filter { !Self.sessionScopedEnvironment.contains($0.key) }
    }

    func capture(_ reference: String) throws -> CapturedRecipe {
        try capture(reference, vars: options.vars, ancestors: [])
    }

    private func read(_ url: URL) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 4_194_304, bytesRead + size <= 16_777_216 else {
            throw RecipeError.failed("Execution plan exceeds the 16 MiB input limit")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: min(4_194_304, 16_777_216 - bytesRead) + 1) ?? Data()
        bytesRead += data.count
        guard data.count <= 4_194_304, bytesRead <= 16_777_216 else { throw RecipeError.failed("Execution plan input grew beyond its limit") }
        return data
    }

    private func capture(_ reference: String, vars: [String: String], ancestors: Set<String>) throws -> CapturedRecipe {
        nodesRead += 1
        guard nodesRead <= 256, ancestors.count < 32 else {
            throw RecipeError.failed("Execution plan exceeds its recipe count or depth limit")
        }
        guard let located = paths.resolveRecipe(reference) else { throw RecipeError.recipeNotFound(reference) }
        let source = located.standardizedFileURL.resolvingSymlinksInPath()
        guard !ancestors.contains(source.path) else { throw RecipeError.dependencyCycle }
        let data = try read(source)
        let recipe = try JSONDecoder().decode(RecipeDefinition.self, from: data)
        try RecipeStore(paths: paths).validate(recipe, backendOverride: options.backend)
        let environment = merged(recipe.env, step: nil, vars: vars)
        var steps: [String: CapturedStep] = [:]
        var summaries: [ExecutionPlan.Step] = []
        for step in recipe.steps {
            guard let backend = step.backend ?? options.backend ?? recipe.backend else {
                throw RecipeError.failed("Admitted steps require an explicit backend: \(step.label)")
            }
            guard let adapter = AdapterRegistry.adapter(named: backend, providers: recipe.providers ?? [:]) else {
                throw RecipeError.backendUnavailable(backend)
            }
            try AdapterRegistry.validate(step: step, adapter: adapter)
            let model = step.model ?? options.model ?? recipe.model ?? recipe.providers?[backend]?.model
            guard backend == "shell" || model?.isEmpty == false else {
                throw RecipeError.failed("Admitted agent steps require an explicit model: \(step.label)")
            }
            let env = merged(recipe.env, step: step.env, vars: vars)
            let rawPrompt: String
            var promptSource = "inline"
            if let inline = step.prompt {
                rawPrompt = inline
            } else if let ref = step.promptFile, let url = paths.resolvePrompt(ref) {
                promptSource = url.standardizedFileURL.resolvingSymlinksInPath().path
                guard let text = String(data: try read(url), encoding: .utf8) else {
                    throw RecipeError.failed("Prompt is not UTF-8: \(step.label)")
                }
                rawPrompt = text
            } else {
                throw RecipeError.missingPrompt(label: step.label)
            }
            let prompt = PromptRenderer.render(rawPrompt, vars: env.merging(vars) { _, new in new })
            let directory = try ExecutionDirectory.resolve(step.dir, workspace: options.workspace)
            steps[step.label] = CapturedStep(prompt: prompt, environment: env, directory: directory)
            let digest = try ExecutionDigest.value([
                "contract": ExecutionDigest.value(step), "backend": backend, "model": model ?? "",
                "prompt_source": promptSource, "prompt_raw": ExecutionDigest.bytes(Data(rawPrompt.utf8)),
                "prompt": ExecutionDigest.bytes(Data(prompt.utf8)), "environment": ExecutionDigest.value(env),
                "directory": directory.path
            ])
            summaries.append(.init(label: step.label, backend: backend, model: model, digest: digest))
        }
        var children: [String: CapturedRecipe] = [:]
        var childPlans: [ExecutionPlan] = []
        for node in recipe.recipes ?? [] {
            let child = try capture(node.recipe, vars: vars.merging(node.vars ?? [:]) { _, new in new },
                                    ancestors: ancestors.union([source.path]))
            children[node.label ?? node.recipe] = child
            childPlans.append(child.review)
        }
        let workspace = options.workspace.standardizedFileURL.resolvingSymlinksInPath().path
        let digest = try ExecutionDigest.value([
            "protocol": "mentu-admission-v1", "source": source.path, "source_bytes": ExecutionDigest.bytes(data),
            "workspace": workspace, "environment": ExecutionDigest.value(environment),
            "vars": ExecutionDigest.value(vars), "steps": ExecutionDigest.value(summaries),
            "children": ExecutionDigest.value(childPlans), "backend": options.backend ?? "",
            "model": options.model ?? "", "parallel": String(options.maxParallel ?? recipe.maxParallel ?? 0),
            "cloud": String(options.cloudEnabled), "cloud_url": options.cloudBaseURL.absoluteString
        ])
        let review = ExecutionPlan(version: 1, digest: digest, recipe: recipe.name, source: source.path,
                                   workspace: workspace, steps: summaries, children: childPlans,
                                   unboundEnvironment: Self.sessionScopedEnvironment.sorted())
        return CapturedRecipe(recipe: recipe, source: source, environment: environment,
                              steps: steps, children: children, review: review)
    }

    private func merged(_ recipe: [String: String]?, step: [String: String]?, vars: [String: String]) -> [String: String] {
        var env = ambient
        for (key, value) in recipe ?? [:] { env[key] = PromptRenderer.render(value, vars: vars) }
        for (key, value) in step ?? [:] { env[key] = PromptRenderer.render(value, vars: vars) }
        return CredentialResolver.resolveEnv(env.merging(vars) { _, new in new })
    }
}

enum ExecutionDirectory {
    static func resolve(_ dir: String?, workspace: URL) throws -> URL {
        guard let dir, !dir.isEmpty else { return workspace.standardizedFileURL.resolvingSymlinksInPath() }
        guard !dir.hasPrefix("/"), !dir.hasPrefix("~") else { throw RecipeError.failed("Step dir must stay inside the workspace") }
        let url = workspace.appendingPathComponent(dir).standardizedFileURL.resolvingSymlinksInPath()
        guard RecipePaths.isDescendant(url, of: workspace) else { throw RecipeError.failed("Step dir escapes the workspace") }
        return url
    }
}
