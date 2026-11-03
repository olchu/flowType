import AppKit

/// Command-line flags for working on the app without clicking through it:
///
/// - `--open-settings` opens the settings window at launch, and
///   `--settings-pane models` picks the pane;
/// - `--appearance dark` or `light` overrides the system appearance;
/// - `--cleanup-transcript "…"` and `--prewarm-cleanup-model` run the text
///   cleanup from the command line, with `--cleanup-model "Qwen3 4B"`, or
///   with `--cleanup-mode "External LLM"` through the model in the settings;
/// - `--record-indicator Aurora` writes the indicator's frames as PNGs to
///   `--record-output dir`, with `--indicator-color Violet` (or a palette),
///   `--record-scale 3` and `--record-background 0d1322`.
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
    static let cleanupMode = value(after: "--cleanup-mode").flatMap(TranscriptCleanupMode.init(rawValue:))
    /// An IndicatorStyle raw value, checked by IndicatorRecorder.
    static let recordedIndicator = value(after: "--record-indicator")
    static let recordOutput = value(after: "--record-output") ?? "indicator-frames"
    static let recordScale = max(1, value(after: "--record-scale").flatMap(Int.init) ?? 2)
    static let recordBackground: CGColor = value(after: "--record-background")
        .flatMap { UInt32($0, radix: 16) }
        .map { CGColor(srgbRed: CGFloat($0 >> 16 & 0xFF) / 255, green: CGFloat($0 >> 8 & 0xFF) / 255, blue: CGFloat($0 & 0xFF) / 255, alpha: 1) }
        ?? .black
    static let indicatorColor = value(after: "--indicator-color")

    private static func has(_ flag: String) -> Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
    }

    private static func value(after flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
