import ServiceManagement
import SwiftUI

#if !SNAPSHOT
@main
#endif
struct PulseApp: App {
    @State private var monitor = Monitor()

    var body: some Scene {
        MenuBarExtra {
            Panel().environment(monitor)
        } label: {
            Image(nsImage: monitor.glyph)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Palette & type

private enum Style {
    static let accent = Color(nsColor: .adaptive(dark: (0.42, 0.80, 0.95), light: (0.05, 0.52, 0.78)))
    static let hairline = Color.primary.opacity(0.08)
    static let well = Color.primary.opacity(0.045)

    static func label(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(.secondary)
    }
    static let mono = Font.system(size: 11, weight: .regular, design: .monospaced)
    static let figure = Font.system(size: 26, weight: .light).monospacedDigit()
}

extension Health {
    /// Status colour, deepened in light mode so it holds contrast on pale glass.
    var color: Color {
        switch self {
        case .nominal: Color(nsColor: .adaptive(dark: (0.30, 0.85, 0.62), light: (0.08, 0.60, 0.38)))
        case .elevated: Color(nsColor: .adaptive(dark: (1.00, 0.72, 0.25), light: (0.85, 0.50, 0.00)))
        case .degraded: Color(nsColor: .adaptive(dark: (1.00, 0.36, 0.36), light: (0.85, 0.18, 0.18)))
        }
    }
}

extension NSColor {
    static func adaptive(dark: (CGFloat, CGFloat, CGFloat), light: (CGFloat, CGFloat, CGFloat)) -> NSColor {
        NSColor(name: nil) { a in
            let c = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        }
    }
}

// MARK: - Panel

struct Panel: View {
    @Environment(Monitor.self) private var m
    @State private var explaining: String?

    init(explaining: String? = nil) { _explaining = State(initialValue: explaining) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Explainable { header }
            Card { cpu }
            Card { graphics }
            Card { memory }
            Card { storage }
            Card { network }
            Explainable { footer }
        }
        .padding(14)
        .frame(width: 348)
        .environment(\.explaining, $explaining)
    }

    // MARK: Header

    private var header: some View {
        let h = m.health
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle().fill(h.level.color).frame(width: 7, height: 7)
                    .shadow(color: h.level.color.opacity(0.8), radius: 4)
                Text(h.level.title.uppercased())
                    .font(.system(size: 10, weight: .bold)).tracking(1.6)
                    .foregroundStyle(h.level.color)
                Text(h.reason).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("up \(Fmt.duration(m.uptime))").font(Style.mono).foregroundStyle(.secondary)
                    .explains("Time since this Mac last restarted")
            }
            .explains("Overall health. Green: all fine. Amber: something is under strain. Red: something needs attention now. The text names the cause.")
            Text(m.host).font(.system(size: 17, weight: .semibold, design: .monospaced))
                .explains("This Mac's network name")
            Text("\(m.chip.replacingOccurrences(of: "Apple ", with: "")) · \(m.cores.count)-core CPU\(m.gpu.map { " · \($0.cores)-core GPU" } ?? "") · \(Fmt.bytes(m.memory.total, binary: true, digits: 0)) · macOS \(m.os.majorVersion).\(m.os.minorVersion)")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4).padding(.top, 2)
    }

    // MARK: CPU

    private var cpu: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Style.label("CPU").explains("Processor: runs apps and the system")
                Spacer()
                Text(demand).font(Style.mono).foregroundStyle(.secondary)
                    .explains("Roughly how many cores' worth of work is running or waiting, and whether it's growing. Near \(m.cores.count) means the CPU is fully booked.\nLoad average (1, 5, 15 min): " + m.load.map { String(format: "%.2f", $0) }.joined(separator: ", "))
            }
            HStack(alignment: .bottom, spacing: 12) {
                Figure(value: Fmt.percent(m.cpu), unit: "%", tint: m.level(cpu: m.cpu))
                    .explains("How busy the CPU is right now, averaged across all cores")
                Sparkline(series: [m.cpuHistory], maxValue: 1)
                    .explains("CPU usage over the last two minutes")
            }
            CoreStrip(cores: m.cores, efficiency: m.efficiencyCores)
            Text("\(m.efficiencyCores) efficiency · \(m.cores.count - m.efficiencyCores) performance")
                .font(Style.mono).foregroundStyle(.tertiary)
                .explains("Efficiency cores handle light background work using little power. Performance cores take heavy work.")
        }
    }

    /// Load average in plain words: roughly how many cores' worth of work is queued, and which way it's heading.
    private var demand: String {
        let now = m.load[0], earlier = m.load[2]
        let trend = now > earlier * 1.15 ? "rising" : now < earlier * 0.85 ? "easing" : "steady"
        return "~\(Int(now.rounded())) of \(m.cores.count) cores busy · \(trend)"
    }

    // MARK: GPU

    @ViewBuilder private var graphics: some View {
        if let g = m.gpu {
            let d = m.gpuDetail
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Style.label("GPU").explains("Graphics processor: draws the screen, video, games, and ML work")
                    Spacer()
                    Text("\(g.model.replacingOccurrences(of: "Apple ", with: "")) · \(g.cores) cores")
                        .font(Style.mono).foregroundStyle(.secondary)
                        .explains("Your graphics chip and how many GPU cores it has")
                }
                HStack(alignment: .bottom, spacing: 12) {
                    Figure(value: Fmt.percent(g.utilization), unit: "%", tint: m.level(cpu: g.utilization))
                        .explains("How busy the GPU is right now")
                    Sparkline(series: [m.gpuHistory], maxValue: 1)
                        .explains("GPU usage over the last two minutes")
                }
                HStack(spacing: 6) {
                    Readout(label: "Clock",
                            value: d?.mhz.map { "\(Int($0))" } ?? "idle", unit: d?.mhz == nil ? "" : "MHz",
                            detail: d?.millivolts.map { "\(Int($0)) mV" } ?? "power-gated",
                            help: "How fast the GPU is running while it works, and the voltage it needs for that speed. It speeds up (and uses more power) only when there's work to do.")
                    Readout(label: "Power",
                            value: d?.watts.map { String(format: $0 < 10 ? "%.2f" : "%.1f", $0) } ?? "—", unit: "W",
                            detail: "peak \(String(format: "%.1f", m.gpuPowerHistory.max() ?? 0)) W",
                            help: "Electricity the GPU is drawing right now, in watts. Peak is the highest in the last two minutes. More watts means more heat and battery drain.")
                    Readout(label: "Temp",
                            value: d?.temp.map { String(format: "%.0f", $0.avg) } ?? "—", unit: "°C",
                            detail: d?.temp.map { String(format: "max %.0f°C", $0.max) } ?? "",
                            help: "Average temperature of the GPU chip, and its hottest spot. Under 80°C is relaxed; Apple Silicon slows itself down only past about 100°C.")
                }
                if !m.gpuStates.isEmpty, let d {
                    DVFSResidency(states: m.gpuStates, residency: d.residency, idle: d.idle)
                }
                Text("\(Fmt.bytes(g.memory, binary: true)) unified memory in use")
                    .font(Style.mono).foregroundStyle(.secondary)
                    .explains("RAM the GPU is using. On Apple Silicon, the CPU and GPU share one pool of memory.")
            }
        }
    }

    // MARK: Memory

    private var memory: some View {
        let mem = m.memory
        let pressure = m.level(memoryPressure: mem.pressure)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Style.label("Memory").explains("RAM: fast working space for apps")
                Spacer()
                HStack(spacing: 4) {
                    Text("pressure").foregroundStyle(.secondary)
                    Text(["normal", "warn", "critical"][pressure.rawValue]).foregroundStyle(pressure == .nominal ? .secondary : pressure.color)
                }.font(Style.mono)
                .explains("How hard macOS is working to find free memory. Normal is fine even when RAM looks full. Warn or critical means apps may slow down.")
            }
            HStack(alignment: .bottom, spacing: 12) {
                Figure(value: Fmt.number(mem.used, binary: true),
                       unit: "/ \(Fmt.bytes(mem.total, binary: true, digits: 0))", tint: pressure)
                    .explains("Memory used by apps and the system (app + wired + compressed), out of your total RAM. File cache isn't counted because it's freed instantly when needed.")
                Sparkline(series: [m.pressureHistory], maxValue: 1)
                    .explains("Memory pressure over the last two minutes. Low and flat is good.")
            }
            Composition(segments: [
                ("app", mem.app, 1.0, "Memory your apps are actively using"),
                ("wired", mem.wired, 0.7, "Memory the system has locked in place; it can't be compressed or freed"),
                ("comp", mem.compressed, 0.45, "Memory macOS has squeezed to make room, instead of writing it to disk"),
                ("cache", mem.cached, 0.2, "Recently used files kept in RAM so they reopen fast. Freed instantly when apps need room."),
            ], total: mem.total)
        }
    }

    // MARK: Disk

    private var storage: some View {
        let lvl = m.level(disk: m.diskFraction)
        return VStack(alignment: .leading, spacing: 9) {
            HStack {
                Style.label("Storage").explains("Your internal SSD")
                Spacer()
                Text("\(Fmt.bytes(m.disk.total - m.disk.used, digits: 0)) free of \(Fmt.bytes(m.disk.total, digits: 1))").font(Style.mono)
                    .foregroundStyle(lvl == .nominal ? .secondary : lvl.color)
            }
            Meter(label: nil, fraction: m.diskFraction,
                  trailing: "\(Fmt.percent(m.diskFraction))%", tint: lvl)
                .explains("How full the startup disk is. Keep at least 10% free so macOS can work comfortably.")
            HStack(spacing: 16) {
                Rate(symbol: "arrow.down.to.line", label: "Reading from the SSD right now", value: m.diskIO.read)
                Rate(symbol: "arrow.up.to.line", label: "Writing to the SSD right now", value: m.diskIO.write)
            }
        }
    }

    // MARK: Network

    private var network: some View {
        VStack(alignment: .leading, spacing: 10) {
            Style.label("Network").explains("Wi-Fi and Ethernet traffic (VPN tunnels excluded so traffic isn't counted twice)")
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Rate(symbol: "arrow.down", label: "Download speed right now", value: m.rx)
                    Rate(symbol: "arrow.up", label: "Upload speed right now", value: m.tx, dim: true)
                }
                .frame(width: 118, alignment: .leading)
                Sparkline(series: [m.rxHistory, m.txHistory], maxValue: nil)
                    .explains("Last two minutes: filled line is download, dashed line is upload")
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Label(thermalText, systemImage: "thermometer.medium")
                .explains("macOS's overall thermal state. 'Warm' or 'throttling' means it's slowing the chip to cool down.")
            if let b = m.battery {
                Label("\(b.percent)%", systemImage: b.charging ? "battery.100percent.bolt" : b.onAC ? "powerplug" : batterySymbol(b.percent))
                    .explains(b.charging ? "Battery, charging" : b.onAC ? "Battery, on power adapter (not charging)" : "Battery, running on battery")
            }
            Spacer()
#if SNAPSHOT
            Image(systemName: "waveform.path.ecg")
            Image(systemName: "ellipsis")
#else
            Button { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) } label: {
                Image(systemName: "waveform.path.ecg")
            }
            .accessibilityHint("Open Activity Monitor")
            Menu {
                Toggle("Open at Login", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { on in try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }))
                Divider()
                Button("Quit Pulse") { NSApp.terminate(nil) }.keyboardShortcut("q")
            } label: { Image(systemName: "ellipsis") }
            .menuIndicator(.hidden).fixedSize()
#endif
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11)).foregroundStyle(.secondary)
        .labelStyle(TightLabel())
        .padding(.horizontal, 4)
    }

    private var thermalText: String {
        switch m.thermal {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "warm"
        case .critical: "throttling"
        @unknown default: "—"
        }
    }

    private func batterySymbol(_ p: Int) -> String {
        p > 87 ? "battery.100percent" : p > 62 ? "battery.75percent" : p > 37 ? "battery.50percent" : p > 12 ? "battery.25percent" : "battery.0percent"
    }
}

// MARK: - Click to explain
//
// Menu bar panels never become the active app, so hover tooltips don't appear. Instead, any element
// marked `.explains(_:)` can be clicked; its explanation opens inline in the enclosing card.

private extension EnvironmentValues {
    @Entry var explaining: Binding<String?> = .constant(nil)
}

private struct ExplanationKey: PreferenceKey {
    static let defaultValue: String? = nil
    static func reduce(value: inout String?, nextValue: () -> String?) { value = value ?? nextValue() }
}

private struct Explains: ViewModifier {
    let id: String
    let text: String
    @Environment(\.explaining) private var selection

    func body(content: Content) -> some View {
        let on = selection.wrappedValue == id
        content
            .contentShape(.rect)
            .background(RoundedRectangle(cornerRadius: 6).fill(Style.accent.opacity(on ? 0.14 : 0)).padding(-3))
            .onTapGesture { withAnimation(.snappy(duration: 0.25)) { selection.wrappedValue = on ? nil : id } }
            .pointerStyle(.link)
            .preference(key: ExplanationKey.self, value: on ? text : nil)
            .accessibilityHint(text)
    }
}

extension View {
    /// Makes the view clickable to reveal `text`. Pass a stable `id` when the text changes with live values.
    func explains(_ text: String, id: String? = nil, line: Int = #line) -> some View {
        modifier(Explains(id: id ?? "line-\(line)", text: text))
    }
}

/// Shows the explanation for whichever element inside it is selected.
private struct Explainable<Content: View>: View {
    @ViewBuilder var content: Content
    @Environment(\.explaining) private var selection
    @State private var text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
            if let text {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "info.circle.fill").font(.system(size: 10)).foregroundStyle(Style.accent)
                    Text(text).font(.system(size: 11)).foregroundStyle(.primary.opacity(0.8))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Style.accent.opacity(0.09), in: .rect(cornerRadius: 9))
                .contentShape(.rect)
                .onTapGesture { withAnimation(.snappy(duration: 0.25)) { selection.wrappedValue = nil } }
                .transition(.opacity.combined(with: .offset(y: -4)))
            }
        }
        .onPreferenceChange(ExplanationKey.self) { value in
            MainActor.assumeIsolated { text = value }
        }
    }
}

// MARK: - Components

private struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        Explainable { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Style.well, in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Style.hairline, lineWidth: 0.5))
    }
}

private struct Figure: View {
    var value: String
    var unit: String
    var tint: Health = .nominal
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value).font(Style.figure).foregroundStyle(tint == .nominal ? .primary : tint.color)
                .contentTransition(.numericText())
            Text(unit).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        .fixedSize()
        .frame(minWidth: 118, alignment: .leading)
    }
}

/// Grafana-style area sparkline. The first series is filled; later ones are drawn as quieter lines.
private struct Sparkline: View {
    var series: [[Double]]
    var maxValue: Double?

    var body: some View {
        Canvas { ctx, size in
            // Quarter gridlines
            for q in 1...3 {
                let y = size.height * CGFloat(q) / 4
                var p = Path(); p.move(to: .init(x: 0, y: y)); p.addLine(to: .init(x: size.width, y: y))
                ctx.stroke(p, with: .color(.primary.opacity(0.07)), style: .init(lineWidth: 0.5, dash: [2, 3]))
            }
            let peak = maxValue ?? max(series.flatMap { $0 }.max() ?? 0, 1) * 1.15
            for (i, values) in series.enumerated().reversed() where values.count > 1 {
                let step = size.width / CGFloat(Monitor.historyLength - 1)
                let x0 = size.width - CGFloat(values.count - 1) * step
                let pts = values.enumerated().map { j, v in
                    CGPoint(x: x0 + CGFloat(j) * step, y: size.height * (1 - CGFloat(min(v / peak, 1))) )
                }
                var line = Path(); line.addLines(pts)
                if i == 0 {
                    var area = line
                    area.addLine(to: .init(x: pts.last!.x, y: size.height))
                    area.addLine(to: .init(x: pts[0].x, y: size.height))
                    area.closeSubpath()
                    ctx.fill(area, with: .linearGradient(
                        Gradient(colors: [Style.accent.opacity(0.35), Style.accent.opacity(0.02)]),
                        startPoint: .zero, endPoint: .init(x: 0, y: size.height)))
                    ctx.stroke(line, with: .color(Style.accent), style: .init(lineWidth: 1.25, lineJoin: .round))
                    if let last = pts.last {
                        ctx.fill(Path(ellipseIn: .init(x: last.x - 2, y: last.y - 2, width: 4, height: 4)), with: .color(Style.accent))
                    }
                } else {
                    ctx.stroke(line, with: .color(.primary.opacity(0.45)), style: .init(lineWidth: 1, lineJoin: .round, dash: [3, 2]))
                }
            }
        }
        .frame(height: 38)
    }
}

/// One slim bar per logical core, efficiency cores set apart.
private struct CoreStrip: View {
    var cores: [Double]
    var efficiency: Int
    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(cores.enumerated()), id: \.offset) { i, v in
                if i == efficiency && efficiency > 0 { Spacer().frame(width: 5) }
                GeometryReader { g in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Color.primary.opacity(0.08))
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(v > 0.9 ? Health.elevated.color : Style.accent.opacity(0.35 + 0.65 * v))
                            .frame(height: max(2, g.size.height * v))
                    }
                }
            }
        }
        .frame(height: 18)
        .animation(.easeOut(duration: 0.35), value: cores)
        .explains("Each bar is one CPU core and how busy it is. The \(efficiency) on the left are efficiency cores; the rest are performance cores.")
    }
}

/// A small instrument tile: label, value, and a quieter secondary line.
private struct Readout: View {
    var label: String
    var value: String
    var unit: String
    var detail: String
    var help: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(.system(size: 8.5, weight: .semibold)).tracking(1.2).foregroundStyle(.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).font(.system(size: 15, weight: .medium, design: .monospaced)).contentTransition(.numericText())
                Text(unit).font(.system(size: 9.5, weight: .medium)).foregroundStyle(.secondary)
            }
            Text(detail).font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 9))
        .explains(help, id: "readout-" + label)
    }
}

/// Stacked bar of what RAM holds, in one hue at falling strengths; the unfilled track is free memory.
private struct Composition: View {
    var segments: [(name: String, bytes: UInt64, strength: Double, help: String)]
    var total: UInt64
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { g in
                HStack(spacing: 1.5) {
                    ForEach(segments, id: \.name) { s in
                        Rectangle().fill(Style.accent.opacity(s.strength))
                            .frame(width: max(0, (g.size.width - 6) * CGFloat(s.bytes) / CGFloat(max(total, 1))))
                    }
                    Spacer(minLength: 0)
                }
                .background(Color.primary.opacity(0.08))
                .clipShape(.capsule)
            }
            .frame(height: 6)
            .animation(.easeOut(duration: 0.35), value: segments.map(\.bytes))
            .explains("What your RAM holds right now; the empty end is unused. Hover the labels below for details.")
            HStack(spacing: 10) {
                ForEach(segments, id: \.name) { s in
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1.5).fill(Style.accent.opacity(s.strength)).frame(width: 6, height: 6)
                        Text(s.name).foregroundStyle(.secondary)
                        Text(String(format: "%.1f", Double(s.bytes) / 1_073_741_824))
                    }
                    .explains("\(s.help) (\(Fmt.bytes(s.bytes, binary: true)))", id: "mem-" + s.name)
                }
            }
            .font(.system(size: 9.5, design: .monospaced))
            .lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

/// Where the GPU spent its active time across its DVFS states, slowest clock on the left.
private struct DVFSResidency: View {
    var states: [GPUTelemetry.State]
    var residency: [Double]
    var idle: Double
    var body: some View {
        let peak = max(residency.max() ?? 0, 0.001)
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("CLOCK RESIDENCY").font(.system(size: 8.5, weight: .semibold)).tracking(1.2).foregroundStyle(.tertiary)
                    .explains("The GPU switches between speed steps. Each bar is one step, slowest on the left; taller means more time spent there. Heavy work shifts the bars right.")
                Spacer()
                Text("gated \(Fmt.percent(idle))%").font(.system(size: 9.5, design: .monospaced)).foregroundStyle(.secondary)
                    .explains("Share of time the GPU was switched off entirely to save power. High is normal when you're not gaming or rendering.")
            }
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(states.indices, id: \.self) { i in
                    let v = i < residency.count ? residency[i] : 0
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(v > 0.005 ? Style.accent.opacity(0.35 + 0.65 * v / peak) : Color.primary.opacity(0.08))
                            .frame(height: max(2, 22 * v / peak))
                    }
                    .frame(maxWidth: .infinity)
                    .explains("\(Int(states[i].mhz)) MHz at \(Int(states[i].millivolts)) mV: \(Fmt.percent(v))% of the GPU's working time was spent at this speed.", id: "dvfs-\(i)")
                }
            }
            .frame(height: 22)
            .animation(.easeOut(duration: 0.35), value: residency)
            HStack {
                Text(String(Int(states.first?.mhz ?? 0)))
                Spacer()
                Text(String(Int(states.map(\.mhz).max() ?? 0)) + " MHz")
            }
            .font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
        }
    }
}

private struct Meter: View {
    var label: String?
    var fraction: Double
    var trailing: String
    var tint: Health = .nominal
    var body: some View {
        HStack(spacing: 10) {
            if let label { Text(label).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(.secondary).frame(width: 28, alignment: .leading) }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(tint == .nominal ? Style.accent : tint.color)
                        .frame(width: max(4, g.size.width * min(fraction, 1)))
                }
            }
            .frame(height: 4)
            Text(trailing).font(Style.mono).foregroundStyle(.secondary).fixedSize()
        }
        .animation(.easeOut(duration: 0.35), value: fraction)
    }
}

private struct Rate: View {
    var symbol: String
    var label: String
    var value: Double
    var dim = false
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold)).foregroundStyle(dim ? AnyShapeStyle(.secondary) : AnyShapeStyle(Style.accent))
            Text(Fmt.rate(value)).font(.system(size: 12, design: .monospaced)).foregroundStyle(dim ? .secondary : .primary)
        }
        .explains(label, id: "rate-" + label)
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) { configuration.icon; configuration.title }
    }
}

// MARK: - Formatting

enum Fmt {
    static func percent(_ f: Double) -> String { String(Int((f * 100).rounded())) }

    static func number(_ b: UInt64, binary: Bool = false) -> String {
        let base = binary ? 1024.0 : 1000.0
        let v = Double(b) / pow(base, 3)
        return String(format: v < 10 ? "%.2f" : "%.1f", v)
    }

    static func bytes(_ b: UInt64, binary: Bool = false, digits: Int = 1) -> String {
        let base = binary ? 1024.0 : 1000.0
        var v = Double(b)
        let units = ["B", "KB", "MB", "GB", "TB"]
        var i = 0
        while v >= base && i < units.count - 1 { v /= base; i += 1 }
        return i == 0 ? "\(b) B" : String(format: "%.\(digits)f %@", v, units[i])
    }

    static func rate(_ bps: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var v = bps, i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        return i == 0 ? String(format: "%.0f %@", v, units[i]) : String(format: v < 10 ? "%.1f %@" : "%.0f %@", v, units[i])
    }

    static func rateValue(_ bps: Double) -> String { String(rate(bps).split(separator: " ")[0]) }
    static func rateUnit(_ bps: Double) -> String { String(rate(bps).split(separator: " ")[1]) }

    static func duration(_ s: TimeInterval) -> String {
        let m = Int(s) / 60, h = m / 60, d = h / 24
        return d > 0 ? "\(d)d \(h % 24)h" : h > 0 ? "\(h)h \(m % 60)m" : "\(m)m"
    }
}
