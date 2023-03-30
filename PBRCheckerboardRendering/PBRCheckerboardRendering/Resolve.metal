#include <metal_stdlib>
using namespace metal;

struct Output {
    float4 position [[position]];
    float2 texcoord;
};

fragment half4 resolveFS(Output input [[stage_in]],
                         texture2d_ms<half> texPrev [[texture(0)]],
                         texture2d_ms<half> texCurrent [[texture(1)]],
                         constant uint& isOdd [[buffer(0)]])
{
    const ushort2 coord = (ushort2)input.position.xy;
    half4 color;
    if ((coord.x ^ coord.y ^ isOdd) & 1)
    {
        color = texPrev.read(coord / 2, coord.y & 1);
    }
    else
    {
        color = texCurrent.read(coord / 2, coord.y & 1);
    }
    return color;
}
