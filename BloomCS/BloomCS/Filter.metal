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

// [numthreads(8,8,1)]
kernel void blurCS(ushort2 dtid [[thread_position_in_grid]],
                   ushort2 gtid [[thread_position_in_threadgroup]],
                   texture2d<half> tex [[texture(0)]],
                   texture2d<half, access::read_write> texOut[[texture(1)]])
{
    const short2 texSize = short2(texOut.get_width() - 1, texOut.get_height() - 1);
    half4 color = 0;
#if 1
    threadgroup half4 cachedColor[8 + 6][8 + 6];
    for (ushort y = gtid.y; y < 8 + 6; y += 8) {
        for (ushort x = gtid.x; x < 8 + 6; x += 8) {
            const short2 idx = clamp(short2(dtid) - short2(gtid) + short2(x, y) - 3, short2(0, 0), texSize);
            cachedColor[y][x] = tex.read(ushort2(idx));
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    
    for (ushort y = 0; y < 7; ++y) {
        for (ushort x = 0; x < 7; ++x) {
            color += cachedColor[gtid.y + y][gtid.x + x];
        }
    }
#else
    for (short y = -3; y <= 3; ++y) {
            for (short x = -3; x <= 3; ++x) {
                const short2 idx = clamp(short2(dtid) + short2(x, y), short2(0, 0), texSize);
                color += tex.read(ushort2(idx));
            }
        }
#endif
    color /= 49.0;
    texOut.write(color, dtid);
}
