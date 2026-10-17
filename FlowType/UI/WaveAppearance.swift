import Combine
import CoreGraphics
import Foundation

/// Every tunable layer of the waves indicator. The defaults are the shipped
/// look; the Wave Tuner window edits a copy that the live indicator reads.
struct WaveAppearance: Codable, Equatable {
    /// Wide, soft glow around each strand (the "halo").
    var showsHalo = true
    var haloOpacity = 0.16
    var haloRadius = 8.0
    /// How far the halo outline extends beyond the strand before blurring.
    var haloSpread = 4.5
    /// 0 keeps the theme colour, 1 is pure white.
    var haloWhiteness = 0.0

    /// Tight glow hugging each strand.
    var showsGlow = true
    var glowOpacity = 0.5
    var glowRadius = 2.0
    var glowWhiteness = 0.55

    /// The strands themselves.
    var showsLines = true
    var lineOpacity = 1.0
    var lineWidth = 0.8
    var lineWhiteness = 0.0

    /// Adds overlapping strands and glows together ("plus lighter"), so
    /// crossings light up. Off uses normal blending.
    var usesAdditiveBlending = true

    /// Orb shown while the waves open and collapse.
    var showsOrb = true

    init() {}

    init(from decoder: Decoder) throws {
        // Missing keys fall back to defaults, so new parameters don't
        // discard a saved tuning.
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WaveAppearance()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        showsHalo = value(.showsHalo, defaults.showsHalo)
        haloOpacity = value(.haloOpacity, defaults.haloOpacity)
        haloRadius = value(.haloRadius, defaults.haloRadius)
        haloSpread = value(.haloSpread, defaults.haloSpread)
        haloWhiteness = value(.haloWhiteness, defaults.haloWhiteness)
        showsGlow = value(.showsGlow, defaults.showsGlow)
        glowOpacity = value(.glowOpacity, defaults.glowOpacity)
        glowRadius = value(.glowRadius, defaults.glowRadius)
        glowWhiteness = value(.glowWhiteness, defaults.glowWhiteness)
        showsLines = value(.showsLines, defaults.showsLines)
        lineOpacity = value(.lineOpacity, defaults.lineOpacity)
        lineWidth = value(.lineWidth, defaults.lineWidth)
        lineWhiteness = value(.lineWhiteness, defaults.lineWhiteness)
        usesAdditiveBlending = value(.usesAdditiveBlending, defaults.usesAdditiveBlending)
        showsOrb = value(.showsOrb, defaults.showsOrb)
    }

    /// Readable dump for sharing a tuning.
    var summary: String {
        func number(_ value: Double) -> String { String(format: "%.2f", value) }
        return """
        halo: \(showsHalo ? "on" : "off") opacity \(number(haloOpacity)) radius \(number(haloRadius)) spread \(number(haloSpread)) white \(number(haloWhiteness))
        glow: \(showsGlow ? "on" : "off") opacity \(number(glowOpacity)) radius \(number(glowRadius)) white \(number(glowWhiteness))
        lines: \(showsLines ? "on" : "off") opacity \(number(lineOpacity)) width \(number(lineWidth)) white \(number(lineWhiteness))
        additive: \(usesAdditiveBlending ? "on" : "off"), orb: \(showsOrb ? "on" : "off")
        """
    }
}

/// Shared, persisted tuning read by every waves indicator on each frame.
final class WaveAppearanceStore: ObservableObject {
    static let shared = WaveAppearanceStore()

    private static let defaultsKey = "waveAppearance"

    @Published var appearance: WaveAppearance {
        didSet {
            guard appearance != oldValue else { return }
            if let data = try? JSONEncoder().encode(appearance) {
                UserDefaults.standard.set(data, forKey: Self.defaultsKey)
            }
        }
    }

    private init() {
        appearance = UserDefaults.standard.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(WaveAppearance.self, from: $0) }
            ?? WaveAppearance()
    }
}

extension CGColor {
    /// The colour moved towards white by `amount` (0...1).
    func mixedWithWhite(_ amount: Double) -> CGColor {
        let amount = min(max(amount, 0), 1)
        guard amount > 0,
              let rgb = converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let components = rgb.components, components.count >= 3 else {
            return self
        }
        let mix = { (value: CGFloat) in value + (1 - value) * CGFloat(amount) }
        return CGColor(
            srgbRed: mix(components[0]),
            green: mix(components[1]),
            blue: mix(components[2]),
            alpha: rgb.alpha
        )
    }
}
