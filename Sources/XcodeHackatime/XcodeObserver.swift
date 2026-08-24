import ApplicationServices
import AppKit

/// Latest known editor state, updated by AX notifications and snapshotted
/// by the heartbeat engine. AX is the sensor; it never schedules heartbeats.
struct EditorState {
    var filePath: String?
    /// UTF-16 character offset of the insertion point in the whole document (0-based).
    var cursorOffset: Int?
}

/// Observes a running Xcode process through the Accessibility API.
final class XcodeObserver {
    static let xcodeBundleID = "com.apple.dt.Xcode"

    /// The running Xcode instance, if any - the one lookup every caller
    /// shares. (Xcode and Xcode-beta ship the same bundle ID; with both
    /// running this returns an arbitrary one.)
    static func runningXcode() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: xcodeBundleID).first
    }

    private(set) var state = EditorState()
    /// Called on every meaningful activity update (already coalesced per AX
    /// event). The second argument lazily resolves the 1-based physical line
    /// number of the insertion point - the fetch behind it is expensive, so
    /// it runs only if the receiver decides to use it.
    var onActivity: ((EditorState, () -> Int?) -> Void)?
    /// Called from the periodic re-sync while attached, so disk writes that
    /// land after the last editor event can still be noticed.
    var onWritePoll: ((EditorState, () -> Int?) -> Void)?

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var trackedEditor: AXUIElement?
    private var pid: pid_t = 0
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void = { _ in }) {
        self.log = log
    }

    // MARK: - Lifecycle

    func startWatchingWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Self.xcodeBundleID else { return }
            self?.log("Xcode launched (pid \(app.processIdentifier))")
            // Give Xcode a moment to build its UI before attaching.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.attachIfRunning() }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Self.xcodeBundleID else { return }
            self?.log("Xcode terminated")
            self?.reconcileAttachment()
        }
        attachIfRunning()

        // Safety net: AX registrations can be missed around app relaunches or
        // window churn; re-sync focus periodically. Synthetic: re-syncing must
        // never count as user activity, or an idle Xcode would keep producing
        // heartbeats forever.
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.reconcileAttachment()
            if self.observer == nil { self.attachIfRunning() } else { self.refocus(synthetic: true) }
            if let editor = self.trackedEditor, self.state.filePath != nil {
                self.onWritePoll?(self.state, self.lineResolver(for: editor))
            }
        }
    }

    func attachIfRunning() {
        guard observer == nil else { return }
        guard let xcode = Self.runningXcode() else { return }
        attach(pid: xcode.processIdentifier)
    }

    /// The one owner of "is our attachment still valid": detach if the pid
    /// we attached to is dead or recycled. Ground truth beats notifications -
    /// a missed didTerminate would otherwise wedge us forever, since
    /// attachIfRunning bails while observer != nil. Checks the attached pid
    /// itself, never "the first running Xcode": Xcode and Xcode-beta share a
    /// bundle ID, and an unstable enumeration order must not thrash a
    /// healthy attachment.
    private func reconcileAttachment() {
        guard observer != nil else { return }
        let attached = NSRunningApplication(processIdentifier: pid)
        let alive = attached.map { !$0.isTerminated && $0.bundleIdentifier == Self.xcodeBundleID } ?? false
        if !alive {
            log("attached Xcode pid \(pid) is gone; detaching")
            detach()
        }
    }

    private func attach(pid: pid_t) {
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon else { return }
            let me = Unmanaged<XcodeObserver>.fromOpaque(refcon).takeUnretainedValue()
            me.handle(notification: notification as String, element: element)
        }
        guard AXObserverCreate(pid, callback, &obs) == .success, let obs else {
            log("AXObserverCreate failed for pid \(pid)")
            return
        }
        self.pid = pid
        self.observer = obs
        let app = AXUIElementCreateApplication(pid)
        self.appElement = app

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for note in [kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification,
                     kAXMainWindowChangedNotification, kAXWindowCreatedNotification] {
            let err = AXObserverAddNotification(obs, app, note as CFString, refcon)
            guard AX.registered(err) else {
                // Xcode's AX server may not be ready yet (racing a slow
                // launch). A partial attach would look healthy but never
                // deliver focus events; drop everything and let the 20s
                // re-sync timer retry from scratch.
                log("app-level AX registration failed for pid \(pid) (\(err.rawValue)); will retry")
                detach()
                return
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        log("attached to Xcode pid \(pid)")
        // Synthetic: merely attaching (agent start, Xcode launch) is not
        // coding activity; the first real keystroke/cursor event reports it.
        refocus(synthetic: true)
    }

    private func detach() {
        if let obs = observer {
            CFRunLoopSourceInvalidate(AXObserverGetRunLoopSource(obs))
        }
        observer = nil
        appElement = nil
        trackedEditor = nil
        state = EditorState()
    }

    // MARK: - Notifications

    private func handle(notification: String, element: AXUIElement) {
        switch notification {
        case kAXFocusedUIElementChangedNotification,
             kAXFocusedWindowChangedNotification,
             kAXMainWindowChangedNotification,
             kAXWindowCreatedNotification:
            refocus()
        case kAXSelectedTextChangedNotification,
             kAXValueChangedNotification:
            refreshAndReport(editor: element)
        default:
            break
        }
    }

    /// Re-resolve which editor is focused and (re)subscribe to its
    /// per-element notifications. `synthetic` marks calls that originate from
    /// timers/attachment rather than a user-driven AX notification: they keep
    /// state and subscriptions fresh but never report activity downstream.
    private func refocus(synthetic: Bool = false) {
        guard let app = appElement, let obs = observer else { return }
        guard let focused = AX.element(app, kAXFocusedUIElementAttribute as String) else { return }

        guard isSourceEditor(focused) else {
            // Focus went to the navigator / console / etc. Keep the last file
            // but stop treating keystrokes elsewhere as coding activity.
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var editorChanged = false
        if let previous = trackedEditor, CFEqual(previous, focused) == false {
            AXObserverRemoveNotification(obs, previous, kAXSelectedTextChangedNotification as CFString)
            AXObserverRemoveNotification(obs, previous, kAXValueChangedNotification as CFString)
            trackedEditor = nil
        }
        if trackedEditor == nil {
            let selErr = AXObserverAddNotification(obs, focused, kAXSelectedTextChangedNotification as CFString, refcon)
            let valErr = AXObserverAddNotification(obs, focused, kAXValueChangedNotification as CFString, refcon)
            if AX.registered(selErr), AX.registered(valErr) {
                trackedEditor = focused
                editorChanged = true
            } else {
                // Element mid-teardown; drop any partial registration and let
                // the next focus event or the 20s re-sync retry.
                AXObserverRemoveNotification(obs, focused, kAXSelectedTextChangedNotification as CFString)
                AXObserverRemoveNotification(obs, focused, kAXValueChangedNotification as CFString)
                return
            }
        }

        if synthetic {
            // Expensive AX reads block Xcode's main thread, so a 20s re-sync
            // refreshes state only when the focused editor actually changed
            // under us - and never reports activity.
            if editorChanged {
                lastExpensiveUpdate = .distantPast
                _ = updateCursor(from: focused)
            }
            return
        }
        lastExpensiveUpdate = .distantPast
        refreshAndReport(editor: focused)
    }

    /// Seconds since the last keyboard/mouse input anywhere in the session
    /// (no extra permissions needed).
    private static func secondsSinceLastUserInput() -> TimeInterval {
        let types: [CGEventType] = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown,
                                    .otherMouseDown, .mouseMoved, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .infinity
    }
    private static let inputRecencyWindow: TimeInterval = 10

    /// Whether an editor event can plausibly be the user. Real typing
    /// produces an AX event within milliseconds of a keystroke, and
    /// keystrokes only reach the frontmost app - so the user is driving this
    /// event only if our Xcode is frontmost AND an input device was touched
    /// moments ago. Anything else is Xcode changing the buffer itself, e.g.
    /// reloading a file that changed on disk while the user is away or
    /// working in another app.
    private func eventIsUserDriven() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            && Self.secondsSinceLastUserInput() <= Self.inputRecencyWindow
    }

    /// The single place activity is reported: only after a successful state
    /// refresh, so a heartbeat can never fire on state older than its
    /// trigger. A skipped (throttled or failed) refresh loses nothing real -
    /// the engine's send spacing is no finer than the refresh throttle.
    /// Events with no human at the input devices are demoted to the
    /// quiet-tick path: no time is credited, and the write classifier judges
    /// the disk change against real user activity (so an unattended buffer
    /// reload is swallowed as external instead of stealing a fresh write).
    private func refreshAndReport(editor: AXUIElement) {
        guard updateCursor(from: editor) else { return }
        if eventIsUserDriven() {
            onActivity?(state, lineResolver(for: editor))
        } else {
            onWritePoll?(state, lineResolver(for: editor))
        }
    }

    /// Xcode's source editor is an AXTextArea whose AXDescription is
    /// "Source Editor". Require both that description and an editable text
    /// range, so we never track filter fields, the console, or description-
    /// less text areas like the commit-message editor.
    private func isSourceEditor(_ element: AXUIElement) -> Bool {
        guard AX.string(element, kAXRoleAttribute as String) == (kAXTextAreaRole as String) else { return false }
        guard AX.range(element, kAXSelectedTextRangeAttribute as String) != nil else { return false }
        guard let desc = AX.string(element, kAXDescriptionAttribute as String) else { return false }
        return desc.localizedCaseInsensitiveContains("source editor")
    }

    // MARK: - State extraction

    /// Returns false when the containing window couldn't be resolved (a
    /// transient AX failure) - state is left untouched so the caller can
    /// treat the whole refresh as not having happened.
    private func updateFilePath(editor: AXUIElement) -> Bool {
        // The window's AXDocument carries the focused editor's file, as a
        // file:// URL string. This is the same source the official
        // macos-wakatime app uses for Xcode.
        guard let window = AX.window(containing: editor) else { return false }
        let resolved: String?
        if let doc = AX.string(window, kAXDocumentAttribute as String) {
            let path: String
            if doc.hasPrefix("file://"), let url = URL(string: doc) {
                path = url.path
            } else {
                path = doc
            }
            resolved = path.hasPrefix("/") ? path : nil
        } else {
            // No document (unsaved file, playground page, …): clear rather
            // than keep attributing activity to the previously focused file.
            resolved = nil
        }
        if state.filePath != resolved {
            log("file: \(resolved ?? "<none>")")
        }
        state.filePath = resolved
        return true
    }

    /// Minimum spacing between the expensive AX reads (the document-prefix
    /// fetch for the line number and the parent walk for the file path).
    /// Every AX read blocks Xcode's main thread while it's serviced, and
    /// heartbeats are throttled harder than this anyway - so per-keystroke
    /// freshness buys nothing.
    private static let expensiveRefreshInterval: TimeInterval = 1
    private var lastExpensiveUpdate: Date = .distantPast

    /// Returns true only when the state refresh actually ran (throttled
    /// otherwise), so callers can avoid reporting activity on stale state.
    private func updateCursor(from editor: AXUIElement) -> Bool {
        guard let sel = AX.range(editor, kAXSelectedTextRangeAttribute as String) else { return false }
        let now = Date()
        guard now.timeIntervalSince(lastExpensiveUpdate) >= Self.expensiveRefreshInterval else { return false }
        lastExpensiveUpdate = now
        // Refresh path, line, and offset together (or not at all): an
        // in-pane file swap (⌃⌘←) emits no focus notification, so a partial
        // update could pair one file's path with another file's cursor. The
        // path resolves first - if that transiently fails, nothing is
        // committed and no refresh is reported.
        guard updateFilePath(editor: editor) else { return false }
        state.cursorOffset = sel.location
        return true
    }

    /// Lazy line lookup for the current cursor, bound to `editor` and the
    /// offset at call time so a later resolution stays coherent with the
    /// state snapshot it was issued for.
    private func lineResolver(for editor: AXUIElement) -> () -> Int? {
        let offset = state.cursorOffset
        return { [weak self] in
            guard let self, let offset else { return nil }
            return self.lineNumber(in: editor, forOffset: offset)
        }
    }

    /// Physical (newline-delimited) 1-based line number for a character
    /// offset. AXLineForIndex counts soft-wrapped display lines, so instead we
    /// fetch only the text *before* the caret via AXStringForRange and count
    /// newlines - cost is proportional to the prefix, never the whole file.
    private func lineNumber(in editor: AXUIElement, forOffset offset: Int) -> Int? {
        guard offset >= 0 else { return nil }
        if offset == 0 { return 1 }
        guard let prefix = AX.string(editor, forRange: CFRange(location: 0, length: offset)) else {
            return nil
        }
        var line = 1
        for scalar in prefix.utf16 where scalar == 0x0A { line += 1 }
        return line
    }

}
