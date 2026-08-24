import AppKit

/// `xcode-hackatime onboard` — a small window shown while Xcode is open but
/// Accessibility permission hasn't been granted. Spawned by the agent, which
/// itself stays headless (it must exit/relaunch to pick up fresh TCC state;
/// keeping the UI in this separate stable process avoids window flicker).
///
/// The window dismisses itself when the agent's trusted marker file is
/// touched (i.e. tracking actually started), or when the user closes it.
/// A user close is remembered for the rest of the current Xcode run, so the
/// agent's respawn loop doesn't put the window straight back.
enum Onboarding {
    static var pidFile: String { Installer.installDir + "/xcode-hackatime-onboard.pid" }
    /// Touched by the agent every time it starts up trusted.
    static var trustedMarker: String { Installer.installDir + "/.ax-trusted" }
    /// Touched when the user closes the window without granting permission.
    static var dismissedMarker: String { Installer.installDir + "/.onboarding-dismissed" }

    /// True if an onboarding window process is already alive. The onboard
    /// process holds an exclusive flock on the pid file for its lifetime, and
    /// the kernel drops the lock the moment it dies — so unlike a pid check,
    /// this can't be fooled by a stale file or a recycled pid.
    static func isRunning() -> Bool {
        let fd = open(pidFile, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }

    /// True if the user closed the window during the current Xcode run.
    /// A dismissal from a previous Xcode run doesn't count, so quitting and
    /// reopening Xcode shows the window again.
    private static func dismissedThisXcodeSession() -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: dismissedMarker),
              let dismissedAt = attrs[.modificationDate] as? Date else { return false }
        guard let xcodeLaunch = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == XcodeObserver.xcodeBundleID })?.launchDate
        else { return true }
        return dismissedAt > xcodeLaunch
    }

    static func spawnIfNeeded() {
        guard !isRunning(), !dismissedThisXcodeSession() else { return }
        let process = Process()
        // Spawn our own binary, not the installed copy — they differ when
        // running from a build directory during development.
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["onboard"]
        try? process.run()
    }

    static func run() -> Int32 {
        try? FileManager.default.createDirectory(atPath: Installer.installDir, withIntermediateDirectories: true)
        // Hold an exclusive lock on the pid file for our whole lifetime (the
        // fd is deliberately never closed); see isRunning().
        let fd = open(pidFile, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            return 0 // another onboarding window is already up
        }
        ftruncate(fd, 0)
        "\(ProcessInfo.processInfo.processIdentifier)\n".withCString { _ = write(fd, $0, strlen($0)) }
        let launchedAt = Date()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let window = makeWindow()
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        // Dismiss when tracking starts (agent touches the marker) or the
        // user closes the window.
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            if let attrs = try? FileManager.default.attributesOfItem(atPath: trustedMarker),
               let mtime = attrs[.modificationDate] as? Date,
               mtime > launchedAt {
                finish(dismissedByUser: false)
            }
            if !window.isVisible {
                finish(dismissedByUser: true)
            }
        }

        app.run()
        return 0
    }

    /// NSApplication.terminate never returns, so cleanup can't live after
    /// app.run(); do it here and exit directly instead.
    private static func finish(dismissedByUser: Bool) -> Never {
        if dismissedByUser {
            FileManager.default.createFile(atPath: dismissedMarker, contents: Data())
        }
        try? FileManager.default.removeItem(atPath: pidFile)
        exit(0)
    }

    // MARK: - UI

    private static func makeWindow() -> NSWindow {
        let width: CGFloat = 460

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.level = .floating

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 40, left: 36, bottom: 28, right: 36)
        content.translatesAutoresizingMaskIntoConstraints = false

        // Icon
        if let icon = NSImage(systemSymbolName: "clock.badge.checkmark",
                              accessibilityDescription: "Hackatime") {
            let config = NSImage.SymbolConfiguration(pointSize: 52, weight: .medium)
                .applying(.init(hierarchicalColor: .controlAccentColor))
            let imageView = NSImageView(image: icon.withSymbolConfiguration(config) ?? icon)
            content.addArrangedSubview(imageView)
        }

        // Title
        let title = NSTextField(labelWithString: "One step to start tracking Xcode")
        title.font = .systemFont(ofSize: 20, weight: .bold)
        title.alignment = .center
        content.addArrangedSubview(title)

        // Subtitle
        let subtitle = NSTextField(wrappingLabelWithString:
            "Hackatime needs Accessibility permission to see which file and line you're working on in Xcode. It never reads your keystrokes in other apps, and your code never leaves your Mac.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.preferredMaxLayoutWidth = width - 88
        content.addArrangedSubview(subtitle)

        content.setCustomSpacing(22, after: subtitle)

        // Steps card
        let steps = NSStackView()
        steps.orientation = .vertical
        steps.alignment = .leading
        steps.spacing = 10
        steps.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        steps.translatesAutoresizingMaskIntoConstraints = false
        for (index, text) in [
            "Click “Open Accessibility Settings” below",
            "Find “xcode-hackatime” in the list",
            "Turn its toggle on",
        ].enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.spacing = 10
            row.alignment = .centerY
            // A fixed circle container with the digit centered inside it -
            // sizing the text field itself leaves the digit top-aligned.
            let badge = NSView()
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            badge.layer?.cornerRadius = 10
            badge.translatesAutoresizingMaskIntoConstraints = false
            let digit = NSTextField(labelWithString: "\(index + 1)")
            digit.font = .monospacedDigitSystemFont(ofSize: 12, weight: .bold)
            digit.textColor = .white
            digit.translatesAutoresizingMaskIntoConstraints = false
            badge.addSubview(digit)
            NSLayoutConstraint.activate([
                badge.widthAnchor.constraint(equalToConstant: 20),
                badge.heightAnchor.constraint(equalToConstant: 20),
                digit.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
                digit.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            ])
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 13)
            row.addArrangedSubview(badge)
            row.addArrangedSubview(label)
            steps.addArrangedSubview(row)
        }
        let card = NSVisualEffectView()
        card.material = .contentBackground
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(steps)
        NSLayoutConstraint.activate([
            steps.topAnchor.constraint(equalTo: card.topAnchor),
            steps.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            steps.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            steps.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        content.addArrangedSubview(card)
        card.widthAnchor.constraint(equalToConstant: width - 72).isActive = true

        content.setCustomSpacing(22, after: card)

        // Action button
        let button = NSButton(title: "Open Accessibility Settings",
                              target: ButtonTarget.shared,
                              action: #selector(ButtonTarget.openSettings))
        button.bezelStyle = .push
        button.controlSize = .large
        button.keyEquivalent = "\r"
        content.addArrangedSubview(button)

        // Footer
        let footer = NSTextField(labelWithString: "This window closes by itself once tracking starts.")
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .tertiaryLabelColor
        content.addArrangedSubview(footer)

        let container = window.contentView!
        container.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            container.widthAnchor.constraint(equalToConstant: width),
        ])
        window.setContentSize(content.fittingSize)
        return window
    }

    final class ButtonTarget: NSObject {
        static let shared = ButtonTarget()
        @objc func openSettings() {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
    }
}
