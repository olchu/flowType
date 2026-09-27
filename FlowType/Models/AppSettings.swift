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
            "Keeps only the basic WhisperKit text cleanup."
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

struct AppSettings: Codable, Equatable {
    var profile: TranscriptionProfile = .balanced
    var language: TranscriptionLanguage = .auto
    var finalizationMode: TranscriptionFinalizationMode = .streamTail
    var cleanupMode: TranscriptCleanupMode = .localRules
    var cleanupModel: CleanupLLMModel = .qwen25_1_5B
    var autoPaste = true
    var restoreClipboard = true
    var microphoneSensitivity = 0.5

    private enum CodingKeys: String, CodingKey {
        case profile
        case language
        case finalizationMode
        case cleanupMode
        case cleanupModel
        case autoPaste
        case restoreClipboard
        case microphoneSensitivity
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profile = try container.decodeIfPresent(TranscriptionProfile.self, forKey: .profile) ?? .balanced
        language = try container.decodeIfPresent(TranscriptionLanguage.self, forKey: .language) ?? .auto
        finalizationMode = try container.decodeIfPresent(TranscriptionFinalizationMode.self, forKey: .finalizationMode) ?? .streamTail
        cleanupMode = try container.decodeIfPresent(TranscriptCleanupMode.self, forKey: .cleanupMode) ?? .localRules
        cleanupModel = (try? container.decodeIfPresent(CleanupLLMModel.self, forKey: .cleanupModel)) ?? .qwen25_1_5B
        autoPaste = try container.decodeIfPresent(Bool.self, forKey: .autoPaste) ?? true
        restoreClipboard = try container.decodeIfPresent(Bool.self, forKey: .restoreClipboard) ?? true
        microphoneSensitivity = try container.decodeIfPresent(Double.self, forKey: .microphoneSensitivity) ?? 0.5
    }
}
