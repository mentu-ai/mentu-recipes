import Foundation

public struct StepRunRecord: Codable, Sendable {
    public let label: String
    public let backend: String
    public let model: String?
    public let exitCode: Int32
    public let outcome: String?
    public let completionMethod: String?
    public let localComplete: Bool
    public let cloudComplete: Bool?
    public let trustScore: Double?
    public let durationSeconds: Int
    public let attempts: Int
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let outputFile: String
    public let errorFile: String
    public let git: StepGitRecord?
    public let verification: VerificationOutcome?
    public let drift: WorkspaceDrift?
    public let warnings: [String]?
    public let hooks: [HookRunRecord]?
    public let executionUnverifiable: Bool?

    public init(
        label: String,
        backend: String,
        model: String?,
        exitCode: Int32,
        outcome: String? = nil,
        completionMethod: String?,
        localComplete: Bool,
        cloudComplete: Bool?,
        trustScore: Double?,
        durationSeconds: Int,
        attempts: Int,
        inputTokens: Int?,
        outputTokens: Int?,
        outputFile: String,
        errorFile: String,
        git: StepGitRecord?,
        verification: VerificationOutcome? = nil,
        drift: WorkspaceDrift? = nil,
        warnings: [String]? = nil,
        hooks: [HookRunRecord]?,
        executionUnverifiable: Bool? = nil
    ) {
        self.label = label
        self.backend = backend
        self.model = model
        self.exitCode = exitCode
        self.outcome = outcome
        self.completionMethod = completionMethod
        self.localComplete = localComplete
        self.cloudComplete = cloudComplete
        self.trustScore = trustScore
        self.durationSeconds = durationSeconds
        self.attempts = attempts
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.outputFile = outputFile
        self.errorFile = errorFile
        self.git = git
        self.verification = verification
        self.drift = drift
        self.warnings = warnings
        self.hooks = hooks
        self.executionUnverifiable = executionUnverifiable
    }

    enum CodingKeys: String, CodingKey {
        case label, backend, model
        case exitCode = "exit_code"
        case outcome
        case completionMethod = "completion_method"
        case localComplete = "local_complete"
        case cloudComplete = "cloud_complete"
        case trustScore = "trust_score"
        case durationSeconds = "duration_seconds"
        case attempts
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case outputFile = "output_file"
        case errorFile = "error_file"
        case git, verification, drift, warnings, hooks
        case executionUnverifiable = "execution_unverifiable"
    }
}

public struct RecipeRunRecord: Codable, Sendable {
    public let runId: String
    public let recipeName: String
    public let startedAt: String
    public var endedAt: String?
    public var outcome: String
    public var cloudRunId: String?
    public var cloudMode: String
    public var steps: [StepRunRecord]
    public var hooks: [HookRunRecord]
    public var recipeRef: String?
    public var eventsFile: String?
    public var stateFile: String?
    public var baselineFile: String?

    public init(
        runId: String,
        recipeName: String,
        startedAt: String,
        endedAt: String?,
        outcome: String,
        cloudRunId: String?,
        cloudMode: String,
        steps: [StepRunRecord],
        hooks: [HookRunRecord],
        recipeRef: String? = nil,
        eventsFile: String? = nil,
        stateFile: String? = nil,
        baselineFile: String? = nil
    ) {
        self.runId = runId
        self.recipeName = recipeName
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.outcome = outcome
        self.cloudRunId = cloudRunId
        self.cloudMode = cloudMode
        self.steps = steps
        self.hooks = hooks
        self.recipeRef = recipeRef
        self.eventsFile = eventsFile
        self.stateFile = stateFile
        self.baselineFile = baselineFile
    }

    enum CodingKeys: String, CodingKey {
        case runId = "run_id"
        case recipeName = "recipe_name"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case outcome
        case cloudRunId = "cloud_run_id"
        case cloudMode = "cloud_mode"
        case recipeRef = "recipe_ref"
        case eventsFile = "events_file"
        case stateFile = "state_file"
        case baselineFile = "baseline_file"
        case steps, hooks
    }
}

public final class RecipeRunner {
    private let options: RunOptions
    private let paths: RecipePaths
    private let store: RecipeStore
    private let renderer: PromptRenderer
    private let progress: RunProgress
    private let captured: CapturedRecipe?
    private let parentRunId: String?

    public convenience init(options: RunOptions) {
        self.init(options: options, captured: nil, parentRunId: nil)
    }

    init(options: RunOptions, captured: CapturedRecipe?, parentRunId: String?) {
        self.options = options
        self.paths = RecipePaths(workspace: options.workspace, home: options.home)
        self.store = RecipeStore(paths: paths)
        self.renderer = PromptRenderer(paths: paths)
        self.progress = RunProgress(quiet: options.quiet)
        self.captured = captured
        self.parentRunId = parentRunId
    }

    public func run(_ nameOrPath: String) async throws -> RecipeRunRecord {
        try Task.checkCancellation()
        if options.planDigest != nil || options.requestKey != nil {
            return try await AdmittedExecution.execute(nameOrPath, options: options)
        }
        return try await start(nameOrPath)
    }

    func runCaptured(runId: String) async throws -> RecipeRunRecord {
        try Task.checkCancellation()
        guard let captured else { throw AdmissionError.invalidRequest }
        return try await start(captured.source.path, assignedRunId: runId)
    }

    private func start(_ nameOrPath: String, assignedRunId: String? = nil) async throws -> RecipeRunRecord {
        let (recipe, recipeURL) = try captured.map { ($0.recipe, $0.source) } ?? store.load(nameOrPath)
        let runId = assignedRunId ?? "run_\(Self.timestampForID())_\(UUID().uuidString.prefix(8))"
        let runDir = paths.projectRuns.appendingPathComponent(runId)
        guard !FileManager.default.fileExists(atPath: runDir.path) else {
            throw RecipeError.failed("Run directory already exists; refusing to overwrite execution evidence")
        }
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        if let captured {
            try WorkspaceAdmissionLease.write(RunAdmission(version: 1, digest: captured.review.digest, parentRunId: parentRunId),
                                              at: runDir.appendingPathComponent("admission.json"))
            try WorkspaceAdmissionLease.write(captured.review, at: runDir.appendingPathComponent("plan.json"))
        }

        let baseEnv = captured?.environment ?? mergedEnvironment(recipeEnv: recipe.env, stepEnv: nil, vars: options.vars)
        let cloudRequested = options.cloudEnabled || recipe.cloud?.enabled == true
        let cloud = cloudRequested
            ? MentuCloudClient.configured(baseURL: options.cloudBaseURL, env: baseEnv)
            : nil

        var record = RecipeRunRecord(
            runId: runId,
            recipeName: recipe.name,
            startedAt: Self.isoNow(),
            endedAt: nil,
            outcome: "running",
            cloudRunId: nil,
            cloudMode: cloud == nil ? "local-only" : "enabled",
            steps: [],
            hooks: [],
            recipeRef: recipeURL.path,
            eventsFile: "events.jsonl",
            stateFile: "state.json",
            baselineFile: "baseline.json"
        )
        try write(record, to: runDir.appendingPathComponent("run.json"))
        let writer = RunEventWriter(runId: runId, recipeName: recipe.name, runDir: runDir)
        let baseline = await WorkspaceBaselineManager.capture(from: options.workspace)
        try write(baseline, to: runDir.appendingPathComponent("baseline.json"))
        let state = try await RunStateStore.create(
            runId: runId,
            recipeName: recipe.name,
            recipeRef: recipeURL.path,
            backend: options.backend,
            model: options.model,
            vars: options.vars,
            labels: runnableLabels(recipe),
            runDir: runDir
        )
        await writer.emit(.runStarted, status: "running", data: ["recipe_ref": recipeURL.path])

        record.hooks += await HookRunner.run(
            event: "before_run",
            commands: recipe.hooks?.beforeRun,
            recipe: recipe,
            step: nil,
            runId: runId,
            runDir: runDir,
            workspace: options.workspace,
            status: "running",
            quiet: options.quiet,
            environment: captured?.environment
        )
        await writer.emit(.hookFinished, status: "ok", data: ["event": "before_run"])

        if let cloud {
            do {
                let start = try await cloud.startRun(recipeName: recipe.name, workspaceID: options.workspace.lastPathComponent)
                record.cloudRunId = start.runId
                try write(record, to: runDir.appendingPathComponent("run.json"))
            } catch {
                record.cloudMode = "unavailable"
            }
        }

        let overallOK = try await runBody(recipe, runDir: runDir, cloud: cloud, record: &record, events: writer, state: state, retryStep: nil, vars: options.vars)

        record.outcome = overallOK ? "ok" : "failed"
        record.endedAt = Self.isoNow()
        record.hooks += await HookRunner.run(
            event: "after_run",
            commands: recipe.hooks?.afterRun,
            recipe: recipe,
            step: nil,
            runId: runId,
            runDir: runDir,
            workspace: options.workspace,
            status: record.outcome,
            quiet: options.quiet,
            environment: captured?.environment
        )
        if let cloudRunId = record.cloudRunId, let cloud {
            _ = try? await cloud.endRun(runId: cloudRunId, outcome: record.outcome)
        }
        try write(record, to: runDir.appendingPathComponent("run.json"))
        await writer.emit(.runFinished, status: record.outcome)
        return record
    }

    public func resume(runId: String, retryStep: String? = nil) async throws -> RecipeRunRecord {
        try Task.checkCancellation()
        try AdmittedExecution.validateRunID(runId)
        if captured == nil, options.planDigest != nil || options.requestKey != nil {
            return try await AdmittedExecution.execute(nil, runId: runId, retryStep: retryStep, options: options)
        }
        let runDir = paths.projectRuns.appendingPathComponent(runId)
        let admissionURL = runDir.appendingPathComponent("admission.json")
        if FileManager.default.fileExists(atPath: admissionURL.path) {
            guard let captured else { throw AdmissionError.invalidRequest }
            let admission = try WorkspaceAdmissionLease.read(RunAdmission.self, at: admissionURL)
            guard admission.version == 1, admission.digest == captured.review.digest else { throw AdmissionError.planChanged }
        }
        let state = try RunStateStore.load(runDir: runDir)
        let snapshot = await state.snapshot()
        let (recipe, _) = try captured.map { ($0.recipe, $0.source) } ?? store.load(snapshot.recipeRef)
        if let retryStep {
            guard runnableLabels(recipe).contains(retryStep) else { throw RecipeError.failed("Unknown retry step: \(retryStep)") }
            if captured != nil, !recipe.steps.isEmpty {
                try await state.invalidateSteps(try retryDependents(of: retryStep, recipe: recipe))
            }
            try await state.markRetryTarget(retryStep)
        }
        var record = try RunReporter.load(runId: runId, workspace: options.workspace)
        record.outcome = "running"
        record.endedAt = nil
        let eventsURL = runDir.appendingPathComponent("events.jsonl")
        let writer = RunEventWriter(
            runId: runId,
            recipeName: recipe.name,
            runDir: runDir,
            startingSequence: RunEventWriter.lastSequence(in: eventsURL)
        )
        await writer.emit(.runResumed, status: "running", data: retryStep.map { ["retry_step": $0] })
        let env = captured?.environment ?? mergedEnvironment(recipeEnv: recipe.env, stepEnv: nil, vars: snapshot.vars)
        let cloudRequested = options.cloudEnabled || recipe.cloud?.enabled == true
        let cloud = cloudRequested ? MentuCloudClient.configured(baseURL: options.cloudBaseURL, env: env) : nil
        let ok = try await runBody(recipe, runDir: runDir, cloud: cloud, record: &record, events: writer, state: state, retryStep: retryStep, vars: snapshot.vars)
        record.outcome = ok ? "ok" : "failed"
        record.endedAt = Self.isoNow()
        try write(record, to: runDir.appendingPathComponent("run.json"))
        await writer.emit(.runFinished, status: record.outcome)
        return record
    }

    private func runBody(
        _ recipe: RecipeDefinition,
        runDir: URL,
        cloud: MentuCloudClient?,
        record: inout RecipeRunRecord,
        events: RunEventWriter,
        state: RunStateStore,
        retryStep: String?,
        vars: [String: String]
    ) async throws -> Bool {
        switch recipe.type ?? .sequence {
        case .sequence, .formula:
            return try await runSteps(recipe, runDir: runDir, cloud: cloud, record: &record, events: events, state: state, retryStep: retryStep, vars: vars)
        case .pipeline:
            return try await runRecipeNodes(recipe.recipes ?? [], recipe: recipe, runDir: runDir, record: &record, parallel: false, events: events, state: state, retryStep: retryStep, vars: vars)
        case .compound:
            return try await runRecipeDAG(recipe.recipes ?? [], recipe: recipe, runDir: runDir, record: &record, events: events, state: state, retryStep: retryStep, vars: vars)
        case .parallel:
            return try await runRecipeNodes(recipe.recipes ?? [], recipe: recipe, runDir: runDir, record: &record, parallel: true, events: events, state: state, retryStep: retryStep, vars: vars)
        }
    }

    private func runSteps(
        _ recipe: RecipeDefinition,
        runDir: URL,
        cloud: MentuCloudClient?,
        record: inout RecipeRunRecord,
        events: RunEventWriter,
        state: RunStateStore,
        retryStep: String?,
        vars: [String: String]
    ) async throws -> Bool {
        let ordered = try store.topologicalOrder(recipe.steps)
        let total = ordered.count
        // The counter column names a step's place in the whole recipe, so it is
        // the topological position even when steps run out of order in waves.
        var position: [String: Int] = [:]
        for (offset, step) in ordered.enumerated() { position[step.label] = offset + 1 }

        let hasDAG = recipe.steps.contains { !($0.dependsOn ?? []).isEmpty }
        if !hasDAG {
            var overallOK = true
            var done = 0
            for step in ordered {
                let index = position[step.label] ?? 0
                if await state.shouldSkipCompleted(label: step.label, retryStep: retryStep) {
                    progress.stepSkipped(index: index, total: total, label: step.label, reason: "already complete")
                    await events.emit(.stepSkipped, stepLabel: step.label, status: "success", message: "already complete")
                    done += 1
                    continue
                }
                await events.emit(.stepQueued, stepLabel: step.label, status: "pending")
                progress.progressBar(done: done, total: total, noun: "steps")
                let stepRecord = await runStepSafely(step, index: index, total: total, recipe: recipe, runDir: runDir, cloud: cloud, cloudRunId: record.cloudRunId, events: events, state: state, vars: vars)
                done += 1
                record.steps.append(stepRecord)
                try write(record, to: runDir.appendingPathComponent("run.json"))
                if !stepRecord.unblocksDependents {
                    overallOK = false
                    break
                }
            }
            return overallOK
        }

        var completed: [String: Bool] = [:]
        var overallOK = true
        var done = 0
        for wave in try stepWaves(recipe.steps) {
            var runnableNow: [RecipeStep] = []
            for step in wave {
                let index = position[step.label] ?? 0
                if await state.shouldSkipCompleted(label: step.label, retryStep: retryStep) {
                    completed[step.label] = true
                    progress.stepSkipped(index: index, total: total, label: step.label, reason: "already complete")
                    await events.emit(.stepSkipped, stepLabel: step.label, status: "success", message: "already complete")
                    done += 1
                    continue
                }
                guard (step.dependsOn ?? []).allSatisfy({ completed[$0] == true }) else {
                    completed[step.label] = false
                    let skippedRecord = failedRecord(step, recipe: recipe, message: "dependency failed or skipped", outcome: StepExecutionState.skipped.rawValue)
                    record.steps.append(skippedRecord)
                    progress.stepSkipped(index: index, total: total, label: step.label, reason: "dependency failed or skipped")
                    try? await state.record(label: step.label, state: .skipped, message: "dependency failed or skipped")
                    await events.emit(.stepSkipped, stepLabel: step.label, status: "skipped", message: "dependency failed or skipped")
                    overallOK = false
                    done += 1
                    continue
                }
                runnableNow.append(step)
            }
            for step in runnableNow {
                await events.emit(.stepQueued, stepLabel: step.label, status: "pending")
            }
            if !runnableNow.isEmpty {
                progress.progressBar(done: done, total: total, noun: "steps")
            }
            let results = await runStepWave(runnableNow, positions: position, total: total, recipe: recipe, runDir: runDir, cloud: cloud, cloudRunId: record.cloudRunId, events: events, state: state, vars: vars)
            done += results.count
            for stepRecord in results {
                completed[stepRecord.label] = stepRecord.unblocksDependents
                if completed[stepRecord.label] != true { overallOK = false }
                record.steps.append(stepRecord)
            }
            try write(record, to: runDir.appendingPathComponent("run.json"))
            if !overallOK { break }
        }
        return overallOK
    }

    private func runStepWave(
        _ steps: [RecipeStep],
        positions: [String: Int],
        total: Int,
        recipe: RecipeDefinition,
        runDir: URL,
        cloud: MentuCloudClient?,
        cloudRunId: String?,
        events: RunEventWriter,
        state: RunStateStore,
        vars: [String: String]
    ) async -> [StepRunRecord] {
        let limit = max(1, options.maxParallel ?? recipe.maxParallel ?? steps.count)
        let semaphore = AsyncSemaphore(value: limit)
        return await withTaskGroup(of: StepRunRecord.self) { group in
                for step in steps {
                    let index = positions[step.label] ?? 0
                    group.addTask {
                        await semaphore.wait()
                    let record = await self.runStepSafely(step, index: index, total: total, recipe: recipe, runDir: runDir, cloud: cloud, cloudRunId: cloudRunId, events: events, state: state, vars: vars)
                    await semaphore.signal()
                    return record
                }
            }
            var records: [StepRunRecord] = []
            for await record in group {
                records.append(record)
            }
            return records.sorted { $0.label < $1.label }
        }
    }

    private func runStepSafely(
        _ step: RecipeStep,
        index: Int,
        total: Int,
        recipe: RecipeDefinition,
        runDir: URL,
        cloud: MentuCloudClient?,
        cloudRunId: String?,
        events: RunEventWriter,
        state: RunStateStore,
        vars: [String: String]
    ) async -> StepRunRecord {
        do {
            return try await runStep(step, index: index, total: total, recipe: recipe, runDir: runDir, cloud: cloud, cloudRunId: cloudRunId, events: events, state: state, vars: vars)
        } catch {
            let message = cleanErrorMessage(String(describing: error))
            progress.stepFailed(index: index, total: total, label: step.label, message: message)
            let attempts = await state.snapshot().steps[step.label]?.attempts ?? 0
            let failed = failedRecord(step, recipe: recipe, message: message, attempts: attempts)
            if attempts > 0 {
                try? (message + "\n").write(to: runDir.appendingPathComponent("\(step.label).attempt-\(attempts).failure.txt"), atomically: true, encoding: .utf8)
            }
            try? await state.record(label: step.label, state: .failed, message: message)
            await events.emit(.error, stepLabel: step.label, status: "failed", message: message)
            try? "".write(to: runDir.appendingPathComponent(failed.outputFile), atomically: true, encoding: .utf8)
            try? (message + "\n").write(to: runDir.appendingPathComponent(failed.errorFile), atomically: true, encoding: .utf8)
            _ = await HookRunner.run(
                event: "on_error",
                commands: recipe.hooks?.onError,
                recipe: recipe,
                step: step,
                runId: runDir.lastPathComponent,
                runDir: runDir,
                workspace: options.workspace,
                status: "failed",
                quiet: options.quiet,
                environment: captured?.environment
            )
            return failed
        }
    }

    private func cleanErrorMessage(_ message: String) -> String {
        var text = ProviderLogSanitizer.clean(message)
        if text.hasPrefix("failed(\""), text.hasSuffix("\")") {
            text.removeFirst("failed(\"".count)
            text.removeLast(2)
            text = text.replacingOccurrences(of: #"\""#, with: #"""#)
        }
        return text
    }

    private func failedRecord(_ step: RecipeStep, recipe: RecipeDefinition, message: String, outcome: String = StepExecutionState.failed.rawValue, attempts: Int = 0) -> StepRunRecord {
        StepRunRecord(
            label: step.label,
            backend: step.backend ?? options.backend ?? recipe.backend ?? "unresolved",
            model: step.model ?? options.model ?? recipe.model,
            exitCode: 1,
            outcome: outcome,
            completionMethod: "failed",
            localComplete: false,
            cloudComplete: nil,
            trustScore: nil,
            durationSeconds: 0,
            attempts: attempts,
            inputTokens: nil,
            outputTokens: nil,
            outputFile: "\(step.label).stdout",
            errorFile: "\(step.label).stderr",
            git: nil,
            warnings: [message],
            hooks: nil
        )
    }

    private func stepWaves(_ steps: [RecipeStep]) throws -> [[RecipeStep]] {
        let ordered = try store.topologicalOrder(steps)
        var levels: [String: Int] = [:]
        let byLabel = Dictionary(uniqueKeysWithValues: ordered.map { ($0.label, $0) })
        func level(_ label: String) -> Int {
            if let cached = levels[label] { return cached }
            let deps = byLabel[label]?.dependsOn ?? []
            let value = deps.isEmpty ? 0 : ((deps.map(level).max() ?? 0) + 1)
            levels[label] = value
            return value
        }
        for step in ordered { _ = level(step.label) }
        return Dictionary(grouping: ordered, by: { levels[$0.label] ?? 0 })
            .keys.sorted()
            .map { key in ordered.filter { (levels[$0.label] ?? 0) == key } }
    }

    private func runRecipeNodes(
        _ nodes: [RecipeNode],
        recipe: RecipeDefinition,
        runDir: URL,
        record: inout RecipeRunRecord,
        parallel: Bool,
        events: RunEventWriter,
        state: RunStateStore,
        retryStep: String?,
        vars: [String: String]
    ) async throws -> Bool {
        if parallel {
            let limit = max(1, options.maxParallel ?? recipe.maxParallel ?? nodes.count)
            let semaphore = AsyncSemaphore(value: limit)
            progress.progressBar(done: 0, total: nodes.count, noun: "recipes")
            let results = await withTaskGroup(of: StepRunRecord.self) { group in
                for node in nodes {
                    let label = node.label ?? node.recipe
                    if await state.shouldSkipCompleted(label: label, retryStep: retryStep) {
                        progress.layer(state: .skipped, label: label, seconds: nil,
                                       deps: node.dependsOn ?? [], waitingOn: [], outcome: "already complete")
                        await events.emit(.stepSkipped, stepLabel: label, status: "success", message: "already complete")
                        continue
                    }
                    group.addTask {
                        await semaphore.wait()
                        let record = await self.runChildRecipe(node, parent: recipe, runDir: runDir, events: events, state: state, vars: vars)
                        await semaphore.signal()
                        return record
                    }
                }
                var records: [StepRunRecord] = []
                for await record in group { records.append(record) }
                return records
            }
            record.steps += results.sorted { $0.label < $1.label }
            try write(record, to: runDir.appendingPathComponent("run.json"))
            return results.allSatisfy(\.unblocksDependents)
        }

        var ok = true
        var done = 0
        for node in nodes {
            let label = node.label ?? node.recipe
            if await state.shouldSkipCompleted(label: label, retryStep: retryStep) {
                progress.layer(state: .skipped, label: label, seconds: nil,
                               deps: node.dependsOn ?? [], waitingOn: [], outcome: "already complete")
                await events.emit(.stepSkipped, stepLabel: label, status: "success", message: "already complete")
                done += 1
                continue
            }
            progress.progressBar(done: done, total: nodes.count, noun: "recipes")
            let result = await runChildRecipe(node, parent: recipe, runDir: runDir, events: events, state: state, vars: vars)
            done += 1
            record.steps.append(result)
            try write(record, to: runDir.appendingPathComponent("run.json"))
            if !result.unblocksDependents {
                ok = false
                break
            }
        }
        return ok
    }

    private func runRecipeDAG(
        _ nodes: [RecipeNode],
        recipe: RecipeDefinition,
        runDir: URL,
        record: inout RecipeRunRecord,
        events: RunEventWriter,
        state: RunStateStore,
        retryStep: String?,
        vars: [String: String]
    ) async throws -> Bool {
        let ordered = try store.topologicalOrder(nodes)
        var completed: [String: Bool] = [:]
        var ok = true
        var done = 0
        for node in ordered {
            let label = node.label ?? node.recipe
            let deps = node.dependsOn ?? []
            if await state.shouldSkipCompleted(label: label, retryStep: retryStep) {
                completed[label] = true
                progress.layer(state: .skipped, label: label, seconds: nil,
                               deps: deps, waitingOn: [], outcome: "already complete")
                await events.emit(.stepSkipped, stepLabel: label, status: "success", message: "already complete")
                done += 1
                continue
            }
            guard deps.allSatisfy({ completed[$0] == true }) else {
                completed[label] = false
                // Name the upstream layers that did not clear, which is the
                // question a halted graph always raises.
                progress.layer(state: .queued, label: label, seconds: nil, deps: deps,
                               waitingOn: deps.filter { completed[$0] != true }, outcome: nil)
                try? await state.record(label: label, state: .skipped, message: "dependency failed or skipped")
                await events.emit(.stepSkipped, stepLabel: label, status: "skipped", message: "dependency failed or skipped")
                ok = false
                done += 1
                continue
            }
            progress.progressBar(done: done, total: ordered.count, noun: "recipes")
            let result = await runChildRecipe(node, parent: recipe, runDir: runDir, events: events, state: state, vars: vars)
            done += 1
            completed[label] = result.unblocksDependents
            record.steps.append(result)
            try write(record, to: runDir.appendingPathComponent("run.json"))
            if !result.unblocksDependents { ok = false }
        }
        return ok
    }

    private func runChildRecipe(_ node: RecipeNode, parent: RecipeDefinition, runDir: URL, events: RunEventWriter, state: RunStateStore, vars: [String: String]) async -> StepRunRecord {
        let label = node.label ?? node.recipe
        let deps = node.dependsOn ?? []
        let start = Date()
        try? await state.record(label: label, state: .running, incrementAttempts: true)
        await events.emit(.stepStarted, stepLabel: label, backend: "recipe", status: "running")
        progress.layer(state: .running, label: label, seconds: 0,
                       deps: deps, waitingOn: [], outcome: "running")
        var childVars = vars
        for (key, value) in node.vars ?? [:] { childVars[key] = value }
        let child = RecipeRunner(options: RunOptions(
            workspace: options.workspace,
            home: options.home,
            backend: options.backend,
            model: options.model,
            vars: childVars,
            cloudEnabled: options.cloudEnabled,
            cloudBaseURL: options.cloudBaseURL,
            quiet: options.quiet,
            maxParallel: options.maxParallel
        ), captured: captured?.children[label], parentRunId: captured == nil ? nil : runDir.lastPathComponent)
        do {
            let childRecord: RecipeRunRecord
            if captured != nil {
                if let childId = await state.snapshot().childRunIds?[label] {
                    try AdmittedExecution.validateRunID(childId)
                    let previous = try RunReporter.load(runId: childId, workspace: options.workspace)
                    guard previous.outcome != "running" else { throw AdmissionError.unverifiable(childId) }
                    childRecord = previous.outcome == "ok" ? previous : try await child.resume(runId: childId)
                } else {
                    let childId = "run_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
                    try await state.reserveChild(label: label, runId: childId)
                    childRecord = try await child.runCaptured(runId: childId)
                }
            } else {
                childRecord = try await child.run(node.recipe)
            }
            let outputFile = "\(label).child-run.txt"
            try? childRecord.runId.write(to: runDir.appendingPathComponent(outputFile), atomically: true, encoding: .utf8)
            let childState: StepExecutionState = childRecord.outcome == "ok" ? .success : .failed
            try? await state.record(label: label, state: childState)
            await events.emit(.stepFinished, stepLabel: label, backend: "recipe", status: childState.rawValue)
            progress.layer(state: childState == .success ? .ok : .failed, label: label,
                           seconds: Int(Date().timeIntervalSince(start)), deps: deps,
                           waitingOn: [], outcome: childState == .success ? "ok" : "failed")
            return StepRunRecord(
                label: label,
                backend: "recipe",
                model: nil,
                exitCode: childRecord.outcome == "ok" ? 0 : 1,
                outcome: childRecord.outcome == "ok" ? StepExecutionState.success.rawValue : StepExecutionState.failed.rawValue,
                completionMethod: "child_recipe",
                localComplete: childRecord.outcome == "ok",
                cloudComplete: nil,
                trustScore: nil,
                durationSeconds: Int(Date().timeIntervalSince(start)),
                attempts: await state.snapshot().steps[label]?.attempts ?? 1,
                inputTokens: nil,
                outputTokens: nil,
                outputFile: outputFile,
                errorFile: "\(label).child-run.err",
                git: nil,
                hooks: nil,
                executionUnverifiable: childRecord.steps.contains(where: { $0.exitCode == 124 || $0.executionUnverifiable == true }) ? true : nil
            )
        } catch {
            let errorFile = "\(label).child-run.err"
            try? String(describing: error).write(to: runDir.appendingPathComponent(errorFile), atomically: true, encoding: .utf8)
            try? await state.record(label: label, state: .failed, message: String(describing: error))
            await events.emit(.stepFinished, stepLabel: label, backend: "recipe", status: StepExecutionState.failed.rawValue)
            progress.layer(state: .failed, label: label,
                           seconds: Int(Date().timeIntervalSince(start)), deps: deps,
                           waitingOn: [], outcome: cleanErrorMessage(String(describing: error)))
            return StepRunRecord(
                label: label,
                backend: "recipe",
                model: nil,
                exitCode: 1,
                outcome: StepExecutionState.failed.rawValue,
                completionMethod: "child_recipe",
                localComplete: false,
                cloudComplete: nil,
                trustScore: nil,
                durationSeconds: Int(Date().timeIntervalSince(start)),
                attempts: await state.snapshot().steps[label]?.attempts ?? 1,
                inputTokens: nil,
                outputTokens: nil,
                outputFile: "\(label).child-run.txt",
                errorFile: errorFile,
                git: nil,
                hooks: nil,
                executionUnverifiable: captured == nil ? nil : true
            )
        }
    }

    private func runStep(
        _ step: RecipeStep,
        index: Int,
        total: Int,
        recipe: RecipeDefinition,
        runDir: URL,
        cloud: MentuCloudClient?,
        cloudRunId: String?,
        events: RunEventWriter,
        state: RunStateStore,
        vars: [String: String]
    ) async throws -> StepRunRecord {
        try Task.checkCancellation()
        let backendName = step.backend ?? options.backend ?? recipe.backend
        let frozenStep = captured?.steps[step.label]
        let env = frozenStep?.environment ?? mergedEnvironment(recipeEnv: recipe.env, stepEnv: step.env, vars: vars)
        let adapter: BackendAdapter
        if let backendName {
            guard let resolved = AdapterRegistry.adapter(named: backendName, providers: recipe.providers ?? [:]) else {
                throw RecipeError.backendUnavailable(backendName)
            }
            adapter = resolved
        } else if let detected = AdapterRegistry.autoDetect(env: env) {
            adapter = detected
        } else {
            throw RecipeError.missingBackend(label: step.label)
        }
        await events.emit(.backendSelected, stepLabel: step.label, backend: adapter.name, status: "selected")

        let promptVars = env.merging(vars) { _, new in new }
        let prompt = try frozenStep?.prompt ?? renderer.prompt(for: step, vars: promptVars)
        let stepDir = try frozenStep?.directory ?? resolveStepDirectory(step.dir)
        if frozenStep != nil, try ExecutionDirectory.resolve(step.dir, workspace: options.workspace) != stepDir {
            throw AdmissionError.planChanged
        }
        let timeout = step.timeout ?? 1800
        let maxOutputBytes = step.maxOutputBytes ?? 5_000_000
        let attemptsAllowed = max(0, step.maxRetries ?? 0) + 1
        let model = captured?.review.steps.first(where: { $0.label == step.label })?.model ?? step.model ?? options.model ?? recipe.model

        var lastResult: AdapterResult?
        var lastLocalComplete = false
        let start = Date()
        let previousAttempts = await state.snapshot().steps[step.label]?.attempts ?? 0
        var attempts = previousAttempts
        var hookRecords: [HookRunRecord] = []
        let preStepBaseline = await WorkspaceBaselineManager.capture(from: stepDir)
        try? await state.record(label: step.label, state: .running, message: nil)
        await events.emit(.stepStarted, stepLabel: step.label, backend: adapter.name, status: "running")
        hookRecords += await HookRunner.run(
            event: "before_step",
            commands: recipe.hooks?.beforeStep,
            recipe: recipe,
            step: step,
            runId: runDir.lastPathComponent,
            runDir: runDir,
            workspace: stepDir,
            status: "running",
            quiet: options.quiet,
            environment: captured?.environment
        )
        await events.emit(.hookFinished, stepLabel: step.label, status: "ok", data: ["event": "before_step"])

        for attempt in 1...attemptsAllowed {
            attempts = previousAttempts + attempt
            if attempt > 1 {
                try? await state.record(label: step.label, state: .running, message: "retry \(attempt)", incrementAttempts: true)
                await events.emit(.stepRetried, stepLabel: step.label, backend: adapter.name, status: "retrying", data: ["attempt": String(attempt)])
            } else {
                try? await state.record(label: step.label, state: .running, incrementAttempts: true)
            }
            progress.stepStarted(index: index, total: total, label: step.label,
                                 engine: adapter.name, attempt: attempt)
            let result = try await adapter.execute(
                AdapterRequest(
                    prompt: prompt,
                    systemContext: nil,
                    model: model,
                    env: env,
                    timeout: timeout,
                    maxOutputBytes: maxOutputBytes,
                    reasoning: step.reasoning,
                    thinking: step.thinking,
                    maxOutputTokens: step.maxOutputTokens,
                    allowedTools: step.allowedTools,
                    disallowedTools: step.disallowedTools,
                    sessionName: "mentu-recipes-\(recipe.name)-\(step.label)",
                    workingDirectory: stepDir
                ),
                eventSink: { text in
                    self.progress.stream(text)
                }
            )
            lastResult = result
            let attemptPrefix = "\(step.label).attempt-\(attempts)"
            try result.stdout.write(to: runDir.appendingPathComponent("\(attemptPrefix).stdout"), atomically: true, encoding: .utf8)
            try result.stderr.write(to: runDir.appendingPathComponent("\(attemptPrefix).stderr"), atomically: true, encoding: .utf8)
            lastLocalComplete = localComplete(step: step, adapter: adapter, result: result)
            if Task.isCancelled {
                lastLocalComplete = false
                break
            }
            if lastLocalComplete {
                await events.emit(.verificationStarted, stepLabel: step.label, status: "running")
                break
            }
            if attempt < attemptsAllowed {
                let backoff = step.retryBackoffMs ?? 1000
                try await Task.sleep(nanoseconds: UInt64(backoff) * 1_000_000)
            }
        }

        guard let result = lastResult else {
            throw RecipeError.failed("Step did not run: \(step.label)")
        }

        let stdoutFile = "\(step.label).stdout"
        let stderrFile = "\(step.label).stderr"
        try result.stdout.write(to: runDir.appendingPathComponent(stdoutFile), atomically: true, encoding: .utf8)
        try result.stderr.write(to: runDir.appendingPathComponent(stderrFile), atomically: true, encoding: .utf8)

        let completionMethod: String
        if let keyword = step.completionKeyword, !keyword.isEmpty, lastLocalComplete {
            completionMethod = "keyword_output"
        } else {
            switch adapter.completionPolicy {
            case .shellExitCode: completionMethod = "exit_code"
            case .providerCompleteEvent: completionMethod = "provider_complete"
            case .keywordRequired: completionMethod = "keyword_required"
            }
        }

        var cloudComplete: Bool?
        var trustScore: Double?
        if let cloud, recipe.cloud?.evaluateSteps == true, !Task.isCancelled {
            let tail = String(result.stdout.suffix(8000))
            do {
                let verdict = try await cloud.evaluateStep(.init(
                    run_id: cloudRunId,
                    recipe_name: recipe.name,
                    step_label: step.label,
                    backend: adapter.name,
                    model: model,
                    exit_code: result.exitCode,
                    local_complete: lastLocalComplete,
                    output_tail: tail,
                    duration_seconds: Int(Date().timeIntervalSince(start))
                ))
                cloudComplete = verdict.complete
                trustScore = verdict.trust_score
            } catch {
                cloudComplete = nil
            }
        }

        var verificationOutcome: VerificationOutcome?
        let processLocalComplete = lastLocalComplete
        if Task.isCancelled { lastLocalComplete = false }
        if lastLocalComplete {
            verificationOutcome = try await Verification.evaluate(step.verify, stepDir: stepDir, preStepBaseline: preStepBaseline, environment: captured?.environment)
            await events.emit(
                .verificationFinished,
                stepLabel: step.label,
                status: verificationOutcome?.passed == true ? "ok" : "failed",
                data: [
                    "warnings": String(verificationOutcome?.warnings.count ?? 0),
                    "errors": String(verificationOutcome?.errors.count ?? 0)
                ]
            )
            if verificationOutcome?.passed != true {
                lastLocalComplete = false
            }
        }

        var gitRecord: StepGitRecord?
        if Task.isCancelled { lastLocalComplete = false }
        if lastLocalComplete {
            gitRecord = await GitWorkspace.finalizeStep(
                label: step.label,
                expectedChanges: step.expectedChanges,
                stepDir: stepDir,
                runDir: runDir,
                runId: runDir.lastPathComponent,
                preStepBaseline: preStepBaseline
            )
        }
        let postStepBaseline = await WorkspaceBaselineManager.capture(from: stepDir)
        let drift = WorkspaceBaselineManager.classify(before: preStepBaseline, after: postStepBaseline, expectedChanges: step.expectedChanges)
        if !drift.createdPaths.isEmpty || !drift.preexistingPaths.isEmpty {
            await events.emit(
                .workspaceDrift,
                stepLabel: step.label,
                status: drift.unexpectedPaths.isEmpty ? "ok" : "warning",
                data: [
                    "created": drift.createdPaths.joined(separator: ","),
                    "expected": drift.expectedPaths.joined(separator: ","),
                    "unexpected": drift.unexpectedPaths.joined(separator: ",")
                ]
            )
        }
        if let gitRecord, !gitRecord.quarantineFiles.isEmpty {
            await events.emit(.quarantineWritten, stepLabel: step.label, status: "warning", data: ["files": gitRecord.quarantineFiles.joined(separator: ",")])
        }
        var warnings = (verificationOutcome?.warnings.map(\.message) ?? [])
        warnings += verificationOutcome?.errors.map(\.message) ?? []
        if gitRecord?.fatal == true {
            lastLocalComplete = false
            warnings.append(gitRecord?.note ?? "Step wrote outside expected_changes")
        }
        if !lastLocalComplete {
            warnings.append(processLocalComplete ? "Step failed boundary verification" : "Completion policy was not satisfied")
        }
        if let note = gitRecord?.note, gitRecord?.fatal != true {
            warnings.append(note)
        }
        if !drift.unexpectedPaths.isEmpty, step.expectedChanges != nil {
            let message = gitRecord?.quarantineFiles.isEmpty == false
                ? "Quarantine patch recorded for changes outside expected_changes"
                : "Changes outside expected_changes (no quarantine patch recorded)"
            warnings.append("\(message): \(drift.unexpectedPaths.joined(separator: ", "))")
        }
        let stepState: StepExecutionState = lastLocalComplete ? (warnings.isEmpty ? .success : .warnBookkeeping) : .failed
        try? await state.record(label: step.label, state: stepState, message: warnings.first)

        hookRecords += await HookRunner.run(
            event: lastLocalComplete ? "after_step" : "on_error",
            commands: lastLocalComplete ? recipe.hooks?.afterStep : recipe.hooks?.onError,
            recipe: recipe,
            step: step,
            runId: runDir.lastPathComponent,
            runDir: runDir,
            workspace: stepDir,
            status: lastLocalComplete ? "ok" : "failed",
            extraEnv: [
                "MENTU_RECIPES_STEP_STDOUT": runDir.appendingPathComponent(stdoutFile).path,
                "MENTU_RECIPES_STEP_STDERR": runDir.appendingPathComponent(stderrFile).path
            ],
            quiet: options.quiet,
            environment: captured?.environment
        )
        await events.emit(.hookFinished, stepLabel: step.label, status: lastLocalComplete ? "ok" : "failed", data: ["event": lastLocalComplete ? "after_step" : "on_error"])
        await events.emit(.stepFinished, stepLabel: step.label, backend: adapter.name, status: stepState.rawValue)

        let elapsedSeconds = Int(Date().timeIntervalSince(start))
        progress.stepFinished(
            index: index,
            total: total,
            label: step.label,
            engine: adapter.name,
            seconds: elapsedSeconds,
            complete: lastLocalComplete,
            detail: lastLocalComplete ? warnings.first : "exit \(result.exitCode)"
        )

        return StepRunRecord(
            label: step.label,
            backend: adapter.name,
            model: model,
            exitCode: result.exitCode,
            outcome: stepState.rawValue,
            completionMethod: completionMethod,
            localComplete: lastLocalComplete,
            cloudComplete: cloudComplete,
            trustScore: trustScore,
            durationSeconds: elapsedSeconds,
            attempts: attempts,
            inputTokens: result.inputTokens,
            outputTokens: result.outputTokens,
            outputFile: stdoutFile,
            errorFile: stderrFile,
            git: gitRecord,
            verification: verificationOutcome,
            drift: drift,
            warnings: warnings.isEmpty ? nil : warnings,
            hooks: hookRecords
        )
    }

    private func localComplete(step: RecipeStep, adapter: BackendAdapter, result: AdapterResult) -> Bool {
        guard result.exitCode == 0 else { return false }
        if let keyword = step.completionKeyword, !keyword.isEmpty {
            return result.stdout.contains(keyword) || result.stderr.contains(keyword)
        }
        switch adapter.completionPolicy {
        case .shellExitCode:
            return result.exitCode == 0
        case .providerCompleteEvent:
            return result.providerCompleted
        case .keywordRequired:
            return false
        }
    }

    private func resolveStepDirectory(_ dir: String?) throws -> URL {
        guard let dir, !dir.isEmpty else { return options.workspace }
        guard !dir.hasPrefix("/"), !dir.hasPrefix("~") else {
            throw RecipeError.failed("Step dir must stay inside the workspace: \(dir)")
        }
        let url = options.workspace.appendingPathComponent(dir).standardizedFileURL
        guard RecipePaths.isDescendant(url, of: options.workspace) else {
            throw RecipeError.failed("Step dir escapes the workspace: \(dir)")
        }
        return url
    }

    private func mergedEnvironment(recipeEnv: [String: String]?, stepEnv: [String: String]?, vars: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        for (key, value) in recipeEnv ?? [:] { env[key] = PromptRenderer.render(value, vars: vars) }
        for (key, value) in stepEnv ?? [:] { env[key] = PromptRenderer.render(value, vars: vars) }
        for (key, value) in vars { env[key] = value }
        return CredentialResolver.resolveEnv(env)
    }

    private func runnableLabels(_ recipe: RecipeDefinition) -> [String] {
        if !recipe.steps.isEmpty {
            return recipe.steps.map(\.label)
        }
        return (recipe.recipes ?? []).map { $0.label ?? $0.recipe }
    }

    private func retryDependents(of target: String, recipe: RecipeDefinition) throws -> Set<String> {
        let ordered = try store.topologicalOrder(recipe.steps)
        if !ordered.contains(where: { !($0.dependsOn ?? []).isEmpty }) {
            return Set(ordered.drop(while: { $0.label != target }).map(\.label))
        }
        var affected: Set<String> = [target]
        for step in ordered where (step.dependsOn ?? []).contains(where: affected.contains) {
            affected.insert(step.label)
        }
        return affected
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func isoNow() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func timestampForID() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: Date())
    }
}

private extension StepRunRecord {
    var unblocksDependents: Bool {
        if let outcome, outcome == StepExecutionState.warnBookkeeping.rawValue || outcome == StepExecutionState.success.rawValue {
            return true
        }
        return cloudComplete ?? localComplete
    }
}
