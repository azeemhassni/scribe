import AppKit
import SwiftUI

/// `Scribe --render-menu <dir>` — renders the menu bar popover to PNGs in both
/// appearances.
///
/// The menu cannot be screenshotted without Screen Recording permission, and
/// eyeballing it by hand means re-opening it after every build. Rendering the
/// same view offscreen with the real library data makes design changes
/// reviewable.
enum MenuPreview {

    static func run(directory: String) -> Never {
        var finished = false

        Task { @MainActor in
            defer { finished = true }
            MeetingLibrary.shared.reload()

            let base = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
            try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

            for scheme in [ColorScheme.light, .dark] {
                let name = scheme == .light ? "menu-light.png" : "menu-dark.png"
                let content = MenuContent()
                    .environmentObject(ScribeController())
                    .environmentObject(Prefs.shared)
                    .environmentObject(MeetingLibrary.shared)
                    .environment(\.colorScheme, scheme)
                    .background(scheme == .light
                                ? Color(white: 0.96)
                                : Color(white: 0.13))

                let renderer = ImageRenderer(content: content)
                renderer.scale = 2
                guard let image = renderer.nsImage,
                      let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff),
                      let png = bitmap.representation(using: .png, properties: [:]) else {
                    print("could not render \(name)")
                    continue
                }
                let url = base.appendingPathComponent(name)
                try? png.write(to: url)
                print("wrote \(url.path)")
            }
        }

        _ = CLIWait.until({ finished }, timeout: 60)
        exit(0)
    }
}
