import AppKit

/// Puts dictations into the app the user is typing in: fits each one to the
/// text around the cursor, pastes it, and can take the last one back out.
final class TextInserter {
    enum Fitting {
        /// Capitals, spaces and the full stop follow the text around the
        /// cursor.
        case full
        /// Exactly as written, as a snippet is: only the spaces around it.
        case spacesOnly
        case none
    }

    /// A dictation as it went into a field.
    private struct Insertion {
        let text: String
        let processID: pid_t?
        /// The field, when it told its text.
        let element: AXUIElement?
        let time: ContinuousClock.Instant
    }

    /// Typing or clicking forgets the last dictation at once; past this the
    /// cursor is unlikely to be after it even without either.
    private static let insertionLifetime: Duration = .seconds(120)

    private let pasteService = PasteService()
    private var lastInsertion: Insertion?

    /// `keptSpellings` are the user's own: the dictionary's and the
    /// snippets', whose capitals fitting leaves alone.
    func paste(
        _ text: String,
        into application: NSRunningApplication?,
        restoreClipboard: Bool,
        fitting: Fitting,
        keptSpellings: [String] = []
    ) async throws {
        // Fitted once the app is in front, so its focused field is the one
        // the text goes into.
        await pasteService.activate(application)
        let focused = fitting == .none ? nil : FocusedText.read(in: application)
        var fitted = text
        if fitting != .none {
            // Where the field doesn't tell its text, the cursor is most
            // likely still just after the last dictation pasted into it.
            let before = focused?.before ?? recentInsertion(in: application)?.text
            let keepsWording = fitting == .spacesOnly || keptSpellings.contains { !$0.isEmpty && text.hasPrefix($0) }
            fitted = InsertionFitting.fit(text, before: before, after: focused?.after, keepsWording: keepsWording)
        }
        try await pasteService.pasteText(fitted, restoreClipboard: restoreClipboard, into: application)
        lastInsertion = Insertion(text: fitted, processID: application?.processIdentifier, element: focused?.element, time: .now)
    }

    func copy(_ text: String) {
        pasteService.copyText(text)
    }

    /// The user typed or clicked: the cursor may no longer be after the last
    /// dictation.
    func forgetLastInsertion() {
        lastInsertion = nil
    }

    /// Takes the last dictation back out of the app in front. Only in the
    /// same app, and where the field tells its text, only from the same
    /// field while the dictation is still just before the cursor. False
    /// when it can't be sure the text is still there.
    func undo() -> Bool {
        let application = NSWorkspace.shared.frontmostApplication
        guard let insertion = recentInsertion(in: application) else { return false }

        let length = insertion.text.utf16.count
        if let focused = FocusedText.read(in: application, beforeLength: length) {
            guard focused.before.hasSuffix(insertion.text),
                  insertion.element.map({ CFEqual($0, focused.element) }) ?? true
            else {
                return false
            }
            if focused.element.select(CFRange(location: focused.location - length, length: length)) {
                // Some fields take the selection but not text set through
                // Accessibility; one Backspace clears the selection there.
                guard focused.element.replaceSelection(with: "") || (try? pasteService.deleteBackward(count: 1)) != nil else {
                    return false
                }
                lastInsertion = nil
                return true
            }
        } else if insertion.element != nil {
            // The field told its text when the dictation went in and doesn't
            // now: the focus has moved on.
            return false
        }

        do {
            try pasteService.deleteBackward(count: insertion.text.count)
        } catch {
            return false
        }
        lastInsertion = nil
        return true
    }

    private func recentInsertion(in application: NSRunningApplication?) -> Insertion? {
        guard let insertion = lastInsertion,
              insertion.processID == application?.processIdentifier,
              .now - insertion.time < Self.insertionLifetime
        else {
            return nil
        }
        return insertion
    }
}
