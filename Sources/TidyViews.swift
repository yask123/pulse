import SwiftUI

// The Running and Apps screens. Same instruments as Vitals: cards on glass, small caps labels,
// monospaced figures, one accent, status colours only where something needs you.

// MARK: - Shared pieces

struct TabBar: View {
    @Binding var tab: Tab
    var badge: Bool
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Tab.allCases, id: \.self) { t in
                let on = t == tab
                Button { withAnimation(.snappy(duration: 0.28)) { tab = t } } label: {
                    HStack(spacing: 5) {
                        Text(t.rawValue)
                        if t == .running && badge {
                            Circle().fill(Health.elevated.color).frame(width: 5, height: 5)
                        }
                    }
                    .font(.system(size: 11, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? .primary : .secondary)
                    .frame(maxWidth: .infinity).frame(height: 24)
                    .background {
                        if on {
                            Capsule().fill(Color.primary.opacity(0.09))
                                .overlay(Capsule().strokeBorder(Style.hairline, lineWidth: 0.5))
                                .matchedGeometryEffect(id: "tab", in: ns)
                        }
                    }
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Style.well, in: .capsule)
    }
}

/// First click arms it; a second click within three seconds does it.
struct ConfirmButton: View {
    var title: String
    var confirm: String
    var busy = false
    var wide = false
    var action: () -> Void
    @State private var armed = false

    var body: some View {
        Button {
            if armed { armed = false; action() } else {
                withAnimation(.snappy(duration: 0.2)) { armed = true }
                Task { try? await Task.sleep(for: .seconds(3)); withAnimation(.snappy(duration: 0.2)) { armed = false } }
            }
        } label: {
            Group {
                if busy { ProgressView().controlSize(.mini) } else { Text(armed ? confirm : title) }
            }
            .font(.system(size: wide ? 12 : 10.5, weight: .semibold))
            .foregroundStyle(armed ? Color.white : Color.primary.opacity(0.8))
            .padding(.horizontal, wide ? 14 : 9).frame(height: wide ? 30 : 20)
            .frame(maxWidth: wide ? .infinity : nil)
            .background(armed ? Health.degraded.color : Color.primary.opacity(0.08), in: .capsule)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(busy)
        .fixedSize(horizontal: !wide, vertical: true)
    }
}

private struct PortChip: View {
    var port: Port
    var body: some View {
        HStack(spacing: 3) {
            Text(":\(String(port.number))")
            if port.exposed { Image(systemName: "wifi").font(.system(size: 7.5, weight: .bold)) }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(port.exposed ? Health.elevated.color : Style.accent)
        .padding(.horizontal, 5).padding(.vertical, 1.5)
        .background((port.exposed ? Health.elevated.color : Style.accent).opacity(0.12), in: .rect(cornerRadius: 4))
        .explains(port.exposed
                  ? "Port \(port.number) is open to your whole network: anyone on this Wi-Fi can reach it. Dev servers usually only need localhost."
                  : "Port \(port.number), reachable only from this Mac (localhost).", id: "port-\(port.number)")
    }
}

private func ago(_ app: AppItem) -> String {
    guard let d = app.lastUsed else { return "no sign of use" }
    let verb = app.opened ? "opened" : "used"
    let days = Int(Date().timeIntervalSince(d) / 86400)
    switch days {
    case ..<1: return "\(verb) today"
    case 1: return "\(verb) yesterday"
    case ..<30: return "\(verb) \(days) days ago"
    case ..<60: return "\(verb) a month ago"
    case ..<365: return "\(verb) \(days / 30) months ago"
    case ..<730: return "\(verb) a year ago"
    default: return "\(verb) \(days / 365) years ago"
    }
}

/// Whole megabytes, one decimal for gigabytes, so figures keep a steady width.
private func size(_ b: UInt64) -> String { Fmt.bytes(b, binary: true, digits: b >= 1 << 30 ? 1 : 0) }

// MARK: - Running

struct RunningView: View {
    @Environment(ProcessWatch.self) private var w
    @Environment(Monitor.self) private var m
    @State private var byCPU = false

    var body: some View {
        CappedScroll(maxHeight: 720) {
            VStack(alignment: .leading, spacing: 10) {
                Card { diagnose }
                Card { strays }
                if !w.snapshot.listeners.isEmpty { Card { ports } }
                Card { heaviest }
            }
        }
    }

    // MARK: Diagnose

    @ViewBuilder private var diagnose: some View {
        HStack {
            Style.label("Diagnose").explains("Pulse sends a text snapshot of what's running (names, CPU, memory, ports, trimmed command lines with secrets stripped) to Claude through your Claude Code sign-in. Only when you ask.")
            Spacer()
            switch w.diagnosis {
            case .running(let t):
                TimelineView(.periodic(from: t, by: 1)) { ctx in
                    Text("\(Int(ctx.date.timeIntervalSince(t)))s").font(Style.mono).foregroundStyle(.secondary).monospacedDigit()
                }
            case .done(let a):
                Button { w.diagnose(machine: m.diagnosticSummary) } label: {
                    Text("\(Int(a.seconds.rounded()))s · again").font(Style.mono).foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            default:
                Text("Claude · Sonnet").font(Style.mono).foregroundStyle(.tertiary)
            }
        }
        switch w.diagnosis {
        case .idle:
            HStack(alignment: .center, spacing: 10) {
                Text("What's slowing this Mac, and what was left running?")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                askButton("Ask")
            }
        case .running:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Reading \(w.snapshot.procs.count) processes…").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { w.cancelDiagnosis() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .done(let a):
            VStack(alignment: .leading, spacing: 10) {
                Text(a.report.verdict).font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(a.report.findings) { f in finding(f) }
            }
        case .failed(let why):
            HStack(spacing: 10) {
                Text(why).font(.system(size: 11.5)).foregroundStyle(Health.degraded.color)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                askButton("Retry")
            }
        }
    }

    private func askButton(_ title: String) -> some View {
        Button { w.diagnose(machine: m.diagnosticSummary) } label: {
            Label(title, systemImage: "sparkle")
                .font(.system(size: 11.5, weight: .semibold))
                .labelStyle(TightLabel())
                .foregroundStyle(Style.accent)
                .padding(.horizontal, 11).frame(height: 24)
                .background(Style.accent.opacity(0.13), in: .capsule)
                .overlay(Capsule().strokeBorder(Style.accent.opacity(0.25), lineWidth: 0.5))
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private func finding(_ f: Diagnosis.Finding) -> some View {
        let tint: Color = switch f.severity {
        case "high": Health.degraded.color
        case "medium": Health.elevated.color
        case "low": Style.accent
        default: Color.secondary
        }
        let live = f.pids.filter { w.snapshot.procs[$0] != nil }
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(tint).frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 2) {
                Text(f.title).font(.system(size: 12, weight: .medium))
                Text(f.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if f.action != "none" {
                if live.isEmpty {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Health.nominal.color)
                } else {
                    let stuck = f.action == "quit" && w.app(of: live).flatMap(\.appPath).map(w.unresponsive.contains) == true
                    ConfirmButton(title: stuck ? "Force Quit" : f.action == "quit" ? "Quit" : "Stop",
                                  confirm: stuck ? "Force quit?" : f.action == "quit" ? "Quit?" : "Stop?",
                                  busy: !w.stopping.isDisjoint(with: live)) { w.act(on: f) }
                }
            }
        }
    }

    // MARK: Dev processes

    @ViewBuilder private var strays: some View {
        let s = w.snapshot.strays
        HStack {
            Style.label("Dev processes").explains("Interpreters and servers outside any app (Ruby, Python, Node, databases, headless browsers) that are holding a port, using real CPU or memory, or whose parent is gone. Orphaned ones were left behind when a terminal or tool quit.")
            Spacer()
            if !s.isEmpty {
                Text("\(s.count) · \(Fmt.bytes(s.reduce(0) { $0 + $1.memory }, binary: true, digits: 0))")
                    .font(Style.mono).foregroundStyle(.secondary)
            }
        }
        if s.isEmpty {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Health.nominal.color)
                Text("Nothing left running.").foregroundStyle(.secondary)
                if !w.snapshot.devQuiet.isEmpty {
                    Text("\(w.snapshot.devQuiet.count) quiet helpers").foregroundStyle(.tertiary)
                        .explains("Dev processes that look intentional: MCP servers and tools under Claude Code or an editor, idle and holding no ports.\n" +
                                  w.snapshot.devQuiet.prefix(8).map { "\($0.root.name) · \($0.host ?? "orphaned")" }.joined(separator: "\n"))
                }
            }
            .font(.system(size: 12))
        } else {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(s.prefix(8)) { stray($0) }
            }
            let orphans = w.orphans
            if orphans.count > 1 {
                HStack {
                    Spacer()
                    ConfirmButton(title: "Stop \(orphans.count) orphaned", confirm: "Stop all \(orphans.count)?",
                                  busy: !w.stopping.isDisjoint(with: orphans.flatMap(\.pids))) {
                        w.stop(orphans.flatMap(\.pids))
                    }
                }
            }
        }
    }

    private func stray(_ x: Stray) -> some View {
        let state = x.orphaned ? "orphaned" : "under \(x.host ?? "")"
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(x.orphaned ? Health.elevated.color : Style.accent.opacity(0.6))
                .frame(width: 6, height: 6).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 2.5) {
                HStack(spacing: 5) {
                    Text(x.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    ForEach(x.ports.prefix(3), id: \.self) { PortChip(port: $0) }
                }
                Text("\(state) · \(Fmt.duration(x.root.age)) · \(size(x.memory))\(x.cpu >= 10 ? " · \(Int(x.cpu.rounded()))% CPU" : "")")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(x.orphaned ? AnyShapeStyle(Health.elevated.color.opacity(0.9)) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                Text(x.command).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .explains("PID \(x.root.pid)\(x.pids.count > 1 ? " and \(x.pids.count - 1) children" : "") · \(String(format: "%.0f", x.cpu))% CPU\n"
                      + (x.cwd.map { "in \(ProcScan.tilde($0))\n" } ?? "") + x.command, id: "stray-\(x.root.pid)")
            Spacer(minLength: 0)
            ConfirmButton(title: "Stop", confirm: "Stop?", busy: w.stopping.contains(x.root.pid)) { w.stop(x.pids) }
        }
    }

    // MARK: Ports

    @ViewBuilder private var ports: some View {
        let l = w.snapshot.listeners
        HStack {
            Style.label("Ports").explains("Apps listening for connections. Dev servers are listed above. A Wi-Fi mark means the port is open to your whole network, not just this Mac.")
            Spacer()
            Text("\(l.count) open").font(Style.mono).foregroundStyle(.secondary)
        }
        VStack(alignment: .leading, spacing: 6) {
            ForEach(l.prefix(10)) { x in
                HStack(spacing: 8) {
                    PortChip(port: x.port).frame(width: 62, alignment: .leading)
                    Text(x.owner).font(.system(size: 11.5)).lineLimit(1)
                    if let n = x.note { Text(n).font(.system(size: 11)).foregroundStyle(.tertiary).lineLimit(1) }
                    Spacer(minLength: 0)
                    if x.stoppable {
                        ConfirmButton(title: "Stop", confirm: "Stop?", busy: w.stopping.contains(x.pid)) { w.stop([x.pid]) }
                    }
                }
            }
        }
    }

    // MARK: Heaviest

    @ViewBuilder private var heaviest: some View {
        let top = w.snapshot.heaviest.sorted { byCPU ? $0.cpu > $1.cpu : $0.memory > $1.memory }.prefix(6)
        HStack {
            Style.label("Heaviest").explains("What's using the most, with each app's helper processes added together. Memory is what macOS counts against the app (its footprint).")
            Spacer()
            Button { withAnimation(.snappy(duration: 0.25)) { byCPU.toggle() } } label: {
                HStack(spacing: 3) {
                    Text(byCPU ? "by CPU" : "by memory")
                    Image(systemName: "arrow.up.arrow.down").font(.system(size: 8, weight: .semibold))
                }
                .font(Style.mono).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        VStack(alignment: .leading, spacing: 7) {
            ForEach(top) { h in
                HStack(spacing: 8) {
                    Group {
                        if let p = h.appPath { Image(nsImage: AppIcon.bitmap(p)).resizable() }
                        else { Image(systemName: h.system ? "gearshape" : "terminal").font(.system(size: 10)).foregroundStyle(.secondary) }
                    }
                    .frame(width: 16, height: 16)
                    Text(h.name).font(.system(size: 11.5)).lineLimit(1)
                    if h.pids.count > 1 { Text("\(h.pids.count)").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.tertiary) }
                    Spacer(minLength: 0)
                    Text(size(h.memory)).font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(byCPU ? .secondary : .primary).frame(width: 58, alignment: .trailing)
                    Text("\(Int(h.cpu.rounded()))%").font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(byCPU ? .primary : .secondary).frame(width: 38, alignment: .trailing)
                    if !h.system {
                        let stuck = h.appPath.map(w.unresponsive.contains) == true
                        ConfirmButton(title: stuck ? "Force Quit" : "Quit", confirm: stuck ? "Force quit?" : "Quit?",
                                      busy: !w.stopping.isDisjoint(with: h.pids)) { w.quit(h) }
                    } else {
                        Color.clear.frame(width: 37, height: 1)
                    }
                }
            }
        }
    }
}

// MARK: - Apps

struct AppsView: View {
    @Environment(AppCatalog.self) private var c

    var body: some View {
        Group {
            if let app = c.selected { Card { detail(app) } } else { Card { list } }
        }
        .onAppear { c.appear() }
    }

    // MARK: List

    @ViewBuilder private var list: some View {
        @Bindable var c = c
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
#if SNAPSHOT
            Text("Search apps").font(.system(size: 12)).foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .leading)
#else
            TextField("Search apps", text: $c.query).textFieldStyle(.plain).font(.system(size: 12))
#endif
        }
        .padding(.horizontal, 9).frame(height: 26)
        .background(Color.primary.opacity(0.06), in: .rect(cornerRadius: 8))

        if case .removed(let name, let bytes, let kept) = c.phase {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Health.nominal.color)
                    Text("\(name) is in the Trash · \(Fmt.bytes(bytes, digits: 0))").font(.system(size: 11.5))
                    Spacer()
                    Button("Open Trash") { NSWorkspace.shared.open(URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Style.accent)
                }
                if !kept.isEmpty {
                    Text("macOS protects \(kept.count == 1 ? "its data folder" : "\(kept.count) of its data folders"), so it stayed. Drag \(kept.count == 1 ? "it" : "them") to the Trash yourself, or give Pulse Full Disk Access and uninstall from here next time.")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(kept) }
                        Button("Full Disk Access") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                        }
                    }
                    .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Style.accent)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .background(Health.nominal.color.opacity(0.1), in: .rect(cornerRadius: 8))
        }

        HStack {
            Text("\(c.apps.count) apps · \(Fmt.bytes(c.totalSize, digits: 0))").font(Style.mono).foregroundStyle(.secondary)
            Spacer()
            HStack(spacing: 2) {
                ForEach(AppCatalog.Sort.allCases, id: \.self) { s in
                    Button { withAnimation(.snappy(duration: 0.25)) { c.sort = s } } label: {
                        Text(s.rawValue).font(.system(size: 10, weight: c.sort == s ? .semibold : .regular))
                            .foregroundStyle(c.sort == s ? .primary : .secondary)
                            .padding(.horizontal, 7).frame(height: 18)
                            .background(c.sort == s ? Color.primary.opacity(0.08) : .clear, in: .capsule)
                    }.buttonStyle(.plain)
                }
            }
        }

        if c.apps.isEmpty {
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }.frame(height: 120)
        } else {
            rows
        }
    }

    private var rows: some View {
#if SNAPSHOT
        VStack(spacing: 0) { ForEach(c.visible.prefix(12)) { row($0) } }
#else
        ScrollView {
            LazyVStack(spacing: 0) { ForEach(c.visible) { row($0) } }
        }
        .scrollIndicators(.never)
        .frame(height: 430)
        .mask(LinearGradient(stops: [.init(color: .black, location: 0.92), .init(color: .clear, location: 1)], startPoint: .top, endPoint: .bottom))
#endif
    }

    private func row(_ app: AppItem) -> some View {
        let stale = app.lastUsed.map { Date().timeIntervalSince($0) > 180 * 86400 } ?? true
        return Button { withAnimation(.snappy(duration: 0.25)) { c.open(app) } } label: {
            HStack(spacing: 9) {
                Image(nsImage: c.icon(app)).resizable().frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(app.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                        if c.running.contains(app.url) {
                            Circle().fill(Style.accent).frame(width: 5, height: 5)
                        }
                    }
                    Text(ago(app)).font(.system(size: 10.5))
                        .foregroundStyle(stale ? AnyShapeStyle(Health.elevated.color.opacity(0.85)) : AnyShapeStyle(.secondary))
                }
                Spacer(minLength: 4)
                Text(c.sizes[app.url].map { Fmt.bytes($0, digits: $0 >= 1_000_000_000 ? 1 : 0) } ?? "…")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6).padding(.vertical, 5)
            .contentShape(.rect)
        }
        .buttonStyle(RowButtonStyle())
    }

    // MARK: Detail

    @ViewBuilder private func detail(_ app: AppItem) -> some View {
        Button { withAnimation(.snappy(duration: 0.25)) { c.close() } } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
                Text("Apps")
            }
            .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)

        HStack(spacing: 12) {
            Image(nsImage: c.icon(app)).resizable().frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name).font(.system(size: 17, weight: .semibold))
                Text([app.version, app.bundleID].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    if c.running.contains(app.url) {
                        Text("running").foregroundStyle(Style.accent)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text(ago(app)).foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }
        }

        VStack(alignment: .leading, spacing: 0) {
            item(icon: "app", label: "Application", name: app.url.lastPathComponent, size: c.sizes[app.url], on: .constant(true), locked: true)
            ForEach(c.leftovers) { l in
                @Bindable var c = c
                item(icon: symbol(l.kind), label: l.kind, name: l.url.lastPathComponent, size: l.size,
                     on: Binding(get: { !c.excluded.contains(l.url) },
                                 set: { on in if on { c.excluded.remove(l.url) } else { c.excluded.insert(l.url) } }),
                     guess: !l.exact)
            }
        }
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 9))

        switch c.phase {
        case .failed(let why):
            Text(why).font(.system(size: 11)).foregroundStyle(Health.degraded.color)
        default:
            EmptyView()
        }

        HStack {
            Text("\(c.removal.count) \(c.removal.count == 1 ? "item" : "items")").foregroundStyle(.secondary)
            Spacer()
            Text("frees \(Fmt.bytes(c.removalBytes, digits: 0))").foregroundStyle(.primary)
        }
        .font(Style.mono)

        ConfirmButton(title: "Move to Trash", confirm: c.running.contains(app.url) ? "Quit \(app.name) and move to Trash" : "Move \(c.removal.count) items to Trash",
                      busy: c.phase == .removing, wide: true) { c.uninstall() }
        Text("Everything goes to the Trash, so you can put it back until you empty it.")
            .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
    }

    private func item(icon: String, label: String, name: String, size: UInt64?, on: Binding<Bool>, locked: Bool = false, guess: Bool = false) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: on).toggleStyle(.checkbox).labelsHidden().controlSize(.small).disabled(locked)
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(label + (guess ? " · matched by name" : "")).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.tertiary)
                Text(name).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(on.wrappedValue ? .primary : .secondary)
            }
            Spacer(minLength: 4)
            Text(size.map { Fmt.bytes($0, digits: 0) } ?? "—").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    private func symbol(_ kind: String) -> String {
        switch kind {
        case "Cache": "internaldrive"
        case "Preferences": "slider.horizontal.3"
        case "Container", "Shared container": "shippingbox"
        case "Launch agent": "power"
        case "Logs": "doc.text"
        case "Web storage", "Web data", "Cookies": "globe"
        case "Window state": "macwindow"
        default: "folder"
        }
    }
}

/// Grows with its content up to `maxHeight`, then scrolls, so the panel never runs off a laptop screen.
struct CappedScroll<Content: View>: View {
    var maxHeight: CGFloat
    @ViewBuilder var content: Content
    @State private var height: CGFloat = 0

    var body: some View {
#if SNAPSHOT
        content
#else
        ScrollView {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(max(height, 1), maxHeight))
        .mask {
            VStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: height > maxHeight ? 24 : 0)
            }
        }
#endif
    }
}

private struct RowButtonStyle: ButtonStyle {
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(Color.primary.opacity(configuration.isPressed ? 0.09 : hover ? 0.05 : 0), in: .rect(cornerRadius: 8))
            .onHover { hover = $0 }
    }
}
