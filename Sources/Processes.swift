import AppKit
import Darwin
import Observation

// What's running, what's listening, and what got left behind.
//
// `ps` (setuid) sees every process with its CPU share; libproc adds what only works for your own
// processes: real memory footprint, listening sockets, working directory, and arguments.

struct Port: Sendable, Hashable {
    let number: UInt16
    /// Bound to every interface, so other machines on the network can reach it.
    let exposed: Bool
}

struct Proc: Sendable, Identifiable {
    let pid: Int32
    let ppid: Int32
    let uid: UInt32
    let path: String
    let cpu: Double          // percent of one core, decaying average
    var memory: UInt64       // footprint for your own processes, resident size for others
    let age: TimeInterval
    var ports: [Port] = []
    var id: Int32 { pid }

    var name: String { (path as NSString).lastPathComponent }
    var isSystem: Bool {
        !path.hasPrefix("/") || ["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"].contains { path.hasPrefix($0) }
            && !path.hasPrefix("/usr/local/")
    }
    /// The outermost .app bundle this executable lives in.
    /// Interpreters like Python run from an .app tucked inside a framework; those aren't apps.
    var appPath: String? {
        guard let r = path.range(of: ".app/") else { return nil }
        let bundle = String(path[..<r.lowerBound])
        return bundle.contains(".framework/") ? nil : bundle + ".app"
    }
    var appName: String? { appPath.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } }

    /// Interpreters, servers and tools that dev work leaves running.
    var runtime: String? {
        guard appPath == nil, !isSystem else { return nil }
        let n = name.lowercased()
        return ProcScan.runtimes.first { r in
            n == r || (n.hasPrefix(r) && n.dropFirst(r.count).first.map { $0.isNumber || $0 == "." || $0 == "-" } == true)
        }
    }
}

/// A dev process and everything it spawned, shown as one row.
struct Stray: Sendable, Identifiable {
    let root: Proc
    let pids: [Int32]
    let memory: UInt64
    let cpu: Double
    let ports: [Port]
    let project: String?
    let command: String
    let cwd: String?
    /// Who it's running under ("Terminal", "Claude Code", "brew services"), or nil when its parent is gone.
    let host: String?
    var id: Int32 { root.pid }
    var orphaned: Bool { host == nil }
    var title: String { project ?? root.name }
}

struct Listener: Sendable, Identifiable {
    let port: Port
    let pid: Int32
    let owner: String
    let note: String?
    let stoppable: Bool
    var id: String { "\(port.number)-\(pid)" }
}

struct Heavy: Sendable, Identifiable {
    let name: String
    let appPath: String?
    let pids: [Int32]
    let memory: UInt64
    let cpu: Double
    let system: Bool
    var id: String { appPath ?? name }
}

struct ProcSnapshot: Sendable {
    var procs: [Int32: Proc] = [:]
    var strays: [Stray] = []
    var devQuiet: [Stray] = []      // dev processes that look intentional (MCP servers, idle tools)
    var listeners: [Listener] = []  // non-dev listening ports
    var heaviest: [Heavy] = []
    var taken = Date.distantPast
}

enum ProcScan {
    static let runtimes = [
        "ruby", "python", "node", "bun", "deno", "java", "php", "php-fpm", "perl", "go", "dotnet", "elixir", "beam.smp",
        "rails", "puma", "unicorn", "sidekiq", "thin", "falcon", "uvicorn", "gunicorn", "hypercorn", "celery", "flask", "jupyter",
        "postgres", "redis-server", "mysqld", "mongod", "memcached", "elasticsearch", "nginx", "caddy", "httpd",
        "chrome-headless-shell", "chromium", "headless_shell", "esbuild", "vite", "next-server", "webpack", "turbo",
        "ngrok", "cloudflared", "hugo", "jekyll", "gradle", "ollama",
    ]

    static let knownPorts: [UInt16: String] = [
        5000: "AirPlay Receiver", 7000: "AirPlay Receiver", 9222: "Chrome remote debugging", 9229: "Node inspector",
        5037: "Android Debug Bridge", 5432: "PostgreSQL", 6379: "Redis", 3306: "MySQL", 27017: "MongoDB",
        11434: "Ollama", 5173: "Vite", 3000: "dev server", 8000: "dev server", 8080: "dev server", 4000: "dev server",
    ]

    static func scan() -> ProcSnapshot {
        let me = getuid()
        var procs: [Int32: Proc] = [:]
        for var p in ps() {
            if p.uid == me {
                if let fp = footprint(p.pid) { p.memory = fp }
                p.ports = listeningPorts(p.pid)
            }
            procs[p.pid] = p
        }

        // Dev processes, gathered under their topmost dev ancestor.
        let dev = procs.values.filter { $0.uid == me && $0.runtime != nil }
        func root(of p: Proc) -> Proc {
            var r = p
            while let parent = procs[r.ppid], parent.uid == me, parent.runtime != nil { r = parent }
            return r
        }
        let groups = Dictionary(grouping: dev) { root(of: $0).pid }
        let brew = brewServices()
        var loud: [Stray] = [], quiet: [Stray] = []
        for (rootPID, members) in groups {
            guard let r = procs[rootPID] else { continue }
            let ports = Array(Set(members.flatMap(\.ports))).sorted { $0.number < $1.number }
            let cwd = workingDirectory(rootPID)
            let args = arguments(rootPID)
            let s = Stray(root: r, pids: members.map(\.pid),
                          memory: members.reduce(0) { $0 + $1.memory }, cpu: members.reduce(0) { $0 + $1.cpu },
                          ports: ports, project: project(path: r.path, cwd: cwd, args: args),
                          command: display(args, fallback: r.path), cwd: cwd,
                          host: host(of: r, procs: procs, brew: brew))
            if s.orphaned || !ports.isEmpty || s.cpu > 20 || s.memory > 1_500_000_000 { loud.append(s) } else { quiet.append(s) }
        }
        loud.sort { ($0.orphaned ? 0 : 1, $1.memory) < ($1.orphaned ? 0 : 1, $0.memory) }

        let devPIDs = Set(loud.flatMap(\.pids) + quiet.flatMap(\.pids))
        let listeners = procs.values
            .filter { !$0.ports.isEmpty && !devPIDs.contains($0.pid) }
            .flatMap { p in p.ports.map { port in
                Listener(port: port, pid: p.pid, owner: p.appName ?? p.name,
                         note: note(port.number, owner: p.name),
                         stoppable: !p.isSystem && p.appPath == nil)
            } }
            .sorted { $0.port.number < $1.port.number }

        let byApp = Dictionary(grouping: procs.values) { $0.appPath ?? $0.name }
        let heaviest = byApp.map { key, ps in
            Heavy(name: ps[0].appName ?? ps[0].name, appPath: ps[0].appPath, pids: ps.map(\.pid),
                  memory: ps.reduce(0) { $0 + $1.memory }, cpu: ps.reduce(0) { $0 + $1.cpu },
                  system: ps.allSatisfy { $0.uid != me || ($0.isSystem && $0.appPath == nil) })
        }

        return ProcSnapshot(procs: procs, strays: loud, devQuiet: quiet, listeners: listeners, heaviest: heaviest, taken: .now)
    }

    // MARK: Sources

    private static func ps() -> [Proc] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axww", "-o", "pid=,ppid=,uid=,%cpu=,rss=,etime=,comm="]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            var rest = Substring(line)
            var fields: [Substring] = []
            for _ in 0..<6 {
                rest = rest.drop { $0 == " " }
                guard let end = rest.firstIndex(of: " ") else { return nil }
                fields.append(rest[..<end]); rest = rest[end...]
            }
            let path = rest.trimmingCharacters(in: .whitespaces)
            guard let pid = Int32(fields[0]), let ppid = Int32(fields[1]), let uid = UInt32(fields[2]) else { return nil }
            return Proc(pid: pid, ppid: ppid, uid: uid, path: path, cpu: Double(fields[3]) ?? 0,
                        memory: (UInt64(fields[4]) ?? 0) * 1024, age: elapsed(fields[5]))
        }
    }

    /// `[[dd-]hh:]mm:ss` to seconds.
    private static func elapsed(_ s: Substring) -> TimeInterval {
        let dayParts = s.split(separator: "-")
        let days = dayParts.count == 2 ? Double(dayParts[0]) ?? 0 : 0
        let clock = (dayParts.last ?? "").split(separator: ":").compactMap { Double($0) }
        return days * 86400 + clock.reduce(0) { $0 * 60 + $1 }
    }

    private static func footprint(_ pid: Int32) -> UInt64? {
        var ru = rusage_info_v4()
        let r = withUnsafeMutablePointer(to: &ru) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return r == 0 ? ru.ri_phys_footprint : nil
    }

    private static func listeningPorts(_ pid: Int32) -> [Port] {
        let need = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard need > 0 else { return [] }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(need) / stride)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return [] }
        var ports = Set<Port>()
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var si = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &si, size) == size,
                  si.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = si.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            let ini = tcp.tcpsi_ini
            let number = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
            let any = Int32(ini.insi_vflag) & INI_IPV4 != 0
                ? ini.insi_laddr.ina_46.i46a_addr4.s_addr == 0
                : withUnsafeBytes(of: ini.insi_laddr.ina_6) { $0.allSatisfy { $0 == 0 } }
            ports.insert(Port(number: number, exposed: any))
        }
        // One socket per address family: keep a single entry per port, exposed if either is.
        return Dictionary(grouping: ports, by: \.number)
            .map { Port(number: $0.key, exposed: $0.value.contains(where: \.exposed)) }
            .sorted { $0.number < $1.number }
    }

    static func workingDirectory(_ pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        return path.isEmpty ? nil : path
    }

    static func arguments(_ pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
        let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }   // executable path
        while i < size && buf[i] == 0 { i += 1 }   // padding
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    private static func brewServices() -> [String] {
        let dir = NSHomeDirectory() + "/Library/LaunchAgents"
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasPrefix("homebrew.mxcl.") }
            .map { String($0.dropFirst("homebrew.mxcl.".count).dropLast(".plist".count)) }
    }

    // MARK: Naming

    /// Who a process runs under: the nearest app or Claude Code above it, or nil if its parent is gone.
    private static func host(of p: Proc, procs: [Int32: Proc], brew: [String]) -> String? {
        if p.ppid <= 1 {
            if let f = brew.first(where: { p.path.contains("/\($0)") }) { return "brew services (\(f))" }
            return nil
        }
        var cur = procs[p.ppid]
        var top = cur
        for _ in 0..<16 {
            guard let c = cur, c.pid > 1 else { break }
            if let app = c.appName { return app }
            if c.name == "claude" { return "Claude Code" }
            top = c
            cur = procs[c.ppid]
        }
        return top?.name ?? "a shell"
    }

    private static func project(path: String, cwd: String?, args: [String]) -> String? {
        let home = NSHomeDirectory()
        if path.hasPrefix(home), let r = path.range(of: "/node_modules/") {
            return (String(path[..<r.lowerBound]) as NSString).lastPathComponent
        }
        if let cwd, cwd.hasPrefix(home + "/") { return (cwd as NSString).lastPathComponent }
        if let script = args.dropFirst().first(where: { $0.hasPrefix(home + "/") }) {
            return ((script as NSString).deletingLastPathComponent as NSString).lastPathComponent
        }
        return nil
    }

    private static func display(_ args: [String], fallback: String) -> String {
        guard let first = args.first else { return tilde(fallback) }
        return ([(first as NSString).lastPathComponent] + args.dropFirst().map(tilde)).joined(separator: " ")
    }

    static func tilde(_ s: String) -> String { s.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    private static func note(_ port: UInt16, owner: String) -> String? {
        switch (port, owner) {
        case (5000, "ControlCenter"), (7000, "ControlCenter"): "AirPlay Receiver"
        case (5000, _), (7000, _): nil
        default: knownPorts[port]
        }
    }
}

// MARK: - Stopping

enum Reaper {
    /// SIGTERM, a short grace period, then SIGKILL for whatever is left. Only ever your own, non-system processes.
    static func stop(_ pids: [Int32]) async {
        let me = getuid(), own = getpid()
        let targets = pids.filter { pid in
            guard pid > 1, pid != own else { return false }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size && info.pbi_uid == me
        }
        for pid in targets { kill(pid, SIGTERM) }
        for _ in 0..<25 {
            try? await Task.sleep(for: .milliseconds(100))
            if targets.allSatisfy({ kill($0, 0) != 0 }) { return }
        }
        for pid in targets where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
    }

    /// Asks the app to quit, as if from its menu. Returns false if no running app matches.
    /// `force` skips the app's own quit handling (and any unsaved-changes prompt), like Force Quit in the Apple menu.
    @MainActor static func quit(appPath: String, force: Bool = false) -> Bool {
        let apps = running(appPath)
        apps.forEach { _ = force ? $0.forceTerminate() : $0.terminate() }
        return !apps.isEmpty
    }

    @MainActor static func running(_ appPath: String) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == appPath && !$0.isTerminated }
    }
}

// MARK: - Model

@Observable @MainActor
final class ProcessWatch {
    var snapshot = ProcSnapshot()
    var stopping: Set<Int32> = []
    /// Apps that were asked to quit and are still running: stuck, or waiting on a save prompt. Offered Force Quit.
    var unresponsive: Set<String> = []
    var diagnosis: Diagnosis.State = .idle
    /// Scan often while the Running screen is open, rarely otherwise (just enough for the Vitals hint).
    var visible = false { didSet { if visible && !oldValue { refresh() } } }

    private var timer: Timer?
    private var scanning = false
    private var diagnosing: Task<Void, Never>?

    init() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.visible || Date().timeIntervalSince(self.snapshot.taken) > 30 { self.refresh() }
            }
        }
        timer?.tolerance = 0.5
    }

    var orphans: [Stray] { snapshot.strays.filter(\.orphaned) }

    func refresh() {
        guard !scanning else { return }
        scanning = true
        Task {
            snapshot = await Task.detached(priority: .utility) { ProcScan.scan() }.value
            scanning = false
        }
    }

    func stop(_ pids: [Int32]) {
        stopping.formUnion(pids)
        Task {
            await Reaper.stop(pids)
            stopping.subtract(pids)
            refresh()
        }
    }

    func quit(_ heavy: Heavy) {
        guard let path = heavy.appPath else { return stop(heavy.pids) }
        let force = unresponsive.contains(path)
        guard Reaper.quit(appPath: path, force: force) else { return stop(heavy.pids) }
        stopping.formUnion(heavy.pids)
        Task {
            // A stuck app ignores a polite quit. Give it a few seconds, then offer Force Quit rather than
            // killing it unasked, since a busy app may just be showing a save prompt.
            for _ in 0..<(force ? 10 : 25) where !Reaper.running(path).isEmpty {
                try? await Task.sleep(for: .milliseconds(200))
            }
            if Reaper.running(path).isEmpty { unresponsive.remove(path) } else { unresponsive.insert(path) }
            stopping.subtract(heavy.pids)
            refresh()
        }
    }

    /// The app a set of processes belongs to, when they all belong to one.
    func app(of pids: [Int32]) -> Heavy? {
        let apps = Set(pids.compactMap { snapshot.procs[$0]?.appPath })
        guard apps.count == 1, let path = apps.first else { return nil }
        return snapshot.heaviest.first { $0.appPath == path }
    }

    /// Acts on a diagnosis finding: quits the app its processes belong to, or stops them.
    func act(on f: Diagnosis.Finding) {
        if f.action == "quit", let h = app(of: f.pids) {
            quit(h)
        } else {
            // Include each process's dev descendants so a server's workers go with it.
            let groups = snapshot.strays + snapshot.devQuiet
            let pids = f.pids.flatMap { pid in groups.first { $0.pids.contains(pid) }.map { $0.root.pid == pid ? $0.pids : [pid] } ?? [pid] }
            stop(Array(Set(pids)))
        }
    }

    func diagnose(machine: String) {
        diagnosing?.cancel()
        diagnosis = .running(Date())
        diagnosing = Task {
            do {
                // Always read a fresh scan, so the answer matches what's on screen.
                snapshot = await Task.detached(priority: .userInitiated) { ProcScan.scan() }.value
                let context = Diagnosis.context(machine: machine, snapshot: snapshot)
                let answer = try await Diagnosis.run(context: context)
                diagnosis = .done(answer)
            } catch is CancellationError {
                diagnosis = .idle
            } catch {
                diagnosis = .failed(String(describing: error))
            }
        }
    }

    func cancelDiagnosis() {
        diagnosing?.cancel()
        diagnosis = .idle
    }
}
