import AppKit
import ApplicationServices

/// latest known editor state. AX notifications update it and the heartbeat
/// engine snapshots it; the sensor never schedules heartbeats
struct EditorState {
    var filePath: String?
    /// utf-16 offset of the insertion point in the whole document, 0-based
    var cursorOffset: Int?
}

/// observes a running Xcode process through the Accessibility API
final class XcodeObserver {
    static let xcodeBundleID = "com.apple.dt.Xcode"

    /// Xcode and Xcode-beta ship the same bundle id; with both running this
    /// returns an arbitrary one
    static func runningXcode() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: xcodeBundleID).first
    }

    private(set) var state = EditorState()
    /// nil while detached
    var attachedXcodeBundleURL: URL? {
        observer == nil ? nil : NSRunningApplication(processIdentifier: pid)?.bundleURL
    }
    /// the second argument lazily resolves the 1-based line and column of
    /// the insertion point; the fetch behind it is expensive, so it runs
    /// only if the receiver decides to use it
    var onActivity: ((EditorState, () -> (line: Int, column: Int)?) -> Void)?
    /// fires from the periodic re-sync so the receiver still notices disk
    /// writes that land after the last editor event
    var onWritePoll: ((EditorState, () -> (line: Int, column: Int)?) -> Void)?

    private var observer: AXObserver?
    private var appElement: AXUIElement?
    private var trackedEditor: AXUIElement?
    private var pid: pid_t = 0
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void = { _ in }) {
        self.log = log
    }

    // MARK: - Lifecycle

    /// main-queue observer for an NSWorkspace app notification, filtered to
    /// Xcode
    static func onXcodeNotification(
        _ name: Notification.Name, _ handler: @escaping (NSRunningApplication) -> Void
    ) {
        NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                app.bundleIdentifier == xcodeBundleID
            else { return }
            handler(app)
        }
    }

    func startWatchingWorkspace() {
        Self.onXcodeNotification(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in
            self?.log("Xcode launched (pid \(app.processIdentifier))")
            // give Xcode a moment to build its ui before attaching
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.attachIfRunning() }
        }
        Self.onXcodeNotification(NSWorkspace.didTerminateApplicationNotification) { [weak self] _ in
            self?.log("Xcode terminated")
            self?.reconcileAttachment()
        }
        attachIfRunning()

        // AX registrations can go missing around app relaunches or window
        // churn, so re-sync periodically. synthetic: a re-sync must never
        // count as user activity, or an idle Xcode would keep producing
        // heartbeats forever
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.reconcileAttachment()
            if self.observer == nil { self.attachIfRunning() } else { self.refocus(synthetic: true) }
            // poll even without a tracked editor or file (focus may sit in
            // the navigator or console); the receiver still sweeps recently
            // active files and deferred sends
            let resolve = self.trackedEditor.map { self.positionResolver(for: $0) } ?? { nil }
            self.onWritePoll?(self.state, resolve)
        }
    }

    func attachIfRunning() {
        guard observer == nil else { return }
        guard let xcode = Self.runningXcode() else { return }
        attach(pid: xcode.processIdentifier)
    }

    /// detach if the attached pid is dead or recycled: a missed didTerminate
    /// would wedge us forever, since attachIfRunning bails while attached.
    /// it checks the attached pid itself, never "the first running Xcode":
    /// Xcode and Xcode-beta share a bundle id, and an unstable enumeration
    /// order must not thrash a healthy attachment
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
        for note in [
            kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification,
            kAXMainWindowChangedNotification, kAXWindowCreatedNotification,
        ] {
            let err = AXObserverAddNotification(obs, app, note as CFString, refcon)
            guard AX.registered(err) else {
                // Xcode's AX server may not be ready during a slow launch; a
                // partial attach would look healthy but never deliver focus
                // events, so drop everything and let the 20s re-sync retry
                log("app-level AX registration failed for pid \(pid) (\(err.rawValue)); will retry")
                detach()
                return
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        log("attached to Xcode pid \(pid)")
        // attaching (agent start, Xcode launch) is not coding activity
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
        // a carried event belongs to the old Xcode process; it must not
        // surface against whatever a new process restores
        pendingUserActivity = false
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

    /// re-resolve the focused editor and (re)subscribe to its per-element
    /// notifications. synthetic calls (timers, attachment) keep state and
    /// subscriptions fresh but never report activity downstream
    private func refocus(synthetic: Bool = false) {
        guard let app = appElement, let obs = observer else { return }
        guard let focused = AX.element(app, kAXFocusedUIElementAttribute as String) else { return }

        guard isSourceEditor(focused) else {
            // focus left the editor (navigator, console, ...); unsubscribe
            // so programmatic changes to the now-unfocused editor (a buffer
            // reload, build-generated edits) cannot masquerade as typing.
            // state keeps the last file for quiet-tick write polling, and a
            // carried event would attribute stale activity, so drop it
            if let previous = trackedEditor {
                unsubscribe(previous, from: obs)
                trackedEditor = nil
            }
            pendingUserActivity = false
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let previous = trackedEditor, !CFEqual(previous, focused) {
            unsubscribe(previous, from: obs)
            trackedEditor = nil
            // a carried event belongs to the replaced editor; flushing it
            // against the new one would credit the wrong file
            pendingUserActivity = false
        }
        if trackedEditor == nil {
            let selErr = AXObserverAddNotification(obs, focused, kAXSelectedTextChangedNotification as CFString, refcon)
            let valErr = AXObserverAddNotification(obs, focused, kAXValueChangedNotification as CFString, refcon)
            if AX.registered(selErr), AX.registered(valErr) {
                trackedEditor = focused
            } else {
                // element mid-teardown; drop the partial registration and let
                // the next focus event or the 20s re-sync retry
                unsubscribe(focused, from: obs)
                return
            }
        }

        // a refocus always bypasses the state-refresh throttle
        lastExpensiveUpdate = .distantPast
        if synthetic {
            // re-syncs are not activity but always refresh state: an in-pane
            // file swap throttled away at event time would otherwise leave
            // path/cursor stuck on the old file. a carried (throttled) real
            // event flushes here on fresh state
            if updateCursor(from: focused), pendingUserActivity {
                pendingUserActivity = false
                onActivity?(state, positionResolver(for: focused))
            }
            return
        }
        refreshAndReport(editor: focused)
    }

    /// seconds since any keyboard/mouse input in the session; needs no extra
    /// permissions
    private static func secondsSinceLastUserInput() -> TimeInterval {
        let types: [CGEventType] = [
            .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown,
            .otherMouseDown, .mouseMoved, .scrollWheel,
        ]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .infinity
    }
    private static let inputRecencyWindow: TimeInterval = 10

    /// real typing produces an AX event within milliseconds of a keystroke,
    /// and keystrokes only reach the frontmost app, so the user drives this
    /// event only if our Xcode is frontmost AND an input device was touched
    /// moments ago. anything else is Xcode changing the buffer itself, e.g.
    /// reloading a file that changed on disk while the user is away
    private func eventIsUserDriven() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            && Self.secondsSinceLastUserInput() <= Self.inputRecencyWindow
    }

    private func unsubscribe(_ editor: AXUIElement, from obs: AXObserver) {
        AXObserverRemoveNotification(obs, editor, kAXSelectedTextChangedNotification as CFString)
        AXObserverRemoveNotification(obs, editor, kAXValueChangedNotification as CFString)
    }

    /// activity reports only follow a successful state refresh, so a
    /// heartbeat can never fire on state older than its trigger. events with
    /// no human at the input devices demote to the quiet-tick path, where
    /// the write classifier judges the disk change against real user
    /// activity (an unattended buffer reload is swallowed as external). a
    /// real event whose refresh got throttled is carried here and flushed by
    /// the next successful refresh: an in-pane file switch may emit exactly
    /// one event, and dropping it would leave the new file without a
    /// heartbeat until the user acts again
    private var pendingUserActivity = false

    private func refreshAndReport(editor: AXUIElement) {
        let userDriven = eventIsUserDriven()
        guard updateCursor(from: editor) else {
            if userDriven { pendingUserActivity = true }
            return
        }
        if userDriven || pendingUserActivity {
            pendingUserActivity = false
            onActivity?(state, positionResolver(for: editor))
        } else {
            onWritePoll?(state, positionResolver(for: editor))
        }
    }

    /// Xcode's source editor is an AXTextArea whose AXDescription is
    /// "Source Editor"; requiring both plus an editable text range excludes
    /// filter fields, the console and description-less text areas like the
    /// commit-message editor
    private func isSourceEditor(_ element: AXUIElement) -> Bool {
        guard AX.string(element, kAXRoleAttribute as String) == (kAXTextAreaRole as String) else { return false }
        guard AX.range(element, kAXSelectedTextRangeAttribute as String) != nil else { return false }
        guard let desc = AX.string(element, kAXDescriptionAttribute as String) else { return false }
        return desc.localizedCaseInsensitiveContains("source editor")
    }

    // MARK: - State extraction

    /// false when the containing window could not resolve (a transient AX
    /// failure); state stays untouched so the caller can treat the whole
    /// refresh as not having happened
    private func updateFilePath(editor: AXUIElement) -> Bool {
        // the window's AXDocument carries the focused editor's file as a
        // file:// url string, the same source macos-wakatime uses for Xcode
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
            // no document (unsaved file, playground page); clear rather than
            // keep attributing activity to the previously focused file
            resolved = nil
        }
        if state.filePath != resolved {
            log("file: \(resolved ?? "<none>")")
        }
        state.filePath = resolved
        return true
    }

    /// minimum spacing between per-event state refreshes. every AX read
    /// blocks Xcode's main thread during service, and heartbeats are
    /// throttled harder than this anyway, so per-keystroke freshness buys
    /// nothing (the heavy document-prefix fetch waits until send time)
    private static let expensiveRefreshInterval: TimeInterval = 1
    private var lastExpensiveUpdate: Date = .distantPast

    /// true only when the state refresh actually ran (throttled otherwise),
    /// so callers can avoid reporting activity on stale state
    private func updateCursor(from editor: AXUIElement) -> Bool {
        guard let sel = AX.range(editor, kAXSelectedTextRangeAttribute as String) else { return false }
        let now = Date()
        guard now.timeIntervalSince(lastExpensiveUpdate) >= Self.expensiveRefreshInterval else { return false }
        lastExpensiveUpdate = now
        // refresh path and offset together or not at all: an in-pane file
        // swap (ctrl-cmd-left) emits no focus notification, so a partial
        // update could pair one file's path with another file's cursor
        guard updateFilePath(editor: editor) else { return false }
        state.cursorOffset = sel.location
        return true
    }

    /// bound to the editor and offset at call time, so a later resolution
    /// stays coherent with the state snapshot it was issued for
    private func positionResolver(for editor: AXUIElement) -> () -> (line: Int, column: Int)? {
        let offset = state.cursorOffset
        return { [weak self] in
            guard let self, let offset else { return nil }
            return self.position(in: editor, forOffset: offset)
        }
    }

    /// AXLineForIndex counts soft-wrapped display lines, so the physical
    /// 1-based line/column comes from fetching the text before the caret
    /// (AXStringForRange) and counting newlines; cost is proportional to the
    /// prefix, never the whole file. AX requests are serviced on Xcode's
    /// main thread, so give up past this many utf-16 units rather than stall
    /// it (line/column is optional metadata)
    private static let maxPrefixLength = 1_000_000

    private func position(in editor: AXUIElement, forOffset offset: Int) -> (line: Int, column: Int)? {
        guard offset >= 0, offset <= Self.maxPrefixLength else { return nil }
        if offset == 0 { return (line: 1, column: 1) }
        guard let prefix = AX.string(editor, forRange: CFRange(location: 0, length: offset)) else {
            return nil
        }
        return Self.lineColumn(ofPrefix: prefix, offset: offset)
    }

    /// the one owner of physical line/column math for a caret offset, shared
    /// with Probe so the two can never silently diverge
    static func lineColumn(ofPrefix prefix: String, offset: Int) -> (line: Int, column: Int) {
        var line = 1
        var lastNewline = -1
        for (index, unit) in prefix.utf16.enumerated() where unit == 0x0A {
            line += 1
            lastNewline = index
        }
        return (line: line, column: offset - lastNewline)
    }

}
