import Foundation

// "What's slowing this Mac?" Pulse writes a plain-text snapshot of the machine and what's running,
// and Claude Code (the `claude` CLI, already signed in) answers with a short, structured verdict.
// Nothing is sent until you ask.

enum Diagnosis {
    struct Finding: Codable, Sendable, Hashable, Identifiable {
        var severity: String     // high | medium | low | info
        var title: String
        var detail: String
        var pids: [Int32]
        var action: String       // stop | quit | none
        var id: String { title + pids.map(String.init).joined() }
    }

    struct Report: Codable, Sendable {
        var verdict: String
        var findings: [Finding]
    }

    struct Answer: Sendable {
        let report: Report
        let seconds: Double
    }

    enum State {
        case idle
        case running(Date)
        case done(Answer)
        case failed(String)
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    static var executable: String? {
        ["/Users/\(NSUserName())/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func run(context: String) async throws -> Answer {
        guard let exe = executable else { throw Failure(description: "Install Claude Code to diagnose with Claude") }
        let started = Date()
        let args = ["-p", "--model", "sonnet", "--output-format", "json", "--tools", "", "--strict-mcp-config",
                    "--no-session-persistence", "--setting-sources", "", "--disable-slash-commands", "--no-chrome",
                    "--system-prompt", system, "--effort", "low", "--json-schema", schema]
        let data = try await CLI.run(exe, args, input: context)
        let parsed = try JSONSerialization.jsonObject(with: data)
        let events = parsed as? [[String: Any]] ?? (parsed as? [String: Any]).map { [$0] } ?? []
        guard let result = events.last(where: { $0["type"] as? String == "result" }) else {
            throw Failure(description: "Claude didn't answer")
        }
        if result["is_error"] as? Bool == true {
            let message = result["result"] as? String ?? ""
            if message.localizedCaseInsensitiveContains("log") { throw Failure(description: "Sign in to Claude Code first") }
            throw Failure(description: message.isEmpty ? "Claude couldn't read this" : message)
        }
        guard let structured = result["structured_output"] else { throw Failure(description: "Claude didn't answer") }
        let report = try JSONDecoder().decode(Report.self, from: JSONSerialization.data(withJSONObject: structured))
        return Answer(report: report, seconds: Date().timeIntervalSince(started))
    }

    static let system = """
    You are the diagnostician inside Pulse, a quiet Mac menu bar monitor used by a software developer. You get a \
    snapshot of the machine and everything running on it. Say what is actually hurting this Mac right now, and what \
    was left running that nobody needs.

    Look for, in order of what matters:
    - Something saturating CPU, memory pressure or swap, heat, or battery drain. Name it as people know it ("Chrome", \
    "a Rails server in shop"), and say the mechanism in plain words (memory, CPU, swap, heat).
    - Dev leftovers: orphaned interpreters or servers (parent gone), dev servers still holding ports, headless browsers \
    left by test or render runs, watchers nobody is watching. Use the project folder and age to judge.
    - Ports open to the whole network ("exposed") that look like dev servers.

    Rules:
    - Never suggest stopping macOS system processes. Explain them if they are heavy (e.g. Spotlight indexing, \
    WindowServer) and what usually triggers that.
    - MCP servers and tools under Claude Code or an editor that's open are expected; don't flag them unless heavy.
    - Only suggest quitting an app if it's clearly heavy. Busy-but-normal is fine.
    - action: "stop" for your own non-app processes (give the root pids), "quit" for an app (give its pids), \
    "none" for advice only. pids must come from the snapshot.
    - severity: "high" (hurting now), "medium" (wasting resources), "low" (tidy-up), "info" (all good / context).
    - verdict: one calm sentence, at most 12 words. Titles at most 6 words. Details at most 28 words, plain English.
    - 1 to 6 findings, most important first. If all is well, say so; don't invent problems.
    """

    static let schema = """
    {"type":"object","additionalProperties":false,"required":["verdict","findings"],"properties":{
      "verdict":{"type":"string"},
      "findings":{"type":"array","maxItems":6,"items":{"type":"object","additionalProperties":false,
        "required":["severity","title","detail","pids","action"],"properties":{
          "severity":{"type":"string","enum":["high","medium","low","info"]},
          "title":{"type":"string"},"detail":{"type":"string"},
          "pids":{"type":"array","items":{"type":"integer"}},
          "action":{"type":"string","enum":["stop","quit","none"]}}}}}}
    """

    // MARK: Snapshot as text

    static func context(machine: String, snapshot s: ProcSnapshot) -> String {
        func mb(_ b: UInt64) -> String { b >= 1 << 30 ? String(format: "%.1f GB", Double(b) / 1_073_741_824) : "\(b >> 20) MB" }
        func age(_ t: TimeInterval) -> String { Fmt.duration(t) }
        func line(_ p: Proc) -> String {
            let kind = p.appName.map { "app \($0)" } ?? (p.isSystem ? "system" : "tool")
            let parent = s.procs[p.ppid].map { $0.name } ?? (p.ppid <= 1 ? "launchd" : "?")
            return "pid \(p.pid) · \(p.name) · \(kind) · \(String(format: "%.0f", p.cpu))% CPU · \(mb(p.memory)) · up \(age(p.age)) · parent \(parent)"
        }
        func stray(_ x: Stray) -> String {
            let ports = x.ports.map { ":\($0.number)\($0.exposed ? " (exposed)" : "")" }.joined(separator: " ")
            return "pid \(x.root.pid) · \(x.root.name) · project \(x.project ?? "?") · under \(x.host ?? "nothing (orphaned)") · "
                + "\(x.pids.count) procs · \(String(format: "%.0f", x.cpu))% CPU · \(mb(x.memory)) · up \(age(x.root.age))"
                + (ports.isEmpty ? "" : " · ports \(ports)") + "\n    $ " + redact(String(x.command.prefix(160)))
        }

        let all = Array(s.procs.values)
        var out = "# Machine\n\(machine)\n\n"
        out += "# Top processes by CPU (% of one core)\n"
        out += all.sorted { $0.cpu > $1.cpu }.prefix(12).map(line).joined(separator: "\n")
        out += "\n\n# Heaviest by memory, grouped by app\n"
        out += s.heaviest.sorted { $0.memory > $1.memory }.prefix(12).map { h in
            "\(h.name)\(h.system ? " (system)" : "") · \(h.pids.count) procs · \(mb(h.memory)) · \(String(format: "%.0f", h.cpu))% CPU · pids \(h.pids.prefix(4).map(String.init).joined(separator: ","))"
        }.joined(separator: "\n")
        out += "\n\n# Dev processes that stand out (orphaned, holding ports, or heavy)\n"
        out += s.strays.isEmpty ? "none" : s.strays.map(stray).joined(separator: "\n")
        out += "\n\n# Other dev processes (quiet)\n"
        out += s.devQuiet.isEmpty ? "none" : s.devQuiet.prefix(20).map(stray).joined(separator: "\n")
        out += "\n\n# Other listening ports\n"
        out += s.listeners.isEmpty ? "none" : s.listeners.map {
            ":\($0.port.number)\($0.port.exposed ? " (exposed)" : "") · \($0.owner) · pid \($0.pid)\($0.note.map { " · \($0)" } ?? "")"
        }.joined(separator: "\n")
        return out
    }

    /// Strips things that look like secrets from command lines before they leave the machine.
    static func redact(_ s: String) -> String {
        var r = s.replacingOccurrences(of: #"(?i)((?:api[_-]?)?key|token|secret|passw(?:or)?d|auth)([=: ])\S+"#,
                                       with: "$1$2…", options: .regularExpression)
        r = r.replacingOccurrences(of: #"[A-Za-z0-9_\-]{32,}"#, with: "…", options: .regularExpression)
        return r
    }

    enum CLI {
        static func run(_ exe: String, _ args: [String], input: String) async throws -> Data {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: exe)
            process.arguments = args
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            let stdin = Pipe(), stdout = Pipe()
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            return try await withTaskCancellationHandler {
                try process.run()
                let reply = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }
                let watchdog = Task.detached {
                    try await Task.sleep(for: .seconds(120))
                    if process.isRunning { process.terminate() }
                }
                stdin.fileHandleForWriting.write(Data(input.utf8))
                try? stdin.fileHandleForWriting.close()
                let data = await reply.value
                process.waitUntilExit()
                watchdog.cancel()
                if Task.isCancelled { throw CancellationError() }
                if process.terminationReason == .uncaughtSignal { throw Failure(description: "Claude took too long") }
                return data
            } onCancel: {
                if process.isRunning { process.terminate() }
            }
        }
    }
}

extension Monitor {
    /// The machine's state in a few lines, for the diagnosis.
    var diagnosticSummary: String {
        let mem = memory
        func gb(_ b: UInt64) -> String { String(format: "%.1f GB", Double(b) / 1_073_741_824) }
        var lines = [
            "\(chip), \(cores.count) CPU cores (\(efficiencyCores) efficiency), \(gb(mem.total)) RAM, macOS \(os.majorVersion).\(os.minorVersion), up \(Fmt.duration(uptime))",
            "Health: \(health.level.title), \(health.reason)",
            "CPU \(Fmt.percent(cpu))% now, load average \(load.map { String(format: "%.1f", $0) }.joined(separator: " / "))",
            "Memory \(gb(mem.used)) used of \(gb(mem.total)), compressed \(gb(mem.compressed)), swap \(gb(mem.swap)), pressure level \(mem.pressure)",
            "Disk \(Fmt.percent(diskFraction))% full",
            "Thermal state: \(["nominal", "fair", "serious", "critical"][min(thermal.rawValue, 3)])",
        ]
        if let g = gpu { lines.append("GPU \(Fmt.percent(g.utilization))% busy") }
        if let b = battery { lines.append("Battery \(b.percent)%\(b.charging ? ", charging" : b.onAC ? ", on power" : ", on battery")") }
        return lines.joined(separator: "\n")
    }
}
