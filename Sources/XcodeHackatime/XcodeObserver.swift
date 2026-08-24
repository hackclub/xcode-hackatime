import ApplicationServices
import AppKit

/// Latest known editor state, updated by AX notifications and snapshotted
/// by the heartbeat engine. AX is the sensor; it never schedules heartbeats.
struct EditorState {
    var filePath: String?
    /// UTF-16 character offset of the insertion point in the whole document (0-based).
    var cursorOffset: Int?
    /// 1-based line number of the insertion point (physical lines, not soft wraps).
    var line: Int?
    var lastActivity: Date?
}

/// Observes a running Xcode process through the Accessibility API.
final class XcodeObserver {
    static let xcodeBundleID = "com.apple.dt.Xcode"

    private(set) var state = EditorState()
    /// Called on every meaningful activity update (already coalesced per AX event).
    var onActivity: ((EditorState) -> Void)?

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
            self?.detach()
        }
        attachIfRunning()

        // Safety net: AX registrations can be missed around app relaunches or
        // window churn; re-sync focus periodically.
        Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.observer == nil { self.attachIfRunning() } else { self.refocus() }
        }
    }

    func attachIfRunning() {
        guard observer == nil else { return }
        guard let xcode = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == Self.xcodeBundleID }) else { return }
        attach(pid: xcode.processIdentifier)
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
            AXObserverAddNotification(obs, app, note as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        log("attached to Xcode pid \(pid)")
        refocus()
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
        case kAXSelectedTextChangedNotification:
            updateCursor(from: element)
            touch()
        case kAXValueChangedNotification:
            // The buffer content changed (typing, paste, refactor, …).
            updateCursor(from: element)
            touch()
        default:
            break
        }
    }

    /// Re-resolve which editor is focused and (re)subscribe to its
    /// per-element notifications.
    private func refocus() {
        guard let app = appElement, let obs = observer else { return }
        guard let focused = AX.element(app, kAXFocusedUIElementAttribute as String) else { return }

        guard isSourceEditor(focused) else {
            // Focus went to the navigator / console / etc. Keep the last file
            // but stop treating keystrokes elsewhere as coding activity.
            return
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let previous = trackedEditor, CFEqual(previous, focused) == false {
            AXObserverRemoveNotification(obs, previous, kAXSelectedTextChangedNotification as CFString)
            AXObserverRemoveNotification(obs, previous, kAXValueChangedNotification as CFString)
        }
        if trackedEditor == nil || CFEqual(trackedEditor!, focused) == false {
            AXObserverAddNotification(obs, focused, kAXSelectedTextChangedNotification as CFString, refcon)
            AXObserverAddNotification(obs, focused, kAXValueChangedNotification as CFString, refcon)
            trackedEditor = focused
        }

        updateFilePath(editor: focused)
        updateCursor(from: focused)
        touch()
    }

    /// Xcode's source editor is an AXTextArea whose AXDescription is
    /// "Source Editor". Match generously but require an editable text range
    /// so we never track the filter fields or console.
    private func isSourceEditor(_ element: AXUIElement) -> Bool {
        guard AX.string(element, kAXRoleAttribute as String) == (kAXTextAreaRole as String) else { return false }
        guard AX.range(element, kAXSelectedTextRangeAttribute as String) != nil else { return false }
        if let desc = AX.string(element, kAXDescriptionAttribute as String), !desc.isEmpty {
            return desc.localizedCaseInsensitiveContains("source editor")
        }
        // Description missing: accept only if it's a large text area (heuristic).
        return true
    }

    // MARK: - State extraction

    private func updateFilePath(editor: AXUIElement) {
        // The window's AXDocument carries the focused editor's file, as a
        // file:// URL string. This is the same source the official
        // macos-wakatime app uses for Xcode.
        guard let window = AX.window(containing: editor),
              let doc = AX.string(window, kAXDocumentAttribute as String) else { return }
        let path: String
        if doc.hasPrefix("file://"), let url = URL(string: doc) {
            path = url.path
        } else {
            path = doc
        }
        guard path.hasPrefix("/") else { return }
        if state.filePath != path {
            log("file: \(path)")
        }
        state.filePath = path
    }

    private func updateCursor(from editor: AXUIElement) {
        guard let sel = AX.range(editor, kAXSelectedTextRangeAttribute as String) else { return }
        state.cursorOffset = sel.location
        state.line = lineNumber(in: editor, forOffset: sel.location)
        // The window's document can change without a focus notification when
        // Xcode swaps the file shown in the same editor pane (e.g. ⌃⌘←).
        updateFilePath(editor: editor)
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

    private func touch() {
        state.lastActivity = Date()
        onActivity?(state)
    }
}
