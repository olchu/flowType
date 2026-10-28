import Foundation

enum TranscriptionFinalizationMode: String, Codable, CaseIterable, Identifiable {
    case streamTail = "Stream + tail"
    case fullRecording = "Full recording"
    case streamOnly = "Stream only"

    var id: Self { self }

    var detail: String {
        switch self {
        case .streamTail:
            "Current mode. Keeps confirmed streaming text and re-decodes only the unconfirmed ending."
        case .fullRecording:
            "Baseline mode. Transcribes the whole recording after you release Fn."
        case .streamOnly:
            "Fastest mode. Uses only streaming text, so the final words may be less reliable."
        }
    }
}

enum TranscriptCleanupMode: String, Codable, CaseIterable, Identifiable {
    case localRules = "Local rules"
    case localLLM = "Local LLM"
    case off = "Off"

    var id: Self { self }

    var detail: String {
        switch self {
        case .localRules:
            "Fast built-in cleanup for duplicate fragments and Whisper artifacts."
        case .localLLM:
            "Local rules plus an on-device model for punctuation and obvious recognition errors. Edits that add or drop words are rejected."
        case .off:
            "Keeps only the basic WhisperKit text cleanup. Text rules still apply."
        }
    }
}

enum CleanupLLMModel: String, Codable, CaseIterable, Identifiable {
    case qwen25_1_5B = "Qwen2.5 1.5B"
    case qwen35_2B = "Qwen3.5 2B"
    case qwen3_4B = "Qwen3 4B"
    case gemma4E2B = "Gemma 4 E2B"

    var id: Self { self }

    var detail: String {
        switch self {
        case .qwen25_1_5B:
            "0.9 GB. Fastest, weakest Russian; best for short phrases."
        case .qwen35_2B:
            "1.7 GB. Newer small model, noticeably better Russian."
        case .qwen3_4B:
            "2.3 GB. Most careful edits, about twice as slow as 1.5B."
        case .gemma4E2B:
            "3.6 GB. Strong multilingual model from Google."
        }
    }
}

enum IndicatorStyle: String, Codable, CaseIterable, Identifiable {
    case bars = "Bars"
    case waves = "Waves"
    case dots = "Dots"
    case aurora = "Aurora"
    case particles = "Particles"

    var id: Self { self }
}

/// Colours of the aurora indicator's smoke and glass; the colours live in
/// AuroraIndicatorView.
enum AuroraPalette: String, Codable, CaseIterable, Identifiable {
    case nebula = "Nebula"
    case ocean = "Ocean"
    case ember = "Ember"
    case borealis = "Borealis"

    var id: Self { self }
}

/// What the floating indicator looks like: its style, and the colours of
/// the styles that have them.
struct IndicatorAppearance: Equatable {
    var style: IndicatorStyle = .bars
    var waveColor: WaveColor = .blue
    var auroraPalette: AuroraPalette = .nebula
}

/// Colour theme of the waves indicator; palettes live in WaveIndicatorView.
enum WaveColor: String, Codable, CaseIterable, Identifiable {
    case blue = "Blue"
    case red = "Red"
    case yellow = "Yellow"
    case green = "Green"
    case violet = "Violet"

    var id: Self { self }
}

struct AppSettings: Codable, Equatable {
    var profile: TranscriptionProfile = .balanced
    var language: TranscriptionLanguage = .auto
    var finalizationMode: TranscriptionFinalizationMode = .streamTail
    var cleanupMode: TranscriptCleanupMode = .localRules
    var cleanupModel: CleanupLLMModel = .qwen25_1_5B
    var removesFillerWords = true
    var fillerWords = FillerWords.defaults
    var writesNumbersAsDigits = true
    var keepsSmallNumbersAsWords = true
    var autoPaste = true
    var restoreClipboard = true
    var microphoneSensitivity = 0.5
    var indicatorStyle: IndicatorStyle = .bars
    var waveColor: WaveColor = .blue
    var auroraPalette: AuroraPalette = .nebula
    /// The indicator's centre where the user placed it, in global screen
    /// coordinates, so it fits every style whatever its size; nil above the
    /// Dock.
    var indicatorPosition: CGPoint?
    var playsSounds = true
    /// Scales every feedback cue; 0.5 is the recommended level.
    var soundVolume = 0.5

    init() {}

    var textRules: TextRules {
        TextRules(
            removesFillerWords: removesFillerWords,
            fillerWords: fillerWords,
            writesNumbersAsDigits: writesNumbersAsDigits,
            keepsSmallNumbersAsWords: keepsSmallNumbersAsWords
        )
    }

    var indicatorAppearance: IndicatorAppearance {
        IndicatorAppearance(style: indicatorStyle, waveColor: waveColor, auroraPalette: auroraPalette)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        profile = try container.decodeIfPresent(TranscriptionProfile.self, forKey: .profile) ?? defaults.profile
        language = try container.decodeIfPresent(TranscriptionLanguage.self, forKey: .language) ?? defaults.language
        finalizationMode = try container.decodeIfPresent(TranscriptionFinalizationMode.self, forKey: .finalizationMode) ?? defaults.finalizationMode
        cleanupMode = try container.decodeIfPresent(TranscriptCleanupMode.self, forKey: .cleanupMode) ?? defaults.cleanupMode
        cleanupModel = (try? container.decodeIfPresent(CleanupLLMModel.self, forKey: .cleanupModel)) ?? defaults.cleanupModel
        removesFillerWords = try container.decodeIfPresent(Bool.self, forKey: .removesFillerWords) ?? defaults.removesFillerWords
        fillerWords = try container.decodeIfPresent([String].self, forKey: .fillerWords) ?? defaults.fillerWords
        writesNumbersAsDigits = try container.decodeIfPresent(Bool.self, forKey: .writesNumbersAsDigits) ?? defaults.writesNumbersAsDigits
        keepsSmallNumbersAsWords = try container.decodeIfPresent(Bool.self, forKey: .keepsSmallNumbersAsWords) ?? defaults.keepsSmallNumbersAsWords
        autoPaste = try container.decodeIfPresent(Bool.self, forKey: .autoPaste) ?? defaults.autoPaste
        restoreClipboard = try container.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? defaults.restoreClipboard
        microphoneSensitivity = try container.decodeIfPresent(Double.self, forKey: .microphoneSensitivity) ?? defaults.microphoneSensitivity
        indicatorStyle = (try? container.decodeIfPresent(IndicatorStyle.self, forKey: .indicatorStyle)) ?? defaults.indicatorStyle
        waveColor = (try? container.decodeIfPresent(WaveColor.self, forKey: .waveColor)) ?? defaults.waveColor
        auroraPalette = (try? container.decodeIfPresent(AuroraPalette.self, forKey: .auroraPalette)) ?? defaults.auroraPalette
        indicatorPosition = try? container.decodeIfPresent(CGPoint.self, forKey: .indicatorPosition)
        playsSounds = try container.decodeIfPresent(Bool.self, forKey: .playsSounds) ?? defaults.playsSounds
        soundVolume = try container.decodeIfPresent(Double.self, forKey: .soundVolume) ?? defaults.soundVolume
    }
}
