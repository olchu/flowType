#include <metal_stdlib>
using namespace metal;

/// Must match ParticleFieldRenderer.Uniforms in ParticleFieldRenderer.swift.
struct ParticleUniforms {
    float2 size;        // drawable size in pixels
    float scale;        // pixels per point
    float phase;        // motion clock, in seconds
    float wavePhase;    // clock of the waves; runs faster with the voice
    float level;        // smoothed voice level, 0...1, for the light
    float lift;         // slower follower of the voice, 0...1, for the hills
    float spread;       // 0 gathered into the middle, 1 full width (intro and dismissal)
    float visibility;   // overall fade
    float flash;        // paste flash
    float processing;   // 0...1 while the text is processed
    float scan;         // processing sweep position, -1...1
};

/// Must match ParticleFieldRenderer.columns and rows.
constant int columns = 110;
constant int rows = 34;

/// The field spans x in -halfWidth...halfWidth and z in -halfDepth...halfDepth.
constant float halfWidth = 1.7;
constant float halfDepth = 0.95;

struct FullscreenVertex {
    float4 position [[position]];
};

vertex FullscreenVertex particleFullscreenVertex(uint id [[vertex_id]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    FullscreenVertex out;
    out.position = float4(corners[id], 0, 1);
    return out;
}

static float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

/// The voice level, lifted so ordinary speech already shows clearly.
static float voiceEnergy(float level) {
    return 1.0 - exp(-6.0 * level);
}

/// A loop of colours the field shimmers through: cyan, blue, violet,
/// magenta and a warm pink, then back to cyan. `t` is in turns.
static float3 shimmer(float t) {
    const float3 colors[5] = {
        float3(0.2, 0.85, 1.0),
        float3(0.25, 0.42, 1.0),
        float3(0.6, 0.3, 1.0),
        float3(1.0, 0.35, 0.85),
        float3(1.0, 0.55, 0.6),
    };
    float position = fract(t) * 5.0;
    int i = int(position);
    float f = smoothstep(0.0, 1.0, position - float(i));
    return mix(colors[i], colors[(i + 1) % 5], f);
}

/// Height of the field at `x`, `z`: broad crossing swells, finer waves
/// running over them and a hill drifting along. The voice raises it all,
/// lifts the finer waves most and speeds the waves up.
static float fieldHeight(float x, float z, constant ParticleUniforms& u) {
    float w = u.wavePhase;
    float swells = 0.5 * sin(1.3 * x + 0.9 * z + 0.55 * w)
        + 0.32 * sin(-2.1 * x + 1.7 * z + 0.8 * w + 1.3);
    float waves = 0.22 * sin(3.6 * x - 2.4 * z - 1.1 * w + 2.1)
        + 0.16 * sin(5.3 * x + 3.1 * z + 1.6 * w + 0.4)
        + 0.11 * sin(-7.4 * x + 1.2 * z + 2.2 * w + 3.3);
    float t = u.phase;
    float hillX = -0.45 + 0.5 * sin(t * 0.21);
    float hill = exp(-pow((x - hillX) / 0.65, 2.0)) * (0.7 + 0.3 * sin(t * 0.37 + 1.0));
    float amplitude = (0.15 + 0.48 * u.lift) * u.spread;
    return amplitude * (0.75 * swells + 0.7 * hill + (0.5 + 1.4 * u.lift) * waves);
}

struct ParticleVertex {
    float4 position [[position]];
    float pointSize [[point_size]];
    float3 color;
};

vertex ParticleVertex particleVertex(uint id [[vertex_id]], constant ParticleUniforms& u [[buffer(0)]]) {
    int column = int(id) % columns;
    int row = int(id) / columns;
    float2 cell = float2(column, row);
    float2 jitter = float2(hash(cell), hash(cell + 17.3)) - 0.5;

    // -1 at the left end, 1 at the right. The grid is denser in the middle
    // and opens up towards the ends and the front and back edges.
    float across = (float(column) + 0.6 * jitter.x) / float(columns - 1) * 2.0 - 1.0;
    across *= 0.55 + 0.45 * across * across;
    // The field thins out towards both ends, like a leaf.
    float body = smoothstep(1.0, 0.2, abs(across));
    float x = across * halfWidth * u.spread;
    float depth = (float(row) + 0.6 * jitter.y) / float(rows - 1) * 2.0 - 1.0;
    depth *= 0.7 + 0.3 * depth * depth;
    float z = depth * halfDepth * (0.2 + 0.8 * body);
    float y = fieldHeight(x, z, u) * body;

    // Camera a little above the field, looking slightly down at it.
    const float3 eye = float3(0, 1.15, -2.9);
    const float3 forward = normalize(-eye);
    const float3 up = cross(forward, float3(1, 0, 0));
    float3 v = float3(x, y, z) - eye;
    float distance = dot(v, forward);
    float2 view = float2(v.x, dot(v, up)) / distance;
    const float focal = 1.5;
    float aspect = u.size.x / u.size.y;

    ParticleVertex out;
    out.position = float4(view.x * focal, view.y * focal * aspect, 0, 1);

    // Bands of colour drift slowly along the field and across it, so it
    // shimmers through the loop; the peaks run a little ahead, warmer, and
    // turn paler.
    float height = saturate((y + 0.08) / 0.6);
    float3 color = shimmer(0.5 * across + 0.15 * depth + 0.35 * height - 0.06 * u.phase);
    color = mix(color, float3(0.95, 0.9, 1.0), 0.3 * smoothstep(0.6, 1.0, height));

    float energy = voiceEnergy(u.level);
    // Each point twinkles a little on its own, and a few sparkle.
    float seed = hash(cell + 41.7);
    float twinkle = 0.75 + 0.35 * sin(u.phase * (1.5 + 2.0 * seed) + seed * 40.0);
    float sparkle = 1.0 + 3.0 * pow(seed, 30.0);
    // Dots thin out away from the hills: in the hollows only about a third
    // of them show. They fade rather than pop as the field moves.
    float keep = smoothstep(-0.15, 0.15, 0.35 + 0.9 * height - hash(cell + 63.1));
    float light = (0.3 + 0.7 * height) * (0.5 + 1.1 * energy + 1.2 * u.flash)
        * twinkle * sparkle * keep * (0.45 + 0.55 * body)
        // The back rows fade into the dark.
        * (1.0 - 0.45 * (depth * 0.5 + 0.5));
    // Processing: a band of light sweeps along the field.
    light *= (0.85 + 0.3 * u.processing) * (1.0 + 0.9 * u.processing * exp(-pow((across - u.scan) / 0.25, 2.0)));
    out.color = color * light;

    out.pointSize = u.scale * (1.1 + 0.8 * height) * (3.0 / distance) * (0.4 + 0.6 * keep);
    return out;
}

fragment float4 particleFragment(ParticleVertex in [[stage_in]], float2 point [[point_coord]]) {
    // A soft round dot with a brighter core.
    float d = length(point - 0.5) * 2.0;
    float disc = exp(-d * d * 3.0) * (1.0 - smoothstep(0.8, 1.0, d)) + 0.6 * exp(-d * d * 14.0);
    return float4(in.color * disc, 0);
}

/// Turns the accumulated light into the drawable: a soft glow around the
/// dots, a soft shoulder so dense bright patches turn pale instead of
/// clipping, premultiplied alpha. `light` has mipmaps; the glow is read
/// from the blurred levels.
fragment float4 particleOutputFragment(FullscreenVertex in [[stage_in]],
                                       constant ParticleUniforms& u [[buffer(0)]],
                                       texture2d<float> light [[texture(0)]]) {
    constexpr sampler linear(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float2 uv = in.position.xy / u.size;
    float3 color = light.sample(linear, uv, level(0)).rgb;
    // The glow spreads a few points round each dot.
    float lod = log2(max(1.0, 1.5 * u.scale));
    float3 glow = light.sample(linear, uv, level(lod)).rgb + 0.6 * light.sample(linear, uv, level(lod + 1.0)).rgb;
    color += glow * 0.5;

    color = 1.0 - exp(-color * 1.2);
    float alpha = saturate(max(color.r, max(color.g, color.b)));
    return float4(color, alpha) * u.visibility;
}
