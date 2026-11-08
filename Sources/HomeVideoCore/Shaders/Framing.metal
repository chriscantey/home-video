#include <metal_stdlib>
using namespace metal;

// Framing: maps the source picture onto the 720 by 480 working raster.
// sourceRect is the normalized region of the source to sample (x, y, w, h).
// destRect is the normalized region of the raster the picture fills; outside it is black.
struct FramingParams {
    float4 sourceRect;
    float4 destRect;
    uint rotation;   // clockwise display rotation, degrees; mirrors FramingMath.bufferPoint
};

inline float2 buffer_point(float2 p, uint rotation) {
    switch (rotation) {
        case 90u: return float2(p.y, 1.0 - p.x);
        case 180u: return float2(1.0 - p.x, 1.0 - p.y);
        case 270u: return float2(1.0 - p.y, p.x);
        default: return p;
    }
}

kernel void framing(texture2d<float, access::sample> src [[texture(0)]],
                    texture2d<float, access::write> dst [[texture(1)]],
                    constant FramingParams &p [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]])
{
    uint w = dst.get_width();
    uint h = dst.get_height();
    if (gid.x >= w || gid.y >= h) return;

    constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);

    float2 uv = (float2(gid) + 0.5) / float2(w, h);
    float2 local = (uv - p.destRect.xy) / p.destRect.zw;
    if (any(local < 0.0) || any(local > 1.0)) {
        dst.write(float4(0.0, 0.0, 0.0, 1.0), gid);
        return;
    }
    float2 suv = p.sourceRect.xy + local * p.sourceRect.zw;
    // Box prefilter over the output pixel's footprint in source texels (up to 8 by 8
    // bilinear taps), so a 1080p source decimated 2.67:1 does not alias. Worked out in the
    // displayed (rotated) picture, each tap mapped back to the buffer. At 1:1 it is a
    // single tap.
    float2 bufSize = float2(src.get_width(), src.get_height());
    float2 shownSize = (p.rotation == 90u || p.rotation == 270u) ? bufSize.yx : bufSize;
    float2 foot = p.sourceRect.zw / p.destRect.zw / float2(w, h) * shownSize;
    int2 n = int2(clamp(ceil(foot - 1e-3), 1.0, 8.0));
    float2 stepUV = (foot / float2(n)) / shownSize;
    float2 origin = suv - stepUV * (float2(n) - 1.0) * 0.5;
    float3 acc = 0.0;
    for (int j = 0; j < n.y; j++) {
        for (int i = 0; i < n.x; i++) {
            acc += src.sample(linearClamp, buffer_point(origin + stepUV * float2(i, j), p.rotation)).rgb;
        }
    }
    dst.write(float4(acc / float(n.x * n.y), 1.0), gid);
}
