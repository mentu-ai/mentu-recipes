import Foundation
import MentuRecipesCore

enum CLI {
    static func main() async -> Int32 {
        // Line buffering, so piping to tee or a log keeps the wizard's output
        // in the same order the runner's progress arrives.
        setvbuf(stdout, nil, _IOLBF, 0)
        var args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            help()
            return 0
        }
        args.removeFirst()

        // --help anywhere in a subcommand's arguments prints that subcommand's
        // usage and does nothing else. It must never run the command.
        if args.contains("--help") || args.contains("-h") {
            usage(for: command)
            return 0
        }

        do {
            switch command {
            case "init":
                try initWorkspace()
            case "setup":
                try await Setup.run(args)
            case "list", "ls":
                try list(args)
            case "check":
                try check(args)
            case "run":
                try await run(args)
            case "plan":
                try plan(args)
            case "resume":
                try await resume(args)
            case "retry-step":
                try await retryStep(args)
            case "report":
                try report(args)
            case "doctor":
                try doctor(args)
            case "analyze-runs":
                try analyzeRuns(args)
            case "adapters":
                try adapters(args)
            case "vault":
                try vault(args)
            case "scan":
                try scan(args)
            case "--version", "-V", "version":
                print("mentu-recipes \(MentuRecipesVersion.string)")
            case "--help", "-h", "help":
                help()
            default:
                fputs("Unknown command: \(command)\n", stderr)
                help()
                return 2
            }
            return 0
        } catch {
            fputs("mentu-recipes: \(error)\n", stderr)
            if let recipeError = error as? RecipeError, case .recipeNotFound = recipeError {
                fputs("Run `mentu-recipes list` to see this workspace's recipes, or `mentu-recipes setup` to place an example here.\n", stderr)
            }
            return 1
        }
    }

    static func initWorkspace() throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let recipes = cwd.appendingPathComponent(".mentu/recipes")
        let prompts = cwd.appendingPathComponent(".mentu/prompts")
        try FileManager.default.createDirectory(at: recipes, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prompts, withIntermediateDirectories: true)
        print("Initialized .mentu/recipes and .mentu/prompts")
    }

    static func check(_ args: [String]) throws {
        guard let name = args.first else { throw RecipeError.failed("Usage: mentu-recipes check <recipe-or-path>") }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let store = RecipeStore(paths: RecipePaths(workspace: cwd))
        let (recipe, url) = try store.load(name)
        print("✓ \(recipe.name) · \(recipe.steps.count) step(s) · \(url.path)")
    }

    static func run(_ args: [String]) async throws {
        guard let name = args.first else { throw RecipeError.failed("Usage: mentu-recipes run <recipe-or-path>") }
        try validateExecutionArguments(Array(args.dropFirst()))
        let parsed = parseOptions(Array(args.dropFirst()))
        let workspace = URL(fileURLWithPath: parsed["workspace"] ?? FileManager.default.currentDirectoryPath)
        let vars = parseVars(parsed["vars"] ?? "")
        let runner = RecipeRunner(options: RunOptions(
            workspace: workspace,
            backend: parsed["backend"],
            model: parsed["model"],
            vars: vars,
            cloudEnabled: parsed["cloud"] == "true",
            quiet: parsed["quiet"] == "true",
            maxParallel: parsed["max-parallel"].flatMap(Int.init),
            planDigest: parsed["plan-digest"],
            requestKey: parsed["request-key"]
        ))
        let record = try await runner.run(name)
        let ok = record.outcome == "ok"
        print("\n\(ok ? "✓" : "✗") \(record.recipeName) · \(record.steps.count) step(s) · \(record.outcome)")
        print("Run record: \(workspace.appendingPathComponent(".mentu/runs/\(record.runId)/run.json").path)")
        if !ok { throw RecipeError.failed("Recipe failed") }
    }

    static func resume(_ args: [String]) async throws {
        guard let runId = args.first else { throw RecipeError.failed("Usage: mentu-recipes resume <run-id> [--workspace PATH]") }
        try validateExecutionArguments(Array(args.dropFirst()))
        let parsed = parseOptions(Array(args.dropFirst()))
        let workspace = URL(fileURLWithPath: parsed["workspace"] ?? FileManager.default.currentDirectoryPath)
        let runner = RecipeRunner(options: RunOptions(
            workspace: workspace,
            backend: parsed["backend"],
            model: parsed["model"],
            vars: parseVars(parsed["vars"] ?? ""),
            cloudEnabled: parsed["cloud"] == "true",
            quiet: parsed["quiet"] == "true",
            maxParallel: parsed["max-parallel"].flatMap(Int.init),
            planDigest: parsed["plan-digest"],
            requestKey: parsed["request-key"]
        ))
        let record = try await runner.resume(runId: runId)
        print("\n\(record.outcome == "ok" ? "✓" : "✗") \(record.recipeName) · \(record.outcome)")
        if record.outcome != "ok" { throw RecipeError.failed("Recipe failed") }
    }

    static func retryStep(_ args: [String]) async throws {
        guard args.count >= 2 else { throw RecipeError.failed("Usage: mentu-recipes retry-step <run-id> <step-label> [--workspace PATH]") }
        let runId = args[0]
        let step = args[1]
        try validateExecutionArguments(Array(args.dropFirst(2)))
        let parsed = parseOptions(Array(args.dropFirst(2)))
        let workspace = URL(fileURLWithPath: parsed["workspace"] ?? FileManager.default.currentDirectoryPath)
        let runner = RecipeRunner(options: RunOptions(
            workspace: workspace,
            backend: parsed["backend"],
            model: parsed["model"],
            vars: parseVars(parsed["vars"] ?? ""),
            cloudEnabled: parsed["cloud"] == "true",
            quiet: parsed["quiet"] == "true",
            maxParallel: parsed["max-parallel"].flatMap(Int.init),
            planDigest: parsed["plan-digest"],
            requestKey: parsed["request-key"]
        ))
        let record = try await runner.resume(runId: runId, retryStep: step)
        print("\n\(record.outcome == "ok" ? "✓" : "✗") \(record.recipeName) · \(record.outcome)")
        if record.outcome != "ok" { throw RecipeError.failed("Recipe failed") }
    }

    static func report(_ args: [String]) throws {
        guard let runId = args.first else { throw RecipeError.failed("Usage: mentu-recipes report <run-id> [--format markdown|json|csv] [--workspace PATH]") }
        let parsed = parseOptions(Array(args.dropFirst()))
        let workspace = URL(fileURLWithPath: parsed["workspace"] ?? FileManager.default.currentDirectoryPath)
        let format = ReportFormat(rawValue: parsed["format"] ?? "markdown") ?? .markdown
        let record = try RunReporter.load(runId: runId, workspace: workspace)
        print(try RunReporter.render(record, format: format))
    }

    static func doctor(_ args: [String]) throws {
        guard let name = args.first else { throw RecipeError.failed("Usage: mentu-recipes doctor <recipe-or-path> [--format markdown|json|csv] [--strict] [--workspace PATH]") }
        let parsed = parseOptions(Array(args.dropFirst()))
        let workspace = URL(fileURLWithPath: parsed["workspace"] ?? FileManager.default.currentDirectoryPath)
        let format = ReportFormat(rawValue: parsed["format"] ?? "markdown") ?? .markdown
        let report = RecipeDoctor.inspect(name, store: RecipeStore(paths: RecipePaths(workspace: workspace)))
        print(try RecipeDoctor.render(report, format: format))
        let strict = parsed["strict"] == "true"
        let hasError = report.findings.contains { $0.severity == "error" }
        let hasWarning = report.findings.contains { $0.severity == "warning" }
        if hasError || (strict && hasWarning) {
            throw RecipeError.failed("doctor found \(report.findings.count) finding(s)")
        }
    }

    static func analyzeRuns(_ args: [String]) throws {
        let parsed = parseOptions(args)
        let workspace = URL(fileURLWithPath: parsed["workspace"] ?? FileManager.default.currentDirectoryPath)
        let format = ReportFormat(rawValue: parsed["format"] ?? "markdown") ?? .markdown
        let summary = RunAnalyzer.analyze(workspace: workspace, redacted: true)
        if let export = parsed["export-jsonl"] {
            try RunAnalyzer.exportJSONL(summary, to: URL(fileURLWithPath: export))
        }
        print(try RunAnalyzer.render(summary, format: format))
    }

    static func adapters(_ args: [String]) throws {
        let env = ProcessInfo.processInfo.environment
        if args.contains("--json") {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(AdapterRegistry.allAdapters().map(\.capabilities))
            print(String(data: data, encoding: .utf8) ?? "[]")
            return
        }
        if let index = args.firstIndex(of: "--explain"), args.count > index + 1 {
            let name = args[index + 1]
            guard let adapter = AdapterRegistry.adapter(named: name) else {
                throw RecipeError.backendUnavailable(name)
            }
            print(try explain(adapter))
            return
        }
        for adapter in AdapterRegistry.allAdapters() {
            let available = adapter.isAvailable(env: env) ? "available" : "unavailable"
            let auto = adapter.isAutoDetectable ? "auto" : "explicit"
            print("\(adapter.name)\t\(adapter.executionKind)\t\(adapter.streamFormat.rawValue)\t\(adapter.systemContextHandling.rawValue)\t\(available)\t\(auto)")
        }
    }

    static func explain(_ adapter: BackendAdapter) throws -> String {
        let caps = adapter.capabilities
        return """
        \(caps.name)
          execution: \(caps.executionKind)
          stream: \(caps.streamFormat.rawValue)
          completion: \(caps.completionPolicy)
          local: \(caps.isLocal)
          network: \(caps.requiresNetwork)
          credential: \(caps.requiresCredential)
          tools: \(caps.supportsTools)
          structured completion: \(caps.supportsStructuredCompletion)
        """
    }

    static func vault(_ args: [String]) throws {
        guard let sub = args.first else { throw RecipeError.failed("Usage: mentu-recipes vault <set|get|list|delete> ...") }
        switch sub {
        case "set":
            guard args.count == 2 else { throw RecipeError.failed("Usage: printf '%s' \"$SECRET\" | mentu-recipes vault set <key>") }
            let value = readStdinSecret()
            guard !value.isEmpty else { throw RecipeError.failed("No secret received on stdin") }
            try CredentialResolver.setKeychain(key: args[1], value: value)
            print("✓ stored \(args[1])")
        case "get":
            guard args.count >= 2 else { throw RecipeError.failed("Usage: mentu-recipes vault get <key>") }
            let value = try CredentialResolver.getKeychain(key: args[1])
            print(value)
        case "list":
            for key in CredentialResolver.listKeychain() { print(key) }
        case "delete":
            guard args.count >= 2 else { throw RecipeError.failed("Usage: mentu-recipes vault delete <key>") }
            try CredentialResolver.deleteKeychain(key: args[1])
            print("✓ deleted \(args[1])")
        default:
            throw RecipeError.failed("Unknown vault command: \(sub)")
        }
    }

    static func scan(_ args: [String]) throws {
        var root = FileManager.default.currentDirectoryPath
        var artifacts: [URL] = []
        var i = 0
        while i < args.count {
            if args[i] == "--artifact", i + 1 < args.count {
                artifacts.append(URL(fileURLWithPath: args[i + 1]))
                i += 2
            } else if !args[i].hasPrefix("--") {
                root = args[i]
                i += 1
            } else {
                i += 1
            }
        }
        let findings = ReleaseScanner.scan(paths: [URL(fileURLWithPath: root)] + artifacts)
        if findings.isEmpty {
            print("✓ release scan passed")
            return
        }
        for finding in findings {
            print("✗ \(finding.file): \(finding.reason)")
        }
        throw RecipeError.failed("release scan failed with \(findings.count) finding(s)")
    }

    static func parseOptions(_ args: [String]) -> [String: String] {
        var result: [String: String] = [:]
        var vars: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--workspace", "--backend", "--model", "--format", "--max-parallel", "--export-jsonl", "--plan-digest", "--request-key":
                if i + 1 < args.count {
                    result[String(arg.dropFirst(2))] = args[i + 1]
                    i += 2
                    continue
                }
            case "--var":
                if i + 1 < args.count {
                    vars.append(args[i + 1])
                    i += 2
                    continue
                }
            case "--no-cloud":
                result["no-cloud"] = "true"
            case "--cloud":
                result["cloud"] = "true"
            case "--quiet":
                result["quiet"] = "true"
            case "--strict":
                result["strict"] = "true"
            default:
                break
            }
            i += 1
        }
        if !vars.isEmpty { result["vars"] = vars.joined(separator: "\n") }
        return result
    }

    static func parseVars(_ raw: String) -> [String: String] {
        var vars: [String: String] = [:]
        for line in raw.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            vars[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return vars
    }

    static func validateExecutionArguments(_ args: [String]) throws {
        let values: Set<String> = ["--workspace", "--backend", "--model", "--max-parallel", "--var", "--plan-digest", "--request-key"]
        let flags: Set<String> = ["--quiet", "--cloud", "--no-cloud"]
        var seen = Set<String>()
        var index = 0
        while index < args.count {
            let flag = args[index]
            guard seen.insert(flag).inserted || flag == "--var" else { throw RecipeError.failed("Duplicate option: \(flag)") }
            if values.contains(flag) {
                guard index + 1 < args.count, !args[index + 1].hasPrefix("--"), !args[index + 1].isEmpty else {
                    throw RecipeError.failed("Missing value for \(flag)")
                }
                if flag == "--max-parallel", (Int(args[index + 1]) ?? 0) < 1 { throw RecipeError.failed("Invalid parallel limit") }
                index += 2
            } else if flags.contains(flag) {
                index += 1
            } else {
                throw RecipeError.failed("Unknown execution option: \(flag)")
            }
        }
    }

    static func plan(_ args: [String]) throws {
        guard let name = args.first else { throw RecipeError.failed("Usage: mentu-recipes plan <recipe> [options]") }
        try validateExecutionArguments(Array(args.dropFirst()))
        let parsed = parseOptions(Array(args.dropFirst()))
        let options = RunOptions(
            workspace: URL(fileURLWithPath: parsed["workspace"] ?? FileManager.default.currentDirectoryPath),
            backend: parsed["backend"], model: parsed["model"], vars: parseVars(parsed["vars"] ?? ""),
            cloudEnabled: parsed["cloud"] == "true", maxParallel: parsed["max-parallel"].flatMap(Int.init)
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: try encoder.encode(ExecutionPlan.resolve(name, options: options)), as: UTF8.self))
    }

    static func readStdinSecret() -> String {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        var value = String(data: data, encoding: .utf8) ?? ""
        while value.last == "\n" || value.last == "\r" {
            value.removeLast()
        }
        return value
    }

    /// One line per subcommand, taken from the same source as the main help.
    static let usageLines: [String: String] = [
        "setup": "mentu-recipes setup [--yes] [--json] [--no-run]",
        "init": "mentu-recipes init",
        "list": "mentu-recipes list [--json]",
        "ls": "mentu-recipes list [--json]",
        "check": "mentu-recipes check <recipe-or-path>",
        "plan": "mentu-recipes plan <recipe-or-path> [--workspace PATH] [--backend NAME] [--model MODEL] [--var KEY=VALUE] [--max-parallel N] [--cloud]",
        "run": "mentu-recipes run <recipe-or-path> [--workspace PATH] [--backend NAME] [--model MODEL] [--cloud] [--max-parallel N] [--var KEY=VALUE]",
        "resume": "mentu-recipes resume <run-id> [--workspace PATH] [--backend NAME] [--model MODEL] [--max-parallel N] [--cloud] [--quiet]",
        "retry-step": "mentu-recipes retry-step <run-id> <step-label> [--workspace PATH] [--backend NAME] [--model MODEL] [--max-parallel N] [--cloud] [--quiet]",
        "report": "mentu-recipes report <run-id> [--format markdown|json|csv]",
        "doctor": "mentu-recipes doctor <recipe-or-path> [--format markdown|json|csv] [--strict]",
        "analyze-runs": "mentu-recipes analyze-runs [--workspace PATH] [--format markdown|json|csv] [--export-jsonl PATH]",
        "adapters": "mentu-recipes adapters [--json|--explain NAME]",
        "vault": "mentu-recipes vault <set|get|list|delete> ...",
        "scan": "mentu-recipes scan [path] [--artifact PATH]",
    ]

    static func usage(for command: String) {
        if let line = usageLines[command] {
            print("Usage:\n  \(line)")
        } else {
            help()
        }
    }

    /// The recipes this workspace can run, so nobody has to guess a name.
    static func list(_ args: [String]) throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let paths = RecipePaths(workspace: cwd)
        let dir = paths.projectRecipes
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
            .sorted()

        if args.contains("--json") {
            var rows: [[String: Any]] = []
            for file in files {
                let url = dir.appendingPathComponent(file)
                let name = String(file.dropLast(5))
                var row: [String: Any] = ["name": name, "path": url.path]
                if let data = try? Data(contentsOf: url),
                   let recipe = try? JSONDecoder().decode(RecipeDefinition.self, from: data) {
                    row["steps"] = recipe.steps.count
                    if let description = recipe.description { row["description"] = description }
                }
                rows.append(row)
            }
            let out = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            print(String(data: out, encoding: .utf8) ?? "[]")
            return
        }

        if files.isEmpty {
            print("No recipes in \(dir.path)")
            print("Run `mentu-recipes setup` to place an example here.")
            return
        }
        for file in files {
            let name = String(file.dropLast(5))
            let url = dir.appendingPathComponent(file)
            var detail = ""
            if let data = try? Data(contentsOf: url),
               let recipe = try? JSONDecoder().decode(RecipeDefinition.self, from: data) {
                detail = "  \(recipe.steps.count) step(s)"
                if let description = recipe.description, !description.isEmpty {
                    detail += " · \(description)"
                }
            }
            print("\(name)\(detail)")
        }
    }

    static func help() {
        print("""
        Mentu Recipes \(MentuRecipesVersion.string)

        New here? Run `mentu-recipes setup`. It shows what is on this Mac, writes one
        example recipe where you are, runs it, and prints the record it wrote.

        Getting started
          setup [--yes] [--json] [--no-run]   Set up this directory and run the example
          list [--json]                       The recipes this workspace can run
          init                                Create .mentu/recipes and .mentu/prompts

        Running
          plan <recipe> [options]             Inspect a content-bound execution digest
          run <recipe> [options]              Run a recipe
          resume <run-id> [options]           Rerun the steps that did not succeed
          retry-step <run-id> <label>         Rerun one step of a past run

        Admitted execution (opt-in)
          Add --plan-digest SHA256 --request-key KEY to run, resume or retry-step.
          Repeat the original plan options when recovering an admitted run.

        Understanding a run
          report <run-id> [--format F]        What a run did, as markdown, json or csv
          analyze-runs [--format F]           Patterns across this workspace's runs

        Before you run
          check <recipe>                      Validate a recipe against the schema
          doctor <recipe> [--strict]          Score the contract and list every finding
          adapters [--json|--explain NAME]    The backends available on this Mac

        Credentials and shipping
          vault <set|get|list|delete> ...     Provider keys in the login Keychain
          scan [path] [--artifact PATH]       Check a tree or a build before publishing

        Add --help to any command for its options. Docs: https://docs.mentu.ai
        """)
    }
}

if ["run", "resume", "retry-step"].contains(CommandLine.arguments.dropFirst().first ?? "") {
    let cancellation = CLISignalCancellation()
    let result = await cancellation.run { await CLI.main() }
    withExtendedLifetime(cancellation) { exit(result) }
} else {
    exit(await CLI.main())
}
