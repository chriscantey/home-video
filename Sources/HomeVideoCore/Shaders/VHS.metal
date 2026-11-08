#include <metal_stdlib>
using namespace metal;

// The VHS layers L1 to L9. Working textures are RGBA16Float holding YIQ (Y in r, I in g,
// Q in b) between L1 and L9. All filter coefficients are designed on the CPU
// (Filters.swift) and arrive in uniform buffers; the kernels only run them.
//
// The shared part (hash, biquad step) sits at the top of this one file rather than in a
// separate header: ShaderLibrary's runtime fallback concatenates the .metal sources, which a
// relative #include would not survive.

// MARK: - Shared

// PCG hash (O'Neill's RXS-M-XS step), the same one Hash.pcg runs on the CPU.
inline uint pcg_hash(uint v) {
    uint state = v * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

// White noise in -1...1 from (seed, layer, frame, field, line, sample). Uniform, so its
// standard deviation is 1/sqrt(3); the CPU folds that into the amplitudes it sends.
inline float noise_hash(uint seed, uint layer, uint frame, uint field, uint line, uint sample) {
    uint h = pcg_hash(seed ^ 0x9E3779B9u);
    h = pcg_hash(h ^ layer);
    h = pcg_hash(h ^ frame);
    h = pcg_hash(h ^ field);
    h = pcg_hash(h ^ line);
    h = pcg_hash(h ^ sample);
    return float(h) * (2.0 / 4294967295.0) - 1.0;
}

struct Biquad { float b0, b1, b2, a1, a2; };

// Transposed direct form II. s holds the two state values.
inline float bq_step(constant Biquad &c, thread float2 &s, float x) {
    float y = c.b0 * x + s.x;
    s.x = c.b1 * x - c.a1 * y + s.y;
    s.y = c.b2 * x - c.a2 * y;
    return y;
}

// State as if the input had been x forever (no startup ramp at the line's left edge).
// Returns the steady output, which is the next section's steady input.
inline float bq_prime(constant Biquad &c, thread float2 &s, float x) {
    float g = (c.b0 + c.b1 + c.b2) / (1.0 + c.a1 + c.a2);
    float y = g * x;
    s.y = c.b2 * x - c.a2 * y;
    s.x = c.b1 * x - c.a1 * y + s.y;
    return y;
}

inline float3 mat3_apply(constant float *m, float3 v) {
    return float3(m[0] * v.x + m[1] * v.y + m[2] * v.z,
                  m[3] * v.x + m[4] * v.y + m[5] * v.z,
                  m[6] * v.x + m[7] * v.y + m[8] * v.z);
}

// Linear interpolation along row y at fractional x. Outside the line: clamp, or black.
inline float3 row_sample(texture2d<float, access::read> t, float x, uint y, bool blackOutside) {
    int w = int(t.get_width());
    float fx = floor(x);
    int x0 = int(fx);
    float f = x - fx;
    if (blackOutside && (x < 0.0 || x > float(w - 1))) return float3(0.0);
    int a = clamp(x0, 0, w - 1);
    int b = clamp(x0 + 1, 0, w - 1);
    return mix(t.read(uint2(a, y)).rgb, t.read(uint2(b, y)).rgb, f);
}

// MARK: - L1 and L9 conversion

kernel void yiq_encode(texture2d<float, access::read> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       constant float *m [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    dst.write(float4(mat3_apply(m, src.read(gid).rgb), 1.0), gid);
}

struct FieldsParams {
    uint mode;      // 0 weave, 1 bob, 2 field blend
    uint temporal;  // weave: even lines (the first field) come from the previous frame
    uint clampRGB;
};

// L9: YIQ to RGB, then the capture software's deinterlace.
kernel void capture_fields(texture2d<float, access::read> cur [[texture(0)]],
                           texture2d<float, access::read> prev [[texture(1)]],
                           texture2d<float, access::write> dst [[texture(2)]],
                           constant float *m [[buffer(0)]],
                           constant FieldsParams &p [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float3 yiq;
    if (p.mode == 1u) {
        // Bob: keep the second (latest) field, the odd lines, and rebuild the even lines
        // by averaging the field lines above and below.
        if ((gid.y & 1u) == 1u) {
            yiq = cur.read(gid).rgb;
        } else {
            uint below = min(gid.y + 1u, h - 1u);
            uint above = gid.y == 0u ? below : gid.y - 1u;
            yiq = 0.5 * (cur.read(uint2(gid.x, above)).rgb + cur.read(uint2(gid.x, below)).rgb);
        }
    } else if (p.mode == 2u) {
        // Field blend: each line a quarter of the lines above and below (the other field)
        // and half its own, so the two fields mix without a vertical shift.
        uint below = min(gid.y + 1u, h - 1u);
        uint above = gid.y == 0u ? below : gid.y - 1u;
        yiq = 0.5 * cur.read(gid).rgb + 0.25 * (cur.read(uint2(gid.x, above)).rgb + cur.read(uint2(gid.x, below)).rgb);
    } else {
        bool fromPrev = p.temporal != 0u && (gid.y & 1u) == 0u;
        yiq = fromPrev ? prev.read(gid).rgb : cur.read(gid).rgb;
    }
    float3 rgb = mat3_apply(m, yiq);
    if (p.clampRGB != 0u) rgb = clamp(rgb, 0.0, 1.0);
    dst.write(float4(rgb, 1.0), gid);
}

// MARK: - L2 composite link

struct CompositeParams {
    float fsc;        // subcarrier, cycles per sample (3.579545 / 13.5)
    uint separator;   // 0 notch, 1 one line comb, 2 two line comb
    uint frame;       // carrier phase flips per frame
};

inline float carrier_phase(constant CompositeParams &p, uint x, uint y) {
    // 227.5 cycles per line: the phase inverts from one line of a field to the next, and
    // between frames.
    float linePhase = 0.5 * float((y >> 1) + (p.frame & 1u));
    return 2.0 * M_PI_F * (p.fsc * float(x) + linePhase);
}

inline float composite_at(texture2d<float, access::read> src, constant CompositeParams &p, uint x, uint y) {
    float3 yiq = src.read(uint2(x, y)).rgb;
    float ph = carrier_phase(p, x, y);
    return yiq.x + yiq.y * cos(ph) + yiq.z * sin(ph);
}

// One thread per line. sections: [0] luma notch at fsc, [1] chroma demodulation lowpass.
kernel void composite_link(texture2d<float, access::read> src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           constant CompositeParams &p [[buffer(0)]],
                           constant Biquad *sections [[buffer(1)]],
                           uint line [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (line >= h) return;
    // Neighbors in the same field (two raster lines away), clamped at the frame edges.
    uint up = line >= 2u ? line - 2u : line + 2u;
    uint down = line + 2u < h ? line + 2u : line - 2u;

    float2 sN = 0.0, sI = 0.0, sQ = 0.0, sK0 = 0.0, sK1 = 0.0, sK2 = 0.0, sK3 = 0.0;
    float c0 = composite_at(src, p, 0u, line);
    bq_prime(sections[0], sN, c0);
    // The 2-line comb's band split (sections[2] to [5], two 3rd order Butterworths in series):
    // only the comb's high band is chroma, so vertical luma detail below the split stays luma.
    float k0 = 0.25 * (2.0 * c0 - composite_at(src, p, 0u, up) - composite_at(src, p, 0u, down));
    bq_prime(sections[5], sK3, bq_prime(sections[4], sK2, bq_prime(sections[3], sK1, bq_prime(sections[2], sK0, k0))));
    for (uint x = 0; x < w; x++) {
        float c = composite_at(src, p, x, line);
        float luma, chroma;
        if (p.separator == 0u) {
            luma = bq_step(sections[0], sN, c);
            chroma = c - luma;
        } else if (p.separator == 1u) {
            chroma = 0.5 * (c - composite_at(src, p, x, up));
            luma = c - chroma;
        } else {
            float k = 0.25 * (2.0 * c - composite_at(src, p, x, up) - composite_at(src, p, x, down));
            chroma = k - bq_step(sections[5], sK3, bq_step(sections[4], sK2,
                                 bq_step(sections[3], sK1, bq_step(sections[2], sK0, k))));
            luma = c - chroma;
        }
        float ph = carrier_phase(p, x, line);
        float i = bq_step(sections[1], sI, 2.0 * chroma * cos(ph));
        float q = bq_step(sections[1], sQ, 2.0 * chroma * sin(ph));
        dst.write(float4(luma, i, q, 1.0), uint2(x, line));
    }
}

// MARK: - L3 luma bandwidth

// One thread per line. sections: the 3rd order Butterworth (biquad, then one pole).
kernel void luma_lowpass(texture2d<float, access::read> src [[texture(0)]],
                         texture2d<float, access::write> dst [[texture(1)]],
                         constant Biquad *sections [[buffer(0)]],
                         uint line [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (line >= h) return;
    float2 s0 = 0.0, s1 = 0.0;
    float y0 = src.read(uint2(0, line)).r;
    bq_prime(sections[1], s1, bq_prime(sections[0], s0, y0));
    for (uint x = 0; x < w; x++) {
        float4 v = src.read(uint2(x, line));
        v.r = bq_step(sections[1], s1, bq_step(sections[0], s0, v.r));
        dst.write(v, uint2(x, line));
    }
}

struct EmphasisParams {
    float c;        // the emphasis one pole lowpass, L += c (x - L)
    float gSmall;   // HF boost (gain - 1) for small signals
    float gLarge;   // HF boost for large signals
    float knee;     // envelope level where the boost is halfway between the two
    float attack;   // envelope follower rates per sample
    float release;
    float clipHi;   // FM white clip, Y units
    float clipLo;   // FM dark clip, Y units
    float soft;     // width of the soft knee below each clip, Y units
    float moire;    // FM sideband beat amplitude at full HF level, Y (0 off)
    uint frame;
};

inline float emph_gain(constant EmphasisParams &p, float env) {
    float r = env / p.knee;
    return p.gLarge + (p.gSmall - p.gLarge) / (1.0 + r * r);
}

inline float emph_env(constant EmphasisParams &p, float env, float a) {
    return env + (a > env ? p.attack : p.release) * (a - env);
}

// Fast math tanh overflows its exponential and returns NaN for arguments past about 44, which
// the 32 dB boost top reaches. Past 20 tanh is 1 in float, so it is taken as 1 there and
// every value under 20 runs through tanh itself.
inline float tanh_safe(float u) { return u > 20.0 ? 1.0 : tanh(u); }
inline float3 tanh_safe(float3 u) { return select(tanh(u), float3(1.0), u > 20.0); }

inline float soft_clip(float e, float hi, float lo, float k) {
    if (e > hi - k) return hi - k + k * tanh_safe((e - (hi - k)) / k);
    if (e < lo + k) return lo + k - k * tanh_safe(((lo + k) - e) / k);
    return e;
}

// L3 with emphasis, one thread per line. Record: a nonlinear pre-emphasis (a high shelf whose
// boost falls as the local HF level rises), then the FM deviation's white and dark clip, then
// the tape's luma lowpass. Playback: the matching de-emphasis, the exact inverse of the
// pre-emphasis when nothing was clipped or filtered. The encoder takes its level from a
// lowpassed copy of the input, the decoder from its own output, so both see nearly the same
// envelope. sections: [0,1] the luma lowpass.
kernel void luma_record(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant Biquad *sections [[buffer(0)]],
                        constant EmphasisParams &p [[buffer(1)]],
                        uint line [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (line >= h) return;
    float2 s0 = 0.0, s1 = 0.0, r0 = 0.0, r1 = 0.0;
    float y0 = src.read(uint2(0, line)).r;
    bq_prime(sections[1], s1, bq_prime(sections[0], s0, y0));
    bq_prime(sections[1], r1, bq_prime(sections[0], r0, y0));
    float c = p.c, k = 1.0 - c;
    float L = y0, Lref = y0, env = 0.0;   // encoder
    float Ld = y0, envd = 0.0;            // decoder
    for (uint x = 0; x < w; x++) {
        float4 v = src.read(uint2(x, line));
        float xi = v.r;
        // Pre-emphasis.
        float g = emph_gain(p, env);
        float e = xi + g * k * (xi - L);
        L += c * (xi - L);
        float xl = bq_step(sections[1], r1, bq_step(sections[0], r0, xi));
        float hl = k * (xl - Lref);
        Lref += c * (xl - Lref);
        env = emph_env(p, env, abs(hl));
        // Deviation clip, then the tape.
        e = soft_clip(e, p.clipHi, p.clipLo, p.soft);
        float el = bq_step(sections[1], s1, bq_step(sections[0], s0, e));
        // De-emphasis: solve el = y + gd k (y - Ld) for y.
        float G = emph_gain(p, envd) * k;
        float y = (el + G * Ld) / (1.0 + G);
        envd = emph_env(p, envd, abs(k * (y - Ld)));
        Ld += c * (y - Ld);
        if (p.moire > 0.0) {
            // Folded lower sideband: a beat gated by the local HF level, its phase stepping a
            // quarter turn per line and flipping per frame, so it reads as a diamond hatch.
            float gate = min(envd / 0.1, 1.0);
            float ph = 2.0 * M_PI_F * (0.3 * float(x) + 0.25 * float(line >> 1) + 0.5 * float(p.frame & 1u));
            y += p.moire * gate * cos(ph);
        }
        v.r = y;
        dst.write(v, uint2(x, line));
    }
}

// MARK: - L4 color-under chroma

// Pass A, one thread per line: the 2nd order Butterworth on I and on Q.
kernel void chroma_lowpass(texture2d<float, access::read> src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           constant Biquad *sections [[buffer(0)]],
                           uint line [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (line >= h) return;
    float2 sI = 0.0, sQ = 0.0;
    float4 first = src.read(uint2(0, line));
    bq_prime(sections[0], sI, first.g);
    bq_prime(sections[0], sQ, first.b);
    for (uint x = 0; x < w; x++) {
        float4 v = src.read(uint2(x, line));
        v.g = bq_step(sections[0], sI, v.g);
        v.b = bq_step(sections[0], sQ, v.b);
        dst.write(v, uint2(x, line));
    }
}

struct ChromaParams {
    float delay;        // px, chroma arrives this late
    uint blend;         // 1H comb: average with the previous line of the same field
    float phaseRadians; // peak per line hue error
    uint seed;
    uint frame;
    float lumaDelay;    // px, the chroma filter's group delay, which the Y delay line equalizes
    uint droop;         // vertical chroma delay, field lines
    float gain;         // chroma gain
};

// Pass B, one thread per pixel (a gather): delay, vertical delay (droop), vertical blend
// (when L5 does not do it after the noise), per line phase error, chroma gain.
// Y comes from `luma` (the unfiltered input, through the delay line), I and Q from the
// lowpassed `chroma`.
kernel void chroma_delay_blend(texture2d<float, access::read> luma [[texture(0)]],
                               texture2d<float, access::read> chroma [[texture(1)]],
                               texture2d<float, access::write> dst [[texture(2)]],
                               constant ChromaParams &p [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    // The chroma filter's own group delay is already in `chroma`. A deck's Y delay line
    // equalizes it and sync is regenerated with Y, so the picture does not move: here chroma
    // is read ahead by the group delay instead, and the net lag is the explicit delay.
    float sx = float(gid.x) - p.delay + p.lumaDelay;
    uint cy = gid.y >= 2u * p.droop ? gid.y - 2u * p.droop : (gid.y & 1u);
    float2 iq = row_sample(chroma, sx, cy, false).yz;
    if (p.blend != 0u && cy >= 2u) {
        iq = 0.5 * (iq + row_sample(chroma, sx, cy - 2u, false).yz);
    }
    iq *= p.gain;
    if (p.phaseRadians > 0.0) {
        // Slow across lines: value noise on knots every 8 field lines, per field and frame.
        uint field = gid.y & 1u;
        float fl = float(gid.y >> 1) / 8.0;
        uint k = uint(fl);
        float f = fl - float(k);
        f = f * f * (3.0 - 2.0 * f);
        float a = noise_hash(p.seed, 41u, p.frame, field, k, 0u);
        float b = noise_hash(p.seed, 41u, p.frame, field, k + 1u, 0u);
        float theta = p.phaseRadians * mix(a, b, f);
        float c = cos(theta), s = sin(theta);
        iq = float2(c * iq.x - s * iq.y, s * iq.x + c * iq.y);
    }
    float y = luma.read(gid).r;
    dst.write(float4(y, iq, 1.0), gid);
}

// MARK: - L5 tape noise

struct NoiseParams {
    float lumaAmp;    // white amplitude, already divided by the shaping filter's noise gain
    float chromaAmp;
    uint seed;
    uint frame;
    float fieldGain;  // the second field's head: its noise is this much stronger
};

// One thread per line. sections: [0,1] the luma lowpass (3rd order), [2] the chroma lowpass.
kernel void tape_noise(texture2d<float, access::read> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       constant NoiseParams &p [[buffer(0)]],
                       constant Biquad *sections [[buffer(1)]],
                       uint line [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (line >= h) return;
    uint field = line & 1u;
    uint fl = line >> 1;
    float2 sy0 = 0.0, sy1 = 0.0, si = 0.0, sq = 0.0;
    float prev = 0.0;
    // Run the shaping filters for 64 samples of the blanking before the line, so the noise
    // is already at its steady level at the left edge.
    for (int x = -64; x < int(w); x++) {
        uint n = uint(x + 64);
        float wy = noise_hash(p.seed, 50u, p.frame, field, fl, n);
        float wi = noise_hash(p.seed, 51u, p.frame, field, fl, n);
        float wq = noise_hash(p.seed, 52u, p.frame, field, fl, n);
        // FM noise rises with frequency: first difference, then the playback lowpass.
        float ny = bq_step(sections[1], sy1, bq_step(sections[0], sy0, wy - prev));
        prev = wy;
        float ni = bq_step(sections[2], si, wi);
        float nq = bq_step(sections[2], sq, wq);
        if (x < 0) continue;
        float4 v = src.read(uint2(x, line));
        float fg = field == 1u ? p.fieldGain : 1.0;
        v.r += fg * p.lumaAmp * ny;
        v.g += fg * p.chromaAmp * ni;
        v.b += fg * p.chromaAmp * nq;
        dst.write(v, uint2(x, line));
    }
}

// MARK: - L6 edge halo

struct HaloParams {
    float peaking;    // k in Y + k (Y - lowpass Y)
    float ring;       // mix toward the notched signal
    float coring;     // threshold, Y units
};

// One thread per line. sections: [0,1] peaking lowpass, [2] ring notch, [3,4] coring lowpass.
kernel void edge_halo(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant HaloParams &p [[buffer(0)]],
                      constant Biquad *sections [[buffer(1)]],
                      uint line [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (line >= h) return;
    float2 a0 = 0.0, a1 = 0.0, n0 = 0.0, c0 = 0.0, c1 = 0.0;
    float y0 = src.read(uint2(0, line)).r;
    bq_prime(sections[1], a1, bq_prime(sections[0], a0, y0));
    bq_prime(sections[2], n0, y0);
    bq_prime(sections[4], c1, bq_prime(sections[3], c0, y0));
    for (uint x = 0; x < w; x++) {
        float4 v = src.read(uint2(x, line));
        float y = v.r;
        float lp = bq_step(sections[1], a1, bq_step(sections[0], a0, y));
        float peaked = y + p.peaking * (y - lp);
        float notched = bq_step(sections[2], n0, peaked);
        float rung = peaked + p.ring * (notched - peaked);
        float base = bq_step(sections[4], c1, bq_step(sections[3], c0, rung));
        float hf = rung - base;
        float cored = sign(hf) * max(abs(hf) - p.coring, 0.0);
        v.r = base + cored;
        dst.write(v, uint2(x, line));
    }
}

// MARK: - L7 head switch and L8 time base (per line shifts, gathers)

struct HeadSwitchParams {
    float noise;      // burst amplitude on the band lines
    float transient;  // extra shift at the start of a shifted span, as a fraction of the shift
    float transientLength; // px
    uint seed;
    uint frame;
};

// One thread per pixel. shift[y] (px, 0 outside the band) and start[y] (px where the shift
// begins on that line) come from the CPU. Shifted content moves right; the gap at the left
// of the span is blanking (black).
kernel void head_switch(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant HeadSwitchParams &p [[buffer(0)]],
                        constant float *shift [[buffer(1)]],
                        constant float *start [[buffer(2)]],
                        uint2 gid [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float s = shift[gid.y];
    float x = float(gid.x);
    if (s == 0.0 || x < start[gid.y]) {
        dst.write(src.read(gid), gid);
        return;
    }
    float d = x - start[gid.y];
    float t = max(1.0 - d / max(p.transientLength, 1.0), 0.0);
    float total = s * (1.0 + p.transient * t * t * t);
    float3 v = row_sample(src, x - total, gid.y, true);
    v.x += p.noise * noise_hash(p.seed, 70u, p.frame, gid.y & 1u, gid.y >> 1, gid.x);
    dst.write(float4(v, 1.0), gid);
}

// MARK: - Frame: blanking and H offset

struct FrameParams {
    float left;       // first active sample
    float right;      // one past the last active sample
    float offset;     // the picture moves left by this many samples
    float topRows;    // rows above this are blanked
};

// One thread per pixel. Outside the window: setup black with no chroma.
kernel void frame_blanking(texture2d<float, access::read> src [[texture(0)]],
                           texture2d<float, access::write> dst [[texture(1)]],
                           constant FrameParams &p [[buffer(0)]],
                           uint2 gid [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float x = float(gid.x);
    float3 v = float3(0.0);
    if (x >= p.left && x < p.right && float(gid.y) >= p.topRows) v = row_sample(src, x + p.offset, gid.y, false);
    dst.write(float4(v, 1.0), gid);
}

// One thread per pixel: line y is displaced right by offset[y] px, edges clamped.
kernel void time_base(texture2d<float, access::read> src [[texture(0)]],
                      texture2d<float, access::write> dst [[texture(1)]],
                      constant float *offset [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float3 v = row_sample(src, float(gid.x) - offset[gid.y], gid.y, false);
    dst.write(float4(v, 1.0), gid);
}

// MARK: - Dropouts

struct DropoutParams {
    uint seed;
    uint frame;
};

// One thread per pixel. ev[y] = (start, end, kind, unused): kind 1 copies the span from the
// previous line of the same field (the DOC), kind 2 is a raw white fleck with soft ends.
kernel void dropouts(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     constant float4 *ev [[buffer(0)]],
                     constant DropoutParams &p [[buffer(1)]],
                     uint2 gid [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float4 e = ev[gid.y];
    float x = float(gid.x);
    float4 v = src.read(gid);
    if (e.z > 0.5 && x >= e.x && x < e.y) {
        if (e.z < 1.5) {
            uint above = gid.y >= 2u ? gid.y - 2u : gid.y + 2u;
            v = src.read(uint2(gid.x, above));
        } else {
            float ramp = clamp(min(x - e.x, e.y - x) / 3.0, 0.0, 1.0);
            float n = 0.05 * noise_hash(p.seed, 95u, p.frame, gid.y & 1u, gid.y >> 1, gid.x);
            v.rgb = mix(v.rgb, float3(1.0 + n, 0.0, 0.0), ramp);
        }
    }
    dst.write(v, gid);
}

// MARK: - Levels

struct LevelsParams {
    float black[2];   // per field, Y
    float gain[2];    // per field
    float clip;       // Y, 0 for no clip
    float soft;       // knee width under the clip
    float bloom;      // share of the clipped excess spread to the neighbors
    float radius;     // bloom radius, px
};

inline float3 levels_at(texture2d<float, access::read> src, constant LevelsParams &p, int x, int y) {
    int w = int(src.get_width()), h = int(src.get_height());
    uint2 q = uint2(clamp(x, 0, w - 1), clamp(y, 0, h - 1));
    float3 v = src.read(q).rgb;
    uint f = q.y & 1u;
    return float3(p.black[f] + p.gain[f] * v.x, p.gain[f] * v.yz);
}

kernel void levels(texture2d<float, access::read> src [[texture(0)]],
                   texture2d<float, access::write> dst [[texture(1)]],
                   constant LevelsParams &p [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    int x = int(gid.x), y = int(gid.y);
    float3 v = levels_at(src, p, x, y);
    if (p.clip > 0.0) {
        float start = p.clip - p.soft;
        if (p.bloom > 0.0) {
            int r = int(p.radius);
            float sum = 0.0, wsum = 0.0;
            float s2 = 2.0 * (0.5 * p.radius) * (0.5 * p.radius);
            for (int dy = -1; dy <= 1; dy++) {
                for (int dx = -r; dx <= r; dx++) {
                    float wt = exp(-float(dx * dx + 4 * dy * dy) / s2);
                    sum += wt * max(levels_at(src, p, x + dx, y + dy).x - start, 0.0);
                    wsum += wt;
                }
            }
            v.x += p.bloom * sum / wsum;
        }
        if (v.x > start) v.x = start + p.soft * tanh_safe((v.x - start) / p.soft);
    }
    dst.write(float4(v, 1.0), gid);
}

// MARK: - Camera (RGB, before L1)

struct CameraParams {
    float sigma;      // soft focus Gaussian, px
    float exposure;   // linear gain on the gamma encoded RGB
    float bloom;
    float toe;
    float cb, cr;     // white balance shift, -0.5...0.5 scale
    float hueCos, hueSin;
    float vignette;
    float radius;
};

inline float cam_luma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

kernel void camera(texture2d<float, access::read> src [[texture(0)]],
                   texture2d<float, access::write> dst [[texture(1)]],
                   constant CameraParams &p [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]])
{
    int w = int(dst.get_width()), h = int(dst.get_height());
    if (int(gid.x) >= w || int(gid.y) >= h) return;
    int r = int(p.radius);
    float s2 = 2.0 * max(p.sigma, 0.05) * max(p.sigma, 0.05);
    float b2 = 2.0 * p.radius * p.radius * 0.5;
    float3 acc = 0.0;
    float wsum = 0.0, bsum = 0.0, bw = 0.0;
    for (int dy = -r; dy <= r; dy++) {
        for (int dx = -r; dx <= r; dx++) {
            uint2 q = uint2(clamp(int(gid.x) + dx, 0, w - 1), clamp(int(gid.y) + dy, 0, h - 1));
            float3 c = src.read(q).rgb;
            float d2 = float(dx * dx + dy * dy);
            float wt = exp(-d2 / s2);
            acc += wt * c;
            wsum += wt;
            float bwt = exp(-d2 / b2);
            bsum += bwt * max(cam_luma(c) * p.exposure - 0.85, 0.0);
            bw += bwt;
        }
    }
    float3 c = acc / wsum * p.exposure;
    c += p.bloom * bsum / bw;
    // Toe: c^2 (1 + t) / (c + t) keeps 0 and 1, flattens the shadows.
    c = max(c, 0.0);
    c = c * c * (1.0 + p.toe) / (c + p.toe + 1e-6);
    // Soft highlight clip per channel.
    float3 over = max(c - 0.85, 0.0);
    c = min(c, 0.85) + 0.15 * tanh_safe(over / 0.15);
    // White balance in Y Cb Cr (Rec. 601).
    float y = cam_luma(c);
    float cb = 0.564 * (c.b - y), cr = 0.713 * (c.r - y);
    float cb2 = p.hueCos * cb - p.hueSin * cr + p.cb;
    float cr2 = p.hueSin * cb + p.hueCos * cr + p.cr;
    float rr = y + cr2 / 0.713, bb = y + cb2 / 0.564;
    float gg = (y - 0.299 * rr - 0.114 * bb) / 0.587;
    c = float3(rr, gg, bb);
    // Vignette: falls as the squared distance from the center, 1 at the corners.
    float2 d = (float2(gid) + 0.5 - 0.5 * float2(w, h)) / (0.5 * float2(w, h));
    c *= 1.0 - p.vignette * 0.5 * dot(d, d);
    dst.write(float4(c, 1.0), gid);
}

// MARK: - L5 playback comb (after the noise)

struct CombParams {
    uint blend;       // average with the previous line of the same field
    float wobble;     // per line saturation wobble, fraction
    uint seed;
    uint frame;
};

// One thread per pixel: the playback 1H comb on I and Q, then a per line saturation wobble.
kernel void chroma_comb(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant CombParams &p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]])
{
    uint w = dst.get_width(), h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float4 v = src.read(gid);
    if (p.blend != 0u && gid.y >= 2u) v.yz = 0.5 * (v.yz + src.read(uint2(gid.x, gid.y - 2u)).yz);
    v.yz *= 1.0 + p.wobble * noise_hash(p.seed, 53u, p.frame, gid.y & 1u, gid.y >> 1, 0u);
    dst.write(v, gid);
}
