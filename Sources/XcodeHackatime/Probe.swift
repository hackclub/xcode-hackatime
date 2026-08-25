import AppKit
import ApplicationServices

/// `xcode-hackatime probe` dumps what Xcode currently exposes through
/// Accessibility, for development and bug reports
enum Probe {
    static func run() -> Int32 {
        guard AXIsProcessTrusted() else {
            print("This process is not trusted for Accessibility.")
            print("Grant it in System Settings → Privacy & Security → Accessibility, then re-run.")
            return 2
        }
        guard let xcode = XcodeObserver.runningXcode() else {
            print("Xcode is not running.")
            return 1
        }
        print("Xcode pid=\(xcode.processIdentifier)")
        let app = AXUIElementCreateApplication(xcode.processIdentifier)

        guard let focused = AX.element(app, kAXFocusedUIElementAttribute as String) else {
            print("No focused UI element. Click inside an Xcode editor first.")
            return 1
        }

        dump(focused, label: "FOCUSED ELEMENT")
        ancestry(of: focused)

        if let sel = AX.range(focused, kAXSelectedTextRangeAttribute as String) {
            print("cursor offset = \(sel.location) (selection length \(sel.length))")
            if let prefix = AX.string(focused, forRange: CFRange(location: 0, length: sel.location)) {
                let position = XcodeObserver.lineColumn(ofPrefix: prefix, offset: sel.location)
                print("derived line = \(position.line), column = \(position.column)")
            } else {
                print("AXStringForRange: unavailable")
            }
            var idx = sel.location as CFIndex
            if let n = CFNumberCreate(nil, .cfIndexType, &idx),
                let displayLine = AX.parameterized(focused, "AXLineForIndex", n) as? NSNumber
            {
                print("AXLineForIndex (display/soft-wrapped) = \(displayLine)")
            }
        }

        if let window = AX.window(containing: focused) {
            print("\n=== WINDOW ===")
            print("AXTitle:    \(AX.string(window, kAXTitleAttribute as String) ?? "<nil>")")
            print("AXDocument: \(AX.string(window, kAXDocumentAttribute as String) ?? "<nil>")")
        }
        return 0
    }

    /// probe output goes into bug reports, so attributes carrying document
    /// content print their size, never their text; a selection can be
    /// anything, including credentials
    private static let contentAttributes: Set<String> = [
        kAXValueAttribute as String,
        kAXSelectedTextAttribute as String,
        "AXVisibleText",
    ]

    private static func dump(_ element: AXUIElement, label: String) {
        print("=== \(label) ===")
        for name in AX.attributeNames(element) {
            if ["AXChildren", "AXVisibleChildren", "AXRows", "AXColumns", "AXVisibleCharacterRange"].contains(name) {
                continue
            }
            if contentAttributes.contains(name) {
                if let v = AX.string(element, name) {
                    print("  \(name): <\(v.count) chars>")
                }
                continue
            }
            print("  \(name): \(describe(AX.attribute(element, name)))")
        }
        print("  parameterized: \(AX.parameterizedAttributeNames(element).joined(separator: ", "))")
    }

    private static func ancestry(of element: AXUIElement) {
        print("=== ANCESTRY (leaf → root) ===")
        var current: AXUIElement? = element
        var depth = 0
        while let c = current, depth < 25 {
            let role = AX.string(c, kAXRoleAttribute as String) ?? "?"
            let id = AX.string(c, kAXIdentifierAttribute as String) ?? ""
            let desc = AX.string(c, kAXDescriptionAttribute as String) ?? ""
            let doc = AX.string(c, kAXDocumentAttribute as String) ?? ""
            print("  [\(depth)] \(role) id=\(id) desc=\(desc) doc=\(doc)")
            current = AX.element(c, kAXParentAttribute as String)
            depth += 1
        }
    }

    private static func describe(_ value: CFTypeRef?) -> String {
        guard let value else { return "<nil>" }
        // backstop for content that sneaks in through unlisted attributes;
        // metadata strings (roles, paths, titles) are short
        if let s = value as? String { return s.count > 200 ? "<\(s.count) chars>" : s }
        if let n = value as? NSNumber { return n.stringValue }
        if CFGetTypeID(value) == AXValueGetTypeID() {
            let ax = value as! AXValue
            if AXValueGetType(ax) == .cfRange {
                var r = CFRange(); AXValueGetValue(ax, .cfRange, &r)
                return "CFRange(loc:\(r.location), len:\(r.length))"
            }
            return "<AXValue>"
        }
        if CFGetTypeID(value) == AXUIElementGetTypeID() {
            let el = value as! AXUIElement
            return "<element \(AX.string(el, kAXRoleAttribute as String) ?? "?")>"
        }
        return "\(value)"
    }
}
