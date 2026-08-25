import AppKit

/// `xcode-hackatime onboard` shows the Accessibility walkthrough window in
/// its own process: the agent must exit/relaunch to pick up fresh TCC state,
/// and a window living in the agent would flicker with every relaunch
enum Onboarding {
    static var pidFile: String { Installer.installDir + "/xcode-hackatime-onboard.pid" }
    /// touched by the agent on every trusted start
    static var trustedMarker: String { Installer.installDir + "/.ax-trusted" }
    /// touched when the user closes the window without granting permission
    static var dismissedMarker: String { Installer.installDir + "/.onboarding-dismissed" }
    /// touched by a reinstall over an existing binary: the Accessibility row
    /// exists but its grant is stale, so the walkthrough shows off-then-on
    /// steps. consumed by the agent once trusted
    static var regrantMarker: String { Installer.installDir + "/.regrant-pending" }
    /// touched while the agent waits for the grant; a trusted start that
    /// consumes it posts the one-time "tracking started" banner
    static var grantPendingMarker: String { Installer.installDir + "/.grant-pending" }

    /// the onboard process holds an exclusive flock on the pid file and the
    /// kernel drops the lock when it dies, so unlike a pid check a stale
    /// file or recycled pid cannot fool this
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

    /// a dismissal only counts within the current Xcode run; quitting and
    /// reopening Xcode shows the window again
    private static func dismissedThisXcodeSession() -> Bool {
        guard let dismissedAt = FileManager.default.modificationDate(atPath: dismissedMarker) else { return false }
        guard let xcodeLaunch = XcodeObserver.runningXcode()?.launchDate else { return true }
        return dismissedAt > xcodeLaunch
    }

    /// `afterInstall` bypasses the dismissal memory: install is an explicit
    /// user action, so the walkthrough is expected even when Xcode is closed
    /// or an old dismissal exists. a freshly-trusted agent means there is
    /// nothing to onboard
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
        // spawn our own binary, not the installed copy; they differ when
        // running from a build directory during development
        Installer.spawnSelf(["onboard"], discardOutput: false)
    }

    static func run() -> Int32 {
        guard Installer.acquireSingletonLock(pidFile) else {
            return 0  // another onboarding window is already up
        }
        let launchedAt = Date()

        // after a reinstall the Accessibility row exists but its grant is
        // stale; the accurate instruction is off-and-on
        let regrant = FileManager.default.fileExists(atPath: regrantMarker)

        // an Xcode quit closes the window without counting as a user
        // dismissal, so it returns on the next launch
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
    /// app.run(); it happens here before a direct exit
    private static func finish(dismissedByUser: Bool) -> Never {
        if dismissedByUser {
            Installer.touchMarker(dismissedMarker)
        }
        try? FileManager.default.removeItem(atPath: pidFile)
        exit(0)
    }
}

/// `xcode-hackatime setup-key` shows a window when install finds no API key.
/// an invitation, never a gate: closing it is respected, and tracking starts
/// the moment a key exists, window or not
enum KeySetup {
    static var pidFile: String { Installer.installDir + "/xcode-hackatime-setupkey.pid" }

    static func run() -> Int32 {
        if Installer.apiKeyConfigured() { return 0 }
        guard Installer.acquireSingletonLock(pidFile) else {
            return 0  // another key-setup window is already up
        }
        // watch the config instead of forking the CLI every poll; the
        // attach-time fire covers a key written moments ago
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
