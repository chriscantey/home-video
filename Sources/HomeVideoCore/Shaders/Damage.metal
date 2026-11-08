#include <metal_stdlib>
using namespace metal;

// The Damage pass's picture events (DamageLayers.swift). Working textures hold
// YIQ (Y in r, I in g, Q in b). ShaderLibrary's runtime fallback concatenates the .metal
// sources in name order, so this file sorts first and carries its own helpers under a dmg_
// prefix rather than reaching for VHS.metal's.

// PCG hash (O'Neill's RXS-M-XS step), the same one Hash.pcg runs on the CPU.
inline uint dmg_pcg(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

// White noise in -1...1 from (seed, layer, frame, field, line, sample).
inline float dmg_noise(uint seed, uint layer, uint frame, uint field, uint line, uint sample) {
    uint h = dmg_pcg(seed ^ 0x9E3779B9u);
    h = dmg_pcg(h ^ layer);
    h = dmg_pcg(h ^ frame);
    h = dmg_pcg(h ^ field);
    h = dmg_pcg(h ^ line);
    h = dmg_pcg(h ^ sample);
    return float(h) * (2.0 / 4294967295.0) - 1.0;
}

// Smooth noise in 0...1 along a line: values every 24 px, eased between, so a span breaks into
// patches a few dozen pixels long rather than per pixel speckle.
inline float dmg_patches(uint seed, uint salt, uint frame, uint field, uint line, float x) {
    float c = x / 24.0;
    float i = floor(c), f = c - i;
    float a = dmg_noise(seed, salt, frame, field, line, uint(int(i) + 64));
    float b = dmg_noise(seed, salt, frame, field, line, uint(int(i) + 65));
    float s = f * f * (3.0 - 2.0 * f);
    return 0.5 + 0.5 * mix(a, b, s);
}

// One raster line of a damage layer's table, worked out on the CPU per frame.
struct DamageEventLine {
    float shift;   // px the line moves right (sync slip), reading blanking past the line's ends
    float noise;   // uniform noise amplitude on Y (half of it on I and Q)
    float chroma;  // gain on I and Q (0 is the color killer)
    float blur;    // Gaussian sigma on Y, px
    float start;   // span [start, end) in px
    float end;
    float kind;    // 0 none, 1 white, 2 black, 3 repeat the line above (same field), 4 noise bar
    float level;   // span mix, 0 to 1
    float fuzz;    // 0 a solid span, 1 broken into patches along the line
    float pad0;
    float pad1;
    float pad2;
};

struct DamageEventParams {
    uint seed;
    uint salt;
    uint field;
    uint pad;
};

inline float4 dmg_read(texture2d<float, access::read> src, float x, int y) {
    int w = int(src.get_width());
    int x0 = int(floor(x));
    float f = x - float(x0);
    float4 a = (x0 >= 0 && x0 < w) ? src.read(uint2(x0, y)) : float4(0.0, 0.0, 0.0, 1.0);
    float4 b = (x0 + 1 >= 0 && x0 + 1 < w) ? src.read(uint2(x0 + 1, y)) : float4(0.0, 0.0, 0.0, 1.0);
    return mix(a, b, f);
}

// One thread per pixel. A line whose entry is all identity copies its pixel unchanged.
kernel void damage_events(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::write> dst [[texture(1)]],
                          constant DamageEventLine *lines [[buffer(0)]],
                          constant DamageEventParams &p [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    DamageEventLine L = lines[gid.y];
    int y = int(gid.y);
    float x = float(gid.x);
    float4 v = (L.shift == 0.0) ? src.read(gid) : dmg_read(src, x - L.shift, y);
    if (L.blur > 0.05) {
        int r = min(int(ceil(3.0 * L.blur)), 12);
        float sum = 0.0, wsum = 0.0;
        for (int k = -r; k <= r; k++) {
            float g = exp(-0.5 * float(k * k) / (L.blur * L.blur));
            sum += g * dmg_read(src, x - L.shift + float(k), y).x;
            wsum += g;
        }
        v.x = sum / wsum;
    }
    v.yz *= L.chroma;
    uint field = gid.y & 1u, line = gid.y >> 1;
    if (L.noise > 0.0) {
        v.x += L.noise * dmg_noise(p.seed, p.salt, p.field + field, 0u, line, gid.x);
        v.y += 0.5 * L.noise * dmg_noise(p.seed, p.salt, p.field + field, 1u, line, gid.x);
        v.z += 0.5 * L.noise * dmg_noise(p.seed, p.salt, p.field + field, 2u, line, gid.x);
    }
    if (L.kind > 0.5 && L.level > 0.0 && x >= L.start && x < L.end) {
        float level = L.level;
        if (L.fuzz > 0.0) {
            // The patches follow the fold or streak (the same along neighboring lines of one
            // event, seeded by the field), so the break up reads as contact coming and going.
            float m = dmg_patches(p.seed, p.salt + 7u, p.field + field, 5u, 0u, x - L.start);
            level *= 1.0 - L.fuzz * (1.0 - m * m);
        }
        float ramp = clamp(min(x - L.start, L.end - x) / 3.0, 0.0, 1.0) * level;
        float n = dmg_noise(p.seed, p.salt, p.field + field, 3u, line, gid.x);
        float4 t = v;
        if (L.kind < 1.5) {
            t = float4(0.92 + 0.12 * n, 0.0, 0.0, v.w);
        } else if (L.kind < 2.5) {
            t = float4(0.03 + 0.03 * n, 0.0, 0.0, v.w);
        } else if (L.kind < 3.5) {
            uint above = gid.y >= 2u ? gid.y - 2u : gid.y + 2u;
            t = src.read(uint2(gid.x, above));
        } else {
            // The noise bar: carrier lost, the limiter's noise reads as gray to white speckle.
            float m = dmg_noise(p.seed, p.salt, p.field + field, 4u, line, gid.x);
            t = float4(0.45 + 0.5 * n * abs(m), 0.0, 0.0, v.w);
        }
        v = mix(v, t, ramp);
    }
    dst.write(v, gid);
}
