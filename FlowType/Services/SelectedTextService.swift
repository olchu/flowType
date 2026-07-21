import ApplicationServices
import AppKit
import Foundation

@MainActor
final class SelectedTextService {
    struct Selection {
        let text: String
        let bounds: CGRect?
        let isEditable: Bool
        fileprivate let focusedElement: AXUIElement?
        fileprivate let editableElement: AXUIElement?
        fileprivate let selectedRange: AXValue?
    }

    enum SelectionError: LocalizedError {
        case accessibilityPermissionMissing
        case selectionUnavailable

        var errorDescription: String? {
            switch self {
            case .accessibilityPermissionMissing:
                "Translation needs Accessibility permission."
            case .selectionUnavailable:
                "Select some editable Russian or English text first."
            }
        }
    }

    func currentSelection(in application: NSRunningApplication?) async throws -> Selection {
        guard AXIsProcessTrusted() else {
            throw SelectionError.accessibilityPermissionMissing
        }

        let element = try? focusedElement()
        if let element, let text = selectedText(in: element) {
            let editableElement = editableElement(for: element)
            return Selection(
                text: text,
                bounds: selectionBounds(in: element),
                isEditable: editableElement != nil,
                focusedElement: element,
                editableElement: editableElement,
                selectedRange: selectedTextRange(in: element)
            )
        }

        return try await selectionUsingClipboard(element: element, application: application)
    }

    func replace(_ selection: Selection, with text: String) throws {
        if let element = selection.focusedElement, setSelectedText(text, in: element) {
            return
        }

        if let element = selection.editableElement, setSelectedText(text, in: element) {
            return
        }

        throw SelectionError.selectionUnavailable
    }

    func prepareForReplacement(
        _ selection: Selection,
        in application: NSRunningApplication?
    ) async {
        application?.activate(options: [])
        try? await Task.sleep(for: .milliseconds(120))

        if let focusedElement = selection.focusedElement {
            AXUIElementSetAttributeValue(
                focusedElement,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            restoreSelectedRange(selection.selectedRange, in: focusedElement)
        } else if let editableElement = selection.editableElement {
            AXUIElementSetAttributeValue(
                editableElement,
                kAXFocusedAttribute as CFString,
                kCFBooleanTrue
            )
            restoreSelectedRange(selection.selectedRange, in: editableElement)
        }
    }

    private func selectedText(in element: AXUIElement) -> String? {
        var selectedTextValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextValue
        ) == .success,
        let text = selectedTextValue as? String,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }

    private func selectionUsingClipboard(
        element: AXUIElement?,
        application: NSRunningApplication?
    ) async throws -> Selection {
        let pasteboard = NSPasteboard.general
        let snapshot = ClipboardSnapshot.capture(from: pasteboard)
        defer { snapshot.restore(to: pasteboard) }

        pasteboard.clearContents()
        try sendCopyCommand()
        try? await Task.sleep(for: .milliseconds(120))

        guard
            let text = pasteboard.string(forType: .string),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw SelectionError.selectionUnavailable
        }

        let editableElement = element.flatMap(editableElement)
        return Selection(
            text: text,
            bounds: element.flatMap(selectionBounds),
            isEditable: editableElement != nil,
            focusedElement: element,
            editableElement: editableElement,
            selectedRange: element.flatMap(selectedTextRange)
        )
    }

    private func setSelectedText(_ text: String, in element: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        ) == .success
    }

    private func restoreSelectedRange(_ range: AXValue?, in element: AXUIElement) {
        guard let range else { return }
        AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            range
        )
    }

    private func selectedTextRange(in element: AXUIElement) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }
        return (value as! AXValue)
    }

    private func sendCopyCommand() throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false)
        else {
            throw SelectionError.selectionUnavailable
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func focusedElement() throws -> AXUIElement {
        let systemWideElement = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else {
            throw SelectionError.selectionUnavailable
        }
        return value as! AXUIElement
    }

    private func editableElement(for element: AXUIElement) -> AXUIElement? {
        if isDirectlyEditable(element) {
            return element
        }

        var ancestorValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            "AXEditableAncestor" as CFString,
            &ancestorValue
        ) == .success,
        let ancestorValue,
        CFGetTypeID(ancestorValue) == AXUIElementGetTypeID() {
            return (ancestorValue as! AXUIElement)
        }

        var current = element
        for _ in 0..<8 {
            guard let parent = parent(of: current) else { break }
            if isDirectlyEditable(parent) {
                return parent
            }
            current = parent
        }

        return nil
    }

    private func isDirectlyEditable(_ element: AXUIElement) -> Bool {
        var isSelectedTextSettable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &isSelectedTextSettable
        ) == .success, isSelectedTextSettable.boolValue {
            return true
        }

        var roleValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success,
        let role = roleValue as? String,
        [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(role) {
            return true
        }

        var isValueSettable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(
            element,
            kAXValueAttribute as CFString,
            &isValueSettable
        ) == .success && isValueSettable.boolValue
    }

    private func parent(of element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXParentAttribute as CFString,
            &value
        ) == .success,
        let value,
        CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func selectionBounds(in element: AXUIElement) -> CGRect? {
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &rangeValue
        ) == .success,
        let rangeValue,
        CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return nil
        }

        var boundsValue: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            rangeValue,
            &boundsValue
        ) == .success,
        let boundsValue,
        CFGetTypeID(boundsValue) == AXValueGetTypeID() else {
            return nil
        }

        var bounds = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &bounds) else { return nil }
        return bounds
    }
}
