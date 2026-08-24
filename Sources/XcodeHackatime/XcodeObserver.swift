import AppKit
import ApplicationServices

/// latest known editor state. AX notifications update it and the heartbeat
/// engine snapshots it. AX is the sensor; it never schedules heartbeats.
struct EditorState {
    var filePath: String?
    /// UTF-16 character offset of the insertion point in the whole document (0-based).
    var cursorOffset: Int?
}

/// observes a running Xcode process through the Accessibility API.
final class XcodeObserver {
    static let xcodeBundleID = "com.apple.dt.Xcode"

    /// the running Xcode instance, if any. this is the one lookup every
    /// caller shares. (Xcode and Xcode-beta ship the same bundle ID; with
    /// both running this returns an arbitrary one.)
    static func runningXcode() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: xcodeBundleID).first
    }

    private(set) var state = EditorState()
    /// the bundle URL of the attached Xcode instance, nil while detached.
    /// consumed by the engine for accurate plugin metadata.
    var attachedXcodeBundleURL: URL? {
        observer == nil ? nil : NSRunningApplication(processIdentifier: pid)?.bundleURL
    }
    /// called on every meaningful activity update (already coalesced per AX
    /// event). the second argument lazily resolves the 1-based physical
    /// line and column of the insertion point. the fetch behind it is
    /// expensive, so it runs only if the receiver decides to use it.
    var onActivity: ((EditorState, () -> (line: Int, column: Int)?) -> Void)?
    /// called from the periodic re-sync while attached, so the receiver can
    /// still notice disk writes that land after the last editor event.
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

    /// installs a main-queue observer for an NSWorkspace app notification,
    /// filtered to Xcode. the userInfo decode and bundle-ID guard live here
    /// once for every subscriber.
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
            // give Xcode a moment to build its UI before attaching.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.attachIfRunning() }
        }
        Self.onXcodeNotification(NSWorkspace.didTerminateApplicationNotification) { [weak self] _ in
            self?.log("Xcode terminated")
            self?.reconcileAttachment()
        }
        attachIfRunning()

        // safety net: AX registrations can go missing around app relaunches
        // or window churn; re-sync focus periodically. synthetic: a re-sync
        // must never count as user activity, or an idle Xcode would keep
        // producing heartbeats forever.
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.reconcileAttachment()
            if self.observer == nil { self.attachIfRunning() } else { self.refocus(synthetic: true) }
            // poll even without a tracked editor or file (focus may sit in
            // the navigator, the console or an unsaved document). the
            // receiver still sweeps recently active files and deferred
            // sends; only the line/column metadata is unavailable then.
            let resolve = self.trackedEditor.map { self.positionResolver(for: $0) } ?? { nil }
            self.onWritePoll?(self.state, resolve)
        }
    }

    func attachIfRunning() {
        guard observer == nil else { return }
        guard let xcode = Self.runningXcode() else { return }
        attach(pid: xcode.processIdentifier)
    }

    /// the one owner of "is our attachment still valid": detach if the pid
    /// we attached to is dead or recycled. ground truth beats notifications.
    /// a missed didTerminate would otherwise wedge us forever, since
    /// attachIfRunning bails while observer != nil. it checks the attached
    /// pid itself, never "the first running Xcode": Xcode and Xcode-beta
    /// share a bundle ID, and an unstable enumeration order must not thrash
    /// a healthy attachment.
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
                // Xcode's AX server may not be ready yet (racing a slow
                // launch). a partial attach would look healthy but never
                // deliver focus events; drop everything and let the 20s
                // re-sync timer retry from scratch.
                log("app-level AX registration failed for pid \(pid) (\(err.rawValue)); will retry")
                detach()
                return
            }
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        log("attached to Xcode pid \(pid)")
        // synthetic: merely attaching (agent start, Xcode launch) is not
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
        // a carried event belongs to the old Xcode process; it must not
        // surface as activity against whatever a new process restores.
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

    /// re-resolve which editor is focused and (re)subscribe to its
    /// per-element notifications. `synthetic` marks calls that originate from
    /// timers/attachment rather than a user-driven AX notification: they keep
    /// state and subscriptions fresh but never report activity downstream.
    private func refocus(synthetic: Bool = false) {
        guard let app = appElement, let obs = observer else { return }
        guard let focused = AX.element(app, kAXFocusedUIElementAttribute as String) else { return }

        guard isSourceEditor(focused) else {
            // focus left the editor (navigator, console, …). unsubscribe so
            // programmatic changes to the now-unfocused editor (a buffer
            // reload, build-generated edits) cannot masquerade as typing;
            // state keeps the last file for quiet-tick write polling.
            if let previous = trackedEditor {
                unsubscribe(previous, from: obs)
                trackedEditor = nil
            }
            // drop any carried event too: focus moved on, so flushing it
            // later would attribute stale activity.
            pendingUserActivity = false
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let previous = trackedEditor, !CFEqual(previous, focused) {
            unsubscribe(previous, from: obs)
            trackedEditor = nil
            // a carried event belongs to the replaced editor; flushing it
            // against the new one would credit the wrong file.
            pendingUserActivity = false
        }
        if trackedEditor == nil {
            let selErr = AXObserverAddNotification(obs, focused, kAXSelectedTextChangedNotification as CFString, refcon)
            let valErr = AXObserverAddNotification(obs, focused, kAXValueChangedNotification as CFString, refcon)
            if AX.registered(selErr), AX.registered(valErr) {
                trackedEditor = focused
            } else {
                // element mid-teardown; drop any partial registration and let
                // the next focus event or the 20s re-sync retry.
                unsubscribe(focused, from: obs)
                return
            }
        }

        // a refocus always bypasses the state-refresh throttle.
        lastExpensiveUpdate = .distantPast
        if synthetic {
            // re-syncs are not user activity themselves, but they always
            // refresh state: an in-pane file swap throttled away at event
            // time would otherwise leave path/cursor stuck on the old file.
            // cheap, since the document-prefix fetch is send-time only. a
            // carried (throttled) real event flushes here on fresh state.
            if updateCursor(from: focused), pendingUserActivity {
                pendingUserActivity = false
                onActivity?(state, positionResolver(for: focused))
            }
            return
        }
        refreshAndReport(editor: focused)
    }

    /// seconds since the last keyboard/mouse input anywhere in the session
    /// (no extra permissions needed).
    private static func secondsSinceLastUserInput() -> TimeInterval {
        let types: [CGEventType] = [
            .keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown,
            .otherMouseDown, .mouseMoved, .scrollWheel,
        ]
        return types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .infinity
    }
    private static let inputRecencyWindow: TimeInterval = 10

    /// whether an editor event can plausibly be the user. real typing
    /// produces an AX event within milliseconds of a keystroke, and
    /// keystrokes only reach the frontmost app. so the user drives this
    /// event only if our Xcode is frontmost AND the user touched an input
    /// device moments ago. anything else is Xcode changing the buffer
    /// itself, e.g. reloading a file that changed on disk while the user is
    /// away or working in another app.
    private func eventIsUserDriven() -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            && Self.secondsSinceLastUserInput() <= Self.inputRecencyWindow
    }

    private func unsubscribe(_ editor: AXUIElement, from obs: AXObserver) {
        AXObserverRemoveNotification(obs, editor, kAXSelectedTextChangedNotification as CFString)
        AXObserverRemoveNotification(obs, editor, kAXValueChangedNotification as CFString)
    }

    /// the single place that reports activity: only after a successful state
    /// refresh, so a heartbeat can never fire on state older than its
    /// trigger. a skipped (throttled or failed) refresh loses nothing real;
    /// the engine's send spacing is no finer than the refresh throttle.
    /// events with no human at the input devices demote to the quiet-tick
    /// path: no time is credited, and the write classifier judges the disk
    /// change against real user activity (so an unattended buffer reload is
    /// swallowed as external instead of stealing a fresh write).
    /// a real event whose refresh got throttled must not vanish: an in-pane
    /// file switch may emit exactly one event, and dropping it would leave
    /// the new file without a heartbeat until the user acts again. it is
    /// carried here and flushed by the next successful refresh (event or
    /// re-sync).
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
    /// "Source Editor". require both that description and an editable text
    /// range, so we never track filter fields, the console or description-
    /// less text areas like the commit-message editor.
    private func isSourceEditor(_ element: AXUIElement) -> Bool {
        guard AX.string(element, kAXRoleAttribute as String) == (kAXTextAreaRole as String) else { return false }
        guard AX.range(element, kAXSelectedTextRangeAttribute as String) != nil else { return false }
        guard let desc = AX.string(element, kAXDescriptionAttribute as String) else { return false }
        return desc.localizedCaseInsensitiveContains("source editor")
    }

    // MARK: - State extraction

    /// returns false when the containing window could not resolve (a
    /// transient AX failure). state stays untouched so the caller can
    /// treat the whole refresh as not having happened.
    private func updateFilePath(editor: AXUIElement) -> Bool {
        // the window's AXDocument carries the focused editor's file, as a
        // file:// URL string. this is the same source the official
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
            // no document (unsaved file, playground page, …): clear rather
            // than keep attributing activity to the previously focused file.
            resolved = nil
        }
        if state.filePath != resolved {
            log("file: \(resolved ?? "<none>")")
        }
        state.filePath = resolved
        return true
    }

    /// minimum spacing between per-event state refreshes (selected range,
    /// window walk, AXDocument read; the heavy document-prefix line fetch
    /// waits until send time). every AX read blocks Xcode's main thread
    /// during service, and heartbeats are throttled harder than this
    /// anyway, so per-keystroke freshness buys nothing.
    private static let expensiveRefreshInterval: TimeInterval = 1
    private var lastExpensiveUpdate: Date = .distantPast

    /// returns true only when the state refresh actually ran (throttled
    /// otherwise), so callers can avoid reporting activity on stale state.
    private func updateCursor(from editor: AXUIElement) -> Bool {
        guard let sel = AX.range(editor, kAXSelectedTextRangeAttribute as String) else { return false }
        let now = Date()
        guard now.timeIntervalSince(lastExpensiveUpdate) >= Self.expensiveRefreshInterval else { return false }
        lastExpensiveUpdate = now
        // refresh path, line and offset together (or not at all): an
        // in-pane file swap (⌃⌘←) emits no focus notification, so a partial
        // update could pair one file's path with another file's cursor. the
        // path resolves first. if that transiently fails, nothing commits
        // and no refresh is reported.
        guard updateFilePath(editor: editor) else { return false }
        state.cursorOffset = sel.location
        return true
    }

    /// lazy line/column lookup for the current cursor, bound to `editor` and
    /// the offset at call time so a later resolution stays coherent with the
    /// state snapshot it was issued for.
    private func positionResolver(for editor: AXUIElement) -> () -> (line: Int, column: Int)? {
        let offset = state.cursorOffset
        return { [weak self] in
            guard let self, let offset else { return nil }
            return self.position(in: editor, forOffset: offset)
        }
    }

    /// physical (newline-delimited) 1-based line and column for a character
    /// offset. AXLineForIndex counts soft-wrapped display lines, so instead
    /// we fetch only the text *before* the caret via AXStringForRange and
    /// count newlines. cost is proportional to the prefix, never the whole
    /// file. (WakaTime's cursorpos field is the column, not the document
    /// offset.) line/column is optional metadata; a fetch of a multi-megabyte
    /// prefix would stall Xcode's main thread (AX requests are serviced
    /// there), so give it up past this many UTF-16 units.
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
    /// with Probe so the two can never silently diverge.
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
