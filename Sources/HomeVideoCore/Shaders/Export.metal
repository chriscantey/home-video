#include <metal_stdlib>
using namespace metal;

// Export: packs the RGBA16Float working raster into the bytes of an 8 bit output buffer.
// The raster holds gamma encoded R'G'B' in 0...1; the Y'CbCr matrix (kr, kb) comes from the
// host so the coefficients always match the matrix tag written on the file.
struct ConvertParams {
    float kr;
    float kb;
    uint width;
    uint height;
};

// Rounds to the nearest code and keeps 0 and 255 out, which are sync codes in 8 bit video.
static inline uchar video_code(float v)
{
    return uchar(clamp(floor(v + 0.5), 1.0, 254.0));
}

// 2vuy (kCVPixelFormatType_422YpCbCr8): per pixel pair the bytes Cb Y0 Cr Y1, video range
// (Y 16 to 235, Cb Cr 16 to 240). Chroma is cosited with the even pixel (the 601 siting), so
// a 4:2:2 source that the decoder upsampled comes back to its own chroma samples; averaging
// the pair instead costs about 2 dB of chroma PSNR on the bars. One thread per pair.
kernel void raster_to_2vuy(texture2d<float, access::read> src [[texture(0)]],
                           device uchar *dst [[buffer(0)]],
                           constant ConvertParams &p [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]])
{
    uint pairs = p.width / 2;
    if (gid.x >= pairs || gid.y >= p.height) return;

    // No RGB clamp here: the raster carries unclipped floats so that smeared chroma on a
    // saturated edge (out of RGB gamut, as on a real capture) still yields the true Y' and
    // chroma; only the final codes are clamped, in video_code. Clamping RGB first corrupts
    // Y' on the yellow to cyan edge of color bars (a 0.8 px luma edge reads as 18 px).
    float3 a = src.read(uint2(gid.x * 2, gid.y)).rgb;
    float3 b = src.read(uint2(gid.x * 2 + 1, gid.y)).rgb;
    float kg = 1.0 - p.kr - p.kb;
    float ya = p.kr * a.r + kg * a.g + p.kb * a.b;
    float yb = p.kr * b.r + kg * b.g + p.kb * b.b;
    float cb = (a.b - ya) / (2.0 * (1.0 - p.kb));
    float cr = (a.r - ya) / (2.0 * (1.0 - p.kr));

    uint o = gid.y * p.width * 2 + gid.x * 4;
    dst[o + 0] = video_code(128.0 + 224.0 * cb);
    dst[o + 1] = video_code(16.0 + 219.0 * ya);
    dst[o + 2] = video_code(128.0 + 224.0 * cr);
    dst[o + 3] = video_code(16.0 + 219.0 * yb);
}

// BGRA fallback: full range 8 bit B G R A; the writer then does the Y'CbCr conversion from
// the buffer's color tags. One thread per pixel.
kernel void raster_to_bgra(texture2d<float, access::read> src [[texture(0)]],
                           device uchar *dst [[buffer(0)]],
                           constant ConvertParams &p [[buffer(1)]],
                           uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= p.width || gid.y >= p.height) return;
    float3 c = clamp(src.read(gid).rgb, 0.0, 1.0);
    uint o = (gid.y * p.width + gid.x) * 4;
    dst[o + 0] = uchar(floor(c.b * 255.0 + 0.5));
    dst[o + 1] = uchar(floor(c.g * 255.0 + 0.5));
    dst[o + 2] = uchar(floor(c.r * 255.0 + 0.5));
    dst[o + 3] = 255;
}
