import Accelerate
import Foundation

/// The voice per frequency band, lowest first, each 0...1.
typealias SpectrumBands = SIMD8<Float>

/// Splits a buffer of microphone audio into a few frequency bands, for
/// indicators that show the voice's spectrum.
///
/// Gives the spectrum's shape, not its loudness: each band from 0 to 1
/// against the strongest one. The indicator multiplies it by the voice level
/// it already gates for background noise, so silence stays flat.
nonisolated final class SpectrumAnalyzer: @unchecked Sendable {
    static let bandCount = SpectrumBands.scalarCount
    /// The voice's range: the lowest fundamentals up to the sibilants.
    private static let lowestFrequency: Float = 90
    private static let highestFrequency: Float = 7000
    /// Bands this far below the strongest one show as nothing.
    private static let dynamicRange: Float = 30
    /// The voice loses about this much per band towards the highs; it is
    /// added back, so "с" and "ш" raise peaks as well as vowels do.
    private static let tiltPerBand: Float = 5

    private static let log2Size = 10
    private static let size = 1 << log2Size

    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    /// The FFT bins of each band, for this sample rate.
    private let bins: [ClosedRange<Int>]

    init?(sampleRate: Double) {
        guard sampleRate > 0,
              let fft = vDSP.FFT(log2n: vDSP_Length(Self.log2Size), radix: .radix2, ofType: DSPSplitComplex.self)
        else {
            return nil
        }
        self.fft = fft
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: Self.size, isHalfWindow: false)

        let half = Self.size / 2
        let binWidth = Float(sampleRate) / Float(Self.size)
        let ratio = Self.highestFrequency / Self.lowestFrequency
        bins = (0..<Self.bandCount).map { band in
            let low = Self.lowestFrequency * pow(ratio, Float(band) / Float(Self.bandCount))
            let high = Self.lowestFrequency * pow(ratio, Float(band + 1) / Float(Self.bandCount))
            // Kept below the top bin: at low sample rates the highest bands
            // lie past it and share it.
            let first = min(max(1, Int(low / binWidth)), half - 1)
            return first...min(half - 1, max(first, Int(high / binWidth)))
        }
    }

    /// The spectrum's shape in `samples`, over the whole buffer however long
    /// the system makes it; flat if there are too few samples.
    func bands(of samples: [Float]) -> SpectrumBands {
        guard samples.count >= Self.size / 2 else { return .zero }

        // The power of each window of the buffer, added up.
        var power = [Float](repeating: 0, count: Self.size / 2)
        for start in stride(from: 0, to: samples.count - Self.size / 2 + 1, by: Self.size) {
            power = vDSP.add(power, self.power(of: samples[start..<min(samples.count, start + Self.size)]))
        }

        var levels = SpectrumBands()
        for (band, range) in bins.enumerated() {
            levels[band] = 10 * log10(vDSP.mean(power[range]) + 1e-12) + Self.tiltPerBand * Float(band)
        }
        let floor = SpectrumBands(repeating: levels.max() - Self.dynamicRange)
        return ((levels - floor) / Self.dynamicRange).clamped(lowerBound: .zero, upperBound: .one)
    }

    /// The power spectrum of one window of samples, zero-padded if short.
    private func power(of samples: ArraySlice<Float>) -> [Float] {
        var frame = [Float](repeating: 0, count: Self.size)
        frame.replaceSubrange(0..<samples.count, with: samples)
        frame = vDSP.multiply(frame, window)

        let half = Self.size / 2
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                // The real frame packed as complex pairs, as the real FFT wants.
                frame.withUnsafeBufferPointer { frameBuffer in
                    frameBuffer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                let input = split
                fft.forward(input: input, output: &split)
                vDSP.squareMagnitudes(split, result: &power)
            }
        }
        return power
    }
}
