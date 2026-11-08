#include <metal_stdlib>
using namespace metal;

// The Telecine stage (docs/TELECINE.md): one kernel per Telecine layer, run by
// TelecineLayers.swift at the 720 by 480 raster, plus the field compose and the interlace.
// Textures hold display (gamma 2.2) values. A kernel that models light works in linear inside.
// The helpers carry a tc_ prefix: at runtime every .metal file is compiled as one source.

inline uint tc_pcg(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

inline float tc_unit(uint a, uint b, uint c, uint d) {
    uint h = tc_pcg(a ^ 0x9E3779B9u);
    h = tc_pcg(h ^ b);
    h = tc_pcg(h ^ c);
    h = tc_pcg(h ^ d);
    return float(h) / 4294967295.0;
}

inline float3 tc_lin(float3 c) { return pow(max(c, 0.0), 2.2); }
inline float3 tc_enc(float3 c) { return pow(max(c, 0.0), 1.0 / 2.2); }
inline float tc_luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

constexpr sampler tc_clamp(coord::normalized, address::clamp_to_edge, filter::linear);
constexpr sampler tc_black(coord::normalized, address::clamp_to_zero, filter::linear);

inline float2 tc_uv(uint2 gid, float2 size) { return (float2(gid) + 0.5) / size; }

/// Distance from a point to a segment.
inline float tc_segment(float2 p, float2 a, float2 b) {
    float2 ab = b - a;
    float t = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
    return length(p - (a + ab * t));
}

// One field from the film frames it holds: per row, the first frame's weight and the next
// frame's (TelecineLayers.exposure), the projector's light added in linear.
kernel void tc_compose(texture2d<float, access::read> a [[texture(0)]],
                       texture2d<float, access::read> b [[texture(1)]],
                       texture2d<float, access::write> dst [[texture(2)]],
                       constant float2 *w [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 k = w[gid.y];
    float3 l = tc_lin(a.read(gid).rgb) * k.x + tc_lin(b.read(gid).rgb) * k.y;
    dst.write(float4(tc_enc(l), 1.0), gid);
}

// The frame from its two fields: the first in time on the odd rows (bottom field first, as
// NTSC DV), the second on the even rows.
kernel void tc_interlace(texture2d<float, access::read> first [[texture(0)]],
                         texture2d<float, access::read> second [[texture(1)]],
                         texture2d<float, access::write> dst [[texture(2)]],
                         uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    dst.write((gid.y & 1u) ? first.read(gid) : second.read(gid), gid);
}

// Gate: the transfer gate's weave, a splice's bump and flash, the overscan crop, dust and a
// hair. p: 0 dx px, 1 dy px, 2 the share of the frame kept, 3 flash gain, 4 polarity (-1 dark
// on reversal, 1 light on a negative), 5 pixel aspect, 6 specks, 7 hair on. Specks from 16,
// four each: x, y, radius px, opacity. The hair from 100: three points, then its width px.
kernel void tc_gate(texture2d<float, access::sample> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant float *p [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]])
{
    float2 size = float2(dst.get_width(), dst.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    float2 uv = tc_uv(gid, size);
    float2 at = 0.5 + (uv - 0.5) * p[2] - float2(p[0], p[1]) / size;
    float3 l = tc_lin(src.sample(tc_black, at).rgb) * p[3];
    float2 px = float2(gid) + 0.5;
    float block = 0.0;
    int specks = int(p[6]);
    for (int i = 0; i < specks; i++) {
        int o = 16 + i * 4;
        float2 c = float2(p[o], p[o + 1]) * size;
        float2 d = (px - c) * float2(p[5], 1.0);
        float r = p[o + 2];
        block = max(block, p[o + 3] * (1.0 - smoothstep(r * 0.6, r, length(d))));
    }
    if (p[7] > 0.5) {
        float2 a = float2(p[100], p[101]) * size, b = float2(p[102], p[103]) * size, c = float2(p[104], p[105]) * size;
        float d = min(tc_segment(px, a, b), tc_segment(px, b, c));
        block = max(block, 0.85 * (1.0 - smoothstep(p[106] * 0.4, p[106], d)));
    }
    // Dirt blocks the light: dark on a reversal original, light where a negative is inverted.
    float3 dirt = p[4] < 0.0 ? float3(0.004) : float3(0.9);
    l = mix(l, dirt, block);
    dst.write(float4(tc_enc(l), 1.0), gid);
}

// Projector light: a hot spot at the center, falloff to the corners, and the lamp's color
// against the camera's 3200 K. p: hot spot, falloff, gains r, g, b, pixel aspect, the
// picture's shape (0 for 4:3).
kernel void tc_light(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     constant float *p [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]])
{
    float2 size = float2(dst.get_width(), dst.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    // Under Fill the frame p[6] is the picture's shape.
    float r2;
    if (p[6] > 0.0) {
        float2 q = (tc_uv(gid, size) - 0.5) * float2(p[6], 1.0);
        r2 = dot(q, q) / (0.25 * p[6] * p[6] + 0.25);
    } else {
        float2 q = (tc_uv(gid, size) - 0.5) * float2(4.0 / 3.0, 1.0);
        r2 = dot(q, q) / (0.25 * (16.0 / 9.0) + 0.25);
    }
    float hot = (1.0 + p[0] * exp(-r2 / 0.12)) / (1.0 + p[0] * 0.3);
    float fall = max(1.0 - p[1] * r2, 0.0);
    float3 l = tc_lin(src.read(gid).rgb) * hot * fall * float3(p[2], p[3], p[4]);
    dst.write(float4(tc_enc(l), 1.0), gid);
}

// Geometry: the camera off the projector's axis (keystone), the picture smaller than the
// camera's frame so the gate's rounded edge shows on the unlit screen, and the screen's own
// texture, fixed in the camera's frame while the picture moves over it.
// p: tan(keystone), gate edge, screen texture, pixel aspect, the picture's shape (0 for 4:3).
kernel void tc_geometry(texture2d<float, access::sample> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant float *p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]])
{
    float2 size = float2(dst.get_width(), dst.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    float2 uv = tc_uv(gid, size);
    // Keystone: the projector aimed up at the screen, so the picture widens toward the top.
    float sx = 1.0 + 2.0 * p[0] * (0.5 - uv.y);
    float zoom = 1.0 - 0.1 * p[1];
    float2 img = float2(0.5 + (uv.x - 0.5) / (sx * zoom), 0.5 + (uv.y - 0.5) / zoom);
    float3 l = tc_lin(src.sample(tc_clamp, img).rgb);
    // The gate's edge: a rounded rectangle, soft as the projector lens leaves it.
    // Under Fill the frame p[4] is the picture's shape, the gate as wide as the frame.
    float2 d, half_;
    if (p[4] > 0.0) {
        d = abs(img - 0.5) * float2(p[4], 1.0);
        half_ = float2(0.5 * p[4], 0.5);
    } else {
        d = abs(img - 0.5) * float2(4.0 / 3.0, 1.0);
        half_ = float2(2.0 / 3.0, 0.5);
    }
    float corner = 0.03;
    float2 e = d - (half_ - corner);
    float dist = length(max(e, 0.0)) + min(max(e.x, e.y), 0.0) - corner;
    float inside = 1.0 - smoothstep(-0.004, 0.006, dist);
    // The unlit screen around it, a little spill from the room.
    float3 screen = float3(0.0015);
    l = mix(screen, l, inside);
    // Screen texture: a fine matte grain, two octaves in camera pixels, static.
    if (p[2] > 0.0) {
        float2 c = float2(gid) / 1.6;
        float2 i = floor(c), f = fract(c);
        float2 s = f * f * (3.0 - 2.0 * f);
        float n00 = tc_unit(uint(i.x), uint(i.y), 0x5343u, 1u), n10 = tc_unit(uint(i.x) + 1u, uint(i.y), 0x5343u, 1u);
        float n01 = tc_unit(uint(i.x), uint(i.y) + 1u, 0x5343u, 1u), n11 = tc_unit(uint(i.x) + 1u, uint(i.y) + 1u, 0x5343u, 1u);
        float n = mix(mix(n00, n10, s.x), mix(n01, n11, s.x), s.y);
        float fine = tc_unit(gid.x, gid.y, 0x5354u, 2u);
        l *= 1.0 + p[2] * 0.12 * ((0.65 * n + 0.35 * fine) - 0.5);
    }
    dst.write(float4(tc_enc(l), 1.0), gid);
}

// Camera: the camcorder's softness, its glow around highlights, the tube's lag (a decaying
// charge left behind bright highlights, so they trail when they move), and the iris and
// white balance hunting. p: softness sigma px, lag keep per field (0 none), lag history valid,
// glow, gains r, g, b, pixel aspect. Texture 2 the lag charge of the last field, 3 this one's.
kernel void tc_camera(texture2d<float, access::sample> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      texture2d<float, access::read> lagIn [[texture(2)]],
                      texture2d<float, access::write> lagOut [[texture(3)]],
                      constant float *p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]])
{
    float2 size = float2(dst.get_width(), dst.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    float2 uv = tc_uv(gid, size);
    float2 texel = 1.0 / size;
    float sigma = p[0];
    float3 l;
    if (sigma > 0.05) {
        float3 sum = 0.0;
        float wsum = 0.0;
        for (int y = -2; y <= 2; y++) {
            for (int x = -2; x <= 2; x++) {
                float2 o = float2(x * p[7], y);
                float w = exp(-dot(o, o) / (2.0 * sigma * sigma));
                sum += tc_lin(src.sample(tc_clamp, uv + float2(x, y) * texel).rgb) * w;
                wsum += w;
            }
        }
        l = sum / wsum;
    } else {
        l = tc_lin(src.sample(tc_clamp, uv).rgb);
    }
    // Glow: the target's bloom, light over the knee spread on a ring of 3 and 7 px.
    if (p[3] > 0.0) {
        float3 g = 0.0;
        for (int i = 0; i < 12; i++) {
            float a = float(i) * 0.5236;
            float2 dir = float2(cos(a) / p[7], sin(a));
            g += max(tc_lin(src.sample(tc_clamp, uv + dir * 3.0 * texel).rgb) - 0.6, 0.0);
            g += 0.5 * max(tc_lin(src.sample(tc_clamp, uv + dir * 7.0 * texel).rgb) - 0.6, 0.0);
        }
        l += p[3] * 0.08 * g;
    }
    // Lag: the charge over the knee left on the target, decaying field by field.
    float3 bright = max(l - 0.35, 0.0);
    float3 charge = bright;
    if (p[1] > 0.0 && p[2] > 0.5) {
        float3 left = lagIn.read(gid).rgb * p[1];
        charge = max(bright, left);
        l += max(left - bright, 0.0);
    }
    lagOut.write(float4(charge, 1.0), gid);
    l *= float3(p[4], p[5], p[6]);
    dst.write(float4(tc_enc(l), 1.0), gid);
}

// Scanner: the flying spot's afterglow, a streak decaying to the right of whites (the
// phosphor still glowing as the spot moves on), the photomultiplier's noise, and a CCD line
// sensor's column streaks (one gain per sensor element, so a streak runs down the frame).
// p: afterglow, tail px, noise, streaks, seed bits, field bits.
kernel void tc_scanner(texture2d<float, access::read> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       constant float *p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
    uint w = dst.get_width();
    if (gid.x >= w || gid.y >= dst.get_height()) return;
    float3 l = tc_lin(src.read(gid).rgb);
    if (p[0] > 0.0) {
        float tail = p[1];
        float3 sum = 0.0;
        float wsum = 0.0;
        for (int k = 1; k <= 48; k++) {
            float dx = float(k) * 5.0;
            float wk = exp(-dx / tail);
            int x = int(gid.x) - int(dx);
            wsum += wk;
            if (x < 0) continue;
            sum += max(tc_lin(src.read(uint2(uint(x), gid.y)).rgb) - 0.5, 0.0) * wk;
        }
        l += p[0] * 0.6 * sum / wsum;
    }
    uint seed = as_type<uint>(p[4]);
    if (p[3] > 0.0) {
        float g = tc_unit(seed, gid.x, 0x434Cu, 7u) - 0.5;
        float g2 = tc_unit(seed, gid.x / 9u, 0x434Cu, 8u) - 0.5;
        l *= 1.0 + p[3] * (0.05 * g + 0.03 * g2);
    }
    if (p[2] > 0.0) {
        uint field = as_type<uint>(p[5]);
        float n = (tc_unit(seed, gid.x, gid.y, field) + tc_unit(seed ^ 0x55u, gid.x, gid.y, field) - 1.0);
        float y = tc_luma(l);
        // Shot noise of the photomultiplier: grows with the light, never zero.
        l += p[2] * 0.035 * n * (0.3 + sqrt(max(y, 0.0)));
    }
    dst.write(float4(tc_enc(l), 1.0), gid);
}

// Grade: the fade correction (per channel, a power and a gain in linear that balance mid gray
// against the dye loss), then the colorist's lift, gamma and gain on display values.
// p: lift r, g, b, gamma r, g, b, gain r, g, b, fade power r, g, b, fade gain r, g, b.
kernel void tc_grade(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     constant float *p [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float3 l = tc_lin(src.read(gid).rgb);
    l = pow(max(l, 0.0), float3(p[9], p[10], p[11])) * float3(p[12], p[13], p[14]);
    float3 c = tc_enc(l);
    float3 lift = float3(p[0], p[1], p[2]), gamma = float3(p[3], p[4], p[5]), gain = float3(p[6], p[7], p[8]);
    c = gain * (c + lift * (1.0 - c));
    c = pow(max(c, 0.0), 1.0 / gamma);
    dst.write(float4(c, 1.0), gid);
}
