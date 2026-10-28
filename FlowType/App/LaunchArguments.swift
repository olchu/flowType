import AppKit

/// Command-line flags for working on the app without clicking through it:
///
/// - `--open-settings` opens the settings window at launch, and
///   `--settings-pane models` picks the pane;
/// - `--appearance dark` or `light` overrides the system appearance;
/// - `--cleanup-transcript "…"` and `--prewarm-cleanup-model` run the text
///   cleanup from the command line, with `--cleanup-model "Qwen3 4B"`.
enum LaunchArguments {
    static let opensSettings = has("--open-settings")
    static let settingsPane = value(after: "--settings-pane").flatMap(SettingsPane.init(rawValue:))
    static let appearance: NSAppearance? = switch value(after: "--appearance") {
    case "dark": NSAppearance(named: .darkAqua)
    case "light": NSAppearance(named: .aqua)
    default: nil
    }
    static let cleanupTranscript = value(after: "--cleanup-transcript")
    static let prewarmsCleanupModel = has("--prewarm-cleanup-model")
    static let cleanupModel = value(after: "--cleanup-model").flatMap(CleanupLLMModel.init(rawValue:))

    private static func has(_ flag: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
    }

    private static func value(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
