import ApplicationServices
import AppKit

/// Thin helpers over the C-style AXUIElement API.
enum AX {
    /// Whether an AXObserverAddNotification result means the registration is
    /// in place.
    static func registered(_ err: AXError) -> Bool {
        err == .success || err == .notificationAlreadyRegistered
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return err == .success ? value : nil
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attribute(element, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func range(_ element: AXUIElement, _ name: String) -> CFRange? {
        guard let v = attribute(element, name), CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        let axValue = v as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var r = CFRange()
        AXValueGetValue(axValue, .cfRange, &r)
        return r
    }

    static func parameterized(_ element: AXUIElement, _ name: String, _ param: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        let err = AXUIElementCopyParameterizedAttributeValue(element, name as CFString, param, &value)
        return err == .success ? value : nil
    }

    /// Text within `range`, fetched without materializing the whole document.
    static func string(_ element: AXUIElement, forRange range: CFRange) -> String? {
        var r = range
        guard let axRange = AXValueCreate(.cfRange, &r) else { return nil }
        return parameterized(element, "AXStringForRange", axRange) as? String
    }

    static func attributeNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    static func parameterizedAttributeNames(_ element: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyParameterizedAttributeNames(element, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    static func pid(_ element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    /// The window containing `element`, found by walking AXParent links.
    static func window(containing element: AXUIElement) -> AXUIElement? {
        if let w = self.element(element, kAXWindowAttribute as String) { return w }
        var current: AXUIElement? = element
        for _ in 0..<25 {
            guard let c = current else { return nil }
            if string(c, kAXRoleAttribute as String) == kAXWindowRole as String { return c }
            current = self.element(c, kAXParentAttribute as String)
        }
        return nil
    }
}
