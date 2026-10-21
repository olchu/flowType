import Accelerate
import CoreML
import Foundation

/// Sber's GigaAM v3 (end-to-end CTC) running through Core ML: Russian only,
/// noticeably more accurate on Russian than Whisper, and it writes
/// punctuation and capitals itself. It decodes a finished recording, so like
/// Parakeet it has no streaming preview.
///
/// The Core ML package takes log-mel features in a fixed 25 s window and
/// returns per-frame token log-probabilities; the feature extraction, the
/// chunking of longer recordings and the greedy CTC decoding live here.
actor GigaAMTranscriber {
    enum GigaAMError: LocalizedError {
        case missingFiles
        case unexpectedOutput

        var errorDescription: String? {
            switch self {
            case .missingFiles:
                "The GigaAM model files are missing; download the model again."
            case .unexpectedOutput:
                "The GigaAM model returned output in an unexpected shape."
            }
        }
    }

    /// Core ML conversion of `v3_e2e_ctc`, pinned to the revision the
    /// feature extraction below was written against.
    static let repository = "inhum/gigaam-v3-coreml"
    private static let revision = "43dc96918bc232deafa7b7d0600fb499806f7ac1"
    private static let packageName = "gigaam_v3_e2e.mlpackage"
    private static let compiledName = "gigaam_v3_e2e.mlmodelc"
    private static let filterbankName = "gigaam-melfb.f32"
    private static let windowName = "gigaam-window.f32"
    private static let vocabularyName = "gigaam-vocab.txt"
    private static let files = [
        filterbankName,
        windowName,
        vocabularyName,
        "\(packageName)/Manifest.json",
        "\(packageName)/Data/com.apple.CoreML/model.mlmodel",
        "\(packageName)/Data/com.apple.CoreML/weights/weight.bin",
    ]

    // The checkpoint's own feature configuration; see the model card.
    private static let sampleRate = 16_000
    private static let fftSize = 320
    private static let hopLength = 160
    private static let bins = fftSize / 2 + 1
    private static let melCount = 64
    /// The model's fixed input: 25 s of audio, 2499 feature frames.
    private static let windowSamples = 25 * sampleRate
    private static let windowFrames = (windowSamples - fftSize) / hopLength + 1
    private static let blank = 256

    private struct Loaded {
        let model: MLModel
        let window: [Float]
        /// Mel filterbank, bins x mels: one matrix product turns a chunk's
        /// power spectra into mel energies.
        let filterbank: [Float]
        let vocabulary: [String]
        /// Real and imaginary DFT bases, samples x bins.
        let cosines: [Float]
        let sines: [Float]
    }

    private var loaded: Loaded?

    nonisolated static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "huggingface/models")
            .appending(path: repository)
    }

    nonisolated static var isDownloaded: Bool {
        files.allSatisfy { FileManager.default.fileExists(atPath: directory.appending(path: $0).path) }
    }

    /// Downloads the files that are missing; the weights are about 420 MB.
    nonisolated static func download() async throws {
        for file in files {
            let destination = directory.appending(path: file)
            guard !FileManager.default.fileExists(atPath: destination.path) else { continue }
            let url = URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(file)")!
            let (temporary, response) = try await URLSession.shared.download(from: url)
            if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
                throw URLError(.badServerResponse)
            }
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: temporary, to: destination)
        }
    }

    func prewarm() async throws {
        _ = try await loadedModel()
    }

    func unload() {
        loaded = nil
    }

    /// - Parameter samples: 16 kHz mono audio.
    func transcribe(_ samples: [Float]) async throws -> String {
        let loaded = try await loadedModel()
        var pieces: [String] = []
        for chunk in Self.chunks(of: samples) {
            let text = try await transcribe(chunk: chunk, with: loaded)
            if !text.isEmpty {
                pieces.append(text)
            }
        }
        return pieces.joined(separator: " ")
    }

    // MARK: - Loading

    private func loadedModel() async throws -> Loaded {
        if let loaded {
            return loaded
        }
        guard Self.isDownloaded else {
            throw GigaAMError.missingFiles
        }

        let directory = Self.directory
        // Compiled once and kept next to the package: compiling takes a few
        // seconds on every load otherwise.
        let compiled = directory.appending(path: Self.compiledName)
        if !FileManager.default.fileExists(atPath: compiled.path) {
            let temporary = try await MLModel.compileModel(at: directory.appending(path: Self.packageName))
            try FileManager.default.moveItem(at: temporary, to: compiled)
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let model = try await MLModel.load(contentsOf: compiled, configuration: configuration)

        let window = try Self.floats(at: directory.appending(path: Self.windowName))
        // Stored bins x mels, as torchaudio keeps it, whatever the model card
        // says.
        let filterbank = try Self.floats(at: directory.appending(path: Self.filterbankName))
        let vocabulary = try String(contentsOf: directory.appending(path: Self.vocabularyName), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard
            window.count == Self.fftSize,
            filterbank.count == Self.melCount * Self.bins,
            vocabulary.count >= Self.blank
        else {
            throw GigaAMError.missingFiles
        }

        var cosines = [Float](repeating: 0, count: Self.fftSize * Self.bins)
        var sines = [Float](repeating: 0, count: Self.fftSize * Self.bins)
        for n in 0..<Self.fftSize {
            for k in 0..<Self.bins {
                let angle = 2 * Double.pi * Double(n * k) / Double(Self.fftSize)
                cosines[n * Self.bins + k] = Float(cos(angle))
                sines[n * Self.bins + k] = Float(sin(angle))
            }
        }

        let result = Loaded(
            model: model,
            window: window,
            filterbank: filterbank,
            vocabulary: vocabulary,
            cosines: cosines,
            sines: sines
        )
        loaded = result
        return result
    }

    private static func floats(at url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    // MARK: - Recognition

    private func transcribe(chunk: ArraySlice<Float>, with loaded: Loaded) async throws -> String {
        let frameCount = (chunk.count - Self.fftSize) / Self.hopLength + 1
        guard frameCount > 0 else { return "" }

        // Zero-padded to the fixed window, as the model was traced; the real
        // frame count tells it where the audio ends.
        var audio = [Float](repeating: 0, count: Self.windowSamples)
        audio.replaceSubrange(0..<chunk.count, with: chunk)
        let features = try Self.features(of: audio, with: loaded)
        let lengths = try MLMultiArray(shape: [1], dataType: .int32)
        lengths[0] = NSNumber(value: frameCount)

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "features": MLFeatureValue(multiArray: features),
            "feature_lengths": MLFeatureValue(multiArray: lengths),
        ])
        let output = try await loaded.model.prediction(from: input)
        return try Self.decode(output, vocabulary: loaded.vocabulary)
    }

    /// Log-mel features of exactly one window of audio, mels x frames.
    private static func features(of audio: [Float], with loaded: Loaded) throws -> MLMultiArray {
        let frames = windowFrames

        // Windowed frames, frames x samples.
        var framed = [Float](repeating: 0, count: frames * fftSize)
        audio.withUnsafeBufferPointer { audio in
            framed.withUnsafeMutableBufferPointer { framed in
                for frame in 0..<frames {
                    vDSP_vmul(
                        audio.baseAddress! + frame * hopLength, 1,
                        loaded.window, 1,
                        framed.baseAddress! + frame * fftSize, 1,
                        vDSP_Length(fftSize)
                    )
                }
            }
        }

        // Power spectrum through the DFT bases, frames x bins.
        var real = [Float](repeating: 0, count: frames * bins)
        var imaginary = [Float](repeating: 0, count: frames * bins)
        vDSP_mmul(framed, 1, loaded.cosines, 1, &real, 1, vDSP_Length(frames), vDSP_Length(bins), vDSP_Length(fftSize))
        vDSP_mmul(framed, 1, loaded.sines, 1, &imaginary, 1, vDSP_Length(frames), vDSP_Length(bins), vDSP_Length(fftSize))
        var power = [Float](repeating: 0, count: frames * bins)
        vDSP_vmma(real, 1, real, 1, imaginary, 1, imaginary, 1, &power, 1, vDSP_Length(power.count))

        // Mel energies, frames x mels, then log(clamp(x, 1e-9, 1e9)).
        var mels = [Float](repeating: 0, count: frames * melCount)
        vDSP_mmul(power, 1, loaded.filterbank, 1, &mels, 1, vDSP_Length(frames), vDSP_Length(melCount), vDSP_Length(bins))
        var low: Float = 1e-9
        var high: Float = 1e9
        vDSP_vclip(mels, 1, &low, &high, &mels, 1, vDSP_Length(mels.count))
        var count = Int32(mels.count)
        vvlogf(&mels, mels, &count)

        // The model wants mels x frames.
        let features = try MLMultiArray(shape: [1, NSNumber(value: melCount), NSNumber(value: frames)], dataType: .float32)
        let pointer = features.dataPointer.assumingMemoryBound(to: Float.self)
        vDSP_mtrans(mels, 1, pointer, 1, vDSP_Length(melCount), vDSP_Length(frames))
        return features
    }

    /// Greedy CTC: the best token per frame, repeats collapsed, blanks and
    /// `<unk>` dropped; `▁` starts a new word.
    private static func decode(_ output: MLFeatureProvider, vocabulary: [String]) throws -> String {
        // Output names come from the converter; the 3-D tensor is the logits
        // and the 1-D one the number of valid frames.
        let arrays = output.featureNames.compactMap { output.featureValue(for: $0)?.multiArrayValue }
        guard
            let logits = arrays.first(where: { $0.shape.count == 3 }),
            let lengths = arrays.first(where: { $0.shape.count == 1 })
        else {
            throw GigaAMError.unexpectedOutput
        }

        let frames = min(lengths[0].intValue, logits.shape[1].intValue)
        let tokens = logits.shape[2].intValue
        let frameStride = logits.strides[1].intValue
        let tokenStride = logits.strides[2].intValue
        // The package says float32, but the converted weights are fp16 and
        // so is the output.
        let value: (Int) -> Float
        switch logits.dataType {
        case .float16:
            let pointer = logits.dataPointer.assumingMemoryBound(to: Float16.self)
            value = { Float(pointer[$0]) }
        case .float32:
            let pointer = logits.dataPointer.assumingMemoryBound(to: Float.self)
            value = { pointer[$0] }
        default:
            throw GigaAMError.unexpectedOutput
        }

        var text = ""
        var previous = -1
        for frame in 0..<frames {
            var best = 0
            var bestValue = -Float.infinity
            for token in 0..<tokens {
                let candidate = value(frame * frameStride + token * tokenStride)
                if candidate > bestValue {
                    bestValue = candidate
                    best = token
                }
            }
            defer { previous = best }
            guard best != previous, best != blank, best != 0, best < vocabulary.count else { continue }
            text += vocabulary[best].replacingOccurrences(of: "▁", with: " ")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Chunking

    /// Splits a recording into pieces that fit the 25 s window, each cut at
    /// the quietest moment of its last few seconds so words aren't split.
    private static func chunks(of samples: [Float]) -> [ArraySlice<Float>] {
        // A little under the window, to leave room to look for a pause.
        let target = windowSamples - sampleRate / 2
        let search = 5 * sampleRate
        let step = sampleRate / 50

        var chunks: [ArraySlice<Float>] = []
        var start = 0
        while samples.count - start > target {
            var cut = start + target
            var quietest = Float.infinity
            var position = start + target - search
            while position + step <= start + target {
                var energy: Float = 0
                samples.withUnsafeBufferPointer {
                    vDSP_svesq($0.baseAddress! + position, 1, &energy, vDSP_Length(step))
                }
                if energy < quietest {
                    quietest = energy
                    cut = position + step / 2
                }
                position += step
            }
            chunks.append(samples[start..<cut])
            start = cut
        }
        chunks.append(samples[start...])
        return chunks
    }
}
