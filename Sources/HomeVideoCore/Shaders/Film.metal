#include <metal_stdlib>
using namespace metal;

// The Film source (docs/FILM.md): one kernel per Film layer, run by FilmLayers.swift on the
// film canvas (the Scan size, or the 720 by 480 raster on the Tape path). Every kernel reads
// texture 0, writes texture 1, and takes its values as a float array in buffer 0. The canvas
// holds display (gamma 2.2) values. A kernel that models light works in linear inside and
// writes display values back, so any layer can be switched off without breaking the others.
// The helpers carry a film_ prefix: at runtime every .metal file is compiled as one source.

inline uint film_pcg(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

/// A uniform 0 to 1 from four integers.
inline float film_unit(uint a, uint b, uint c, uint d) {
    uint h = film_pcg(a ^ 0x9E3779B9u);
    h = film_pcg(h ^ b);
    h = film_pcg(h ^ c);
    h = film_pcg(h ^ d);
    return float(h) / 4294967295.0;
}

inline float3 film_lin(float3 c) { return pow(max(c, 0.0), 2.2); }
inline float3 film_enc(float3 c) { return pow(max(c, 0.0), 1.0 / 2.2); }
inline float film_luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

constexpr sampler film_clamp(coord::normalized, address::clamp_to_edge, filter::linear);
constexpr sampler film_black(coord::normalized, address::clamp_to_zero, filter::linear);

inline float2 film_uv(uint2 gid, float2 size) { return (float2(gid) + 0.5) / size; }

// Shutter and flicker. p: previous frame weight, flicker gain.
kernel void film_shutter(texture2d<float, access::read> src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         texture2d<float, access::read> prev [[texture(2)]],
                         constant float *p [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 c = src.read(gid);
    float3 l = film_lin(c.rgb);
    float3 lp = film_lin(prev.read(gid).rgb);
    l = mix(l, lp, p[0]) * p[1];
    dst.write(float4(film_enc(l), c.a), gid);
}

// Light: the residual cast and the exposure. p: cast r, g, b, exposure multiplier.
kernel void film_light(texture2d<float, access::read> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       constant float *p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 c = src.read(gid);
    float3 l = film_lin(c.rgb) * float3(p[0], p[1], p[2]) * p[3];
    dst.write(float4(film_enc(l), c.a), gid);
}

// Optics: lens softness, vignette (stops at the corner), lateral chromatic aberration.
// p: softness sigma (canvas px, vertical), vignette stops, CA (canvas px at the corner),
// pixel aspect (pixel width over height), the picture's shape (0 for 4:3).
kernel void film_optics(texture2d<float, access::sample> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant float *p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]])
{
    float2 size = float2(dst.get_width(), dst.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    float2 uv = film_uv(gid, size);
    float aspect = p[3];
    // Display space: 4:3, the corner at radius 1. Under Fill the frame p[4] is the picture's
    // shape, its corner at radius 1 the same way.
    float r2;
    if (p[4] > 0.0) {
        float2 q = (uv - 0.5) * float2(p[4], 1.0);
        r2 = dot(q, q) / (0.25 * p[4] * p[4] + 0.25);
    } else {
        float2 q = (uv - 0.5) * float2(4.0 / 3.0, 1.0);
        r2 = dot(q, q) / (0.25 * (16.0 / 9.0) + 0.25);
    }
    float2 dir = uv - 0.5;
    // CA: red lands a little outward of green, blue a little inward, growing with the radius.
    float halfDiagonal = 0.5 * length(float2(size.x * aspect, size.y));
    float2 ca = dir * (p[2] / max(halfDiagonal, 1.0));
    float sigma = p[0];
    float2 stepUV = float2(sigma / aspect / size.x, sigma / size.y);
    float3 acc = 0.0;
    float wsum = 0.0;
    for (int j = -1; j <= 1; j++) {
        for (int i = -1; i <= 1; i++) {
            float w = (i == 0 && j == 0) ? 4.0 : ((i == 0 || j == 0) ? 2.0 : 1.0);
            float2 o = float2(i, j) * stepUV;
            float r = src.sample(film_clamp, uv + o + ca).r;
            float g = src.sample(film_clamp, uv + o).g;
            float b = src.sample(film_clamp, uv + o - ca).b;
            acc += w * film_lin(float3(r, g, b));
            wsum += w;
        }
    }
    float3 l = acc / wsum;
    l *= exp2(-p[1] * r2 * r2);
    dst.write(float4(film_enc(l), 1.0), gid);
}

// Format: the emulsion and lens blur at the frame's scale. A 7 by 7 Gaussian over a step that
// grows with sigma. p: sigma (canvas px, vertical), pixel aspect.
kernel void film_format(texture2d<float, access::sample> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant float *p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]])
{
    float2 size = float2(dst.get_width(), dst.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    float2 uv = film_uv(gid, size);
    float sigma = max(p[0], 0.01);
    float aspect = p[1];
    // Taps three per side, spaced to cover 2.5 sigma.
    float stepPx = max(sigma * 2.5 / 3.0, 0.35);
    float2 stepUV = float2(stepPx / aspect / size.x, stepPx / size.y);
    float3 acc = 0.0;
    float wsum = 0.0;
    for (int j = -3; j <= 3; j++) {
        for (int i = -3; i <= 3; i++) {
            float d2 = float(i * i + j * j) * stepPx * stepPx;
            float w = exp(-d2 / (2.0 * sigma * sigma));
            acc += w * film_lin(src.sample(film_clamp, uv + float2(i, j) * stepUV).rgb);
            wsum += w;
        }
    }
    dst.write(float4(film_enc(acc / wsum), 1.0), gid);
}

// Halation: light above a threshold goes through the emulsion, reflects off the base back and
// exposes the red sensitive layer again around the highlight. A 48 tap golden angle spiral
// over the radius. p: threshold (linear), strength, radius (canvas px, vertical), pixel
// aspect, tint r, g, b.
kernel void film_halation(texture2d<float, access::sample> src [[texture(0)]],
                          texture2d<float, access::write> dst [[texture(1)]],
                          constant float *p [[buffer(0)]],
                          uint2 gid [[thread_position_in_grid]])
{
    float2 size = float2(dst.get_width(), dst.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    float2 uv = film_uv(gid, size);
    float3 base = film_lin(src.sample(film_clamp, uv).rgb);
    float thr = p[0], radius = max(p[2], 0.5), aspect = p[3];
    float glow = 0.0, wsum = 0.0;
    const int taps = 48;
    for (int k = 0; k < taps; k++) {
        float t = (float(k) + 0.5) / float(taps);
        float r = sqrt(t) * radius;
        float a = float(k) * 2.39996323;
        float2 o = float2(cos(a) * r / aspect / size.x, sin(a) * r / size.y);
        float w = exp(-2.0 * t);
        float3 s = film_lin(src.sample(film_clamp, uv + o).rgb);
        glow += w * max(film_luma(s) - thr, 0.0) / max(1.0 - thr, 0.05);
        wsum += w;
    }
    glow /= wsum;
    float3 l = base + p[1] * glow * float3(p[4], p[5], p[6]);
    dst.write(float4(film_enc(l), 1.0), gid);
}

// Stock: the dyes' saturation and the stock's own cast. p: saturation, cast r, g, b.
kernel void film_stock(texture2d<float, access::read> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       constant float *p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float3 l = film_lin(src.read(gid).rgb);
    float y = film_luma(l);
    l = max(y + (l - y) * p[0], 0.0) * float3(p[1], p[2], p[3]);
    dst.write(float4(film_enc(l), 1.0), gid);
}

// Tone: the characteristic curve, per channel (so the toe crosses colors over as it does on
// reversal). p: negative (0 or 1), latitude in stops, contrast, exposure multiplier.
// Reversal: an S curve over the latitude around mid gray, steep, blacks crushed at Dmax and
// whites clipped at Dmin. Negative scanned: a long shoulder that keeps two stops over white,
// and a lifted toe from the base density.
kernel void film_tone(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant float *p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float3 e = film_lin(src.read(gid).rgb) * p[3];
    float range = max(p[1], 1.0), k = max(p[2], 0.05);
    float3 y;
    if (p[0] < 0.5) {
        float3 x = log2(max(e, 1e-6) / 0.18) / (range * 0.5);
        x = clamp(x, -2.0, 2.0);
        float3 s = tanh(k * x) / tanh(k);
        // Mid gray lands at 0.46 display, as on a straight 2.2 encode.
        y = select(0.46 + 0.46 * s, 0.46 + 0.54 * s, x >= 0.0);
        y = clamp(y, 0.0, 1.0);
    } else {
        // The scan is timed so mid gray lands where it was. Contrast turns about mid gray, the
        // straight line runs up to it, and above it a shoulder keeps about two stops past
        // white (video white reads 0.79 linear at the 12 stop latitude). The toe lifts by the
        // base density.
        float3 c = 0.18 * pow(max(e, 1e-6) / 0.18, k);
        float s = 0.6 * range / 12.0;
        float3 v = select(c, 0.18 + 0.82 * (1.0 - exp(-(c - 0.18) / s)), c > 0.18);
        y = 0.02 + 0.98 * film_enc(clamp(v, 0.0, 1.0));
    }
    dst.write(float4(y, 1.0), gid);
}

// Grain: the grain is never sharper than the scan, and sharper than the
// picture, which also went through the lens and the emulsion's scatter. Three passes.
// `film_grain_field` draws a fresh field every film frame, two octaves of value noise at the
// grain size, mostly shared by the three dye layers with a share of its own per layer at that
// layer's size. `film_grain_soften` runs the field through the scanner's part of the format's
// Gaussian (FilmLayers.swift, `grainScanShare`), with the same taps and the same sampler, so
// the field's spectrum is the scan's MTF times the noise's own, which falls from 0.
// `film_grain` adds it to the picture, each dye
// layer by its amount and by the stock's curve against that layer's encoded value.
inline float film_value(float2 q, uint seed, uint frame, uint ch) {
    float2 i = floor(q), f = q - i;
    f = f * f * (3.0 - 2.0 * f);
    int2 ii = int2(i);
    float a = film_unit(seed, frame, uint(ii.x) * 7919u + ch, uint(ii.y));
    float b = film_unit(seed, frame, uint(ii.x + 1) * 7919u + ch, uint(ii.y));
    float c = film_unit(seed, frame, uint(ii.x) * 7919u + ch, uint(ii.y + 1));
    float d = film_unit(seed, frame, uint(ii.x + 1) * 7919u + ch, uint(ii.y + 1));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y) * 2.0 - 1.0;
}

// The field, signed, one value per dye layer. p: cell (canvas px, vertical), pixel aspect,
// shared part's weight, seed bits, frame bits, each layer's own cell over the shared one (r, g,
// b), the shared part's gain, each layer's own part's gain (r, g, b). The gains put back the
// RMS the softening takes out, so the field keeps its strength through the softening (FilmLayers.swift,
// `grainGains`).
kernel void film_grain_field(texture2d<float, access::write> dst [[texture(1)]],
                             constant float *p [[buffer(0)]],
                             uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float cell = max(p[0], 0.5), aspect = p[1], share = p[2];
    uint seed = as_type<uint>(p[3]), frame = as_type<uint>(p[4]);
    float2 at = float2(gid) * float2(aspect, 1.0);
    float2 q = at / cell;
    float common = film_value(q, seed, frame, 0u) + 0.5 * film_value(q * 2.0 + 17.3, seed, frame, 4u);
    float3 own;
    own.r = film_value(at / max(cell * p[5], 0.5) + 3.1, seed, frame, 1u);
    own.g = film_value(at / max(cell * p[6], 0.5) + 5.7, seed, frame, 2u);
    own.b = film_value(at / max(cell * p[7], 0.5) + 9.3, seed, frame, 3u);
    float3 n = (1.0 - share) * p[8] * common + share * 1.25 * float3(p[9], p[10], p[11]) * own;
    dst.write(float4(n, 0.0), gid);
}

// The scan's softening, on the field, linear (the field is signed).
// p: sigma (canvas px, vertical), pixel aspect. The taps are the 7 by 7 Gaussian of
// `film_format`.
kernel void film_grain_soften(texture2d<float, access::sample> src [[texture(0)]],
                              texture2d<float, access::write> dst [[texture(1)]],
                              constant float *p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]])
{
    float2 size = float2(dst.get_width(), dst.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    float2 uv = film_uv(gid, size);
    float aspect = p[1];
    float3 acc = 0.0;
    float wsum = 0.0;
    float sigma = max(p[0], 0.01);
    float stepPx = max(sigma * 2.5 / 3.0, 0.35);
    float2 stepUV = float2(stepPx / aspect / size.x, stepPx / size.y);
    for (int j = -3; j <= 3; j++) {
        for (int i = -3; i <= 3; i++) {
            float d2 = float(i * i + j * j) * stepPx * stepPx;
            float w = exp(-d2 / (2.0 * sigma * sigma));
            acc += w * src.sample(film_clamp, uv + float2(i, j) * stepUV).rgb;
            wsum += w;
        }
    }
    dst.write(float4(acc / wsum, 0.0), gid);
}

// The grain on the picture. Texture 2 is the softened field. p: amplitude, the stock's curve
// at encoded 0, 0.25, 0.5, 0.75 and 1 (FilmStock.grainCurve), each dye layer's amount (r, g, b,
// FilmStock.grainPerChannel).
inline float film_curve(float v, constant float *k) {
    float x = clamp(v, 0.0, 1.0) * 4.0;
    int i = min(int(x), 3);
    return mix(k[i], k[i + 1], x - float(i));
}

kernel void film_grain(texture2d<float, access::read> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       texture2d<float, access::read> field [[texture(2)]],
                       constant float *p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float3 c = src.read(gid).rgb;
    float3 n = field.read(gid).rgb;
    float3 m = float3(film_curve(c.r, p + 1), film_curve(c.g, p + 1), film_curve(c.b, p + 1));
    dst.write(float4(c + p[0] * float3(p[6], p[7], p[8]) * m * n, 1.0), gid);
}

// Fade: each dye loses density over the years at its own rate. Cyan sets red, magenta green,
// yellow blue. p: density kept for cyan, magenta, yellow.
kernel void film_fade(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant float *p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float3 t = clamp(film_lin(src.read(gid).rgb), 0.001, 1.0);
    float3 d = -log10(t) * float3(p[0], p[1], p[2]);
    dst.write(float4(film_enc(pow(10.0, -d)), 1.0), gid);
}

// Damage: dust, hair, scratches, a splice, roll end fog and the frame line, from a table the
// CPU builds per film frame (FilmLayers.swift, `damageTable`). Dust and hair take the stock's
// polarity: they block light, so dark on a reversal original, white on a print or scan of a
// negative. Scratches the other way: an emulsion scratch on reversal lets light through.
// p[0] polarity (+1 white, -1 dark), p[1] fog, p[2] frame line height (share of height),
// p[3] pixel aspect, p[4] specks, p[5] scratches, p[6] hairs, p[7] splice top, p[8] splice
// bottom, p[9] splice level, p[10] unit (canvas px per 1080 px). Specks from 16, four floats
// each (x, y, radius at 1080, opacity), 48 of them. Scratches from 208, four each (x, width
// at 1080, opacity, unused), 4 of them. Hairs from 224, ten each (four x, y points, width at
// 1080, opacity), 3 of them.
kernel void film_damage(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant float *p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]])
{
    float2 size = float2(dst.get_width(), dst.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    float3 c = src.read(gid).rgb;
    float2 uv = film_uv(gid, size);
    float aspect = p[3], unit = p[10];
    // Positions in 1080 line units, x scaled to display width.
    float2 pos = float2(gid) * float2(aspect, 1.0) / unit;
    float2 scale = size * float2(aspect, 1.0) / unit;
    float block = 0.0;
    int specks = int(p[4]);
    for (int i = 0; i < specks; i++) {
        int o = 16 + i * 4;
        float2 ctr = float2(p[o], p[o + 1]) * scale;
        float r = p[o + 2];
        float d = length(pos - ctr) / max(r, 0.3);
        if (d < 1.6) {
            float edge = 0.25 * (film_unit(uint(i), uint(gid.x), uint(gid.y), 77u) - 0.5);
            block = max(block, p[o + 3] * smoothstep(1.0, 0.55, d + edge));
        }
    }
    int hairs = int(p[6]);
    for (int h = 0; h < hairs; h++) {
        int o = 224 + h * 10;
        float best = 1e9;
        float2 prevPt = float2(p[o], p[o + 1]) * scale;
        for (int s = 1; s <= 12; s++) {
            float t = float(s) / 12.0;
            float u = 1.0 - t;
            float2 b = u * u * u * float2(p[o], p[o + 1]) + 3.0 * u * u * t * float2(p[o + 2], p[o + 3])
                + 3.0 * u * t * t * float2(p[o + 4], p[o + 5]) + t * t * t * float2(p[o + 6], p[o + 7]);
            b *= scale;
            float2 ab = b - prevPt, ap = pos - prevPt;
            float k = clamp(dot(ap, ab) / max(dot(ab, ab), 1e-4), 0.0, 1.0);
            best = min(best, length(ap - ab * k));
            prevPt = b;
        }
        block = max(block, p[o + 9] * smoothstep(p[o + 8], p[o + 8] * 0.4, best));
    }
    float3 l = film_lin(c);
    float pol = p[0];
    float3 target = pol > 0.0 ? float3(1.0) : float3(0.02);
    l = mix(l, target, block);
    int scratches = int(p[5]);
    for (int s = 0; s < scratches; s++) {
        int o = 208 + s * 4;
        float x = p[o] * scale.x;
        float d = abs(pos.x - x) / max(p[o + 1], 0.3);
        float a = p[o + 2] * smoothstep(1.0, 0.3, d);
        // The opposite of dust: bright on reversal, dark on a negative's print.
        float3 st = pol > 0.0 ? float3(0.03) : float3(0.9, 1.0, 0.95);
        l = mix(l, st, a);
    }
    // A splice: the cement overlap band reads lighter, with a hard edge.
    if (p[9] > 0.0 && uv.y >= p[7] && uv.y <= p[8]) {
        l = l * (1.0 - 0.5 * p[9]) + 0.35 * p[9];
        if (uv.y - p[7] < 2.0 / size.y || p[8] - uv.y < 2.0 / size.y) l *= 0.3;
    }
    // Roll end fog: light leaked onto the spool's outer turns, warm, from the left edge.
    if (p[1] > 0.0) {
        float leak = p[1] * exp(-uv.x / 0.35) * (0.7 + 0.3 * sin(uv.y * 5.0 + 1.3));
        l += leak * float3(1.0, 0.45, 0.12);
    }
    // The frame line: the bar between frames, seen at the top when the frame sits low.
    if (p[2] > 0.0) {
        float edge = smoothstep(p[2], p[2] - 2.0 / size.y, uv.y);
        l *= 1.0 - 0.97 * edge;
    }
    dst.write(float4(film_enc(l), 1.0), gid);
}

// Weave: the whole frame moved in the gate. Revealed edges are the gate's black.
// p: dx, dy in canvas px.
kernel void film_weave(texture2d<float, access::sample> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       constant float *p [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
    float2 size = float2(dst.get_width(), dst.get_height());
    if (gid.x >= size.x || gid.y >= size.y) return;
    float2 uv = (float2(gid) + 0.5 - float2(p[0], p[1])) / size;
    float4 c = src.sample(film_black, uv);
    dst.write(float4(c.rgb, 1.0), gid);
}
