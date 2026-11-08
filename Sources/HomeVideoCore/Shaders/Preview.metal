#include <metal_stdlib>
using namespace metal;

// Preview: draws the working raster as one quad. The renderer sets the viewport to the
// 4:3 display rect inside the drawable, so the shader only has to cover the viewport.
struct PreviewVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex PreviewVertexOut preview_vertex(uint vid [[vertex_id]])
{
    // Triangle strip: (0,0) (1,0) (0,1) (1,1) in uv space.
    float2 uv = float2(float(vid & 1u), float((vid >> 1) & 1u));
    PreviewVertexOut o;
    o.position = float4(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, 0.0, 1.0);
    o.uv = uv;
    return o;
}

fragment float4 preview_fragment(PreviewVertexOut in [[stage_in]],
                                 texture2d<float, access::sample> raster [[texture(0)]])
{
    // Linear filtering, no sharpening.
    constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);
    return float4(raster.sample(linearClamp, in.uv).rgb, 1.0);
}

// The Display zoom: a window of the Display canvas, x, y, width and height in uv,
// drawn over the whole viewport, so the preview can come up close to the mask and the
// scanlines. Past 2 to 1 the canvas pixels are drawn as squares, as a loupe shows them.
fragment float4 preview_display_zoom(PreviewVertexOut in [[stage_in]],
                                     texture2d<float, access::sample> canvas [[texture(0)]],
                                     constant float *window [[buffer(0)]])
{
    constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);
    constexpr sampler nearestClamp(coord::normalized, address::clamp_to_edge, filter::nearest);
    float2 uv = float2(window[0], window[1]) + in.uv * float2(window[2], window[3]);
    float3 c = window[4] > 0.5 ? canvas.sample(nearestClamp, uv).rgb : canvas.sample(linearClamp, uv).rgb;
    return float4(c, 1.0);
}
