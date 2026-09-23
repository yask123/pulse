import SwiftUI

// Renders the panel to PNG for design review and the README.
//   swiftc -parse-as-library -D SNAPSHOT Sources/*.swift Tools/Snapshot.swift -o snap && ./snap <out-dir> [explain-id]
@main @MainActor
struct Snapshot {
    static func main() async throws {
        let m = Monitor()
        m.host = "macbook-pro"
        for _ in 0..<30 { try await Task.sleep(for: .seconds(2.1)) }   // let history fill
        for scheme in [ColorScheme.dark, .light] {
            let view = Panel(explaining: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil).environment(m)
                .background(scheme == .dark ? Color(red: 0.11, green: 0.12, blue: 0.15).opacity(0.94) : Color(white: 0.97).opacity(0.94),
                            in: .rect(cornerRadius: 24))
                .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Color.white.opacity(scheme == .dark ? 0.12 : 0.5), lineWidth: 1))
                .environment(\.colorScheme, scheme)
            let r = ImageRenderer(content: view)
            r.scale = 3
            guard let img = r.nsImage, let tiff = img.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
            let out = CommandLine.arguments[1] + "/panel-\(scheme == .dark ? "dark" : "light").png"
            try png.write(to: URL(fileURLWithPath: out))
            print(out)
        }
    }
}
