import AppKit

/// `xcode-hackatime notify <message>` posts a user notification through
/// UNUserNotificationCenter. that API refuses unbundled binaries, so this
/// subcommand only works when the binary runs from inside the Hackatime.app
/// helper bundle that install assembles; the agent invokes it there, and a
/// missing helper means no banner (banners are best-effort, and never wear
/// another app's identity). the payoff is a real notification identity: our
/// name, our icon and a Focus-manageable app the user can allow through.
enum Notifier {
    static func run(message: String) -> Never {
        // bundleIdentifier resolves only inside the helper bundle; an
        // unbundled invocation has no notification identity.
        guard Bundle.main.bundleIdentifier != nil else { exit(1) }
        guard !message.isEmpty else { exit(0) }
        // deliberately the deprecated API: UNUserNotificationCenter
        // silently auto-denies authorization for processes outside a full
        // app lifecycle (verified against ad-hoc, developer-cert and
        // LaunchServices launches alike), while NSUserNotification has
        // delivered from bundled CLI helpers for a decade (the
        // terminal-notifier model). it uses the bundle's name and icon and
        // needs no authorization prompt.
        let note = NSUserNotification()
        note.title = "Hackatime"
        note.informativeText = message
        NSUserNotificationCenter.default.deliver(note)
        // give the notification daemon a beat before this process exits.
        Thread.sleep(forTimeInterval: 0.7)
        exit(0)
    }

    /// render our icon (SF symbol on a Hack Club red rounded square) into
    /// an .icns via iconutil, entirely on-device so the bare-binary
    /// distribution needs no bundled assets.
    static func writeIcon(to icnsPath: String) {
        let iconset = NSTemporaryDirectory() + "hackatime-\(getpid()).iconset"
        try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: iconset) }
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                guard let png = renderIcon(pixels: px) else { continue }
                let suffix = scale == 2 ? "@2x" : ""
                try? png.write(to: URL(fileURLWithPath: "\(iconset)/icon_\(base)x\(base)\(suffix).png"))
            }
        }
        Installer.shell("/usr/bin/iconutil", ["-c", "icns", iconset, "-o", icnsPath])
    }

    private static func renderIcon(pixels: Int) -> Data? {
        let size = CGFloat(pixels)
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        // macOS icon grid: content inset ~10%, corner radius ~22.5%.
        let rect = NSRect(x: 0, y: 0, width: size, height: size).insetBy(dx: size * 0.09, dy: size * 0.09)
        NSColor(red: 0.925, green: 0.216, blue: 0.314, alpha: 1).setFill()  // hack club red
        NSBezierPath(roundedRect: rect, xRadius: size * 0.2, yRadius: size * 0.2).fill()
        if let symbol = NSImage(systemSymbolName: "clock.badge.checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .medium)
                    .applying(.init(paletteColors: [.white])))
        {
            let symbolSize = symbol.size
            let origin = NSPoint(x: (size - symbolSize.width) / 2, y: (size - symbolSize.height) / 2)
            symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
        }
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        rep.size = NSSize(width: size, height: size)
        return rep.representation(using: .png, properties: [:])
    }
}
