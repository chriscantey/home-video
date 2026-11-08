#include <metal_stdlib>
using namespace metal;

// The VCR on-screen display, composited into the YIQ raster before L9. The text texture is
// premultiplied RGBA8 at character-generator scale; each of its pixels covers scale by scale
// raster pixels (nearest neighbor), so the letters stay blocky.

struct OSDParams { uint originX, originY, scale; };

kernel void osd_overlay(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::read> text [[texture(1)]],
                        texture2d<float, access::write> dst [[texture(2)]],
                        constant OSDParams &p [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 v = src.read(gid);
    if (gid.x >= p.originX && gid.y >= p.originY) {
        uint2 t = uint2((gid.x - p.originX) / p.scale, (gid.y - p.originY) / p.scale);
        if (t.x < text.get_width() && t.y < text.get_height()) {
            float4 c = text.read(t);
            // Premultiplied: c.r is luma times coverage. White text is Y 1, the edge Y 0,
            // and the deck's character generator has no chroma.
            v.rgb = v.rgb * (1.0 - c.a) + float3(c.r, 0.0, 0.0);
        }
    }
    dst.write(v, gid);
}
