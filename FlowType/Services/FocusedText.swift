import AppKit
import ApplicationServices

extension AXUIElement {
    /// The focused element of `application`, or of whichever app is in
    /// front when it's nil.
    static func focused(in application: NSRunningApplication?) -> AXUIElement? {
        guard let application = application ?? NSWorkspace.shared.frontmostApplication else { return nil }
        let owner = AXUIElementCreateApplication(application.processIdentifier)
        // An app that hangs would otherwise hold the paste for six seconds.
        // Set per app: on the system-wide element it would apply to every
        // Accessibility call Flow Type makes.
        AXUIElementSetMessagingTimeout(owner, 0.25)
        let element = owner.element(kAXFocusedUIElementAttribute)
        element.map { AXUIElementSetMessagingTimeout($0, 0.25) }
        return element
    }

    func element(_ attribute: String) -> AXUIElement? {
        guard let value = value(attribute), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    func string(_ attribute: String) -> String? {
        value(attribute) as? String
    }

    var children: [AXUIElement] {
        value(kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    var selectedRange: CFRange? {
        guard let value = value(kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range) else { return nil }
        return range
    }

    /// Selects `range`; true if the field took the selection.
    func select(_ range: CFRange) -> Bool {
        var range = range
        guard let value = AXValueCreate(.cfRange, &range),
              AXUIElementSetAttributeValue(self, kAXSelectedTextRangeAttribute as CFString, value) == .success
        else {
            return false
        }
        return selectedRange.map { $0.location == range.location && $0.length == range.length } ?? false
    }

    /// Types `text` over the selection, or at the cursor.
    func replaceSelection(with text: String) -> Bool {
        AXUIElementSetAttributeValue(self, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
    }

    /// The text in `range` of a text field, in UTF-16 units.
    func string(in range: CFRange) -> String? {
        guard range.length > 0 else { return "" }
        var range = range
        guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(self, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success else {
            return nil
        }
        return value as? String
    }

    var characterCount: Int? {
        value(kAXNumberOfCharactersAttribute) as? Int
    }

    private func value(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(self, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}

/// The text around the cursor in the focused field of another app, read
/// through Accessibility. Electron apps and some browsers don't expose it.
struct FocusedText {
    let element: AXUIElement
    /// Up to `beforeLength` UTF-16 units before the cursor, or before the
    /// selection, which the paste replaces.
    let before: String
    /// Up to 256 UTF-16 units after the cursor or the selection.
    let after: String
    /// Where the cursor or the selection starts, in UTF-16 units.
    let location: Int

    /// Nil when the app has no focused text field or it doesn't tell its
    /// text. Reads only around the cursor, not a long document whole.
    static func read(in application: NSRunningApplication?, beforeLength: Int = 256) -> FocusedText? {
        guard AXIsProcessTrusted(),
              let element = AXUIElement.focused(in: application),
              let selection = element.selectedRange
        else {
            return nil
        }

        let location = max(selection.location, 0)
        let end = location + max(selection.length, 0)
        let start = max(0, location - beforeLength)
        if let count = element.characterCount, end <= count,
           let before = element.string(in: CFRange(location: start, length: location - start)),
           let after = element.string(in: CFRange(location: end, length: min(256, count - end))) {
            return FocusedText(element: element, before: before, after: after, location: location)
        }

        // Fields without ranged reads tell only their whole text.
        guard let value = element.string(kAXValueAttribute) else { return nil }
        let text = value as NSString
        let clampedLocation = min(location, text.length)
        let clampedStart = min(start, clampedLocation)
        let clampedEnd = min(end, text.length)
        return FocusedText(
            element: element,
            before: text.substring(with: NSRange(location: clampedStart, length: clampedLocation - clampedStart)),
            after: text.substring(with: NSRange(location: clampedEnd, length: min(256, text.length - clampedEnd))),
            location: clampedLocation
        )
    }
}
