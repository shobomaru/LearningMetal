#include <metal_stdlib>
using namespace metal;

kernel void stretchCS(ushort2 dtid [[thread_position_in_grid]],
                      texture2d<half> tex [[texture(0)]],
                      texture2d<half, access::read_write> texOut[[texture(1)]],
                      constant float& threshold [[buffer(0)]])
{
    constexpr sampler ss(filter::linear, address::clamp_to_edge);
    const float2 texSize = float2(texOut.get_width() - 1, texOut.get_height() - 1);
    float2 texcoord = float2(dtid) / texSize;
    half4 color = tex.sample(ss, texcoord);
    color -= threshold;
    texOut.write(color, dtid);
}

kernel void addBlendCS(ushort2 dtid [[thread_position_in_grid]],
                       texture2d<half> tex [[texture(0)]],
                       texture2d<half, access::read_write> texOut[[texture(1)]])
{
    constexpr sampler ss(filter::linear, address::clamp_to_edge);
    const float2 texSize = float2(texOut.get_width() - 1, texOut.get_height() - 1);
    float2 texcoord = float2(dtid) / texSize;
    half4 color = tex.sample(ss, texcoord);
    color += texOut.read(dtid);
    texOut.write(color, dtid);
}

kernel void blurCS(ushort2 dtid [[thread_position_in_grid]],
                      texture2d<half> tex [[texture(0)]],
                      texture2d<half, access::read_write> texOut[[texture(1)]])
{
    const short2 texSize = short2(texOut.get_width() - 1, texOut.get_height() - 1);
    half4 color = 0;
    for (short y = -3; y <= 3; ++y) {
        for (short x = -3; x <= 3; ++x) {
            const short2 idx = clamp(short2(dtid) + short2(x, y), short2(0, 0), texSize);
            color += tex.read(ushort2(idx));
        }
    }
    color /= 49.0;
    texOut.write(color, dtid);
}
