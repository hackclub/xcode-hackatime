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
    /// touched by a reinstall over an existing binary: the Accessibility row
    /// exists but its grant is stale, so the walkthrough shows off-then-on
    /// steps. the agent consumes it once trusted.
    static var regrantMarker: String { Installer.installDir + "/.regrant-pending" }
    /// touched while the agent waits for the grant; a trusted start that
    /// consumes it posts the one-time "tracking started" banner.
    static var grantPendingMarker: String { Installer.installDir + "/.grant-pending" }

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
    /// Xcode is closed or an old dismissal exists. a freshly-trusted agent
    /// (marker touched moments ago) means there is nothing to onboard.
    static func spawnIfNeeded(afterInstall: Bool = false) {
        guard !isRunning() else { return }
        if afterInstall {
            if let trusted = FileManager.default.modificationDate(atPath: trustedMarker),
                Date().timeIntervalSince(trusted) < 15
            {
                return
            }
        } else {
            guard !dismissedThisXcodeSession() else { return }
        }
        // spawn our own binary, not the installed copy. they differ when
        // running from a build directory during development.
        Installer.spawnSelf(["onboard"], discardOutput: false)
    }

    static func run() -> Int32 {
        guard Installer.acquireSingletonLock(pidFile) else {
            return 0  // another onboarding window is already up
        }
        let launchedAt = Date()

        // after a reinstall the Accessibility row already exists but the
        // grant is stale; the accurate instruction is off-and-on.
        let regrant = FileManager.default.fileExists(atPath: regrantMarker)

        // Xcode-quit dismissal (the window only makes sense alongside Xcode
        // once one was seen; not a user dismissal, so it returns on the next
        // launch) rides workspace notifications, not per-tick polling.
        var sawXcode = XcodeObserver.runningXcode() != nil
        XcodeObserver.onXcodeNotification(NSWorkspace.didLaunchApplicationNotification) { _ in sawXcode = true }
        XcodeObserver.onXcodeNotification(NSWorkspace.didTerminateApplicationNotification) { _ in
            if sawXcode { finish(dismissedByUser: false) }
        }

        OnboardingUI.runWindow(
            .init(
                icon: "clock.badge.checkmark",
                title: "One step to start tracking Xcode",
                subtitle:
                    "Hackatime needs Accessibility permission to see which file and line you're working on in Xcode. It never reads your keystrokes in other apps, and your code never leaves your Mac.",
                steps: [
                    "Click “Open Accessibility Settings” below",
                    "Find “xcode-hackatime” in the list",
                    regrant ? "Turn its toggle OFF, then ON (the update reset it)" : "Turn its toggle on",
                ],
                buttonTitle: "Open Accessibility Settings",
                buttonURL: URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"),
                footer: "This window closes by itself once tracking starts."),
            pollEvery: 0.5,
            isComplete: {
                guard let mtime = FileManager.default.modificationDate(atPath: trustedMarker) else { return false }
                return mtime > launchedAt
            },
            successTitle: "You're all set!",
            successSubtitle: "Hackatime is tracking Xcode now. Happy hacking!",
            onDismiss: { byUser in finish(dismissedByUser: byUser) }
        )
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
    static var pidFile: String { Installer.installDir + "/xcode-hackatime-setupkey.pid" }

    static func run() -> Int32 {
        if Installer.apiKeyConfigured() { return 0 }
        guard Installer.acquireSingletonLock(pidFile) else {
            return 0  // another key-setup window is already up
        }
        // watch the config instead of forking the CLI every poll: the key
        // probe only runs after the file actually changed (the watcher also
        // fires once at attach, covering a key written moments ago).
        var configChanged = false
        Installer.watchFile(NSHomeDirectory() + "/.wakatime.cfg") { configChanged = true }

        OnboardingUI.runWindow(
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
                buttonURL: URL(string: Installer.setupURL),
                footer: "Closes by itself once your key is set. Closing it early is fine too."),
            pollEvery: 1,
            isComplete: {
                guard configChanged else { return false }
                configChanged = false
                return Installer.apiKeyConfigured()
            },
            successTitle: "Connected!",
            successSubtitle: "Your Hackatime key is set. Time in Xcode counts from here on.",
            onDismiss: { _ in
                try? FileManager.default.removeItem(atPath: pidFile)
                exit(0)
            }
        )
    }
}
