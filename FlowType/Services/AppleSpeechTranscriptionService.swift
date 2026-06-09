import AVFoundation
import Foundation
import Speech

final class AppleSpeechTranscriptionService {
    enum AppleSpeechError: LocalizedError {
        case authorizationDenied
        case recognizerUnavailable
        case emptyTranscript
        case couldNotCreateAudioBuffer

        var errorDescription: String? {
            switch self {
            case .authorizationDenied:
                "Speech recognition permission is required for Intel transcription."
            case .recognizerUnavailable:
                "Apple Speech recognition is not available for the selected language."
            case .emptyTranscript:
                "Apple Speech did not return any text."
            case .couldNotCreateAudioBuffer:
                "Could not prepare recorded audio for Apple Speech."
            }
        }
    }

    func transcribe(_ audio: RecordedAudio, language: TranscriptionLanguage) async throws -> String {
        try await requestAuthorizationIfNeeded()

        let audioURL = try writeTemporaryAudioFile(from: audio)
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        let transcript = try await transcript(
            from: audioURL,
            candidateLocales: candidateLocales(for: language)
        )

        guard !transcript.isEmpty else {
            throw AppleSpeechError.emptyTranscript
        }

        return transcript
    }

    private func transcript(from audioURL: URL, candidateLocales: [Locale]) async throws -> String {
        var lastError: Error?

        for locale in candidateLocales {
            guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
                continue
            }

            let request = SFSpeechURLRecognitionRequest(url: audioURL)
            request.shouldReportPartialResults = true
            request.taskHint = .dictation
            if recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }

            do {
                let transcript = try await recognitionResult(for: request, recognizer: recognizer)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !transcript.isEmpty {
                    return transcript
                }
            } catch {
                lastError = error
            }
        }

        if let lastError {
            throw lastError
        }

        throw AppleSpeechError.recognizerUnavailable
    }

    private func requestAuthorizationIfNeeded() async throws {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:
            return
        case .notDetermined:
            let status = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            guard status == .authorized else {
                throw AppleSpeechError.authorizationDenied
            }
        case .denied, .restricted:
            throw AppleSpeechError.authorizationDenied
        @unknown default:
            throw AppleSpeechError.authorizationDenied
        }
    }

    private func recognitionResult(
        for request: SFSpeechURLRecognitionRequest,
        recognizer: SFSpeechRecognizer
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let lock = NSLock()
            var didResume = false
            var latestTranscript = ""
            var task: SFSpeechRecognitionTask?

            func resumeOnce(with result: Result<String, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !didResume else { return }
                didResume = true
                task?.cancel()

                switch result {
                case .success(let transcript):
                    continuation.resume(returning: transcript)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            task = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    latestTranscript = result.bestTranscription.formattedString
                    if result.isFinal {
                        resumeOnce(with: .success(latestTranscript))
                    }
                    return
                }

                if let error {
                    if latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        resumeOnce(with: .failure(error))
                    } else {
                        resumeOnce(with: .success(latestTranscript))
                    }
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
                if latestTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    resumeOnce(with: .failure(AppleSpeechError.emptyTranscript))
                } else {
                    resumeOnce(with: .success(latestTranscript))
                }
            }
        }
    }

    private func candidateLocales(for language: TranscriptionLanguage) -> [Locale] {
        switch language {
        case .russian:
            return [Locale(identifier: "ru_RU")]
        case .english:
            return [Locale(identifier: "en_US")]
        case .auto:
            let preferredLocales = Locale.preferredLanguages.map(Locale.init(identifier:))
            return uniqueLocales([Locale(identifier: "ru_RU")] + preferredLocales + [.current, Locale(identifier: "en_US")])
        }
    }

    private func uniqueLocales(_ locales: [Locale]) -> [Locale] {
        var seen = Set<String>()
        return locales.filter { locale in
            let identifier = locale.identifier
            guard !seen.contains(identifier) else { return false }
            seen.insert(identifier)
            return true
        }
    }

    private func writeTemporaryAudioFile(from audio: RecordedAudio) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "FlowType-\(UUID().uuidString)")
            .appendingPathExtension("caf")

        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: audio.sampleRate,
            channels: 1,
            interleaved: false
        ), let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(audio.samples.count)
        ), let channelData = buffer.floatChannelData else {
            throw AppleSpeechError.couldNotCreateAudioBuffer
        }

        buffer.frameLength = AVAudioFrameCount(audio.samples.count)
        audio.samples.withUnsafeBufferPointer { samples in
            channelData[0].update(from: samples.baseAddress!, count: samples.count)
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }
}
