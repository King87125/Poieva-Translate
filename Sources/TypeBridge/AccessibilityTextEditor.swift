import AppKit
import ApplicationServices
import TypeBridgeCore

/// Focus and capability discovery only. This layer never reads an entire page to locate an editor.
@MainActor
final class AccessibilityTextEditor {
    private struct Activation {
        var launchDate: Date?
        var requestedManual = false
        var requestedEnhanced = false
        var accepted = false
    }
    private var activations: [pid_t: Activation] = [:]
    private var transportFailed = false

    func prepare(in app: NSRunningApplication, action: ShortcutAction) async throws -> AXUIElement {
        transportFailed = false
        if let initial = focused(app.processIdentifier) {
            if isSecure(initial) { throw TextAccessFailure.secureField }
            if suitable(initial, action: action) { return initial }
        }
        guard !transportFailed else { throw TextAccessFailure.editorUnavailable(app.localizedName ?? L10n.tr("当前应用")) }

        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 0.2)
        var activation = activations[app.processIdentifier] ?? Activation(launchDate: app.launchDate)
        if activation.launchDate != app.launchDate { activation = Activation(launchDate: app.launchDate) }
        if !activation.requestedManual {
            activation.accepted = enable("AXManualAccessibility", on: root) || activation.accepted
            activation.requestedManual = true
        }
        if !activation.accepted, !activation.requestedEnhanced {
            activation.accepted = enable("AXEnhancedUserInterface", on: root)
            activation.requestedEnhanced = true
        }
        activations[app.processIdentifier] = activation

        // Supported renderers can initialize asynchronously. Unsupported native controls get a short retry.
        let attempts = activation.accepted ? 40 : 2
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        for attempt in 0..<attempts {
            try Task.checkCancellation()
            if transportFailed || ContinuousClock.now >= deadline { break }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                throw TextAccessFailure.changedTarget(L10n.tr("输入位置已改变，请回到原输入框重新触发翻译。"))
            }
            if let current = focused(app.processIdentifier) {
                if isSecure(current) { throw TextAccessFailure.secureField }
                if suitable(current, action: action) { return current }
            }
            if attempt == 3, !activation.requestedEnhanced {
                activation.accepted = enable("AXEnhancedUserInterface", on: root) || activation.accepted
                activation.requestedEnhanced = true
                activations[app.processIdentifier] = activation
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        if let current = focused(app.processIdentifier), scope(current) == .documentContainer {
            throw TextAccessFailure.unsafeSelection
        }
        throw TextAccessFailure.editorUnavailable(app.localizedName ?? L10n.tr("当前应用"))
    }

    func isFocused(_ element: AXUIElement, in app: NSRunningApplication) -> Bool {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier,
              let current = focused(app.processIdentifier) else { return false }
        return CFEqual(element, current)
    }

    func value(_ element: AXUIElement) -> String? { string(element, kAXValueAttribute) }
    func selectedText(_ element: AXUIElement) -> String? { string(element, kAXSelectedTextAttribute) }

    /// Geometry only; unsupported bounds must not change editor/writeback eligibility.
    func feedbackBounds(_ element: AXUIElement) -> CGRect? {
        var selected: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selected) == .success,
           let selected, CFGetTypeID(selected) == AXValueGetTypeID() {
            let value = selected as! AXValue
            var cfRange = CFRange()
            if AXValueGetType(value) == .cfRange, AXValueGetValue(value, .cfRange, &cfRange), cfRange.location >= 0, cfRange.length >= 0,
               let parameter = AXValueCreate(.cfRange, &cfRange) {
                var raw: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString,
                    parameter, &raw) == .success, let raw, CFGetTypeID(raw) == AXValueGetTypeID() {
                    var rect = CGRect.zero
                    let value = raw as! AXValue
                    if AXValueGetType(value) == .cgRect, AXValueGetValue(value, .cgRect, &rect),
                       rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite,
                       rect.width >= 0, rect.height > 0 {
                        return rect
                    }
                }
            }
        }
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size, CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        let p = position as! AXValue
        let s = size as! AXValue
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetType(p) == .cgPoint, AXValueGetType(s) == .cgSize,
              AXValueGetValue(p, .cgPoint, &point), AXValueGetValue(s, .cgSize, &dimensions),
              point.x.isFinite, point.y.isFinite, dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width >= 0, dimensions.height > 0 else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    func text(in range: TextSelection, on element: AXUIElement) -> String? {
        guard !transportFailed, range.location >= 0, range.length > 0 else { return nil }
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var result: CFTypeRef?
        let error = AXUIElementCopyParameterizedAttributeValue(element,
            kAXStringForRangeParameterizedAttribute as CFString, parameter, &result)
        if error == .cannotComplete || error == .apiDisabled { transportFailed = true }
        guard error == .success else { return nil }
        if let text = result as? String { return text }
        return (result as? NSAttributedString)?.string
    }

    func selectedRange(_ element: AXUIElement) -> TextSelection? {
        guard let raw = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = raw as! AXValue
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return TextSelection(location: range.location, length: range.length)
    }

    func characterCount(_ element: AXUIElement) -> Int? {
        guard let count = attribute(element, kAXNumberOfCharactersAttribute) as? Int, count >= 0 else { return nil }
        return count
    }

    func canSetRange(_ element: AXUIElement) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success && settable.boolValue
    }

    @discardableResult
    func setRange(_ range: TextSelection, on element: AXUIElement) -> Bool {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let value = AXValueCreate(.cfRange, &cfRange) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    func isEditable(_ element: AXUIElement) -> Bool {
        if let editable = attribute(element, kAXIsEditableAttribute) as? Bool { return editable }
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role(element))
    }

    func isSecure(_ element: AXUIElement) -> Bool {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let candidate = current else { return false }
            if string(candidate, kAXSubroleAttribute) == kAXSecureTextFieldSubrole { return true }
            current = elementAttribute(candidate, kAXParentAttribute)
        }
        return false
    }

    func scope(_ element: AXUIElement) -> EditorScope {
        if transportFailed { return .documentContainer }
        // Only an actual text control can own a whole-input replacement. Containers
        // may aggregate many editable blocks even when they advertise AXIsEditable.
        if ![kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role(element)) || containsNestedEditors(element) {
            return .documentContainer
        }
        if attribute(element, "AXDOMIdentifier") != nil { return .webInput }
        var current: AXUIElement? = element
        for _ in 0..<14 {
            guard let candidate = current else { break }
            if role(candidate) == "AXWebArea" { return .webInput }
            if role(candidate) == kAXWindowRole { break }
            current = elementAttribute(candidate, kAXParentAttribute)
        }
        return transportFailed ? .documentContainer : .nativeInput
    }

    private func suitable(_ element: AXUIElement, action: ShortcutAction) -> Bool {
        if action == .input {
            guard isEditable(element) else { return false }
            return scope(element) != .documentContainer ||
                InputTranslationPolicy.scope(selectedText: selectedText(element), selectedRange: selectedRange(element)) == .selection
        }
        return ![kAXApplicationRole, kAXWindowRole].contains(role(element))
    }

    private func enable(_ name: String, on root: AXUIElement) -> Bool {
        if let active = attribute(root, name) as? Bool, active { return true }
        return AXUIElementSetAttributeValue(root, name as CFString, kCFBooleanTrue) == .success
    }

    private func focused(_ pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var candidates: [AXUIElement] = []
        if let direct = elementAttribute(app, kAXFocusedUIElementAttribute) { candidates.append(direct) }
        if let window = elementAttribute(app, kAXFocusedWindowAttribute),
           let child = elementAttribute(window, kAXFocusedUIElementAttribute) { candidates.append(child) }
        let system = AXUIElementCreateSystemWide()
        if let global = elementAttribute(system, kAXFocusedUIElementAttribute) {
            var owner: pid_t = 0
            if AXUIElementGetPid(global, &owner) == .success, owner == pid { candidates.insert(global, at: 0) }
        }
        var fallback: AXUIElement?
        for candidate in candidates {
            let deepest = followFocus(candidate)
            if isSecure(deepest) { return deepest }
            let resolved = editableAncestor(deepest) ?? deepest
            if isEditable(resolved), scope(resolved) != .documentContainer { return resolved }
            if fallback == nil { fallback = resolved }
        }
        return transportFailed ? nil : fallback
    }

    private func followFocus(_ element: AXUIElement) -> AXUIElement {
        var current = element
        for _ in 0..<6 {
            guard let nested = elementAttribute(current, kAXFocusedUIElementAttribute), !CFEqual(nested, current) else { break }
            current = nested
        }
        return current
    }

    private func editableAncestor(_ element: AXUIElement) -> AXUIElement? {
        if isEditable(element) { return element }
        if let explicit = elementAttribute(element, "AXEditableAncestor"), isEditable(explicit), !isSecure(explicit) { return explicit }
        var current = element
        for _ in 0..<8 {
            if [kAXApplicationRole, kAXWindowRole, "AXWebArea"].contains(role(current)) { break }
            guard let parent = elementAttribute(current, kAXParentAttribute) else { break }
            current = parent
            if isEditable(current) { return current }
        }
        return nil
    }

    private func containsNestedEditors(_ element: AXUIElement) -> Bool {
        var pending = children(element).prefix(12).map { ($0, 1) }
        var inspected = 0
        while !pending.isEmpty, inspected < 48 {
            let (candidate, depth) = pending.removeFirst()
            inspected += 1
            if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role(candidate)), isEditable(candidate) { return true }
            if depth < 3 { pending.append(contentsOf: children(candidate).prefix(12).map { ($0, depth + 1) }) }
        }
        return false
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
    }

    private func role(_ element: AXUIElement) -> String { string(element, kAXRoleAttribute) ?? "" }

    private func elementAttribute(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let raw = attribute(element, name), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return (raw as! AXUIElement)
    }

    private func string(_ element: AXUIElement, _ name: String) -> String? {
        let raw = attribute(element, name)
        if let text = raw as? String { return text }
        return (raw as? NSAttributedString)?.string
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        if transportFailed { return nil }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if error == .cannotComplete || error == .apiDisabled { transportFailed = true }
        return error == .success ? value : nil
    }
}
