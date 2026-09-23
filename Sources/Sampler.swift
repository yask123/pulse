import Darwin
import Foundation
import IOKit
import IOKit.ps

/// Raw system probes. Stateful only where a rate needs the previous counter.
final class Sampler {
    private var prevTicks: [(busy: UInt32, total: UInt32)] = []
    private var prevNet: (rx: UInt64, tx: UInt64, t: TimeInterval)?
    private var prevDisk: (r: UInt64, w: UInt64, t: TimeInterval)?

    // MARK: CPU

    /// Per-core utilisation 0...1 since the previous call.
    func cores() -> [Double] {
        var n: natural_t = 0
        var info: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &count) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info),
                          vm_size_t(Int(count) * MemoryLayout<integer_t>.stride))
        }
        var ticks: [(busy: UInt32, total: UInt32)] = []
        for i in 0..<Int(n) {
            let b = Int(CPU_STATE_MAX) * i
            let user = UInt32(bitPattern: info[b + Int(CPU_STATE_USER)])
            let sys = UInt32(bitPattern: info[b + Int(CPU_STATE_SYSTEM)])
            let nice = UInt32(bitPattern: info[b + Int(CPU_STATE_NICE)])
            let idle = UInt32(bitPattern: info[b + Int(CPU_STATE_IDLE)])
            let busy = user &+ sys &+ nice
            ticks.append((busy, busy &+ idle))
        }
        defer { prevTicks = ticks }
        guard prevTicks.count == ticks.count else { return Array(repeating: 0, count: ticks.count) }
        return zip(ticks, prevTicks).map { cur, old in
            let total = Double(cur.total &- old.total)
            return total > 0 ? min(1, Double(cur.busy &- old.busy) / total) : 0
        }
    }

    static func loadAverage() -> [Double] {
        var l = [Double](repeating: 0, count: 3)
        getloadavg(&l, 3)
        return l
    }

    struct GPU { var model: String; var cores: Int; var utilization: Double; var memory: UInt64 }

    /// Apple Silicon GPU: model and core count from the registry, load and memory from its performance stats.
    /// macOS exposes utilisation for the whole GPU only, not per core.
    static func gpu() -> GPU? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iter) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iter) }
        while case let s = IOIteratorNext(iter), s != 0 {
            defer { IOObjectRelease(s) }
            func prop(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let stats = prop("PerformanceStatistics") as? [String: Any],
                  let u = (stats["Device Utilization %"] as? NSNumber)?.doubleValue else { continue }
            return GPU(model: (prop("model") as? String) ?? "GPU",
                       cores: (prop("gpu-core-count") as? NSNumber)?.intValue ?? 0,
                       utilization: u / 100,
                       memory: (stats["In use system memory"] as? NSNumber)?.uint64Value ?? 0)
        }
        return nil
    }

    // MARK: Memory

    struct Memory {
        var total: UInt64
        var app: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0, cached: UInt64 = 0
        var compressedOriginal: UInt64 = 0   // what the compressor holds, before compression
        var swap: UInt64 = 0
        var pressure = 1                     // kernel level: 1 normal, 2 warn, 4 critical
        var headroom = 1.0                   // kern.memorystatus_level: share of memory still available
        var compressRate = 0.0, swapRate = 0.0   // bytes/s

        /// Activity Monitor's "Memory Used".
        var used: UInt64 { app + wired + compressed }
        var free: UInt64 { total > used + cached ? total - used - cached : 0 }
        var compressionRatio: Double? { compressed > 0 ? Double(compressedOriginal) / Double(compressed) : nil }
    }

    private var prevVM: (compressions: UInt64, swaps: UInt64, t: TimeInterval)?

    func memory() -> Memory {
        var s = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let page = UInt64(getpagesize())
        var m = Memory(total: ProcessInfo.processInfo.physicalMemory)
        m.app = (UInt64(s.internal_page_count) - min(UInt64(s.purgeable_count), UInt64(s.internal_page_count))) * page
        m.wired = UInt64(s.wire_count) * page
        m.compressed = UInt64(s.compressor_page_count) * page
        m.compressedOriginal = UInt64(s.total_uncompressed_pages_in_compressor) * page
        m.cached = (UInt64(s.external_page_count) + UInt64(s.purgeable_count)) * page

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swap, &size, nil, 0)
        m.swap = swap.xsu_used
        m.pressure = Int(Self.sysctlInt("kern.memorystatus_vm_pressure_level"))
        m.headroom = Double(Self.sysctlInt("kern.memorystatus_level")) / 100

        let now = ProcessInfo.processInfo.systemUptime
        let compressions = UInt64(s.compressions), swaps = UInt64(s.swapins) + UInt64(s.swapouts)
        if let p = prevVM, now > p.t, compressions >= p.compressions, swaps >= p.swaps {
            m.compressRate = Double((compressions - p.compressions) * page) / (now - p.t)
            m.swapRate = Double((swaps - p.swaps) * page) / (now - p.t)
        }
        prevVM = (compressions, swaps, now)
        return m
    }

    // MARK: Disk

    static func volume() -> (used: UInt64, total: UInt64) {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = v.volumeTotalCapacity, let free = v.volumeAvailableCapacityForImportantUsage
        else { return (0, 0) }
        return (UInt64(total) - UInt64(free), UInt64(total))
    }

    /// Bytes/s read and written across block storage since the previous call.
    func diskIO() -> (read: Double, write: Double) {
        var r: UInt64 = 0, w: UInt64 = 0
        var iter: io_iterator_t = 0
        if IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iter) == KERN_SUCCESS {
            while case let s = IOIteratorNext(iter), s != 0 {
                defer { IOObjectRelease(s) }
                if let st = IORegistryEntryCreateCFProperty(s, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] {
                    r += (st["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                    w += (st["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
                }
            }
            IOObjectRelease(iter)
        }
        let now = ProcessInfo.processInfo.systemUptime
        defer { prevDisk = (r, w, now) }
        guard let p = prevDisk, now > p.t, r >= p.r, w >= p.w else { return (0, 0) }
        return (Double(r - p.r) / (now - p.t), Double(w - p.w) / (now - p.t))
    }

    // MARK: Network

    /// Bytes/s in and out across physical (en*) interfaces, using 64-bit counters.
    func network() -> (rx: Double, tx: Double) {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0 else { return (0, 0) }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return (0, 0) }

        var rx: UInt64 = 0, tx: UInt64 = 0
        var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let h = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                if Int32(h.ifm_type) == RTM_IFINFO2 {
                    let h2 = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    if h2.ifm_flags & IFF_LOOPBACK == 0,
                       if_indextoname(UInt32(h2.ifm_index), &name) != nil,
                       Self.string(name).hasPrefix("en") {
                        rx += h2.ifm_data.ifi_ibytes
                        tx += h2.ifm_data.ifi_obytes
                    }
                }
                guard h.ifm_msglen > 0 else { break }
                off += Int(h.ifm_msglen)
            }
        }
        let now = ProcessInfo.processInfo.systemUptime
        defer { prevNet = (rx, tx, now) }
        guard let p = prevNet, now > p.t, rx >= p.rx, tx >= p.tx else { return (0, 0) }
        return (Double(rx - p.rx) / (now - p.t), Double(tx - p.tx) / (now - p.t))
    }

    // MARK: Power & host

    struct Battery { var percent: Int; var charging: Bool; var onAC: Bool }

    static func battery() -> Battery? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return Battery(percent: cur * 100 / max,
                           charging: d[kIOPSIsChargingKey] as? Bool ?? false,
                           onAC: (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue)
        }
        return nil
    }

    static func uptime() -> TimeInterval {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return 0 }
        return Date().timeIntervalSince1970 - Double(tv.tv_sec)
    }

    static func sysctlInt(_ name: String) -> Int64 {
        var v: Int64 = 0
        var size = MemoryLayout<Int64>.size
        sysctlbyname(name, &v, &size, nil, 0)
        return size == 4 ? Int64(Int32(truncatingIfNeeded: v)) : v
    }

    static func sysctlString(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: size)
        sysctlbyname(name, &buf, &size, nil, 0)
        return string(buf)
    }

    static func string(_ c: [CChar]) -> String {
        String(decoding: c.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
