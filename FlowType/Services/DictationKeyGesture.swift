import Foundation

/// Reads presses of the dictation key: hold it to dictate, or double-press
/// it to keep recording without holding, until it is pressed once more.
///
/// Recording starts on the first press either way, so holding never waits
/// to see whether a second press comes. A press too short to be a dictation
/// is what waits instead, for `secondPressWindow`. A second press that is
/// held is a hold after all, and a hands-free recording finishes on the
/// release, so a shortcut made with the key can leave it running.
struct DictationKeyGesture {
    enum Step {
        case none
        case start
        case finish
        case cancel
        /// Call `secondPressTimedOut` after `secondPressWindow`, unless
        /// another step comes first.
        case awaitSecondPress
    }

    /// A hands-free recording is `idle` too: only the next press matters.
    private enum State {
        case idle
        case holding(since: TimeInterval)
        case awaitingSecondPress
        case heldAgain(since: TimeInterval)
        /// The press that will finish a hands-free recording, once released.
        case stopping
    }

    /// A shorter press counts as the first half of a double press.
    static let tapLength: TimeInterval = 0.3
    static let secondPressWindow: Duration = .milliseconds(300)

    private var state = State.idle

    /// `isRecording` is checked rather than remembered: Escape or an error
    /// can end a recording while the key is up.
    mutating func press(at time: TimeInterval, isRecording: Bool) -> Step {
        guard isRecording else {
            state = .holding(since: time)
            return .start
        }

        switch state {
        case .awaitingSecondPress:
            state = .heldAgain(since: time)
        case .idle:
            state = .stopping
        case .holding, .heldAgain, .stopping:
            break
        }
        return .none
    }

    mutating func release(at time: TimeInterval, allowsHandsFree: Bool) -> Step {
        switch state {
        case .holding(let since):
            if allowsHandsFree && time - since < Self.tapLength {
                state = .awaitingSecondPress
                return .awaitSecondPress
            }
            state = .idle
            return .finish
        case .heldAgain(let since):
            state = .idle
            return time - since < Self.tapLength ? .none : .finish
        case .stopping:
            state = .idle
            return .finish
        case .idle, .awaitingSecondPress:
            return .none
        }
    }

    /// Another key or a mouse button: while the key is held, that makes it
    /// a shortcut like ⌘C and not a dictation.
    mutating func interrupted() -> Step {
        switch state {
        case .holding, .heldAgain:
            state = .idle
            return .cancel
        case .stopping:
            state = .idle
            return .none
        case .idle, .awaitingSecondPress:
            return .none
        }
    }

    mutating func secondPressTimedOut() -> Step {
        guard case .awaitingSecondPress = state else { return .none }
        state = .idle
        return .finish
    }
}
