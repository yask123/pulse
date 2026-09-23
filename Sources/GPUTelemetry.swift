import Foundation
import IOKit

/// GPU clock, voltage and power from IOReport (the private framework behind powermetrics), plus die
/// temperatures from the SMC. Neither needs root. Every probe degrades to nil if the OS moves things.
final class GPUTelemetry {
    struct Reading {
        var residency: [Double]      // share of active time per DVFS state, index-aligned with `states`
        var idle: Double             // share of the interval the GPU was powered off
        var mhz: Double?             // residency-weighted clock while active
        var millivolts: Double?
        var watts: Double?
        var temp: (avg: Double, max: Double)?
    }
    struct State { var mhz: Double; var millivolts: Double }

    /// DVFS table (P1…Pn), from the power manager's device-tree node.
    let states: [State]

    private let io = IOReport()
    private let smc = SMC()
    private lazy var tempKeys: [UInt32] = smc?.keys(prefix: "Tg") ?? []
    private var subscription: IOReport.Subscription?
    private var previous: (sample: CFDictionary, t: TimeInterval)?

    init() {
        states = Self.dvfsTable()
        if let io {
            subscription = io.subscribe([("Energy Model", nil), ("GPU Stats", "GPU Performance States")])
        }
    }

    func read() -> Reading {
        var r = Reading(residency: Array(repeating: 0, count: states.count), idle: 1)
        if let temps = tempKeys.isEmpty ? nil : smc?.floats(tempKeys), !temps.isEmpty {
            r.temp = (temps.reduce(0, +) / Double(temps.count), temps.max()!)
        }
        guard let io, let sub = subscription, let now = io.sample(sub) else { return r }
        let t = ProcessInfo.processInfo.systemUptime
        defer { previous = (now, t) }
        guard let prev = previous, t > prev.t, let delta = io.delta(prev.sample, now) else { return r }

        for ch in delta {
            switch io.name(ch) {
            case "GPU Energy":
                let scale: Double = switch io.unit(ch) { case "mJ": 1e-3; case "uJ", "µJ": 1e-6; default: 1e-9 }
                r.watts = Double(io.integer(ch)) * scale / (t - prev.t)
            case "GPUPH":
                var off = 0.0, active = [Double](repeating: 0, count: states.count)
                for (i, (name, ticks)) in io.states(ch).enumerated() {
                    if name == "OFF" { off += Double(ticks) } else if i - 1 < states.count, i >= 1 { active[i - 1] = Double(ticks) }
                }
                let busy = active.reduce(0, +), total = busy + off
                guard total > 0 else { continue }
                r.idle = off / total
                if busy > 0 {
                    r.residency = active.map { $0 / busy }
                    r.mhz = zip(r.residency, states).reduce(0) { $0 + $1.0 * $1.1.mhz }
                    r.millivolts = zip(r.residency, states).reduce(0) { $0 + $1.0 * $1.1.millivolts }
                }
            default: break
            }
        }
        return r
    }

    /// `voltage-states9` holds (frequency, millivolts) pairs for the GPU; entry 0 is the off state.
    private static func dvfsTable() -> [State] {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceNameMatching("pmgr"), &iter) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iter) }
        while case let s = IOIteratorNext(iter), s != 0 {
            defer { IOObjectRelease(s) }
            guard let data = IORegistryEntryCreateCFProperty(s, "voltage-states9" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Data else { continue }
            let u = data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) }
            let pairs = stride(from: 0, to: u.count - 1, by: 2).map { (Double(u[$0]), Double(u[$0 + 1])) }
            let peak = pairs.map(\.0).max() ?? 0
            let toMHz = peak > 1e8 ? 1e-6 : peak > 1e5 ? 1e-3 : 1   // Hz, kHz or MHz depending on chip
            return pairs.dropFirst().map { State(mhz: $0.0 * toMHz, millivolts: $0.1) }
        }
        return []
    }
}

// MARK: - IOReport (private, loaded at runtime)

private final class IOReport {
    typealias Subscription = (handle: OpaquePointer, channels: CFMutableDictionary)

    private typealias CopyChannels = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias Merge = @convention(c) (CFMutableDictionary, CFMutableDictionary, CFTypeRef?) -> Void
    private typealias Subscribe = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?) -> OpaquePointer?
    private typealias Sample = @convention(c) (OpaquePointer, CFMutableDictionary?, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Delta = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias Str = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias Int64At = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias Count = @convention(c) (CFDictionary) -> Int32
    private typealias StrAt = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?

    private let copy: CopyChannels, merge: Merge, subscribeFn: Subscribe, sampleFn: Sample, deltaFn: Delta
    private let nameFn: Str, unitFn: Str, intFn: Int64At, stateCount: Count, stateName: StrAt, stateResidency: Int64At

    init?() {
        guard let h = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW) else { return nil }
        func sym<T>(_ n: String) -> T? { dlsym(h, n).map { unsafeBitCast($0, to: T.self) } }
        guard let copy: CopyChannels = sym("IOReportCopyChannelsInGroup"),
              let merge: Merge = sym("IOReportMergeChannels"),
              let sub: Subscribe = sym("IOReportCreateSubscription"),
              let sample: Sample = sym("IOReportCreateSamples"),
              let delta: Delta = sym("IOReportCreateSamplesDelta"),
              let name: Str = sym("IOReportChannelGetChannelName"),
              let unit: Str = sym("IOReportChannelGetUnitLabel"),
              let int: Int64At = sym("IOReportSimpleGetIntegerValue"),
              let sc: Count = sym("IOReportStateGetCount"),
              let sn: StrAt = sym("IOReportStateGetNameForIndex"),
              let sr: Int64At = sym("IOReportStateGetResidency")
        else { return nil }
        (self.copy, self.merge, subscribeFn, sampleFn, deltaFn) = (copy, merge, sub, sample, delta)
        (nameFn, unitFn, intFn, stateCount, stateName, stateResidency) = (name, unit, int, sc, sn, sr)
    }

    func subscribe(_ groups: [(String, String?)]) -> Subscription? {
        var merged: CFMutableDictionary?
        for (g, sg) in groups {
            guard let ch = copy(g as CFString, sg as CFString?, 0, 0, 0)?.takeRetainedValue() else { continue }
            if let merged { merge(merged, ch, nil) } else { merged = ch }
        }
        guard let merged else { return nil }
        var out: Unmanaged<CFMutableDictionary>?
        guard let handle = subscribeFn(nil, merged, &out, 0, nil), let chans = out?.takeRetainedValue() else { return nil }
        return (handle, chans)
    }

    func sample(_ s: Subscription) -> CFDictionary? { sampleFn(s.handle, s.channels, nil)?.takeRetainedValue() }

    func delta(_ a: CFDictionary, _ b: CFDictionary) -> [CFDictionary]? {
        guard let d = deltaFn(a, b, nil)?.takeRetainedValue() as? [String: Any] else { return nil }
        return (d["IOReportChannels"] as? [NSDictionary])?.map { $0 as CFDictionary }
    }

    func name(_ c: CFDictionary) -> String { nameFn(c)?.takeUnretainedValue() as String? ?? "" }
    func unit(_ c: CFDictionary) -> String {
        (unitFn(c)?.takeUnretainedValue() as String? ?? "").trimmingCharacters(in: .whitespaces)
    }
    func integer(_ c: CFDictionary) -> Int64 { intFn(c, 0) }
    func states(_ c: CFDictionary) -> [(String, Int64)] {
        (0..<stateCount(c)).map { (stateName(c, $0)?.takeUnretainedValue() as String? ?? "", stateResidency(c, $0)) }
    }
}

// MARK: - SMC

/// Minimal AppleSMC reader for float sensors.
private final class SMC {
    private struct KeyInfo { var size: UInt32 = 0; var type: UInt32 = 0; var attributes: UInt8 = 0; var pad: (UInt8, UInt8, UInt8) = (0, 0, 0) }
    /// Mirrors the kernel's SMCKeyData_t (80 bytes).
    private struct Param {
        var key: UInt32 = 0
        var version: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
        var limit: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
        var info = KeyInfo()
        var result: UInt8 = 0, status: UInt8 = 0, command: UInt8 = 0
        var index: UInt32 = 0
        var bytes: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0)
    }
    private enum Command: UInt8 { case read = 5, keyAtIndex = 8, keyInfo = 9 }
    private static let float = fourcc("flt ")

    private var conn: io_connect_t = 0
    private var infoCache: [UInt32: KeyInfo] = [:]

    init?() {
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        guard IOServiceOpen(svc, mach_task_self_, 0, &conn) == KERN_SUCCESS else { return nil }
    }
    deinit { IOServiceClose(conn) }

    private func call(_ p: Param) -> Param? {
        var input = p, output = Param()
        var size = MemoryLayout<Param>.stride
        guard IOConnectCallStructMethod(conn, 2, &input, MemoryLayout<Param>.stride, &output, &size) == KERN_SUCCESS,
              output.result == 0 else { return nil }
        return output
    }

    private func info(_ key: UInt32) -> KeyInfo? {
        if let i = infoCache[key] { return i }
        guard let o = call(Param(key: key, command: Command.keyInfo.rawValue)) else { return nil }
        infoCache[key] = o.info
        return o.info
    }

    /// All float keys starting with `prefix`, enumerated once.
    func keys(prefix: String) -> [UInt32] {
        guard let countInfo = info(Self.fourcc("#KEY")),
              let o = call(Param(key: Self.fourcc("#KEY"), info: countInfo, command: Command.read.rawValue)) else { return [] }
        var b = o.bytes
        let n = withUnsafeBytes(of: &b) { UInt32(bigEndian: $0.load(as: UInt32.self)) }
        let want = Self.fourcc(prefix.padding(toLength: 4, withPad: "\0", startingAt: 0)) >> UInt32(8 * (4 - prefix.utf8.count))
        return (0..<n).compactMap { i in
            guard let k = call(Param(command: Command.keyAtIndex.rawValue, index: i))?.key,
                  k >> UInt32(8 * (4 - prefix.utf8.count)) == want, info(k)?.type == Self.float else { return nil }
            return k
        }
    }

    /// Current values, dropping sensors that report nothing plausible.
    func floats(_ keys: [UInt32]) -> [Double] {
        keys.compactMap { k in
            guard let i = info(k), let o = call(Param(key: k, info: i, command: Command.read.rawValue)) else { return nil }
            var b = o.bytes
            let v = Double(withUnsafeBytes(of: &b) { $0.load(as: Float.self) })
            return (5...130).contains(v) ? v : nil
        }
    }

    static func fourcc(_ s: String) -> UInt32 { s.utf8.prefix(4).reduce(0) { $0 << 8 | UInt32($1) } }
}
