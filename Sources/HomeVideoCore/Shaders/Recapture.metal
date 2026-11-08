#include <metal_stdlib>
using namespace metal;

// Re-capture (RecaptureLayers.swift): a newer camera filming the Display canvas, from the
// canvas onto the camera's frame. Linear light from rc_optics to rc_denoise, the camera's encode
// in rc_sharpen, the codec last. ShaderLibrary's runtime fallback concatenates the .metal
// sources in name order, so every helper here carries an rc_ prefix. The unsharp mask's blur
// reuses CRT.metal's crt_blur.

constexpr sampler rc_linear(coord::normalized, address::clamp_to_edge, filter::linear);

// The phosphor's light caught by a row exposed from a to a + s, everything in fields. The beam
// lands at height y once a field, at k + y, and the light then decays with time constant tau.
// The share of one landing's light inside the window is G(end) minus G(start), G(u) = 1 minus
// exp(-u / tau) for u over 0. Held so a window of whole fields reads 1: divided by s when the
// window is longer than a field, so a shorter one reads 1 where a landing falls inside and
// darker where none does (the bar).
inline float rc_caught(float a, float s, float y, float tau) {
    int k0 = int(floor(a - y - 12.0 * tau)) - 1;
    int k1 = int(ceil(a + s - y));
    float e = 0.0;
    for (int k = k0; k <= k1; k++) {
        float land = float(k) + y;
        float u1 = a + s - land, u0 = a - land;
        float g1 = u1 > 0.0 ? 1.0 - exp(-u1 / tau) : 0.0;
        float g0 = u0 > 0.0 ? 1.0 - exp(-u0 / tau) : 0.0;
        e += g1 - g0;
    }
    return e / max(1.0, s);
}

// 1 Hand, Lens, Glare and Shutter. p: scale (screen heights per frame height), hand x, hand y
// (frame heights), yaw, pitch (radians), distance (screen heights), whole screen, defocus (px),
// low pass (px), vignette, glare strength, glare size, glare x, glare y, room light, shutter
// on, beam phase (fields), readout (fields), exposure (fields), decay (fields), the tube's shape
// under Fill the frame (0 for 4:3). `across` is the upright phone's readout: its
// sensor's rows stand on end, so a column starts its exposure readout times its place across the
// frame later. A template rather than a branch, so every other camera keeps its exact bytes (a
// branch on a parameter moves the rounding).
template <bool across>
inline void rc_optics_body(texture2d<float> canvas, texture2d<float, access::write> dst,
                           constant float *p, uint2 gid) {
    float W = float(dst.get_width()), H = float(dst.get_height());
    if (float(gid.x) >= W || float(gid.y) >= H) return;
    float scale = p[0], d = p[5];
    bool whole = p[6] > 0.5;
    float blur = sqrt(p[7] * p[7] + p[8] * p[8]);
    float cy = cos(p[3]), sy = sin(p[3]), cp = cos(p[4]), sp = sin(p[4]);
    // The rolling shutter: this row starts its exposure readout times its height later.
    float start = across ? p[16] + (float(gid.x) + 0.5) / W * p[17] : p[16] + (float(gid.y) + 0.5) / H * p[17];
    float3 sum = 0.0;
    for (int i = 0; i < 16; i++) {
        // A 4 by 4 grid over the site's area, each point spread on a disc for the lens's blur.
        float2 o = (float2(float(i % 4), float(i / 4)) + 0.5) / 4.0 - 0.5;
        float r = sqrt((float(i) + 0.5) / 16.0) * blur, ang = float(i) * 2.39996323;
        o += r * float2(cos(ang), sin(ang));
        // The site in frame heights from the center, the hand taken out.
        float2 q = (float2(gid) + 0.5 + o - float2(W, H) * 0.5) / H - float2(p[1], p[2]);
        q *= scale;
        // The keystone: the screen turned by yaw about its vertical axis, then by pitch.
        float X = q.x * d / (d * cy - q.x * sy);
        float Y = q.y * (d + X * sy) / d;
        float Y2 = Y * d / (d * cp - Y * sp);
        float X2 = X * (d + Y2 * sp) / d;
        // Under Fill the frame p[20] is the tube's shape.
        bool wide = p[20] > 0.0;
        float2 uv = wide ? float2(X2 / p[20] + 0.5, Y2 + 0.5) : float2(X2 * 0.75 + 0.5, Y2 + 0.5);
        float3 light = 0.0;
        // The face of the tube, a rounded rectangle, with the bezel and the room around it.
        float2 e = abs(float2(X2, Y2)) - (wide ? float2(0.5 * p[20], 0.5) : float2(2.0 / 3.0, 0.5)) + 0.05;
        float face = length(max(e, 0.0)) + min(max(e.x, e.y), 0.0) - 0.05;
        float px = scale / H;
        float onGlass = whole ? 1.0 - smoothstep(-px, px, face) : 1.0;
        if (onGlass > 0.0) {
            float3 c = pow(max(canvas.sample(rc_linear, uv).rgb, 0.0), 2.2);
            if (p[15] > 0.5) c *= rc_caught(start, p[18], clamp(uv.y, 0.0, 1.0), p[19]);
            // The glass: a lamp's soft reflection and the room's light, fixed to the screen.
            float2 g = wide ? (float2(uv.x * p[20], uv.y) - float2(p[12] * p[20], p[13])) / max(p[11], 1e-3)
                            : (float2(uv.x * 4.0 / 3.0, uv.y) - float2(p[12] * 4.0 / 3.0, p[13])) / max(p[11], 1e-3);
            c += p[10] * exp(-0.5 * dot(g, g)) + p[14];
            light += c * onGlass;
        }
        if (whole) {
            // The bezel, dark plastic lit a little by the room, then the room.
            float bezel = (1.0 - smoothstep(0.09 - px, 0.09 + px, face)) * (1.0 - onGlass);
            float room = 1.0 - onGlass - bezel;
            light += float3(0.004, 0.0037, 0.0034) * bezel + float3(0.0015, 0.0013, 0.0011) * room;
        }
        sum += light;
    }
    float3 c = sum / 16.0;
    // The vignette: falloff with the square of the distance from the frame's center, cosine
    // fourth in shape, 1 at the center and 1 / (1 + v)^2 in the corners.
    float2 f = ((float2(gid) + 0.5) / float2(W, H) - 0.5) * 2.0;
    float v = 1.0 + p[9] * 0.5 * dot(f, f);
    dst.write(float4(c / (v * v), 1.0), gid);
}

kernel void rc_optics(texture2d<float> canvas [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant float *p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    rc_optics_body<false>(canvas, dst, p, gid);
}

// The upright phone's optics, its readout across the frame.
kernel void rc_optics_across(texture2d<float> canvas [[texture(0)]],
                             texture2d<float, access::write> dst [[texture(1)]],
                             constant float *p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
    rc_optics_body<true>(canvas, dst, p, gid);
}

// A hash to a uniform in 0 to 1.
inline float rc_hash(uint a, uint b, uint c, uint d) {
    uint h = a * 0x8DA6B343u ^ b * 0xD8163841u ^ c * 0xCB1AB31Fu ^ d * 0x9E3779B1u;
    h ^= h >> 15; h *= 0x2C1B3C6Du; h ^= h >> 12; h *= 0x297A2D39u; h ^= h >> 15;
    return (float(h >> 8) + 0.5) / 16777216.0;
}

// 2 Exposure and the Sensor's wells. p: exposure gain, white balance red, green, blue, noise,
// mosaic, frame, seed. The light times the gain and the balance, shot and read noise, clipped at
// the full well (1) and the floor. Alpha carries the value the site's own Bayer filter passes:
// red, green, green, blue on a 2 by 2 tile.
kernel void rc_sensor(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant float *p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float3 v = src.read(gid).rgb * p[0] * float3(p[1], p[2], p[3]);
    if (p[4] > 0.0) {
        uint fr = uint(p[6]), sd = uint(p[7]);
        for (int ch = 0; ch < 3; ch++) {
            float u1 = rc_hash(gid.x, gid.y, fr * 3u + uint(ch), sd);
            float u2 = rc_hash(gid.y, gid.x, fr * 3u + uint(ch) + 7919u, sd ^ 0x5bd1e995u);
            float n = sqrt(-2.0 * log(u1)) * cos(6.28318531 * u2);
            v[ch] += p[4] * sqrt(max(v[ch], 0.0) + 0.01) * n;
        }
    }
    v = clamp(v, 0.0, 1.0);
    uint sx = gid.x & 1u, sy = gid.y & 1u;
    float site = (sx == 0u && sy == 0u) ? v.r : ((sx == 1u && sy == 1u) ? v.b : v.g);
    dst.write(float4(v, site), gid);
}

// A neighbor's Bayer value, mirrored at the edge so a site's parity is kept.
inline float rc_site(texture2d<float, access::read> src, int2 c, int dx, int dy) {
    int W = int(src.get_width()), H = int(src.get_height());
    int2 q = c + int2(dx, dy);
    if (q.x < 0) q.x = -q.x;
    if (q.y < 0) q.y = -q.y;
    if (q.x >= W) q.x = 2 * W - 2 - q.x;
    if (q.y >= H) q.y = 2 * H - 2 - q.y;
    return src.read(uint2(q)).a;
}

// The Sensor's demosaic: each site's two missing colors from its neighbors (bilinear), mixed
// with the full color by the mosaic. p: mosaic.
kernel void rc_demosaic(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant float *p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]]) {
    int W = int(dst.get_width()), H = int(dst.get_height());
    if (int(gid.x) >= W || int(gid.y) >= H) return;
    int2 c = int2(gid);
    float self = rc_site(src, c, 0, 0);
    float orth = 0.25 * (rc_site(src, c, -1, 0) + rc_site(src, c, 1, 0) + rc_site(src, c, 0, -1)
                         + rc_site(src, c, 0, 1));
    float diag = 0.25 * (rc_site(src, c, -1, -1) + rc_site(src, c, 1, -1) + rc_site(src, c, -1, 1)
                         + rc_site(src, c, 1, 1));
    float horiz = 0.5 * (rc_site(src, c, -1, 0) + rc_site(src, c, 1, 0));
    float vert = 0.5 * (rc_site(src, c, 0, -1) + rc_site(src, c, 0, 1));
    bool ex = (c.x & 1) == 0, ey = (c.y & 1) == 0;
    float3 m;
    if (ex && ey) m = float3(self, orth, diag);           // red site
    else if (!ex && !ey) m = float3(diag, orth, self);    // blue site
    else if (!ex && ey) m = float3(horiz, self, vert);    // green on a red row
    else m = float3(vert, self, horiz);                    // green on a blue row
    float3 full = src.read(gid).rgb;
    dst.write(float4(mix(full, m, p[0]), 1.0), gid);
}

// 3 Processing, noise reduction: a range weighted 5 by 5 blur on the encoded values, so it
// smooths noise and fine texture and stops at edges. p: strength.
kernel void rc_denoise(texture2d<float, access::read> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       constant float *p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    int W = int(dst.get_width()), H = int(dst.get_height());
    if (int(gid.x) >= W || int(gid.y) >= H) return;
    float3 c = src.read(gid).rgb;
    if (p[0] <= 0.0) { dst.write(float4(c, 1.0), gid); return; }
    float3 ce = pow(max(c, 0.0), 1.0 / 2.2);
    float range = 0.02 + 0.1 * p[0];
    float3 s = 0.0;
    float wsum = 0.0;
    for (int j = -2; j <= 2; j++) {
        for (int i = -2; i <= 2; i++) {
            int2 q = clamp(int2(gid) + int2(i, j), int2(0), int2(W - 1, H - 1));
            float3 v = src.read(uint2(q)).rgb;
            float3 dv = pow(max(v, 0.0), 1.0 / 2.2) - ce;
            float w = exp(-0.5 * float(i * i + j * j) / 2.25 - 0.5 * dot(dv, dv) / (range * range));
            s += v * w;
            wsum += w;
        }
    }
    dst.write(float4(mix(c, s / wsum, p[0]), 1.0), gid);
}

// 3 Processing, sharpening and the camera's encode: an unsharp mask on the encoded values, then
// clipped to the file's 0 to 1. p: amount, 1 / encode gamma.
kernel void rc_sharpen(texture2d<float, access::read> src [[texture(0)]],
                       texture2d<float, access::read> blurred [[texture(1)]],
                       texture2d<float, access::write> dst [[texture(2)]],
                       constant float *p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float3 e = pow(max(src.read(gid).rgb, 0.0), float3(p[1]));
    float3 b = pow(max(blurred.read(gid).rgb, 0.0), float3(p[1]));
    dst.write(float4(clamp(e + p[0] * (e - b), 0.0, 1.0), 1.0), gid);
}

// The orthonormal DCT basis, N points, frequency u at sample i.
inline float rc_basis(int N, int u, int i) {
    float c = u == 0 ? sqrt(1.0 / float(N)) : sqrt(2.0 / float(N));
    return c * cos((2.0 * float(i) + 1.0) * float(u) * 3.14159265 / (2.0 * float(N)));
}

// Quantize a coefficient with a dead zone: a level is rounded down past a sixth of a step,
// so small coefficients go to 0 (the encoder's rounding offset, INFERRED).
inline float rc_quant(float c, float step) {
    return sign(c) * floor(fabs(c) / step + 1.0 / 6.0) * step;
}

// 3 Processing, the codec: one thread per 8 by 8 block. Rec. 709 Y'CbCr, luma through an 8 by 8
// transform, chroma averaged 2 by 2 (4:2:0) through a 4 by 4 one, every coefficient quantized
// with a step that grows with frequency, back to R'G'B' and rounded to 8 bits. p: step.
kernel void rc_codec(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     constant float *p [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    int W = int(dst.get_width()), H = int(dst.get_height());
    int2 b0 = int2(gid) * 8;
    if (b0.x >= W || b0.y >= H) return;
    float y[64], cb[16], cr[16];
    for (int j = 0; j < 16; j++) { cb[j] = 0.0; cr[j] = 0.0; }
    for (int j = 0; j < 8; j++) {
        for (int i = 0; i < 8; i++) {
            int2 q = min(b0 + int2(i, j), int2(W - 1, H - 1));
            float3 c = src.read(uint2(q)).rgb;
            float l = dot(c, float3(0.2126, 0.7152, 0.0722));
            y[j * 8 + i] = l;
            cb[(j / 2) * 4 + i / 2] += 0.25 * (c.b - l) / 1.8556;
            cr[(j / 2) * 4 + i / 2] += 0.25 * (c.r - l) / 1.5748;
        }
    }
    float step = p[0];
    // Luma, 8 by 8.
    float k[64];
    for (int v = 0; v < 8; v++) {
        for (int u = 0; u < 8; u++) {
            float s = 0.0;
            for (int j = 0; j < 8; j++)
                for (int i = 0; i < 8; i++) s += y[j * 8 + i] * rc_basis(8, u, i) * rc_basis(8, v, j);
            k[v * 8 + u] = rc_quant(s, step * 8.0 * (1.0 + 0.25 * float(u + v)));
        }
    }
    for (int j = 0; j < 8; j++) {
        for (int i = 0; i < 8; i++) {
            float s = 0.0;
            for (int v = 0; v < 8; v++)
                for (int u = 0; u < 8; u++) s += k[v * 8 + u] * rc_basis(8, u, i) * rc_basis(8, v, j);
            y[j * 8 + i] = s;
        }
    }
    // Chroma, 4 by 4 each, a coarser step.
    float kb[16], kr[16];
    for (int v = 0; v < 4; v++) {
        for (int u = 0; u < 4; u++) {
            float sb = 0.0, sr = 0.0;
            for (int j = 0; j < 4; j++)
                for (int i = 0; i < 4; i++) {
                    float w = rc_basis(4, u, i) * rc_basis(4, v, j);
                    sb += cb[j * 4 + i] * w;
                    sr += cr[j * 4 + i] * w;
                }
            float cs = step * 6.0 * (1.0 + 0.25 * float(u + v));
            kb[v * 4 + u] = rc_quant(sb, cs);
            kr[v * 4 + u] = rc_quant(sr, cs);
        }
    }
    for (int j = 0; j < 4; j++) {
        for (int i = 0; i < 4; i++) {
            float sb = 0.0, sr = 0.0;
            for (int v = 0; v < 4; v++)
                for (int u = 0; u < 4; u++) {
                    float w = rc_basis(4, u, i) * rc_basis(4, v, j);
                    sb += kb[v * 4 + u] * w;
                    sr += kr[v * 4 + u] * w;
                }
            cb[j * 4 + i] = sb;
            cr[j * 4 + i] = sr;
        }
    }
    for (int j = 0; j < 8; j++) {
        for (int i = 0; i < 8; i++) {
            int2 q = b0 + int2(i, j);
            if (q.x >= W || q.y >= H) continue;
            float l = y[j * 8 + i], b = cb[(j / 2) * 4 + i / 2], r = cr[(j / 2) * 4 + i / 2];
            float3 c = float3(l + 1.5748 * r, l - 0.1873 * b - 0.4681 * r, l + 1.8556 * b);
            c = round(clamp(c, 0.0, 1.0) * 255.0) / 255.0;
            dst.write(float4(c, 1.0), uint2(q));
        }
    }
}
