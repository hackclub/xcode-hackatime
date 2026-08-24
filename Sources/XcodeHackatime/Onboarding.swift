import AppKit

/// `xcode-hackatime onboard` shows a small window while Accessibility
/// permission is not granted. the agent spawns it and itself stays headless
/// (the agent must exit/relaunch to pick up fresh TCC state; keeping the UI
/// in this separate stable process avoids window flicker). install spawns
/// it too, so the walkthrough appears even with Xcode closed.
///
/// the window flips to a short success state when the agent touches its
/// trusted marker (tracking actually started), and dismisses when the user
/// closes it. a user close persists for the rest of the current Xcode run,
/// so the agent's respawn loop does not put the window straight back.
enum Onboarding {
    static var pidFile: String { Installer.installDir + "/xcode-hackatime-onboard.pid" }
    /// the agent touches this every time it starts up trusted.
    static var trustedMarker: String { Installer.installDir + "/.ax-trusted" }
    /// touched when the user closes the window without granting permission.
    static var dismissedMarker: String { Installer.installDir + "/.onboarding-dismissed" }

    /// true if an onboarding window process is already alive. the onboard
    /// process holds an exclusive flock on the pid file for its lifetime, and
    /// the kernel drops the lock the moment it dies. unlike a pid check,
    /// a stale file or a recycled pid cannot fool this.
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

    /// true if the user closed the window during the current Xcode run.
    /// a dismissal from a previous Xcode run does not count, so quitting and
    /// reopening Xcode shows the window again.
    private static func dismissedThisXcodeSession() -> Bool {
        guard let dismissedAt = FileManager.default.modificationDate(atPath: dismissedMarker) else { return false }
        guard let xcodeLaunch = XcodeObserver.runningXcode()?.launchDate else { return true }
        return dismissedAt > xcodeLaunch
    }

    /// `afterInstall` bypasses the Xcode-session dismissal memory: install is
    /// an explicit user action, so the walkthrough is expected even when
    /// Xcode is closed or an old dismissal exists.
    static func spawnIfNeeded(afterInstall: Bool = false) {
        guard !isRunning() else { return }
        guard afterInstall || !dismissedThisXcodeSession() else { return }
        // spawn our own binary, not the installed copy. they differ when
        // running from a build directory during development.
        Installer.spawnSelf(["onboard"], discardOutput: false)
    }

    static func run() -> Int32 {
        // already tracking: a marker touched moments ago means the agent
        // started trusted (e.g. install spawned us needlessly). nothing to
        // onboard.
        if let trusted = FileManager.default.modificationDate(atPath: trustedMarker),
            Date().timeIntervalSince(trusted) < 15
        {
            return 0
        }
        Installer.ensureInstallDir()
        // hold an exclusive lock on the pid file for our whole lifetime (we
        // deliberately never close the fd); see isRunning().
        let fd = open(pidFile, O_WRONLY | O_CREAT, 0o644)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            return 0  // another onboarding window is already up
        }
        ftruncate(fd, 0)
        "\(ProcessInfo.processInfo.processIdentifier)\n".withCString { _ = write(fd, $0, strlen($0)) }
        let launchedAt = Date()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // after a reinstall the Accessibility row already exists but the
        // grant is stale; the accurate instruction is off-and-on.
        let regrant = FileManager.default.fileExists(atPath: Installer.regrantMarker)
        let window = OnboardingUI.makeWindow(
            .init(
                icon: "clock.badge.checkmark",
                title: "One step to start tracking Xcode",
                subtitle:
                    "Hackatime needs Accessibility permission to see which file and line you're working on in Xcode. It never reads your keystrokes in other apps, and your code never leaves your Mac.",
                steps: regrant
                    ? [
                        "Click “Open Accessibility Settings” below",
                        "Find “xcode-hackatime” in the list",
                        "Turn its toggle OFF, then ON (the update reset it)",
                    ]
                    : [
                        "Click “Open Accessibility Settings” below",
                        "Find “xcode-hackatime” in the list",
                        "Turn its toggle on",
                    ],
                buttonTitle: "Open Accessibility Settings",
                buttonURL: URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
                footer: "This window closes by itself once tracking starts."))
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        // dismiss when the user closes the window, or when Xcode quits after
        // having been seen running (not a user dismissal, so the window
        // returns on the next Xcode launch). when tracking starts, flip to a
        // short success state first: silence reads as "did it work?".
        var sawXcode = false
        var celebrating = false
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            if !window.isVisible {
                finish(dismissedByUser: !celebrating)
            }
            if celebrating { return }
            if let mtime = FileManager.default.modificationDate(atPath: trustedMarker),
                mtime > launchedAt
            {
                celebrating = true
                OnboardingUI.apply(
                    .init(
                        icon: "checkmark.seal.fill", iconColor: .systemGreen,
                        title: "You're all set!",
                        subtitle: "Hackatime is tracking Xcode now. Happy hacking!",
                        footer: ""), to: window)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { finish(dismissedByUser: false) }
                return
            }
            if XcodeObserver.runningXcode() != nil {
                sawXcode = true
            } else if sawXcode {
                finish(dismissedByUser: false)
            }
        }

        app.run()
        return 0
    }

    /// NSApplication.terminate never returns, so cleanup cannot live after
    /// app.run(); do it here and exit directly instead.
    private static func finish(dismissedByUser: Bool) -> Never {
        if dismissedByUser {
            Installer.touchMarker(dismissedMarker)
        }
        try? FileManager.default.removeItem(atPath: pidFile)
        exit(0)
    }
}

/// `xcode-hackatime setup-key` shows a window when install finds no API key.
/// an invitation, never a gate: closing it is respected (no respawn) and
/// tracking starts automatically the moment a key exists, window or not.
enum KeySetup {
    static func run() -> Int32 {
        if Installer.apiKeyConfigured() { return 0 }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = OnboardingUI.makeWindow(
            .init(
                icon: "key.horizontal.fill",
                title: "Connect your Hackatime account",
                subtitle:
                    "Tracking is ready, but ~/.wakatime.cfg has no API key yet, so heartbeats have nowhere to go. The Hackatime setup page writes the key for you.",
                steps: [
                    "Click “Open Hackatime Setup” below",
                    "Sign in and run the one-line setup script",
                    "Come back and code - that's it",
                ],
                buttonTitle: "Open Hackatime Setup",
                buttonURL: URL(string: "https://hackatime.hackclub.com/my/wakatime_setup"),
                footer: "Closes by itself once your key is set. Closing it early is fine too."))
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)

        var celebrating = false
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            if !window.isVisible { exit(0) }  // user closed: respected, no nagging
            if celebrating { return }
            if Installer.apiKeyConfigured() {
                celebrating = true
                OnboardingUI.apply(
                    .init(
                        icon: "checkmark.seal.fill", iconColor: .systemGreen,
                        title: "Connected!",
                        subtitle: "Your Hackatime key is set. Time in Xcode counts from here on.",
                        footer: ""), to: window)
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { exit(0) }
            }
        }

        app.run()
        return 0
    }
}
