import SwiftUI

// Renders the panel to PNG for design review and the README.
//   swiftc -parse-as-library -D SNAPSHOT Sources/*.swift Tools/Snapshot.swift -o snap && ./snap <out-dir> [explain-id|-] [vitals|running|apps[:App Name]]
@main @MainActor
struct Snapshot {
    static func main() async throws {
        let args = CommandLine.arguments
        let screen = args.count > 3 ? args[3].split(separator: ":", maxSplits: 1).map(String.init) : []
        let tab = screen.first.flatMap { Tab(rawValue: $0.capitalized) } ?? .vitals
        let detail = screen.count > 1 ? screen[1] : nil
        let explain = args.count > 2 && !args[2].isEmpty && args[2] != "-" ? args[2] : nil
        let m = Monitor(), watch = ProcessWatch(), catalog = AppCatalog()
        m.host = "macbook-pro"
        if tab == .apps { catalog.appear() }
        if tab == .running { watch.diagnose(machine: m.diagnosticSummary) }
        for _ in 0..<(tab == .vitals ? 30 : 8) { try await Task.sleep(for: .seconds(2.1)) }   // let history fill
        if tab == .running { while case .running = watch.diagnosis { try await Task.sleep(for: .seconds(1)) } }
        if let detail, let app = catalog.apps.first(where: { $0.name == detail }) {
            catalog.open(app)
            try await Task.sleep(for: .seconds(3))
        }
        for scheme in [ColorScheme.dark, .light] {
            let view = Panel(explaining: explain, tab: tab).environment(m).environment(watch).environment(catalog)
                .background(scheme == .dark ? Color(red: 0.11, green: 0.12, blue: 0.15).opacity(0.94) : Color(white: 0.97).opacity(0.94),
                            in: .rect(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.white.opacity(scheme == .dark ? 0.12 : 0.5), lineWidth: 1))
                .environment(\.colorScheme, scheme)
            let r = ImageRenderer(content: view)
            r.scale = 3
            guard let img = r.nsImage, let tiff = img.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            // The README shows an app's uninstall view as panel-apps; the bare list renders as panel-apps-list.
            let suffix = tab == .vitals ? "" : "-\(tab.rawValue.lowercased())" + (tab == .apps && detail == nil ? "-list" : "")
            let out = args[1] + "/panel\(suffix)-\(scheme == .dark ? "dark" : "light").png"
            try png.write(to: URL(fileURLWithPath: out))
            print(out)
        }
    }
}
