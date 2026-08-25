import AppKit

/// `xcode-hackatime notify <message>` posts a user notification. delivery
/// needs a bundle identity, so this only works from inside the Hackatime.app
/// helper that install assembles; a missing helper means no banner, never a
/// fallback under another app's identity
enum Notifier {
    static let bundleID = "com.hackclub.hackatime.notifier"
    static let executableName = "hackatime-notifier"

    static func run(message: String) -> Never {
        // bundleIdentifier resolves only inside the helper bundle
        guard Bundle.main.bundleIdentifier != nil else { exit(1) }
        guard !message.isEmpty else { exit(0) }
        // deliberately the deprecated API: UNUserNotificationCenter silently
        // auto-denies authorization for processes outside a full app
        // lifecycle (verified live against ad-hoc, developer-cert and
        // LaunchServices launches alike), while NSUserNotification has
        // delivered from bundled CLI helpers for a decade
        let note = NSUserNotification()
        note.title = "Hackatime"
        note.informativeText = message
        NSUserNotificationCenter.default.deliver(note)
        // give the notification daemon a beat before this process exits
        Thread.sleep(forTimeInterval: 0.7)
        exit(0)
    }

    /// the first delivery registers the source suppressed, so: deliver to
    /// register, wait for the ncprefs entry, approve it, deliver again so
    /// the banner is actually seen. install-only; a user's later off toggle
    /// in System Settings is never overridden
    static func primeDelivery(message: String, deliver: (String) -> Void) {
        deliver(message)
        // the ncprefs entry appears asynchronously after the first delivery
        for _ in 0..<10 {
            switch approveDelivery() {
            case .alreadyApproved:
                return
            case .approved:
                // give the bounced usernoted a moment to come back
                Thread.sleep(forTimeInterval: 1)
                deliver(message)
                return
            case .notRegistered:
                Thread.sleep(forTimeInterval: 0.3)
            }
        }
    }

    private enum Approval {
        case approved, alreadyApproved, notRegistered
    }

    /// macOS registers a first-time NSUserNotification source suppressed:
    /// deliver() reports success, nothing shows, and no approval prompt ever
    /// comes. there is no API to approve, so this edits com.apple.ncprefs
    /// the way the Settings pane does and bounces usernoted. verified live:
    /// the suppressed entry read flags 0x1280200e / auth 6, Script Editor's
    /// delivering entry reads 0x280200e; clearing bit 28 plus auth 7 made
    /// banners appear. raw CFPreferences rather than a UserDefaults
    /// persistent domain: the explicit synchronize before the usernoted
    /// bounce is the sequence that was verified live
    private static func approveDelivery() -> Approval {
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
        // usernoted caches the domain; launchd respawns it immediately
        Installer.shell("/usr/bin/killall", ["usernoted"])
        return .approved
    }

    /// render the icon into an .icns via iconutil, entirely on-device so the
    /// bare-binary distribution needs no bundled assets
    static func writeIcon(to icnsPath: String) {
        let iconset = NSTemporaryDirectory() + "hackatime-\(getpid()).iconset"
        try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: iconset) }
        // adjacent iconset sizes share pixel dimensions (16@2x = 32@1x);
        // render each dimension once
        var rendered: [Int: Data] = [:]
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                guard let png = rendered[px] ?? renderIcon(pixels: px) else { continue }
                rendered[px] = png
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
        // macOS icon grid: content inset ~10%, corner radius ~22.5%
        let rect = NSRect(x: 0, y: 0, width: size, height: size).insetBy(dx: size * 0.09, dy: size * 0.09)
        NSColor(red: 0.925, green: 0.216, blue: 0.314, alpha: 1).setFill()  // Hack Club red
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
