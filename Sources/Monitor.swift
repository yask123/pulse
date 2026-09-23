import AppKit
import Observation
import SystemConfiguration

enum Health: Int, Comparable {
    case nominal, elevated, degraded
    static func < (a: Health, b: Health) -> Bool { a.rawValue < b.rawValue }

    var title: String { ["Nominal", "Elevated", "Degraded"][rawValue] }
    var nsColor: NSColor {
        switch self {
        case .nominal: NSColor(srgbRed: 0.30, green: 0.85, blue: 0.62, alpha: 1)
        case .elevated: NSColor(srgbRed: 1.00, green: 0.72, blue: 0.25, alpha: 1)
        case .degraded: NSColor(srgbRed: 1.00, green: 0.36, blue: 0.36, alpha: 1)
        }
    }
}

@Observable @MainActor
final class Monitor {
    static let interval: TimeInterval = 2
    static let historyLength = 60   // two minutes

    // Static host facts
    var host = (SCDynamicStoreCopyLocalHostName(nil) as String? ?? ProcessInfo.processInfo.hostName).lowercased()
    let chip = Sampler.sysctlString("machdep.cpu.brand_string")
    let efficiencyCores = Int(Sampler.sysctlInt("hw.perflevel1.logicalcpu"))
    let os = ProcessInfo.processInfo.operatingSystemVersion

    // Live
    var cores: [Double] = []
    var cpuHistory: [Double] = []
    var gpu: Sampler.GPU?
    var gpuHistory: [Double] = []
    var gpuDetail: GPUTelemetry.Reading?
    var gpuPowerHistory: [Double] = []
    let gpuStates: [GPUTelemetry.State]
    var load: [Double] = [0, 0, 0]
    var memory = Sampler.Memory(total: ProcessInfo.processInfo.physicalMemory)
    var pressureHistory: [Double] = []
    var memHistory: [Double] = []
    var disk: (used: UInt64, total: UInt64) = (0, 0)
    var diskIO: (read: Double, write: Double) = (0, 0)
    var rxHistory: [Double] = []
    var txHistory: [Double] = []
    var thermal = ProcessInfo.processInfo.thermalState
    var battery: Sampler.Battery?
    var uptime: TimeInterval = 0

    var cpu: Double { cores.isEmpty ? 0 : cores.reduce(0, +) / Double(cores.count) }
    var memFraction: Double { Double(memory.used) / Double(max(memory.total, 1)) }
    var diskFraction: Double { Double(disk.used) / Double(max(disk.total, 1)) }
    var rx: Double { rxHistory.last ?? 0 }
    var tx: Double { txHistory.last ?? 0 }

    private let sampler = Sampler()
    private let gpuTelemetry = GPUTelemetry()
    private var timer: Timer?

    init() {
        gpuStates = gpuTelemetry.states
        _ = gpuTelemetry.read()
        _ = sampler.memory(); _ = sampler.cores(); _ = sampler.network(); _ = sampler.diskIO()   // prime deltas
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer?.tolerance = 0.3
    }

    private func tick() {
        cores = sampler.cores()
        gpu = Sampler.gpu()
        load = Sampler.loadAverage()
        memory = sampler.memory()
        disk = Sampler.volume()
        diskIO = sampler.diskIO()
        let net = sampler.network()
        thermal = ProcessInfo.processInfo.thermalState
        battery = Sampler.battery()
        uptime = Sampler.uptime()

        push(&cpuHistory, cpu)
        push(&memHistory, memFraction)
        push(&pressureHistory, 1 - memory.headroom)
        push(&rxHistory, net.rx)
        push(&txHistory, net.tx)
        push(&gpuHistory, gpu?.utilization ?? 0)
        gpuDetail = gpuTelemetry.read()
        push(&gpuPowerHistory, gpuDetail?.watts ?? 0)
    }

    private func push(_ a: inout [Double], _ v: Double) {
        a.append(v)
        if a.count > Self.historyLength { a.removeFirst(a.count - Self.historyLength) }
    }

    // MARK: Health

    /// Worst signal wins; the reason names what tripped it.
    var health: (level: Health, reason: String) {
        var worst: (Health, String) = (.nominal, "All systems healthy")
        func flag(_ h: Health, _ why: String) { if h > worst.0 { worst = (h, why) } }

        let recent = cpuHistory.suffix(5)
        let sustained = recent.isEmpty ? 0 : recent.reduce(0, +) / Double(recent.count)
        if sustained > 0.95 { flag(.degraded, "CPU saturated") } else if sustained > 0.80 { flag(.elevated, "CPU running hot") }

        switch memory.pressure {
        case 4...: flag(.degraded, "Critical memory pressure")
        case 2...: flag(.elevated, "Memory pressure")
        default: break
        }
        if memory.swapRate > 20e6 { flag(.elevated, "Swapping to disk") } else if memory.swap > 8 << 30 { flag(.elevated, "Heavy swap use") }

        if diskFraction > 0.95 { flag(.degraded, "Disk nearly full") } else if diskFraction > 0.90 { flag(.elevated, "Disk space low") }

        switch thermal {
        case .critical: flag(.degraded, "Thermal throttling")
        case .serious: flag(.elevated, "Running warm")
        default: break
        }
        if let b = battery, !b.onAC, b.percent <= 10 { flag(.elevated, "Battery low") }
        return worst
    }

    func level(cpu v: Double) -> Health { v > 0.95 ? .degraded : v > 0.80 ? .elevated : .nominal }
    func level(memoryPressure p: Int) -> Health { p >= 4 ? .degraded : p >= 2 ? .elevated : .nominal }
    func level(disk v: Double) -> Health { v > 0.95 ? .degraded : v > 0.90 ? .elevated : .nominal }

    // MARK: Menu bar glyph

    /// Three slim gauges (CPU, memory, disk). Template when healthy; a hot gauge takes its status colour.
    var glyph: NSImage {
        let gauges: [(Double, Health)] = [
            (cpu, level(cpu: cpu)),
            (memFraction, level(memoryPressure: memory.pressure)),
            (diskFraction, level(disk: diskFraction)),
        ]
        let allNominal = gauges.allSatisfy { $0.1 == .nominal }
        let w: CGFloat = 3, gap: CGFloat = 2.5, h: CGFloat = 13
        let size = NSSize(width: 3 * w + 2 * gap + 2, height: 16)
        let img = NSImage(size: size, flipped: false) { _ in
            for (i, (v, lvl)) in gauges.enumerated() {
                let x = 1 + CGFloat(i) * (w + gap)
                let track = NSRect(x: x, y: 1.5, width: w, height: h)
                let base: NSColor = allNominal ? .black : .labelColor
                base.withAlphaComponent(0.28).setFill()
                NSBezierPath(roundedRect: track, xRadius: w / 2, yRadius: w / 2).fill()
                let fillH = max(w, h * CGFloat(min(max(v, 0), 1)))
                (lvl == .nominal ? base : lvl.nsColor).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 1.5, width: w, height: fillH), xRadius: w / 2, yRadius: w / 2).fill()
            }
            return true
        }
        img.isTemplate = allNominal
        img.accessibilityDescription = "CPU \(Int(cpu * 100))%, memory \(Int(memFraction * 100))%, disk \(Int(diskFraction * 100))%"
        return img
    }
}
