import Foundation

/// Uses the locally installed Claude Code CLI (`claude -p`) so requests run on the
/// user's Claude subscription. No API key needed.
struct ClaudeCLIBrain: MoodBrain {
    let kind = BrainKind.claude
    var model: String?
    /// Picking songs for a mood doesn't need deep reasoning. Low effort cuts latency roughly in half.
    var effort: String? = ProcessInfo.processInfo.environment["SPOTHELPER_EFFORT"] ?? "low"
    var executableOverride: String?
    var timeout: Duration = .seconds(120)

    func interpret(_ request: MoodRequest) async throws -> MoodPlan {
        try await ClaudeCLI.structuredRequest(
            MoodPlan.self,
            prompt: MoodPrompt.user(request, compact: false),
            systemPrompt: MoodPrompt.system,
            schema: MoodPrompt.jsonSchema,
            // No tools and no MCP servers: the brain only needs to think.
            extraArguments: ["--tools", "", "--strict-mcp-config"],
            model: model,
            effort: effort,
            executableOverride: executableOverride,
            timeout: timeout
        )
    }
}

enum ClaudeCLI {
    private static var home: String { FileManager.default.homeDirectoryForCurrentUser.path }

    /// GUI apps don't inherit the shell PATH, so check the usual install spots first.
    static func locate(override: String? = nil) -> URL? {
        let fm = FileManager.default
        if let override = override?.trimmingCharacters(in: .whitespaces), !override.isEmpty {
            let path = (override as NSString).expandingTildeInPath
            return fm.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        if let hit = candidates.first(where: fm.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: hit)
        }
        return locateViaLoginShell()
    }

    private static func locateViaLoginShell() -> URL? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // A slow or interactive shell config must not hang the app: give it 5 seconds.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        if exited.wait(timeout: .now() + 5) == .timedOut {
            process.terminate()
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return process.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: path)
            ? URL(fileURLWithPath: path) : nil
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        env["PATH"] = (extra + [env["PATH"] ?? ""]).filter { !$0.isEmpty }.joined(separator: ":")
        return env
    }

    /// A neutral directory so the CLI doesn't pick up project files from wherever the app was launched.
    static var workingDirectory: URL {
        let dir = AppPaths.support.appendingPathComponent("claude", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Runs one `claude -p` request with a JSON Schema and decodes the structured output.
    static func structuredRequest<T: Decodable>(
        _ type: T.Type,
        prompt: String,
        systemPrompt: String?,
        schema: String,
        extraArguments: [String],
        model: String? = nil,
        effort: String? = nil,
        executableOverride: String? = nil,
        timeout: Duration
    ) async throws -> T {
        guard let executable = locate(override: executableOverride) else {
            throw BrainError.unavailable("Claude Code CLI not found. Install it or set its path in Settings.")
        }

        var arguments = [
            "-p", prompt,
            "--output-format", "json",
            "--json-schema", schema,
            "--disable-slash-commands",
            "--no-session-persistence",
        ] + extraArguments
        if let systemPrompt {
            arguments += ["--system-prompt", systemPrompt]
        }
        if let model = model?.trimmingCharacters(in: .whitespaces), !model.isEmpty {
            arguments += ["--model", model]
        }
        if let effort, !effort.isEmpty {
            arguments += ["--effort", effort]
        }

        let output: ProcessRunner.Output
        do {
            output = try await ProcessRunner.run(
                executable,
                arguments: arguments,
                environment: environment,
                currentDirectory: workingDirectory,
                timeout: timeout
            )
        } catch is ProcessRunner.TimedOut {
            throw BrainError.timedOut
        }

        // With --output-format json the CLI prints a result envelope even for errors,
        // so try to parse it before looking at the exit status.
        if let value = try? parseEnvelope(output.stdout, as: T.self) {
            return value
        }
        if output.status != 0 {
            let detail = [errorMessage(from: output.stdout), output.stderrText]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "exit status \(output.status)"
            throw BrainError.failed("Claude Code failed: \(detail.truncated(to: 300))")
        }
        return try parseEnvelope(output.stdout, as: T.self)
    }

    /// Parses the `claude -p --output-format json` envelope. Prefers `structured_output`
    /// and falls back to decoding the `result` text.
    static func parseEnvelope<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        guard let envelope = lastJSONObject(in: data) else {
            throw BrainError.badOutput("no JSON from Claude Code")
        }
        if ProcessInfo.processInfo.environment["MJ_CLAUDE_USAGE"] != nil {
            // Test switch: print what each Claude call costs.
            let u = envelope["usage"] as? [String: Any] ?? [:]
            func n(_ k: String) -> Int { (u[k] as? Int) ?? 0 }
            print("claude usage: input \(n("input_tokens")), cache write \(n("cache_creation_input_tokens")), cache read \(n("cache_read_input_tokens")), output \(n("output_tokens")), turns \(envelope["num_turns"] ?? 0), cost $\(envelope["total_cost_usd"] ?? 0)")
        }
        if envelope["is_error"] as? Bool == true {
            throw BrainError.failed("Claude Code: \((envelope["result"] as? String ?? "unknown error").truncated(to: 300))")
        }
        let decoder = JSONDecoder()
        if let structured = envelope["structured_output"], !(structured is NSNull) {
            let json = try JSONSerialization.data(withJSONObject: structured)
            do {
                return try decoder.decode(T.self, from: json)
            } catch {
                throw BrainError.badOutput(String(describing: error).truncated(to: 200))
            }
        }
        if let text = envelope["result"] as? String, let json = extractJSON(from: text) {
            do {
                return try decoder.decode(T.self, from: json)
            } catch {
                throw BrainError.badOutput(String(describing: error).truncated(to: 200))
            }
        }
        throw BrainError.badOutput("missing structured output")
    }

    static func errorMessage(from data: Data) -> String? {
        lastJSONObject(in: data)?["result"] as? String
    }

    private static func lastJSONObject(in data: Data) -> [String: Any]? {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }
        // Tolerate stray lines before the envelope.
        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.split(separator: "\n").reversed() where line.hasPrefix("{") {
            if let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] {
                return object
            }
        }
        return nil
    }

    /// Pulls a JSON object out of free text, e.g. inside a ```json fence.
    static func extractJSON(from text: String) -> Data? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else {
            return nil
        }
        return Data(text[start...end].utf8)
    }
}
