#include <metal_stdlib>
using namespace metal;

struct Output {
    float4 position [[position]];
    float2 texcoord;
};

vertex Output sceneVS(uint vid [[vertex_id]])
{
    float x = (vid & 2) ? 3.0 : -1.0;
    float y = (vid & 1) ? 3.0 : -1.0;
    Output output;
    output.position = float4(x, y, 0, 1);
    output.texcoord = (output.position.xy) * float2(1, -1) * 0.5 + 0.5;
    return output;
}

fragment half4 sceneFS(Output input [[stage_in]],
                       texture2d<half> tex [[texture(0)]])
{
    constexpr sampler ss(filter::linear, address::clamp_to_edge);
    half4 color = tex.sample(ss, input.texcoord);
    return color;
}
