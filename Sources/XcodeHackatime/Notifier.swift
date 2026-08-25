import AppKit

/// `xcode-hackatime notify <message>` posts a user notification. delivery
/// needs a bundle identity, so this subcommand only works when the binary
/// runs from inside the Hackatime.app helper bundle that install assembles;
/// the agent invokes it there, and a missing helper means no banner (banners
/// are best-effort, and never wear another app's identity). the payoff is a
/// real notification identity: our name, our icon and a Focus-manageable
/// app the user can allow through.
enum Notifier {
    static let bundleID = "com.hackclub.hackatime.notifier"

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

    enum Approval {
        case approved, alreadyApproved, notRegistered
    }

    /// macOS registers a first-time notification source in a suppressed
    /// pending state: deliver() reports success but nothing shows until the
    /// source's entry in the com.apple.ncprefs domain gains the approved
    /// bits, and NSUserNotification sources never get an approval prompt to
    /// clear it. there is no API for that, so this edits the preference the
    /// way the Settings pane does - clear the pending bit, set auth to
    /// allowed - and bounces usernoted to reload it. verified live: the
    /// suppressed entry read flags 0x1280200e / auth 6, Script Editor's
    /// delivering entry reads 0x280200e, and clearing bit 28 plus auth 7
    /// made banners appear. install is the only caller, so a user who later
    /// turns Hackatime off in System Settings stays off.
    static func approveDelivery() -> Approval {
        let domain = "com.apple.ncprefs" as CFString
        let key = "apps" as CFString
        let pendingBit = 1 << 28
        guard
            var apps = CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
                as? [[String: Any]],
            let index = apps.firstIndex(where: { $0["bundle-id"] as? String == bundleID })
        else { return .notRegistered }
        let flags = apps[index]["flags"] as? Int ?? 0
        if flags & pendingBit == 0 && apps[index]["auth"] as? Int == 7 { return .alreadyApproved }
        apps[index]["flags"] = flags & ~pendingBit
        apps[index]["auth"] = 7
        CFPreferencesSetValue(key, apps as CFArray, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        // usernoted caches the domain; a bounce makes it reload. launchd
        // respawns it immediately.
        Installer.shell("/usr/bin/killall", ["usernoted"])
        return .approved
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
