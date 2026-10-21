#include <metal_stdlib>
using namespace metal;

/// Must match AuroraRenderer.Uniforms in AuroraRenderer.swift.
struct AuroraUniforms {
    float2 size;        // drawable size in pixels
    float radius;       // sphere radius in pixels
    float phase;        // motion clock, in seconds
    float level;        // smoothed voice level, 0...1
    float accent;       // short lift on syllables and peaks, 0...1
    float glow;         // 0 a dark ball with no light in it, 1 fully lit (intro and dismissal)
    float visibility;   // overall fade
    float flash;        // paste flash
    float processing;   // 0...1 while the text is processed
    float scan;         // processing sweep position, -1...1
};

struct FullscreenVertex {
    float4 position [[position]];
};

vertex FullscreenVertex auroraFullscreenVertex(uint id [[vertex_id]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    FullscreenVertex out;
    out.position = float4(corners[id], 0, 1);
    return out;
}

/// Sphere coordinates of a pixel: centre at 0, rim at 1, y up.
static float2 sphereCoordinates(float2 pixel, constant AuroraUniforms& u) {
    float2 p = (pixel - u.size * 0.5) / u.radius;
    p.y = -p.y;
    return p;
}

/// Coverage of the sphere at distance `r` from its centre, with a soft
/// edge about a pixel and a half wide.
static float insideSphere(float r, constant AuroraUniforms& u) {
    return 1.0 - smoothstep(1.0 - 1.5 / u.radius, 1.0, r);
}

/// The voice level, lifted so ordinary speech (a level of 0.1 to 0.25)
/// already lights the smoke to about half to three quarters, and loud
/// speech closes in on full without a hard ceiling.
static float voiceEnergy(constant AuroraUniforms& u) {
    return 1.0 - exp(-6.0 * u.level);
}

/// Overall light level, with the paste flash and the processing sweep.
static float brightness(constant AuroraUniforms& u, float x) {
    float energy = voiceEnergy(u);
    float b = (0.45 + 2.0 * energy + 0.7 * u.accent + 1.2 * u.flash) * (0.85 + 0.3 * u.processing);
    return b * (1.0 + 0.7 * u.processing * exp(-pow((x - u.scan * 0.8) / 0.3, 2.0)));
}

// MARK: - Smoke

/// Random value in 0...1 for a lattice point. The look of the smoke was
/// tuned with this exact hash, under fast math; the phase is reset on every
/// presentation, so its argument never grows large.
static float hash(float3 p) {
    return fract(sin(dot(p, float3(127.1, 311.7, 74.7))) * 43758.5453);
}

/// Smooth value noise in 0...1.
static float noise(float3 p) {
    float3 i = floor(p);
    float3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = hash(i);
    float n100 = hash(i + float3(1, 0, 0));
    float n010 = hash(i + float3(0, 1, 0));
    float n110 = hash(i + float3(1, 1, 0));
    float n001 = hash(i + float3(0, 0, 1));
    float n101 = hash(i + float3(1, 0, 1));
    float n011 = hash(i + float3(0, 1, 1));
    float n111 = hash(i + float3(1, 1, 1));
    return mix(
        mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
        mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y),
        f.z);
}

/// Layered noise in 0...1, each octave turned so the grid never shows.
static float fbm(float3 p, int octaves) {
    const float3x3 turn = float3x3(
        float3(0.00, 0.80, 0.60),
        float3(-0.80, 0.36, -0.48),
        float3(-0.60, -0.48, 0.64));
    float value = 0;
    float amplitude = 0.5;
    float total = 0;
    for (int i = 0; i < octaves; i++) {
        value += amplitude * noise(p);
        total += amplitude;
        p = turn * p * 2.05 + 1.7;
        amplitude *= 0.5;
    }
    return value / total;
}

/// Rotation of `p` about `axis` by `angle`.
static float3 rotate(float3 p, float3 axis, float angle) {
    float c = cos(angle);
    float sn = sin(angle);
    return p * c + cross(axis, p) * sn + axis * dot(axis, p) * (1.0 - c);
}

/// One smoke inside the glass: a cloud of its own colour, turning about
/// its own axis, thickest towards `home`.
struct Smoke {
    float3 axis;        // it turns about this
    float3 home;        // the side of the glass it keeps to
    float speed;        // turns on the motion clock
    float scale;        // size of its clouds; larger is finer
    float3 offset;      // its own place in the noise
    float3 dim;         // colour of its thin parts
    float3 bright;      // colour of its thick parts
    float strength;
};

static Smoke smokeAt(int index) {
    Smoke s;
    switch (index) {
    case 0:
        // Orange, keeping low and to the front.
        s.axis = normalize(float3(0.3, 1.0, 0.4));
        s.home = normalize(float3(0.2, -0.7, 0.7));
        s.speed = 0.5; s.scale = 1.3;
        s.offset = float3(0.0, 0.0, 0.0);
        s.dim = float3(1.0, 0.45, 0.2); s.bright = float3(1.0, 0.8, 0.5);
        s.strength = 1.0;
        break;
    case 1:
        // Violet, round the right side.
        s.axis = normalize(float3(-0.5, 0.8, -0.3));
        s.home = normalize(float3(0.8, 0.1, 0.3));
        s.speed = -0.4; s.scale = 1.2;
        s.offset = float3(7.3, 2.1, 4.8);
        s.dim = float3(0.5, 0.15, 1.0); s.bright = float3(0.85, 0.55, 1.0);
        s.strength = 1.0;
        break;
    default:
        // Blue, along the top.
        s.axis = normalize(float3(0.8, 0.3, 0.5));
        s.home = normalize(float3(-0.5, 0.8, 0.2));
        s.speed = 0.35; s.scale = 1.5;
        s.offset = float3(3.9, 8.2, 1.4);
        s.dim = float3(0.15, 0.4, 1.0); s.bright = float3(0.55, 0.8, 1.0);
        s.strength = 0.8;
        break;
    }
    return s;
}

/// Where the point `q` inside the unit sphere lands in a smoke's noise:
/// turned about its axis and stirred by a slow current. The smoke moves on
/// its own, at its own pace; the voice never shapes it.
static float3 stirredPoint(float3 q, Smoke s, float t) {
    // The smoke turns faster near the middle than at the glass, so it
    // winds into a spiral.
    float angle = t * s.speed + 2.5 * (1.0 - length(q));
    float3 n = rotate(q, s.axis, angle) * s.scale + s.offset;
    float3 current = float3(
        fbm(n + float3(0.0, 0.0, t * 0.12), 3),
        fbm(n + float3(5.2, 1.3, t * 0.1), 3),
        fbm(n + float3(1.7, 9.2, -t * 0.09), 3)) - 0.5;
    return n + current * 2.6;
}

/// Thickness of smoke at a stirred point, 0...1: fine strands along the
/// contours of the noise, inside soft clouds of it.
static float smokeDensity(float3 stirred, float t) {
    // Few octaves: long smooth curls, with just a little fine detail.
    float raw = fbm(stirred + float3(0, t * 0.04, 0), 4);
    float cloud = 0.15 + 0.85 * smoothstep(0.42, 0.7, fbm(stirred * 0.5 + 11.0, 2));
    float strands = pow(1.0 - abs(fract(raw * 3.0 + t * 0.03) * 2.0 - 1.0), 3.0);
    float body = smoothstep(0.45, 0.75, raw);
    return (0.15 * body + 0.85 * strands) * cloud;
}

/// Three coloured smokes turning inside the glass. Added over the glass
/// interior; the alpha channel stays untouched.
fragment float4 auroraSmokeFragment(FullscreenVertex in [[stage_in]], constant AuroraUniforms& u [[buffer(0)]]) {
    float2 p = sphereCoordinates(in.position.xy, u);
    float r = length(p);
    float inside = insideSphere(r, u);
    if (inside <= 0) {
        return float4(0);
    }

    float light = brightness(u, p.x);
    float energy = voiceEnergy(u);
    // A point inside the sphere behind this pixel; the glass bends the view
    // a little towards the rim.
    float z = sqrt(max(0.0, 1.0 - r * r));
    float3 q = float3(p * (1.0 + 0.12 * r * r), z * 0.6);
    // Thinner towards the rim, where there is less sphere to look through.
    float depth = 0.35 + 0.65 * z;
    float3 toLight = normalize(float3(-0.6, 0.7, 0.4));

    float3 color = float3(0);
    for (int i = 0; i < 3; i++) {
        Smoke s = smokeAt(i);
        // Each smoke keeps to its side of the glass while it turns.
        float home = smoothstep(0.0, 0.9, dot(q, s.home));
        if (home <= 0) {
            continue;
        }
        float3 stirred = stirredPoint(q, s, u.phase);
        float density = smokeDensity(stirred, u.phase) * home;
        if (density <= 0.001) {
            continue;
        }
        // Lit from the upper left: the side of each cloud facing the light
        // is brighter, the far side falls into shadow.
        float lit = smokeDensity(stirred + toLight * 0.12, u.phase) * home;
        float shade = 0.45 + 0.55 * smoothstep(-0.15, 0.15, lit - density);

        // The voice lights the smoke: brighter, and hotter in colour.
        float3 tint = mix(s.dim, s.bright, saturate(density * 1.2 - 0.2 + 0.5 * energy + 0.3 * u.accent));
        // Louder: the smoke also fills in a little.
        density *= 1.0 + 0.6 * energy;
        color += tint * density * (0.4 + 0.6 * shade) * s.strength;
    }

    color *= light * depth * inside * 1.1 * u.glow;
    return float4(color, 0);
}

// MARK: - Glass

/// The dark interior, the glass shell and the glow around it. Added under
/// the smoke; the alpha channel carries the coverage of the sphere.
fragment float4 auroraGlassFragment(FullscreenVertex in [[stage_in]], constant AuroraUniforms& u [[buffer(0)]]) {
    float2 p = sphereCoordinates(in.position.xy, u);
    float r = length(p);
    float pixel = 1.0 / u.radius;
    float energy = voiceEnergy(u);
    float inside = insideSphere(r, u);

    // Blue and white along the top, violet and magenta round the sides and
    // bottom; the light comes from the upper left.
    float angle = atan2(p.y, p.x);
    float topness = 0.5 + 0.5 * sin(angle);
    float3 rimColor = mix(float3(0.7, 0.3, 1.0), float3(0.55, 0.78, 1.0), smoothstep(0.1, 0.9, topness));
    float litSide = 0.55 + 0.45 * smoothstep(-1.0, 1.0, p.y - 0.4 * p.x);
    float highlight = 1.0 + 2.0 * exp(-pow((angle - 2.0) / 0.9, 2.0));

    float3 color = float3(0);
    float alpha = 0;

    if (inside > 0) {
        // Dark, slightly violet interior, a touch lighter towards the rim.
        color = mix(float3(0.006, 0.008, 0.03), float3(0.03, 0.03, 0.1), r * r);

        // The shell: a soft band of light at the rim, a sharp hairline on
        // it, a faint second ring inside it from the refraction, and a
        // fresnel sheen that grows towards the edge.
        float band = exp(-pow((1.0 - r) / (0.035 + 0.025 * topness), 2.0)) * 0.9 * litSide * highlight;
        float hairline = exp(-pow((1.0 - r) / (pixel * 1.2 + 0.003), 2.0)) * 0.6 * litSide * highlight;
        float innerRing = exp(-pow((0.93 - r) / 0.012, 2.0)) * 0.2 * (0.3 + 0.7 * topness);
        float fresnel = pow(r, 6.0) * 0.2 * litSide;
        float2 spot = (p - float2(-0.4, 0.6)) / float2(0.36, 0.14);
        float reflection = exp(-dot(spot, spot)) * 0.25;
        float3 shell = rimColor * (band + hairline + innerRing + fresnel) + float3(0.75, 0.85, 1.0) * reflection;
        color += shell * (0.8 + 0.7 * energy + 0.4 * u.accent + 0.8 * u.flash) * u.glow;
        color *= inside;
        alpha = 0.94 * inside;
    }

    // A faint glow around the glass.
    float outside = max(0.0, r - 1.0);
    float halo = exp(-outside / (0.06 + 0.06 * energy)) * (1.0 - inside) * (0.05 + 0.3 * energy + 0.15 * u.accent + 0.5 * u.flash) * u.glow;
    color += rimColor * halo;
    alpha = max(alpha, saturate(halo * 0.9));

    return float4(color, alpha);
}

// MARK: - Output

/// Turns the accumulated light into the drawable: a soft glow around the
/// brightest light, a soft shoulder so bright overlaps turn pale instead
/// of clipping, premultiplied alpha. `light` has mipmaps; the glow is read
/// from the blurred levels.
fragment float4 auroraOutputFragment(FullscreenVertex in [[stage_in]],
                                     constant AuroraUniforms& u [[buffer(0)]],
                                     texture2d<float> light [[texture(0)]]) {
    constexpr sampler linear(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float2 uv = in.position.xy / u.size;
    float4 sample = light.sample(linear, uv, level(0));

    // The glow spreads about a tenth of the radius, mostly inside the glass.
    float lod = log2(max(1.0, 0.045 * u.radius));
    float3 glow = max(light.sample(linear, uv, level(lod)).rgb - 0.03, 0.0)
        + max(light.sample(linear, uv, level(lod + 1.0)).rgb - 0.03, 0.0) * 0.6;
    float r = length(sphereCoordinates(in.position.xy, u));
    float3 color = sample.rgb + glow * 0.5 * (0.25 + 0.75 * (1.0 - smoothstep(0.97, 1.03, r)));

    color = 1.0 - exp(-color * 1.15);
    float alpha = saturate(max(sample.a, max(color.r, max(color.g, color.b))));
    return float4(color, alpha) * u.visibility;
}
