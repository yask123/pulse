import AppKit
import CoreServices
import Observation

// Every app you installed, how big it is, when you last opened it, and the files it scattered
// through ~/Library. Uninstalling quits it and moves the app and its leftovers to the Trash,
// so nothing is gone until you empty it.

struct AppItem: Sendable, Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleID: String
    let version: String
    let lastUsed: Date?
    /// True when `lastUsed` comes from Spotlight; false when inferred from the app's own files.
    let opened: Bool
    var id: URL { url }
}

struct Leftover: Sendable, Identifiable, Hashable {
    let url: URL
    let kind: String
    /// Found by bundle identifier (safe) rather than by name (a guess, off by default).
    let exact: Bool
    var size: UInt64?
    var id: URL { url }
}

@Observable @MainActor
final class AppCatalog {
    enum Sort: String, CaseIterable { case largest = "Largest", unused = "Unused", name = "A–Z" }
    enum Phase: Equatable { case browsing, confirming, removing, removed(name: String, bytes: UInt64, kept: [URL]), failed(String) }

    var apps: [AppItem] = []
    var sizes: [URL: UInt64] = [:]
    var running: Set<URL> = []
    var loaded = false
    var query = ""
    var sort = Sort.largest

    var selected: AppItem? { didSet { if selected != oldValue { loadLeftovers() } } }
    var leftovers: [Leftover] = []
    var excluded: Set<URL> = []
    var phase = Phase.browsing

    private var icons: [URL: NSImage] = [:]
    private var sizing: Task<Void, Never>?

    var visible: [AppItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let hits = q.isEmpty ? apps : apps.filter { $0.name.localizedCaseInsensitiveContains(q) }
        switch sort {
        case .largest: return hits.sorted { (sizes[$0.url] ?? 0) > (sizes[$1.url] ?? 0) }
        case .unused: return hits.sorted { ($0.lastUsed ?? .distantPast) < ($1.lastUsed ?? .distantPast) }
        case .name: return hits.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    var totalSize: UInt64 { apps.reduce(0) { $0 + (sizes[$1.url] ?? 0) } }

    func icon(_ app: AppItem) -> NSImage {
        if let i = icons[app.url] { return i }
        let i = AppIcon.bitmap(app.url.path)
        icons[app.url] = i
        return i
    }

    func appear() {
        running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleURL))
        guard !loaded else { return }
        loaded = true
        reload()
    }

    func reload() {
        sizing?.cancel()
        sizing = Task {
            apps = await Task.detached(priority: .userInitiated) { AppScan.installed() }.value
            sizes = AppScan.cachedSizes(apps)
            // Measure what the cache didn't cover, a few at a time, largest bundles land as they finish.
            let todo = apps.filter { sizes[$0.url] == nil }.map(\.url)
            await withTaskGroup(of: (URL, UInt64).self) { group in
                var it = todo.makeIterator()
                for _ in 0..<4 { if let u = it.next() { group.addTask { (u, AppScan.allocatedSize(u)) } } }
                while let (u, size) = await group.next() {
                    if Task.isCancelled { group.cancelAll(); return }
                    sizes[u] = size
                    if let next = it.next() { group.addTask { (next, AppScan.allocatedSize(next)) } }
                }
            }
            AppScan.storeSizes(sizes, for: apps)
        }
    }

    // MARK: Uninstall

    func open(_ app: AppItem) { phase = .browsing; selected = app }
    func close() { selected = nil; phase = .browsing }

    var removal: [URL] {
        guard let app = selected else { return [] }
        return [app.url] + leftovers.filter { !excluded.contains($0.url) }.map(\.url)
    }
    var removalBytes: UInt64 {
        guard let app = selected else { return 0 }
        return (sizes[app.url] ?? 0) + leftovers.filter { !excluded.contains($0.url) }.reduce(0) { $0 + ($1.size ?? 0) }
    }

    private func loadLeftovers() {
        leftovers = []
        excluded = []
        guard let app = selected else { return }
        Task {
            let found = await Task.detached(priority: .userInitiated) { AppScan.leftovers(for: app) }.value
            guard selected == app else { return }
            leftovers = found
            excluded = Set(found.filter { !$0.exact }.map(\.url))
        }
    }

    func uninstall() {
        guard let app = selected else { return }
        let urls = removal, bytes = removalBytes
        phase = .removing
        Task {
            await AppScan.quit(app)
            let agents = urls.filter { $0.path.contains("/Library/LaunchAgents/") }
            let stuck = await Task.detached { AppScan.unload(agents); return AppScan.trash(urls) }.value
            if stuck.contains(app.url) {
                phase = .failed("Couldn't move \(app.name) to the Trash.")
            } else {
                // The app is gone. Protected data folders it left behind are reported, not treated as failure.
                let keptBytes = leftovers.filter { stuck.contains($0.url) }.reduce(0) { $0 + ($1.size ?? 0) }
                apps.removeAll { $0.url == app.url }
                sizes[app.url] = nil
                phase = .removed(name: app.name, bytes: bytes - keptBytes, kept: stuck)
                selected = nil
            }
            running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleURL))
        }
    }
}

enum AppIcon {
    @MainActor private static var cache: [String: NSImage] = [:]

    /// The app's icon flattened to one 96 px bitmap: cheaper to draw in a list than the full multi-size icon.
    @MainActor static func bitmap(_ path: String) -> NSImage {
        if let i = cache[path] { return i }
        let icon = NSWorkspace.shared.icon(forFile: path)
        let px = 96
        var image = icon
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
           let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            icon.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
            NSGraphicsContext.restoreGraphicsState()
            rep.size = NSSize(width: 32, height: 32)
            image = NSImage(size: rep.size)
            image.addRepresentation(rep)
        }
        cache[path] = image
        return image
    }
}

enum AppScan {
    static func installed() -> [AppItem] {
        let fm = FileManager.default
        var roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Applications/Utilities"),
                     URL(fileURLWithPath: NSHomeDirectory() + "/Applications")]
        // Vendor folders like /Applications/Adobe Photoshop/ hold the app one level down.
        for dir in (try? fm.contentsOfDirectory(at: roots[0], includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        where dir.pathExtension.isEmpty && dir.lastPathComponent != "Utilities" {
            roots.append(dir)
        }
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return roots.flatMap { root in
            ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []).compactMap { url -> AppItem? in
                guard url.pathExtension == "app", let b = Bundle(url: url), let id = b.bundleIdentifier,
                      !id.hasPrefix("com.apple."), id != own, seen.insert(url.path).inserted else { return nil }
                let version = b.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                let name = url.deletingPathExtension().lastPathComponent
                let spotlight = lastUsed(url)
                return AppItem(url: url, name: name, bundleID: id, version: version,
                               lastUsed: spotlight ?? lastActivity(id: id, name: name), opened: spotlight != nil)
            }
        }
    }

    static func lastUsed(_ url: URL) -> Date? {
        guard let item = MDItemCreateWithURL(kCFAllocatorDefault, url as CFURL) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Spotlight doesn't know every launch. The app's own preferences and support files are touched when it runs.
    static func lastActivity(id: String, name: String) -> Date? {
        let lib = NSHomeDirectory() + "/Library/"
        return [lib + "Preferences/\(id).plist", lib + "Application Support/\(id)", lib + "Application Support/\(name)", lib + "Caches/\(id)"]
            .compactMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }
            .max()
    }

    static func allocatedSize(_ url: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        if let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true { return UInt64(v.totalFileAllocatedSize ?? 0) }
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: UInt64 = 0
        for case let f as URL in e {
            if let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true { total += UInt64(v.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    // Sizes keyed by path and the bundle's modification date, so an update re-measures.
    private static let cacheKey = "appSizes"
    private static func stamp(_ url: URL) -> String {
        let d = (try? url.appendingPathComponent("Contents/Info.plist").resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(url.path)|\(Int(d?.timeIntervalSince1970 ?? 0))"
    }
    @MainActor static func cachedSizes(_ apps: [AppItem]) -> [URL: UInt64] {
        let cache = UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: Int] ?? [:]
        return Dictionary(uniqueKeysWithValues: apps.compactMap { a in cache[stamp(a.url)].map { (a.url, UInt64($0)) } })
    }
    @MainActor static func storeSizes(_ sizes: [URL: UInt64], for apps: [AppItem]) {
        let cache = Dictionary(uniqueKeysWithValues: apps.compactMap { a in sizes[a.url].map { (stamp(a.url), Int($0)) } })
        UserDefaults.standard.set(cache, forKey: cacheKey)
    }

    // MARK: Leftovers

    private static let places: [(dir: String, kind: String, measure: Bool)] = [
        ("Application Support", "Support files", true), ("Caches", "Cache", true), ("Preferences", "Preferences", true),
        ("Preferences/ByHost", "Preferences", true), ("Containers", "Container", false), ("Group Containers", "Shared container", false),
        ("Application Scripts", "Scripts", false), ("Saved Application State", "Window state", true), ("HTTPStorages", "Web storage", true),
        ("WebKit", "Web data", true), ("Cookies", "Cookies", true), ("Logs", "Logs", true), ("LaunchAgents", "Launch agent", true),
    ]

    static func leftovers(for app: AppItem) -> [Leftover] {
        let lib = NSHomeDirectory() + "/Library/"
        let id = app.bundleID.lowercased()
        let names = Set([app.name, app.url.deletingPathExtension().lastPathComponent].map { $0.lowercased() })
        var found: [Leftover] = []
        for place in places {
            let dir = URL(fileURLWithPath: lib + place.dir)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
                let n = name.lowercased()
                let exact = n == id || n.hasPrefix(id + ".") || n.hasSuffix("." + id) || n.contains("." + id + ".")
                let byName = !exact && names.contains(n) && ["Application Support", "Caches", "Logs"].contains(place.dir)
                guard exact || byName else { continue }
                let url = dir.appendingPathComponent(name)
                found.append(Leftover(url: url, kind: place.kind, exact: exact, size: place.measure ? allocatedSize(url) : nil))
            }
        }
        return found.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
    }

    // MARK: Removing

    /// Quits the app and anything else running from inside its bundle (launchers, menu bar helpers).
    @MainActor static func quit(_ app: AppItem) async {
        let inside = { (r: NSRunningApplication) in r.bundleURL.map { $0 == app.url || $0.path.hasPrefix(app.url.path + "/") } ?? false }
        NSWorkspace.shared.runningApplications.filter(inside).forEach { $0.terminate() }
        for _ in 0..<30 where NSWorkspace.shared.runningApplications.contains(where: inside) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        NSWorkspace.shared.runningApplications.filter(inside).forEach { $0.forceTerminate() }
        // Background helpers that aren't NSRunningApplications.
        let snap = await Task.detached { ProcScan.scan() }.value
        let pids = snap.procs.values.filter { $0.path.hasPrefix(app.url.path + "/") }.map(\.pid)
        if !pids.isEmpty { await Reaper.stop(pids) }
    }

    static func unload(_ agents: [URL]) {
        for plist in agents {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["bootout", "gui/\(getuid())", plist.path]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
            p.waitUntilExit()
        }
    }

    /// Moves each item to the Trash. An app bundle Pulse can't move (installed by an admin) goes through
    /// Finder, which can ask for your password. Returns what still couldn't be moved.
    static func trash(_ urls: [URL]) -> [URL] {
        let fm = FileManager.default
        let failed = urls.filter { (try? fm.trashItem(at: $0, resultingItemURL: nil)) == nil && fm.fileExists(atPath: $0.path) }
        // Containers are guarded by macOS's app data protection, which Finder can't get past on Pulse's behalf
        // either; asking would only raise a permission error dialog. Those wait for Full Disk Access.
        let protected = failed.filter { isProtected($0) }
        var stuck = failed.filter { !isProtected($0) }
        guard !stuck.isEmpty else { return protected }
        let list = stuck.map { "POSIX file \"\($0.path.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ", ")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"Finder\" to delete {\(list)}"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        stuck.removeAll { !fm.fileExists(atPath: $0.path) }
        return stuck + protected
    }

    static func isProtected(_ url: URL) -> Bool {
        let lib = NSHomeDirectory() + "/Library/"
        return ["Containers/", "Group Containers/", "Application Scripts/"].contains { url.path.hasPrefix(lib + $0) }
    }
}
