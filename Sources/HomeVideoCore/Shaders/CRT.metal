#include <metal_stdlib>
using namespace metal;

// The Display stage (CRTLayers.swift): what the tube does to the light, from the 720 by
// 480 raster onto a 4:3 canvas at the Display size. Linear light between crt_transfer and
// crt_glass. ShaderLibrary's runtime fallback concatenates the .metal sources in name order,
// so every helper here carries a crt_ prefix.

constexpr sampler crt_linear(coord::normalized, address::clamp_to_edge, filter::linear);

// The error function, Abramowitz and Stegun 7.1.26 (absolute error under 1.5e-7).
inline float crt_erf(float x) {
    float s = sign(x), a = fabs(x);
    float t = 1.0 / (1.0 + 0.3275911 * a);
    float y = 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t
                     + 0.254829592) * t * exp(-a * a);
    return s * y;
}

// The share of a unit-area Gaussian of `sigma` centered at 0 that lies in [a, b].
inline float crt_band(float a, float b, float sigma) {
    float k = 1.0 / (sigma * 1.41421356);
    return 0.5 * (crt_erf(b * k) - crt_erf(a * k));
}

// 1 Transfer: the signal decoded to light. p: gamma, black lift, then the three gun gains.
// With Transfer off the Swift side passes gamma 2.2, lift 0 and unit gains.
kernel void crt_transfer(texture2d<float, access::read> src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         constant float *p [[buffer(0)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float3 v = max(src.read(gid).rgb, 0.0);
    v = p[1] + (1.0 - p[1]) * v;
    float3 l = pow(v, float3(p[0])) * float3(p[2], p[3], p[4]);
    dst.write(float4(l, 1.0), gid);
}

// One gun's light at canvas point uv (0 to 1 over the raster), channel c, through the beam.
// Lines are the raster's 480, line k's center at k + 0.5. The spot's sigma, in lines, runs from
// `dark` to `bright` with the gun's level (its encoded value, so the step looks even). `h` is
// the canvas pixel's height in lines: the spot is integrated over it, so a thin line keeps its
// light and does not alias.
inline float crt_beam(texture2d<float> lin, float2 uv, int c, float h, float dark, float bright,
                      float fade, int field) {
    float H = float(lin.get_height());
    float y = uv.y * H;
    int k0 = int(floor(y)) - 2;
    float sum = 0.0;
    for (int k = k0; k <= k0 + 5; k++) {
        if (k < 0 || k >= int(H)) continue;
        float level = lin.sample(crt_linear, float2(uv.x, (float(k) + 0.5) / H))[c];
        float e = pow(clamp(level, 0.0, 1.0), 1.0 / 2.2);
        float sigma = mix(dark, bright, e);
        float d = y - (float(k) + 0.5);
        float w = crt_band(d - 0.5 * h, d + 0.5 * h, sigma) / h;
        // The field drawn before the current one has faded a little.
        if ((k & 1) != field) w *= 1.0 - fade;
        sum += level * w;
    }
    // Held at the picture's mean level: the two fields average to 1 - fade / 2.
    return sum / (1.0 - 0.5 * fade);
}

// 2 Beam and 5 Geometry. p: beam on, sigma dark, sigma bright, field fade, current field,
// geometry on, overscan, barrel, corner falloff, rotation (radians), convergence (lines), the
// tube's shape under Fill the frame (0 for 4:3).
kernel void crt_scan(texture2d<float> lin [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     constant float *p [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    uint W = dst.get_width(), Hc = dst.get_height();
    if (gid.x >= W || gid.y >= Hc) return;
    bool beam = p[0] > 0.5, geo = p[5] > 0.5;
    float aspect = float(W) / float(Hc);
    float2 c = (float2(gid) + 0.5) / float2(W, Hc) * 2.0 - 1.0;
    float shade = 1.0;
    float overscan = 0.0;
    if (geo) {
        // In square units on the glass, then back.
        float2 q = float2(c.x * aspect, c.y);
        float cs = cos(p[9]), sn = sin(p[9]);
        q = float2(cs * q.x - sn * q.y, sn * q.x + cs * q.y);
        float r2 = dot(q, q) / (aspect * aspect + 1.0);
        q *= 1.0 + p[7] * r2;
        overscan = p[6];
        c = float2(q.x / aspect, q.y) * (1.0 - overscan);
        shade = 1.0 - p[8] * r2 * r2;
    }
    float2 uv = (c + 1.0) * 0.5;
    // The raster's edge, softened over one canvas pixel so a curved edge does not stair.
    float2 px = float2(1.0 - overscan) / float2(W, Hc);
    float2 inside = smoothstep(-px, px, uv) * smoothstep(-px, px, 1.0 - uv);
    float edge = inside.x * inside.y;

    float H = float(lin.get_height());
    float h = H * (1.0 - overscan) / float(Hc);
    // Convergence: red lands right and down, blue left and up, green on the mark. One line is
    // 1/480 of the height, and the same distance across is 3/4 of that in uv.
    float conv = geo ? p[10] : 0.0;
    float2 off = float2(conv * 0.75 / H, conv * 0.5 / H);
    // Under Fill the frame p[11] is the tube's shape: the same distance across is one
    // over that shape of a line in uv.
    if (p[11] > 0.0) off.x = conv / p[11] / H;
    float3 rgb;
    int field = int(p[4]);
    for (int ch = 0; ch < 3; ch++) {
        float2 u = uv + off * float(1 - ch);
        rgb[ch] = beam ? crt_beam(lin, u, ch, h, p[1], p[2], p[3], field)
                       : lin.sample(crt_linear, u)[ch];
    }
    dst.write(float4(max(rgb, 0.0) * shade * edge, 1.0), gid);
}

// The share of [a, b) (in triad units, b - a under 1) that falls in [lo, hi) of each period.
inline float crt_cover(float a, float b, float lo, float hi) {
    float n = floor(a);
    float s = 0.0;
    for (int i = 0; i < 2; i++) {
        float base = n + float(i);
        s += max(0.0, min(b, base + hi) - max(a, base + lo));
    }
    return s / (b - a);
}

// 3 Mask. p: kind (0 shadow mask dots, 1 aperture grille), triad (px), strength. The mask is
// fixed on the glass, in canvas pixels. Each phosphor passes only its own gun's light: red
// light lands on the red third of the triad, and so on. Strength mixes the mask in, divided by
// its own mean so the picture keeps its level. The pixel's coverage of each phosphor is worked
// out exactly across, and on a 4 point grid down for the dots' rows.
kernel void crt_mask(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     constant float *p [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float T = p[1], s = p[2];
    bool dots = p[0] < 0.5;
    float3 cover = 0.0;
    // The shadow mask's dots: 3 phosphor columns per triad, rows a triad tall with a gap of a
    // quarter of it, alternate triads shifted half a row. Mean coverage 0.75 / 3.
    float rowOn = dots ? 0.75 : 1.0;
    for (int j = 0; j < 4; j++) {
        float y = float(gid.y) + (float(j) + 0.5) / 4.0;
        float a = float(gid.x) / T, b = (float(gid.x) + 1.0) / T;
        for (int ch = 0; ch < 3; ch++) {
            float lo = float(ch) / 3.0, hi = float(ch + 1) / 3.0;
            if (dots) {
                // The triad under the pixel's center sets the row offset.
                float triad = floor((float(gid.x) + 0.5) / T);
                float fy = fract(y / T + 0.5 * fmod(triad, 2.0));
                if (fy >= rowOn) continue;
            }
            cover[ch] += crt_cover(a, b, lo, hi) * 0.25;
        }
    }
    // Rounding in the coverage leaves a few parts in a hundred thousand on a phosphor the pixel
    // does not touch: a phosphor is lit or it is not.
    cover = select(cover, float3(0.0), cover < 1e-3);
    float3 m = (1.0 - s) + s * cover / (rowOn / 3.0);
    dst.write(float4(src.read(gid).rgb * m, 1.0), gid);
}

// 4 Glow, first step: a quarter size copy (4 by 4 box average) for the wide blurs.
kernel void crt_glow_down(texture2d<float, access::read> src [[texture(0)]],
                          texture2d<float, access::write> dst [[texture(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float3 s = 0.0;
    for (uint j = 0; j < 4; j++)
        for (uint i = 0; i < 4; i++) s += src.read(gid * 4 + uint2(i, j)).rgb;
    dst.write(float4(s / 16.0, 1.0), gid);
}

// One pass of a separable Gaussian. p: direction x, direction y, sigma (px of this texture).
kernel void crt_blur(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     constant float *p [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    int W = int(dst.get_width()), H = int(dst.get_height());
    if (int(gid.x) >= W || int(gid.y) >= H) return;
    float sigma = max(p[2], 0.3);
    int r = int(ceil(3.0 * sigma));
    int2 dir = int2(int(p[0]), int(p[1]));
    float3 s = 0.0;
    float wsum = 0.0;
    for (int i = -r; i <= r; i++) {
        int2 q = clamp(int2(gid) + dir * i, int2(0), int2(W - 1, H - 1));
        float w = exp(-0.5 * float(i * i) / (sigma * sigma));
        s += src.read(uint2(q)).rgb * w;
        wsum += w;
    }
    dst.write(float4(s / wsum, 1.0), gid);
}

// 4 Glow: the diffusion mixed in, the halation added. p: diffusion weight, halation weight.
kernel void crt_glow(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float> diffused [[texture(1)]],
                     texture2d<float> halo [[texture(2)]],
                     texture2d<float, access::write> dst [[texture(3)]],
                     constant float *p [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float3 c = src.read(gid).rgb;
    float3 d = diffused.sample(crt_linear, uv).rgb;
    float3 h = halo.sample(crt_linear, uv).rgb;
    dst.write(float4(mix(c, d, p[0]) + p[1] * h, 1.0), gid);
}

// 6 Glass, then the encode. p: glass on, tint, room reflection, black glow, 1 / encode gamma.
// The tint passes 1 - tint of the picture. The room's light reflects off the front surface
// (a lift the tint does not touch). The black glow is light scattered in the glass, read from
// the wide blur and dimmed by the tint.
kernel void crt_glass(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<float> halo [[texture(1)]],
                      texture2d<float, access::write> dst [[texture(2)]],
                      constant float *p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float3 c = src.read(gid).rgb;
    if (p[0] > 0.5) {
        float t = 1.0 - p[1];
        float3 glow = 0.0;
        if (p[3] > 0.0) {
            float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
            glow = halo.sample(crt_linear, uv).rgb;
        }
        c = c * t + p[3] * glow * t + p[2];
    }
    dst.write(float4(pow(max(c, 0.0), float3(p[4])), 1.0), gid);
}
